#!/usr/bin/env bash
# test-install-box.sh — drive install-box.sh into a scratch tree.
#
# Checks the things that silently produce a box with no working preserve: the
# scripts not landing, the env file missing a knob the scripts read, the units
# pointing somewhere the scripts are not, and the two units running as the wrong
# user (the idle one MUST be root to terminate the box; the watcher MUST NOT be,
# because preserve.sh needs the box user's ssh key).
#
#     ./test-install-box.sh
#
# Writes nothing outside its scratch directory and needs no root.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/install-box-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$3', got '$2')"; fi; }
has()   { if grep -qF "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3"; fi; }

echo "== a normal install =="
out=$(SPOT_TEST_ROOT="$SCRATCH" SPOT_PREFIX=/opt/spot SPOT_USER=builder \
      REPO=/home/builder/src/proj BUCKET=proj-bucket WORK_BRANCH=trunk \
      IDLE_SECONDS=900 IDLE_ACTIVE_PATTERN='ninja|clang|pharo' \
      AUTOSAVE_AUTHOR_NAME='proj-builder' \
      AUTOSAVE_SUBJECT_PREFIX='wip(proj): autosave on' \
      "$HERE/install-box.sh" 2>&1)
rc=$?
check "installer succeeded" "$rc" "0"

P="$SCRATCH/opt/spot"
U="$SCRATCH/etc/systemd/system"
for f in preserve.sh spot-watch.sh idle-shutdown.sh; do
    if [ -x "$P/$f" ]; then pass "$f installed and executable"
    else fail "$f installed and executable"; fi
done

echo "== the env file carries what the scripts actually read =="
has "$P/env" "REPO=/home/builder/src/proj"            "REPO"
has "$P/env" "BUCKET=proj-bucket"                     "BUCKET"
has "$P/env" "WORK_BRANCH=trunk"                      "WORK_BRANCH"
has "$P/env" "IDLE_SECONDS=900"                       "IDLE_SECONDS"
has "$P/env" "IDLE_ACTIVE_PATTERN=ninja|clang|pharo"  "IDLE_ACTIVE_PATTERN (pipes survive)"
has "$P/env" "AUTOSAVE_SUBJECT_PREFIX=wip(proj): autosave on" \
                                                      "AUTOSAVE_SUBJECT_PREFIX (spaces survive)"
has "$P/env" "SPOT_USER=builder"                      "SPOT_USER"
# An unset knob must be absent, not empty: an empty value in the env file would
# override the script's own default with "".
if grep -q '^SPOT_SUBMODULE_PATHS=' "$P/env"; then
    fail "an unset knob is omitted, not written empty"
else pass "an unset knob is omitted, not written empty"; fi
check "env is world-readable (the box user sources it)" \
      "$(stat -f '%Lp' "$P/env" 2>/dev/null || stat -c '%a' "$P/env")" "644"
if grep -qiE 'secret|password|aws_access_key|private' "$P/env"; then
    fail "no secrets in the env file"
else pass "no secrets in the env file"; fi

echo "== the units point at what was installed =="
has "$U/spot-idle.service"  "ExecStart=/opt/spot/idle-shutdown.sh" "idle unit ExecStart"
has "$U/spot-watch.service" "ExecStart=/opt/spot/spot-watch.sh"    "watch unit ExecStart"
has "$U/spot-idle.service"  "EnvironmentFile=-/opt/spot/env"       "idle unit reads the env"
has "$U/spot-watch.service" "EnvironmentFile=-/opt/spot/env"       "watch unit reads the env"
if [ -f "$U/spot-idle.timer" ]; then pass "the timer exists"
else fail "the timer exists"; fi

echo "== who each unit runs as (this is the bug the move fixed) =="
# The idle unit terminates the instance, so it must be root -- no User= line.
if grep -q '^User=' "$U/spot-idle.service"; then
    fail "idle unit runs as root (no User=)"
else pass "idle unit runs as root (no User=)"; fi
# The watcher runs preserve.sh directly, which needs the box user's ssh key.
has "$U/spot-watch.service" "User=builder" "watch unit runs as the box user"
# And the idle unit's own preserve must drop to that user, or its push cannot
# authenticate -- the defect found on the live iospharo box.
has "$P/idle-shutdown.sh" "runuser -u" "idle-shutdown drops to the box user"
has "$P/idle-shutdown.sh" 'env HOME=' "and sets HOME (runuser alone keeps /root)"

echo "== re-running replaces cleanly =="
SPOT_TEST_ROOT="$SCRATCH" SPOT_PREFIX=/opt/spot SPOT_USER=builder \
    REPO=/home/builder/src/proj BUCKET=proj-bucket WORK_BRANCH=other \
    "$HERE/install-box.sh" >/dev/null 2>&1
has "$P/env" "WORK_BRANCH=other" "a second run rewrites the env"
if grep -q "IDLE_SECONDS=900" "$P/env"; then
    fail "a second run does not keep stale knobs"
else pass "a second run does not keep stale knobs"; fi
if [ -e "$P/env.new" ]; then fail "no temp file left behind"
else pass "no temp file left behind"; fi

echo "== required knobs are required =="
out=$(SPOT_TEST_ROOT="$SCRATCH/bare" REPO=/x "$HERE/install-box.sh" 2>&1; echo "rc=$?")
case "$out" in
    *BUCKET*rc=1*) pass "a missing BUCKET is refused" ;;
    *)             fail "a missing BUCKET is refused (got: $out)" ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all install-box.sh cases passed"
else
    echo "$FAILED assertion(s) failed"
fi
exit "$FAILED"
