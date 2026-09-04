#!/usr/bin/env bash
# idle-shutdown.sh — runs every 5 min (spot-idle.timer).  If the box has been
# idle for IDLE_SECONDS, preserve state then terminate the instance.
#
# "Active" means any of: a logged-in SSH session, a process matching
# IDLE_ACTIVE_PATTERN, or 1-min load average >= IDLE_LOAD_FLOOR.  Each active
# check refreshes the activity stamp.
#
# Project-independent, but IDLE_ACTIVE_PATTERN is the setting that matters most
# and every project must think about it.  Getting it wrong destroys work:
#
#   iospharo, 2026-08-11.  `pharo` and the suite drivers were missing from the
#   pattern.  A 200-package A/B sweep spends most of its time in network-bound
#   Metacello loads driven by the stock `pharo` VM, so no listed process was
#   running and 1-min load sat near 0.2 — under the floor.  The box counted
#   itself idle for 30 min and terminated ITSELF 74 minutes into the sweep
#   (i-05fa7bff75e0eb0ad, 07:18 UTC, confirmed in CloudTrail: the caller was the
#   instance's own role from its own IP).  All sweep results were lost.
#
# The rule that follows from it: list the process that does the WAITING, not
# just the one that does the work.  A low-CPU, network-bound, long-running job
# is invisible to both this check and a CloudWatch CPU alarm.
set -uo pipefail

IDLE_SECONDS="${IDLE_SECONDS:-1800}"
IDLE_LOAD_FLOOR="${IDLE_LOAD_FLOOR:-0.5}"
IDLE_ACTIVE_PATTERN="${IDLE_ACTIVE_PATTERN:-cmake|cc1plus|make|ninja|clang|gcc|node|claude|git }"
SPOT_PREFIX="${SPOT_PREFIX:-/opt/spot}"
SPOT_USER="${SPOT_USER:-ubuntu}"
STAMP="${IDLE_STAMP:-/var/lib/spot-last-active}"
PRESERVE="${PRESERVE:-${SPOT_PREFIX}/preserve.sh}"

# This unit runs as root (it has to terminate the instance), but preserve.sh
# must NOT.  The git deploy key and the ~/.ssh/config entry that selects it live
# in the box user's home, so a root-run preserve cannot authenticate to GitHub:
# its `git push` fails and only the S3 half of the dump survives.  That was the
# live behaviour in iospharo -- /root/.ssh held nothing but authorized_keys, and
# every preserve that ever reached the log came from the spot watcher, which
# runs as the box user.  `runuser` alone is not enough: without -l it keeps
# HOME=/root, which is the very thing that breaks, so set HOME explicitly.
preserve_as_box_user() {
    if [ "$(id -u)" = 0 ] && [ -n "$SPOT_USER" ] && [ "$SPOT_USER" != root ] \
       && command -v runuser >/dev/null 2>&1; then
        local home
        home=$(getent passwd "$SPOT_USER" | cut -d: -f6)
        runuser -u "$SPOT_USER" -- env HOME="${home:-/home/$SPOT_USER}" \
            "$PRESERVE" "$1"
    else
        "$PRESERVE" "$1"
    fi
}

now=$(date +%s)
[ -f "$STAMP" ] || echo "$now" >"$STAMP"

active=0
# logged-in users (ssh)
[ "$(who | wc -l)" -gt 0 ] && active=1
# meaningful processes (NB: -f matches full cmdline; do NOT combine with -x,
# which would require the whole cmdline to equal the alternation and never match)
if pgrep -f "$IDLE_ACTIVE_PATTERN" >/dev/null 2>&1; then
    active=1
fi
# load average
load1=$(awk '{print $1}' /proc/loadavg)
awk "BEGIN{exit !($load1 >= $IDLE_LOAD_FLOOR)}" && active=1

if [ "$active" -eq 1 ]; then
    echo "$now" >"$STAMP"
    echo "idle-shutdown: active (load=$load1), stamp refreshed"
    exit 0
fi

last=$(cat "$STAMP" 2>/dev/null || echo "$now")
idle=$(( now - last ))
echo "idle-shutdown: idle ${idle}s / threshold ${IDLE_SECONDS}s"

if [ "$idle" -ge "$IDLE_SECONDS" ]; then
    echo "idle-shutdown: threshold reached — preserving + terminating"
    [ -x "$PRESERVE" ] && preserve_as_box_user "idle-${idle}s" || true

    # IMDSv2 token -> instance id + region, then terminate self.
    TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
    IID=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id || true)
    REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/region || true)
    if [ -n "$IID" ] && [ -n "$REGION" ]; then
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$IID" || \
            shutdown -h now
    else
        shutdown -h now
    fi
fi
