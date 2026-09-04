#!/usr/bin/env bash
# test-preserve.sh — drive preserve.sh against a throwaway repo, a bare remote
# and a fake `aws`.
#
# preserve.sh only ever ran on a box that was two minutes from being reclaimed,
# which is why it clobbered a shared branch twice in avwohl/iospharo before
# anyone noticed:
#
#   27d378d2  2026-06-03  reverted a submodule pin (68 days of broken clones)
#   ede0fd65  2026-09-03  put a 242-commit-stale tree on the branch, deleting a
#                         script on the way past
#
# Case 3 below is that failure, reproduced deliberately.  Run it from anywhere:
#
#     spot/test-preserve.sh
#
# Exits non-zero on the first failed assertion.  Touches nothing outside its
# scratch directory and never talks to AWS or GitHub — the `aws` the script
# calls is a stub that copies into a scratch directory, so what preserve.sh
# would have uploaded can be unbundled and read back.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
PRESERVE="$HERE/preserve.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/preserve-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$3', got '$2')"; fi; }

# The box id comes from Nitro DMI, which does not exist here, so preserve.sh
# falls back to host-<hostname>.  Compute the same name to assert against.
BOX="host-$(hostname -s 2>/dev/null || echo unknown)"

# --- the fake aws -----------------------------------------------------------
# Understands only the two verbs preserve.sh uses.  s3://B/k lands at $S3/B/k,
# so a dump can be inspected exactly as `aws s3 cp` would have left it.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/aws" <<'STUB'
#!/usr/bin/env bash
set -u
S3="${FAKE_S3:?}"
to_path() { printf '%s' "$S3/${1#s3://}"; }
[ "${1:-}" = "s3" ] || exit 0
verb="$2"; src="$3"; dst="$4"
case "$verb" in
    cp)   d=$(to_path "$dst"); mkdir -p "$(dirname "$d")"; cp "$src" "$d" ;;
    sync) d=$(to_path "$dst"); mkdir -p "$d"; cp -R "$src"/. "$d"/ 2>/dev/null ;;
    *)    exit 0 ;;
esac
STUB
chmod 755 "$SCRATCH/bin/aws"

# A fresh remote + working clone, with `jit` holding one shared commit.
new_world() {
    rm -rf "$SCRATCH/remote.git" "$SCRATCH/box" "$SCRATCH/notes" "$SCRATCH/s3"
    mkdir -p "$SCRATCH/s3"
    git init -q --bare "$SCRATCH/remote.git"
    git init -q "$SCRATCH/box"
    git -C "$SCRATCH/box" config user.email t@t; git -C "$SCRATCH/box" config user.name t
    git -C "$SCRATCH/box" remote add origin "$SCRATCH/remote.git"
    mkdir -p "$SCRATCH/box/scripts"
    echo "shared" > "$SCRATCH/box/shared.txt"
    echo "sweeper" > "$SCRATCH/box/scripts/sweep-3way.sh"
    git -C "$SCRATCH/box" add -A
    git -C "$SCRATCH/box" commit -qm "base"
    git -C "$SCRATCH/box" branch -M jit
    git -C "$SCRATCH/box" push -q origin jit
}

run_preserve() {
    REPO="$SCRATCH/box" NOTES_DIR="$SCRATCH/notes" WORK_BRANCH=jit \
        BUCKET=testbucket S3_PREFIX="s3://testbucket/notes" \
        AUTOSAVE_AUTHOR_NAME="test-builder" \
        AUTOSAVE_AUTHOR_EMAIL="builder@test.local" \
        AUTOSAVE_SUBJECT_PREFIX="wip: autosave on" \
        AWS_CLI="$SCRATCH/bin/aws" FAKE_S3="$SCRATCH/s3" \
        "$PRESERVE" "$1" >"$SCRATCH/out.txt" 2>&1
}

remote_sha()  { git -C "$SCRATCH/remote.git" rev-parse "$1" 2>/dev/null || echo missing; }
remote_has()  { git -C "$SCRATCH/remote.git" rev-parse --verify -q "$1" >/dev/null 2>&1; }
remote_file() { git -C "$SCRATCH/remote.git" cat-file -e "$1:$2" 2>/dev/null; }

