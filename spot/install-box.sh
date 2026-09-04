#!/usr/bin/env bash
# install-box.sh — install the spot lifecycle onto an ephemeral build box.
# Run as root ON THE BOX, from a copy of this directory:
#
#     sudo REPO=/home/ubuntu/src/myproj BUCKET=my-build-bucket \
#          WORK_BRANCH=main ./install-box.sh
#
# Installs preserve.sh, spot-watch.sh and idle-shutdown.sh under $SPOT_PREFIX,
# writes $SPOT_PREFIX/env from the knobs below, and enables two systemd units:
#
#     spot-watch.service   watches for the ~2-min spot reclaim notice
#     spot-idle.timer      terminates the box after IDLE_SECONDS idle
#
# Idempotent: safe to re-run to update the scripts or the env.
#
# NO SECRETS go in $SPOT_PREFIX/env -- it is world-readable by design so the
# box user can source it.  Credentials belong to the instance role (S3, EC2)
# and to the box user's ~/.ssh (the git deploy key).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SPOT_PREFIX="${SPOT_PREFIX:-/opt/spot}"
SPOT_USER="${SPOT_USER:-ubuntu}"

# SPOT_TEST_ROOT installs into a scratch tree instead of the real one, and skips
# root and systemctl.  test-install-box.sh drives it.  An installer that has
# only ever been run during a real provision is how a box ends up with no
# preserve at all and nobody finds out until the box is gone.
SPOT_TEST_ROOT="${SPOT_TEST_ROOT:-}"
SYSTEMD_DIR="${SPOT_TEST_ROOT}/etc/systemd/system"
PREFIX="${SPOT_TEST_ROOT}${SPOT_PREFIX}"

if [ -z "$SPOT_TEST_ROOT" ]; then
    [ "$(id -u)" = 0 ] || { echo "install-box.sh: must run as root" >&2; exit 1; }
fi
: "${REPO:?REPO must be set (the checkout on the box)}"
: "${BUCKET:?BUCKET must be set (the S3 bucket dumps go to)}"

install -d "$PREFIX" "$SYSTEMD_DIR"

# preserve.sh writes its notes, diffs and manifests here, and it runs as
# $SPOT_USER (the spot watcher's unit user, and the user idle-shutdown drops
# to).  Create it owned by that user NOW: if it is ever created by a root-run
# preserve instead, every later preserve as the box user silently fails to
# write its diff -- the one artifact that needs no git objects to read.
NOTES_DIR="${NOTES_DIR:-/var/tmp/spot-notes}"
if [ -z "$SPOT_TEST_ROOT" ]; then
    install -d -o "$SPOT_USER" -g "$SPOT_USER" -m 755 "$NOTES_DIR"
else
    install -d -m 755 "${SPOT_TEST_ROOT}${NOTES_DIR}"
fi
install -m755 "$HERE/preserve.sh" "$HERE/spot-watch.sh" "$HERE/idle-shutdown.sh" \
    "$PREFIX/"

# --- $SPOT_PREFIX/env -------------------------------------------------------
# Exactly the knobs the on-box scripts read.  Anything unset here falls back to
# the default in the script, so a project only sets what it cares about.
: >"$PREFIX/env.new"
for k in REPO BUCKET WORK_BRANCH NOTES_DIR S3_PREFIX AUTOSAVE_PREFIX \
         AUTOSAVE_AUTHOR_NAME AUTOSAVE_AUTHOR_EMAIL AUTOSAVE_SUBJECT_PREFIX \
         SPOT_SUBMODULE_PATHS SPOT_PREFIX SPOT_USER \
         IDLE_SECONDS IDLE_LOAD_FLOOR IDLE_ACTIVE_PATTERN IDLE_STAMP; do
    v="${!k:-}"
    [ -n "$v" ] && printf '%s=%s\n' "$k" "$v" >>"$PREFIX/env.new"
done
chmod 644 "$PREFIX/env.new"
mv "$PREFIX/env.new" "$PREFIX/env"

# --- systemd units ----------------------------------------------------------
# spot-idle runs as ROOT: it terminates the instance, and falls back to
# `shutdown -h now`.  It drops to $SPOT_USER for the preserve itself -- see the
# comment in idle-shutdown.sh for why that matters.
cat >"$SYSTEMD_DIR/spot-idle.service" <<UNIT
[Unit]
Description=spot box idle auto-terminate check
[Service]
Type=oneshot
EnvironmentFile=-${SPOT_PREFIX}/env
ExecStart=${SPOT_PREFIX}/idle-shutdown.sh
UNIT

cat >"$SYSTEMD_DIR/spot-idle.timer" <<'UNIT'
[Unit]
Description=run the spot idle check every 5 minutes
[Timer]
OnBootSec=15min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT

# spot-watch runs as $SPOT_USER so preserve.sh can reach the git deploy key in
# that user's ~/.ssh.  It never terminates anything, so it needs nothing more.
cat >"$SYSTEMD_DIR/spot-watch.service" <<UNIT
[Unit]
Description=spot-interruption watcher (preserve state on the 2-min notice)
[Service]
Type=simple
EnvironmentFile=-${SPOT_PREFIX}/env
ExecStart=${SPOT_PREFIX}/spot-watch.sh
Restart=always
RestartSec=10
User=${SPOT_USER}
UNIT

if [ -z "$SPOT_TEST_ROOT" ]; then
    systemctl daemon-reload
    systemctl enable --now spot-idle.timer spot-watch.service
fi

echo "install-box: installed under ${PREFIX}, units in ${SYSTEMD_DIR}"
echo "  repo   : ${REPO}"
echo "  bucket : ${BUCKET}"
echo "  dumps  : ${AUTOSAVE_PREFIX:-s3://${BUCKET}/autosave}/<instance-id>/<ts>/"
echo "  idle   : ${IDLE_SECONDS:-1800}s"
