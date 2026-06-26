#!/usr/bin/env bash
# aws-lease-beat-hook.sh - Claude Code PostToolUse hook: heartbeat the aws_watch
# keep-alive lease for the temporary cloud box this Claude is actively working on.
#
# This is the ONLY thing that updates a lease heartbeat, and it fires on Claude's
# tool use -- so the box stays alive exactly while a Claude is running / looping /
# in a goal, and the moment that Claude finishes and walks away the heartbeats
# stop, the lease goes stale, and aws_watch reaps the box.  No cron, no daemon,
# no provisioning script ever beats; only a working Claude does.
#
# It is wired as a PostToolUse hook (see README).  It must be cheap and silent:
# it no-ops in well under a millisecond off-box, never blocks the tool call, and
# never fails it (always exits 0).  Throttled to one beat per AWS_LEASE_THROTTLE
# seconds.  Reads its stdin (the hook JSON) but does not need it.
#
# Box identity, cheapest-first:
#   1. $AWS_LEASE_IID                      - explicit (a Mac/control session that
#                                            is driving a box exports this).
#   2. EC2 Nitro DMI board_asset_tag       - the instance id, no network call,
#                                            present only when running ON the box.
# If neither yields an i-... id, this is not a leased-box context -> silent no-op.
set -u

THROTTLE="${AWS_LEASE_THROTTLE:-600}"          # >= one beat per 10 min (< 20m spec)
STAMP="${TMPDIR:-/tmp}/aws-lease-beat.stamp"

# Throttle FIRST (a single cheap file stat) so the common path does no work.
now="$(date +%s 2>/dev/null || echo 0)"
last=0; [ -f "$STAMP" ] && last="$(cat "$STAMP" 2>/dev/null || echo 0)"
[ "$last" -gt 0 ] && [ $(( now - last )) -lt "$THROTTLE" ] && exit 0

# Identify the box (no network on either path).
IID="${AWS_LEASE_IID:-}"
if [ -z "$IID" ]; then
    IID="$(cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null || true)"
fi
case "$IID" in i-*) ;; *) exit 0 ;; esac     # not on/attached to a leased box

echo "$now" >"$STAMP" 2>/dev/null || true

# Beat, detached and time-boxed, so this never adds latency to the tool call.
# region/project may be empty here -- register (provision.sh) already set them and
# a bare beat preserves existing metadata.  owner defaults to "claude".
KEY="${AWS_LEASE_KEY:-$HOME/.ssh/aws-lease}"
( ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new -p "${AWS_LEASE_PORT:-24}" \
      "${AWS_LEASE_HOST:-wohl@awohl.com}" \
      "beat $IID ${AWS_LEASE_REGION:-} ${AWS_LEASE_PROJECT:-} ${AWS_LEASE_OWNER:-claude}" \
      >/dev/null 2>&1 || true ) &
exit 0
