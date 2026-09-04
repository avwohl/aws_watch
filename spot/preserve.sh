#!/usr/bin/env bash
# preserve.sh — push all work off an ephemeral (spot) build box so nothing is
# lost when it is reclaimed or idle-terminated.  Safe to run repeatedly.
#
#   $1 = reason string (for the note), default "manual"
#
# Two destinations, and the split between them is the whole point:
#   1. git, $WORK_BRANCH  — commits the box made DELIBERATELY.  An ordinary
#                           push: if the box is behind, the server rejects it
#                           as a non-fast-forward, which is the right answer.
#   2. S3                 — the crash dump.  A git BUNDLE of everything the box
#                           holds that origin does not, plus the uncommitted
#                           diff, notes and build logs.  See "WHY THE CRASH DUMP
#                           IS NOT A GIT PUSH" below.
#
# Project-independent: everything it needs comes from the environment, which on
# a provisioned box is $SPOT_PREFIX/env (systemd EnvironmentFile).  REPO and
# BUCKET are required; see spot.env.example for the full set of knobs.
set -uo pipefail

REASON="${1:-manual}"
# All overridable so the script can be exercised against a throwaway repo.  A
# disaster-recovery path that has never been run outside a disaster is how the
# two clobbers documented below went unnoticed; test-preserve.sh drives this.
REPO="${REPO:-}"
BUCKET="${BUCKET:-}"
NOTES_DIR="${NOTES_DIR:-/var/tmp/spot-notes}"
WORK_BRANCH="${WORK_BRANCH:-main}"
S3_PREFIX="${S3_PREFIX:-s3://${BUCKET}/spot}"
# Where crash dumps land.  One prefix per box, one directory per dump.
AUTOSAVE_PREFIX="${AUTOSAVE_PREFIX:-s3://${BUCKET}/autosave}"
# Who the snapshot commit is attributed to, and what its subject says.  Making
# these greppable is what lets a project detect its own autosaves later.
AUTOSAVE_AUTHOR_NAME="${AUTOSAVE_AUTHOR_NAME:-spot-autosave}"
AUTOSAVE_AUTHOR_EMAIL="${AUTOSAVE_AUTHOR_EMAIL:-autosave@spot.local}"
AUTOSAVE_SUBJECT_PREFIX="${AUTOSAVE_SUBJECT_PREFIX:-wip: autosave on}"
# Overridable so the test harness can drive the S3 path with a stub.
AWS="${AWS_CLI:-aws}"
ts=$(date -u +%Y%m%dT%H%M%SZ)

if [ -z "$REPO" ] || [ -z "$BUCKET" ]; then
    echo "preserve: REPO and BUCKET must be set (normally from \$SPOT_PREFIX/env)" >&2
    exit 2
fi

# This box's own name for its dump prefix.  The Nitro DMI board_asset_tag IS
# the instance id and exists only on the box — ../aws-lease-beat-hook.sh reads
# the same file for the same reason.  Falling back to the hostname rather than
# to a shared constant matters: two boxes must never write one prefix, or the
# second one's dump lands on top of the first one's.
box_id() {
    local id
    id=$(cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null || true)
    case "$id" in
        i-*) printf '%s' "$id"; return ;;
    esac
    printf 'host-%s' "$(hostname -s 2>/dev/null || echo unknown)"
}

mkdir -p "$NOTES_DIR"
{
    echo "preserve @ ${ts}  reason=${REASON}  host=$(hostname)"
    echo "load: $(cat /proc/loadavg)"
} >>"$NOTES_DIR/preserve.log"

