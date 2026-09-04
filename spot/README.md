# spot — keeping work off an ephemeral build box

A spot instance is cheap because AWS can take it back with about two minutes'
notice. This directory is the machinery that gets work off such a box before it
stops existing, and gets it back afterwards. It is project-independent: every
setting comes from the environment (see `spot.env.example`), and nothing here
knows what your project builds.

It came out of `avwohl/iospharo`, which is where the incidents cited throughout
these scripts happened. The reaper and lease table it works alongside are in the
parent directory.

## The parts

| file | runs | what it does |
|---|---|---|
| `preserve.sh` | on the box, on demand | pushes committed work to `$WORK_BRANCH`, writes a crash dump to S3 |
| `spot-watch.sh` | on the box, always | watches IMDS for the reclaim notice, then preserves |
| `idle-shutdown.sh` | on the box, every 5 min | preserves and self-terminates after `$IDLE_SECONDS` idle |
| `install-box.sh` | on the box, once, as root | installs the three above plus their systemd units |
| `restore-autosave.sh` | on your machine | lists and recovers dumps |
| `test-preserve.sh` | anywhere | drives `preserve.sh` against a throwaway repo and a stub `aws` |
| `test-install-box.sh` | anywhere | drives `install-box.sh` into a scratch tree |
| `load-creds.sh` | on your machine | parses AWS keys out of `~/.ssh/aws.txt` |

## Wiring it into a project

Your provisioner copies this directory to the box and runs the installer:

    scp -r spot/ ubuntu@$IP:/tmp/
    ssh ubuntu@$IP "sudo REPO=/home/ubuntu/src/myproj BUCKET=$BUCKET \
        WORK_BRANCH=main IDLE_ACTIVE_PATTERN='cmake|ninja|clang|node|claude' \
        /tmp/spot/install-box.sh"

The box needs an instance role with `s3:PutObject` on `$BUCKET/*` (for the
dumps), `ec2:TerminateInstances` on itself (for the idle timer), and a git
deploy key in the box user's `~/.ssh` with a `Host github.com` entry selecting
it. See `avwohl/iospharo`'s `scripts/aws/provision.sh` for a worked example.

## What a dump looks like

    s3://$BUCKET/autosave/<instance-id>/<timestamp>/
        autosave.bundle    a git bundle: every commit the box held that origin
                           did not, including the working-tree snapshot
        wip.diff           the same uncommitted work as a plain patch, new and
                           untracked files included
        status.txt         `git status -sb` as the box last saw it
        manifest.txt       instance, reason, HEAD, the bundle's prerequisites

## Recovering one

    ./restore-autosave.sh list
    ./restore-autosave.sh show  i-0abc.../20260904T181500Z
    ./restore-autosave.sh fetch i-0abc.../20260904T181500Z

`fetch` lands the dump at `refs/autosave/<instance>/<timestamp>` and stops. No
branch moves and no file is touched — recovering an autosave is meant to be a
deliberate act. From there:

    git log  refs/autosave/<instance>/<ts>
    git diff main..refs/autosave/<instance>/<ts>
    git cherry-pick <sha>                     # or: git checkout <ref> -- <path>
    git update-ref -d refs/autosave/<instance>/<ts>     # when you're done

The bundle is a **delta** against what `origin` held when the dump was taken, so
`git fetch origin` first if your clone is behind; `restore-autosave.sh` names
the missing objects rather than failing obscurely. If a bundle cannot be
unpacked at all, `wip.diff` beside it is a plain patch that needs no objects.

## Why the crash dump is not a git push

An autosave is not a commit anyone chose to make. It is `git add -A` — a
snapshot of whatever the working tree happened to hold — committed with the
box's HEAD as its parent, and those two inputs are **independent**. When the
parent is current and the tree is stale, the snapshot records the difference as
deletions, the push is a clean fast-forward, and the server accepts it. No force
flag is involved, so nothing anywhere refuses it.

It has happened twice in iospharo. `27d378d2` (2026-06-03) reverted a submodule
pin to unpatched upstream and broke fresh clones for 68 days. `ede0fd65`
(2026-09-03) put a 242-commit-stale tree on the shared branch, deleting a script
on the way past.

Aiming the dump at a per-box `autosave/<instance-id>` **branch** fixes that much,
and was the first version of this fix. S3 is better for a second reason: a git
object is forever. Once a dump is reachable from any ref its blobs are in the
pack permanently, `add -A` stages whatever untracked build output `.gitignore`
misses, and a stale autosave branch is exactly the ref nobody deletes. An S3
object can be deleted, or expired by a lifecycle rule.

A bundle keeps everything a branch gave you — full history, real commits,
`git fetch`-able — while being reachable from nothing.

**Committed work is different** and still goes to `$WORK_BRANCH` as an ordinary
push. If the box is behind, the server rejects it as a non-fast-forward, which
is the right answer and needs no help from us.

## Testing

    ./test-preserve.sh
    ./test-install-box.sh

Neither contacts AWS or GitHub, needs root, or touches anything outside its own
scratch directory. `test-install-box.sh` drives the installer via
`SPOT_TEST_ROOT`, checking the failures that leave a box with no working
preserve and no sign of it: a script not landing, the env file missing a knob
the scripts read, a unit pointing somewhere the scripts are not, and either unit
running as the wrong user.

`test-preserve.sh` is ten cases against a throwaway repo, a bare remote and a
stub `aws`.

    1  nothing to save              branch unmoved, no dump
    2  a deliberate commit          reaches the branch, no dump needed
    3  THE CLOBBER                  current parent, stale tree: branch unmoved,
                                    the deleted file survives, dump written
    4  commit + dirty tree          branch gets the commit, dump gets the snapshot
    5  a second preserve            both dumps kept, branch still untouched
    6  submodule drift              refused; the pin is preserved
    7  box state after a preserve   HEAD, index and worktree unchanged
    8  no git ref left behind       on the remote or on the box
    9  a REFUSED push               its commits still reach the dump
    10 missing REPO/BUCKET          refused loudly, nothing written

Case 3 is the `ede0fd65` failure reproduced deliberately. Case 9 is the hole the
branch-based design had: a clean tree meant no snapshot commit, so a box whose
push was rejected saved nothing anywhere.

## Two things that bite

**`IDLE_ACTIVE_PATTERN` must list the process that WAITS.** iospharo lost a
74-minute sweep because `pharo` was missing from it: the work was network-bound
Metacello loads, no listed process was running, load sat near 0.2, and the box
terminated itself. A low-CPU long-running job is invisible to this check and to
a CloudWatch CPU alarm alike.

**The idle timer runs as root; `preserve.sh` must not.** The git deploy key and
the `~/.ssh/config` entry that selects it live in the box user's home, so a
root-run preserve cannot authenticate and its push fails silently, leaving only
the S3 half. `idle-shutdown.sh` drops to `$SPOT_USER` (with `HOME` set — without
it `runuser` keeps `/root`, which is the very thing that breaks).