# The newest dump directory the stub recorded, if any.
dumps()      { ls -d "$SCRATCH"/s3/testbucket/autosave/"$BOX"/*/ 2>/dev/null; }
dump_count() { dumps | wc -l | tr -d ' '; }
last_dump()  { dumps | tail -1; }

# Unbundle the newest dump into a fresh clone of the remote — the real recovery
# path, prerequisites and all — and answer whether it carries $1.
recover_dump() {
    local d src
    d=$(last_dump); [ -n "$d" ] || return 1
    rm -rf "$SCRATCH/recover"
    git clone -q -b jit "$SCRATCH/remote.git" "$SCRATCH/recover" 2>/dev/null || return 1
    git -C "$SCRATCH/recover" bundle verify "${d}autosave.bundle" >/dev/null 2>&1 || return 1
    # The bundle's ref is named for the timestamp the box wrote it at, so take
    # the name from the bundle -- the same thing restore-autosave.sh does.
    src=$(git -C "$SCRATCH/recover" bundle list-heads "${d}autosave.bundle" | awk 'NR==1 {print $2}')
    [ -n "$src" ] || return 1
    git -C "$SCRATCH/recover" fetch -q "${d}autosave.bundle" \
        "${src}:refs/autosave/recovered" 2>/dev/null || return 1
}
dump_carries() {
    local f
    recover_dump || return 1
    for f in "$@"; do
        git -C "$SCRATCH/recover" cat-file -e "refs/autosave/recovered:$f" 2>/dev/null || return 1
    done
}
dump_has_commit() {
    recover_dump || return 1
    git -C "$SCRATCH/recover" merge-base --is-ancestor "$1" refs/autosave/recovered 2>/dev/null
}

echo "== case 1: nothing to save — jit untouched, no dump =="
new_world
before=$(remote_sha jit)
run_preserve manual
check "jit unmoved"   "$(remote_sha jit)" "$before"
check "no dump written" "$(dump_count)" "0"

echo "== case 2: a deliberate commit still reaches jit =="
new_world
echo "real work" > "$SCRATCH/box/feature.txt"
git -C "$SCRATCH/box" add -A && git -C "$SCRATCH/box" commit -qm "deliberate"
want=$(git -C "$SCRATCH/box" rev-parse HEAD)
run_preserve manual
check "jit fast-forwarded to the deliberate commit" "$(remote_sha jit)" "$want"
check "a pushed clean tree needs no dump" "$(dump_count)" "0"

echo "== case 3: THE CLOBBER — current parent, stale tree =="
# Exactly the ede0fd65 shape: the box is on the true tip, but its working tree
# has lost a file.  Before the fix, `add -A` recorded the deletion and the push
# was a fast-forward the server could not refuse.
new_world
rm "$SCRATCH/box/scripts/sweep-3way.sh"
echo "half-finished" > "$SCRATCH/box/wip.txt"
before=$(remote_sha jit)
run_preserve spot-interruption
check "jit NOT moved by the autosave" "$(remote_sha jit)" "$before"
if remote_file jit scripts/sweep-3way.sh; then pass "deleted file still on jit"
else fail "deleted file still on jit"; fi
check "the dump was written" "$(dump_count)" "1"
if dump_carries wip.txt; then pass "dump unbundles and carries the WIP"
else fail "dump unbundles and carries the WIP"; fi
if [ -s "$(last_dump)wip.diff" ] && [ -s "$(last_dump)manifest.txt" ]; then
    pass "wip.diff and manifest.txt beside it"
else fail "wip.diff and manifest.txt beside it"; fi

echo "== case 4: deliberate work and a dirty tree, in one run =="
new_world
echo "real work" > "$SCRATCH/box/feature.txt"
git -C "$SCRATCH/box" add -A && git -C "$SCRATCH/box" commit -qm "deliberate"
want=$(git -C "$SCRATCH/box" rev-parse HEAD)
echo "scratch" > "$SCRATCH/box/wip.txt"
run_preserve idle
check "jit gets the commit, not the snapshot" "$(remote_sha jit)" "$want"
if dump_carries wip.txt; then pass "the snapshot went to the dump"
else fail "the snapshot went to the dump"; fi

echo "== case 5: a second preserve writes a second dump, jit still untouched =="
echo "more scratch" > "$SCRATCH/box/wip2.txt"
before=$(remote_sha jit)
sleep 1   # the dump directory is timestamped to the second
run_preserve spot-interruption
check "jit still unmoved"    "$(remote_sha jit)" "$before"
check "both dumps kept"      "$(dump_count)" "2"
if dump_carries wip.txt wip2.txt; then pass "the later dump carries both"
else fail "the later dump carries both"; fi

echo "== case 6: submodule-pointer drift is still refused =="
new_world
git init -q --bare "$SCRATCH/sub.git"
git init -q "$SCRATCH/subwork"
git -C "$SCRATCH/subwork" config user.email t@t; git -C "$SCRATCH/subwork" config user.name t
echo a > "$SCRATCH/subwork/a"; git -C "$SCRATCH/subwork" add -A
git -C "$SCRATCH/subwork" commit -qm s1; git -C "$SCRATCH/subwork" branch -M main
git -C "$SCRATCH/subwork" remote add origin "$SCRATCH/sub.git" 2>/dev/null
git -C "$SCRATCH/subwork" push -q origin main
git -C "$SCRATCH/box" -c protocol.file.allow=always submodule add -q "$SCRATCH/sub.git" third_party/asmjit 2>/dev/null
git -C "$SCRATCH/box" add -A && git -C "$SCRATCH/box" commit -qm "add submodule"
git -C "$SCRATCH/box" push -q origin jit
pinned=$(git -C "$SCRATCH/box" rev-parse HEAD:third_party/asmjit)
echo b > "$SCRATCH/subwork/b"; git -C "$SCRATCH/subwork" add -A
git -C "$SCRATCH/subwork" commit -qm s2; git -C "$SCRATCH/subwork" push -q origin main
git -C "$SCRATCH/box/third_party/asmjit" fetch -q origin
git -C "$SCRATCH/box/third_party/asmjit" checkout -q origin/main   # the drift
echo "some work" > "$SCRATCH/box/wip.txt"
run_preserve spot-interruption
if recover_dump; then
    got=$(git -C "$SCRATCH/recover" rev-parse "refs/autosave/recovered:third_party/asmjit" 2>/dev/null || echo none)
    check "the dump kept the pinned submodule SHA" "$got" "$pinned"
else
    fail "a dump was written and unbundles (case 6)"
fi

echo "== case 7: the box's own state survives a preserve untouched =="
# The reason case 5 used to fail: preserve.sh committed on the box's branch, so
# its own HEAD became the autosave.  It now builds the commit with plumbing in a
# scratch index, and a human who reconnects to a preserved-but-not-reclaimed box
# must find their working tree exactly as they left it.
new_world
echo "staged"   > "$SCRATCH/box/staged.txt"
git -C "$SCRATCH/box" add staged.txt
echo "unstaged" > "$SCRATCH/box/unstaged.txt"
head_before=$(git -C "$SCRATCH/box" rev-parse HEAD)
idx_before=$(git -C "$SCRATCH/box" status --porcelain | sort)
run_preserve spot-interruption
check "box HEAD unmoved"  "$(git -C "$SCRATCH/box" rev-parse HEAD)" "$head_before"
check "box index unmoved" "$(git -C "$SCRATCH/box" status --porcelain | sort)" "$idx_before"
if dump_carries staged.txt unstaged.txt; then
    pass "the dump carries staged and unstaged alike"
else
    fail "the dump carries staged and unstaged alike"
fi
if [ -s "$SCRATCH/notes/wip-"*.diff ]; then pass "S3-bound diff is non-empty"
else fail "S3-bound diff is non-empty"; fi
if ls "${TMPDIR:-/tmp}"/preserve-index.* >/dev/null 2>&1; then
    fail "scratch index cleaned up"
else
    pass "scratch index cleaned up"
fi

echo "== case 8: no git ref is left behind, on either side =="
# The point of moving the dump to S3: a git object is forever, so a crash dump
# must not become one.  Nothing may be created under refs/heads/autosave on the
# remote, and the local ref the bundle is built from must not survive the run.
if remote_has "refs/heads/autosave/$BOX" || \
   [ -n "$(git -C "$SCRATCH/remote.git" for-each-ref --format='%(refname)' 'refs/heads/autosave/*')" ]; then
    fail "no autosave branch on the remote"
else pass "no autosave branch on the remote"; fi
if [ -n "$(git -C "$SCRATCH/box" for-each-ref --format='%(refname)' 'refs/autosave/*')" ]; then
    fail "no autosave ref left on the box"
else pass "no autosave ref left on the box"; fi

echo "== case 9: a REFUSED push still gets its commits into the dump =="
# The hole the branch-based design had: if the box committed real work and the
# push was rejected as non-fast-forward, a clean tree meant no snapshot commit,
# so nothing was saved anywhere but a diff of nothing.  The bundle is built
# from what origin lacks, not from whether the tree is dirty, so it catches it.
new_world
git clone -q -b jit "$SCRATCH/remote.git" "$SCRATCH/other"
git -C "$SCRATCH/other" config user.email t@t; git -C "$SCRATCH/other" config user.name t
echo "someone else" > "$SCRATCH/other/theirs.txt"
git -C "$SCRATCH/other" add -A && git -C "$SCRATCH/other" commit -qm "diverged"
git -C "$SCRATCH/other" push -q origin jit          # remote moves out from under the box
echo "the box's real work" > "$SCRATCH/box/mine.txt"
git -C "$SCRATCH/box" add -A && git -C "$SCRATCH/box" commit -qm "box work"
mine=$(git -C "$SCRATCH/box" rev-parse HEAD)
theirs=$(remote_sha jit)
run_preserve spot-interruption
check "the refused push left jit alone" "$(remote_sha jit)" "$theirs"
if grep -q "failed" "$SCRATCH/out.txt"; then pass "the refusal was reported"
else fail "the refusal was reported"; fi
if dump_has_commit "$mine"; then pass "the unpushable commit is in the dump"
else fail "the unpushable commit is in the dump"; fi

echo "== case 10: REPO and BUCKET are required, not guessed =="
# The iospharo-specific defaults this script used to carry are gone.  A box that
# is misconfigured must say so rather than quietly preserving to someone else's
# bucket, or reading a repo path that happens to exist.
new_world
out=$(REPO="$SCRATCH/box" NOTES_DIR="$SCRATCH/notes" AWS_CLI="$SCRATCH/bin/aws" \
        FAKE_S3="$SCRATCH/s3" "$PRESERVE" manual 2>&1; echo "rc=$?")
case "$out" in
    *"REPO and BUCKET must be set"*rc=2*) pass "a missing BUCKET is refused, loudly" ;;
    *) fail "a missing BUCKET is refused, loudly (got: $out)" ;;
esac
check "and it wrote nothing" "$(dump_count)" "0"

echo "== case 11: a FAILED bundle is never reported as 'nothing to save' =="
# `git bundle create` exits non-zero both when there is nothing to bundle and
# when bundling broke.  Conflating them is how a box two minutes from death
# tells you its work is safe on origin when nothing was written anywhere.
new_world
echo "work that must not be quietly lost" > "$SCRATCH/box/precious.txt"
RO="$SCRATCH/readonly"; rm -rf "$RO"; mkdir -p "$RO"; chmod 500 "$RO"
REPO="$SCRATCH/box" NOTES_DIR="$SCRATCH/notes" WORK_BRANCH=jit \
    BUCKET=testbucket S3_PREFIX="s3://testbucket/notes" \
    AUTOSAVE_BUNDLE_DIR="$RO" \
    AWS_CLI="$SCRATCH/bin/aws" FAKE_S3="$SCRATCH/s3" \
    "$PRESERVE" spot-interruption >"$SCRATCH/out.txt" 2>&1
chmod 700 "$RO"
if grep -q "BUNDLE FAILED" "$SCRATCH/out.txt"; then pass "the failure is reported"
else fail "the failure is reported (got: $(tail -2 "$SCRATCH/out.txt"))"; fi
if grep -q "nothing to bundle" "$SCRATCH/out.txt"; then
    fail "it does NOT claim origin already has everything"
else pass "it does NOT claim origin already has everything"; fi
if grep -q "commit(s) only on this box" "$SCRATCH/out.txt"; then
    pass "it says how much work is at risk"
else fail "it says how much work is at risk"; fi
# The plain patch is the fallback, and it must still have gone out.
if [ -s "$SCRATCH/notes/wip-"*.diff ]; then pass "wip.diff still written as the fallback"
else fail "wip.diff still written as the fallback"; fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all preserve.sh cases passed"
else
    echo "$FAILED assertion(s) failed"
fi
exit "$FAILED"
