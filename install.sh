#!/usr/bin/env bash
# Install aws_watch as cron jobs for the current user.
#
#   ./install.sh [MINUTE] [--with-reaper]
#
# MINUTE (0-59) is the minute past each hour to run the hourly watcher; default 7.
#
# --with-reaper additionally installs the DESTRUCTIVE reaper (`reap --apply`,
# every 15 min) and retires the old ~/bin/iospharo-reap-cron.sh crontab line.
# The reaper is refused unless config.yaml has reap.enabled: true and a non-empty
# reap.name_prefixes -- preview it first with:  python3 aws_watch.py reap
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3)"

MINUTE=7
WITH_REAPER=0
for arg in "$@"; do
  case "$arg" in
    --with-reaper) WITH_REAPER=1 ;;
    [0-9]|[0-9][0-9]) MINUTE="$arg" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

CRON_CMD="$PY $REPO/aws_watch.py run >> $REPO/state/cron.log 2>&1"
CRON_LINE="$MINUTE * * * * $CRON_CMD"
MARK="# aws_watch (hourly)"

REAP_CMD="$PY $REPO/aws_watch.py reap --apply >> $REPO/state/reap.log 2>&1"
REAP_LINE="*/15 * * * * $REAP_CMD"
REAP_MARK="# aws_watch reaper (DESTRUCTIVE -- terminates instances)"

echo "aws_watch installer"
echo "  repo:   $REPO"
echo "  python: $PY"
echo "  reaper: $([[ $WITH_REAPER -eq 1 ]] && echo 'YES (--with-reaper)' || echo 'no')"
echo

# 1. Dependencies -----------------------------------------------------------
if ! "$PY" -c 'import boto3, yaml' 2>/dev/null; then
  echo "Installing Python dependencies (boto3, PyYAML) ..."
  "$PY" -m pip install --user -r "$REPO/requirements.txt"
else
  echo "Dependencies present (boto3, PyYAML)."
fi

# 2. Config + creds ---------------------------------------------------------
if [[ ! -f "$REPO/config.yaml" ]]; then
  cp "$REPO/config.example.yaml" "$REPO/config.yaml"
  echo "Created config.yaml from example -- edit it (email, thresholds)."
fi
if [[ ! -f "$REPO/.env" ]]; then
  cp "$REPO/.env.example" "$REPO/.env"
  chmod 600 "$REPO/.env"
  echo "Created .env from example -- PUT YOUR AWS KEYS IN IT (chmod 600 already set)."
fi
mkdir -p "$REPO/state"

# 2b. Reaper safety gate ----------------------------------------------------
# Refuse to wire up auto-termination unless the reaper is actually configured.
if [[ $WITH_REAPER -eq 1 ]]; then
  if ! "$PY" - "$REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import aws_watch as a
c = a.load_config(sys.argv[1] + "/config.yaml")["reap"]
sys.exit(0 if (c.get("enabled") and c.get("name_prefixes")) else 1)
PY
  then
    echo >&2
    echo "REFUSING to install the reaper cron: config.yaml does not have BOTH" >&2
    echo "  reap.enabled: true   AND   a non-empty reap.name_prefixes" >&2
    echo "Configure them, PREVIEW with '$PY $REPO/aws_watch.py reap', then re-run." >&2
    exit 1
  fi
fi

# 3. Cron entries (idempotent) ----------------------------------------------
current="$(crontab -l 2>/dev/null || true)"
# Drop any prior aws_watch lines (watcher + reaper) and the legacy reaper.
current="$(printf '%s\n' "$current" \
  | grep -vF "$REPO/aws_watch.py" \
  | grep -vF "$MARK" \
  | grep -vF "$REAP_MARK" \
  | grep -vF 'iospharo-reap-cron.sh' || true)"

{
  [[ -n "$current" ]] && printf '%s\n' "$current"
  printf '%s\n%s\n' "$MARK" "$CRON_LINE"
  if [[ $WITH_REAPER -eq 1 ]]; then
    printf '%s\n%s\n' "$REAP_MARK" "$REAP_LINE"
  fi
} | crontab -

echo
echo "Installed cron entries:"
echo "  $CRON_LINE"
if [[ $WITH_REAPER -eq 1 ]]; then
  echo "  $REAP_LINE"
  echo
  echo "  *** The reaper is now LIVE and will TERMINATE matching instances every"
  echo "  *** 15 minutes.  Any legacy ~/bin/iospharo-reap-cron.sh line was removed."
fi
echo
echo "Next steps:"
echo "  1. Ensure $REPO/.env has real AWS keys."
echo "  2. Test:    $PY $REPO/aws_watch.py report"
echo "  3. E-mail:  $PY $REPO/aws_watch.py test-email"
if [[ $WITH_REAPER -eq 1 ]]; then
  echo "  4. Preview: $PY $REPO/aws_watch.py reap        # terminates nothing"
fi