if [ -d "$REPO/.git" ]; then
    cd "$REPO"
    # Capture uncommitted state even if every push and upload fails.  Against
    # HEAD, not against the index: a crash dump wants staged and unstaged work
    # alike.  This file is also the one artifact that needs NO prerequisite
    # objects to read, so it stays useful when the bundle cannot be unpacked.
    git -c safe.directory="$REPO" diff HEAD > "$NOTES_DIR/wip-${ts}.diff" 2>/dev/null || true
    git -c safe.directory="$REPO" status -sb > "$NOTES_DIR/status-${ts}.txt" 2>/dev/null || true

    # Snapshot the working tree into a SCRATCH index, never the real one, and
    # build the commit with plumbing so HEAD is not moved either.
    #
    # This script used to `git add -A && git commit` on the box's own branch,
    # and that made it non-idempotent: after one autosave the box's HEAD *was*
    # the autosave, so the next run read it as deliberate work and pushed it to
    # the shared branch after all.  Leaving HEAD and the index untouched also
    # means a human who reconnects to a box that was preserved but not actually
    # reclaimed finds their working state exactly as they left it.
    TMPIDX="${TMPDIR:-/tmp}/preserve-index.$$"
    rm -f "$TMPIDX"
    export GIT_INDEX_FILE="$TMPIDX"
    git -c safe.directory="$REPO" read-tree HEAD 2>/dev/null || true
    git -c safe.directory="$REPO" add -A

    # Never let an autosave move a submodule pointer.  The box's submodules
    # drift (a plain `submodule update` checks out the upstream default rather
    # than the fork branch named in .gitmodules), and `add -A` stages that drift
    # as if it were a deliberate pin change.  That is exactly how iospharo's
    # 27d378d2 reverted a patched submodule pin to unpatched upstream, breaking
    # fresh clones for two months before 86151021 restored it.  Pin bumps are a
    # deliberate act made on a dev machine — an autosave must never make one.
    #
    # Paths come from .gitmodules rather than a hardcoded list so a submodule
    # added later is protected automatically.  SPOT_SUBMODULE_PATHS (space
    # separated) is a fallback for a repo whose .gitmodules is unreadable from
    # the box; setting it can only over-protect.
    SUBMODS=()
    while IFS= read -r p; do
        [ -n "$p" ] && SUBMODS+=("$p")
    done < <(git -c safe.directory="$REPO" config -f .gitmodules \
                 --get-regexp '^submodule\..*\.path$' 2>/dev/null | cut -d' ' -f2-)
    if [ ${#SUBMODS[@]} -eq 0 ] && [ -n "${SPOT_SUBMODULE_PATHS:-}" ]; then
        # shellcheck disable=SC2206
        SUBMODS=(${SPOT_SUBMODULE_PATHS})
    fi

    # Record what we drop.  The 27d378d2 regression stayed invisible for two
    # months partly because nothing ever said a pin had been touched.
    dropped=""
    [ ${#SUBMODS[@]} -gt 0 ] && dropped=$(git -c safe.directory="$REPO" \
        diff --cached --name-only -- "${SUBMODS[@]}" 2>/dev/null)
    if [ -n "$dropped" ]; then
        {
            echo "preserve @ ${ts}: refused to autosave submodule-pointer drift:"
            git -c safe.directory="$REPO" diff --cached --submodule=short \
                -- "${SUBMODS[@]}" 2>/dev/null
        } | tee -a "$NOTES_DIR/submodule-drift.log" >&2
    fi
    [ ${#SUBMODS[@]} -gt 0 ] && \
        git -c safe.directory="$REPO" reset -q -- "${SUBMODS[@]}" 2>/dev/null
    true

    # HEAD, which preserve.sh never moves.  Everything reachable from here was
    # committed by a person (or by a Claude working on the box), so it is
    # ordinary work and belongs on the work branch.
    deliberate=$(git -c safe.directory="$REPO" rev-parse HEAD 2>/dev/null || true)

    # The snapshot, as a commit that lives on no branch.  Compare trees rather
    # than asking `diff --cached`, so a scratch index with no stat cache cannot
    # report a difference that is not there.
    autosaved=""
    snap_tree=$(git -c safe.directory="$REPO" write-tree 2>/dev/null || true)
    head_tree=$(git -c safe.directory="$REPO" rev-parse "HEAD^{tree}" 2>/dev/null || true)
    if [ -n "$snap_tree" ] && [ -n "$deliberate" ] && [ "$snap_tree" != "$head_tree" ]; then
        autosaved=$(git -c safe.directory="$REPO" \
            -c user.name="$AUTOSAVE_AUTHOR_NAME" \
            -c user.email="$AUTOSAVE_AUTHOR_EMAIL" \
            commit-tree "$snap_tree" -p "$deliberate" \
            -m "${AUTOSAVE_SUBJECT_PREFIX} ${REASON} @ ${ts}" 2>/dev/null || true)
    fi
    unset GIT_INDEX_FILE
    rm -f "$TMPIDX"

    # Re-derive the plain-patch fallback from the snapshot now that we have it.
    # `git diff HEAD` above cannot see UNTRACKED files, so on a box whose work
    # is a new file it writes an empty patch -- the snapshot tree is the only
    # thing that has them.  Diffing HEAD against the snapshot commit gets the
    # new files as additions, and this file is the one artifact that needs no
    # prerequisite objects to read.
    if [ -n "$autosaved" ]; then
        git -c safe.directory="$REPO" diff HEAD "$autosaved" \
            > "$NOTES_DIR/wip-${ts}.diff" 2>/dev/null || true
    fi

    # Deliberate work goes to the shared branch, as it always has.  A push of
    # real commits is safe: if this box is behind, the server rejects it as a
    # non-fast-forward, and that is the correct outcome.
    if [ -n "$deliberate" ]; then
        git -c safe.directory="$REPO" push origin \
            "${deliberate}:refs/heads/${WORK_BRANCH}" || \
            echo "preserve: push of committed work to ${WORK_BRANCH} failed (S3 still gets the dump)" >&2
    fi

    # --- WHY THE CRASH DUMP IS NOT A GIT PUSH --------------------------------
    #
    # An autosave is not a commit anyone chose to make.  It is `git add -A` — a
    # snapshot of whatever the working tree happened to hold — committed with
    # the box's HEAD as its parent, and those two inputs are INDEPENDENT.  When
    # the parent is current and the tree is stale, the snapshot records the
    # difference as deletions, the push is a clean fast-forward, and the server
    # accepts it.  No force flag is involved, so nothing anywhere refuses it.
    #
    # It has happened twice, in avwohl/iospharo, which is where this script
    # came from:
    #   27d378d2 (2026-06-03) reverted a submodule pin to unpatched upstream and
    #     broke fresh clones for 68 days.  The submodule guard above is the
    #     answer to that one, and it protects only paths in .gitmodules.
    #   ede0fd65 (2026-09-03) put a 242-commit-stale snapshot of the whole tree
    #     onto the shared branch, deleting a script on the way past.
    # An ordinary source file has never had a guard at all.
    #
    # Sending the dump to a per-box `autosave/<instance-id>` BRANCH fixes that
    # much, and was what this script did before.  It was traded for S3 because a
    # git object is forever: once a dump is reachable from any ref, its blobs
    # are in the pack permanently, and a forgotten autosave branch is exactly
    # the ref nobody deletes.  `add -A` also stages whatever untracked build
    # output .gitignore happens to miss, and that is not hypothetical: 20 MiB of
    # iospharo's pack is `build*/` test binaries that were committed and then
    # untracked again, which reclaimed nothing.  An S3 object is deletable and
    # can be expired by a lifecycle rule; a git object cannot.
    #
    # So the dump goes to S3 as a BUNDLE, which is a git pack that is not a ref:
    # complete history, fetchable on demand, reachable from nothing.  It carries
    # everything the box holds that origin does not — including commits whose
    # push above was refused, which is the case a plain diff would lose.
    # Recovering one is `restore-autosave.sh` beside this file; see README.md
    # under "Recovering an autosave".
    dump_commit="${autosaved:-$deliberate}"
    if [ -n "$dump_commit" ]; then
        DUMP_DIR="${AUTOSAVE_PREFIX}/$(box_id)/${ts}"
        # The pid is in the FILE name for the same reason it is in the ref:
        # two preserves can overlap.  Without it they collide on git's
        # <bundle>.lock, and whichever finishes first `rm -f`s the other's
        # bundle out from under its upload.  Both runs then fail -- one loudly,
        # one with a half-written dump.
        BUNDLE="${AUTOSAVE_BUNDLE_DIR:-${TMPDIR:-/tmp}}/autosave-${ts}.$$.bundle"
        # A bundle needs a ref name, not a raw SHA, and the name travels inside
        # it.  This ref is local to the box and is never pushed anywhere.
        #
        # The pid is in the name because two preserves CAN overlap: the spot
        # watcher re-preserves every 20s while an interruption notice stands,
        # and the idle timer fires independently.  Sharing a ref name, one run
        # would delete the ref the other was about to bundle -- which now
        # raises the BUNDLE FAILED alarm below.  An alarm with a known false
        # positive is one you learn to ignore, so give each run its own ref.
        DUMP_REF="refs/autosave/${ts}.$$"
        git -c safe.directory="$REPO" update-ref "$DUMP_REF" "$dump_commit"

        # --not --remotes=origin makes this a DELTA against what origin already
        # has, so a dump is diff-sized rather than repo-sized.
        #
        # ASK "IS THERE ANYTHING TO SAVE" SEPARATELY FROM "DID SAVING WORK".
        # `bundle create` exits non-zero both when there is nothing to bundle
        # ("Refusing to create empty bundle") and when bundling FAILED -- no
        # space in the bundle directory, a permission problem, an unreadable
        # object.  Treating those alike is how a box two minutes from death
        # reports "origin already has everything" when in fact nothing was
        # written anywhere.  A disaster-recovery path must never say the work
        # is safe when it has not looked.
        n_new=$(git -c safe.directory="$REPO" rev-list --count \
                    "$DUMP_REF" --not --remotes=origin 2>/dev/null || echo 0)
        bundle_err=""
        bundle_ok=0
        if [ "${n_new:-0}" -gt 0 ]; then
            if bundle_err=$(git -c safe.directory="$REPO" bundle create "$BUNDLE" \
                    "$DUMP_REF" --not --remotes=origin 2>&1); then
                bundle_ok=1
            fi
        fi
        if [ "$bundle_ok" = 1 ]; then
            {
                echo "instance      $(box_id)"
                echo "host          $(hostname)"
                echo "reason        ${REASON}"
                echo "timestamp     ${ts}"
                echo "repo          ${REPO}"
                echo "work_branch   ${WORK_BRANCH}"
                echo "head          ${deliberate}"
                echo "dump_commit   ${dump_commit}"
                echo "dump_ref      ${DUMP_REF}"
                echo "is_snapshot   $([ -n "$autosaved" ] && echo yes || echo no)"
                echo "origin_${WORK_BRANCH}  $(git -c safe.directory="$REPO" \
                    rev-parse "refs/remotes/origin/${WORK_BRANCH}" 2>/dev/null || echo unknown)"
                echo "bundle_bytes  $(wc -c <"$BUNDLE" | tr -d ' ')"
                echo "--- bundle contents ---"
                git -c safe.directory="$REPO" bundle list-heads "$BUNDLE" 2>/dev/null
                echo "--- bundle verify (prerequisites must exist where you restore) ---"
                git -c safe.directory="$REPO" bundle verify "$BUNDLE" 2>&1
            } > "$NOTES_DIR/manifest-${ts}.txt" 2>/dev/null

            ok=1
            $AWS s3 cp "$BUNDLE" "${DUMP_DIR}/autosave.bundle" --no-progress || ok=0
            $AWS s3 cp "$NOTES_DIR/manifest-${ts}.txt" "${DUMP_DIR}/manifest.txt" --no-progress || ok=0
            $AWS s3 cp "$NOTES_DIR/wip-${ts}.diff" "${DUMP_DIR}/wip.diff" --no-progress || ok=0
            $AWS s3 cp "$NOTES_DIR/status-${ts}.txt" "${DUMP_DIR}/status.txt" --no-progress || ok=0
            if [ "$ok" = 1 ]; then
                echo "preserve: autosave ${dump_commit} -> ${DUMP_DIR}" \
                    | tee -a "$NOTES_DIR/preserve.log"
            else
                echo "preserve: autosave upload to ${DUMP_DIR} FAILED or was partial" \
                    | tee -a "$NOTES_DIR/preserve.log" >&2
            fi
        elif [ "${n_new:-0}" -eq 0 ]; then
            echo "preserve: nothing to bundle (origin already has everything)" \
                >>"$NOTES_DIR/preserve.log"
        else
            # ${n_new} commits exist only on this box and we could not package
            # them.  Say so as loudly as possible: this is work about to be
            # lost, not a quiet no-op.
            {
                echo "preserve: BUNDLE FAILED with ${n_new} commit(s) only on this box"
                echo "preserve: ${bundle_err}"
                echo "preserve: the uncommitted half is still going to S3 as wip.diff"
            } | tee -a "$NOTES_DIR/preserve.log" >&2
        fi
        # The ref would otherwise accumulate one entry per preserve, and a box
        # that is preserved but not reclaimed gets preserved again and again.
        git -c safe.directory="$REPO" update-ref -d "$DUMP_REF" 2>/dev/null || true
        rm -f "$BUNDLE"
    fi
fi

# Sync notes + build log to S3 (best effort).
$AWS s3 sync "$NOTES_DIR" "${S3_PREFIX}/notes/" --no-progress 2>/dev/null || \
    echo "preserve: s3 sync notes failed" >&2
[ -f "$REPO/build/build.log" ] && \
    $AWS s3 cp "$REPO/build/build.log" "${S3_PREFIX}/logs/build-${ts}.log" --no-progress 2>/dev/null || true

echo "preserve: done (${REASON})"
