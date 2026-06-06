#!/usr/bin/env bash
# Install aws_watch as an hourly cron job for the current user.
#
#   ./install.sh [MINUTE]
#
# MINUTE (0-59) is the minute past each hour to run; default 7.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3)"
MINUTE="${1:-7}"
CRON_CMD="$PY $REPO/aws_watch.py run >> $REPO/state/cron.log 2>&1"
CRON_LINE="$MINUTE * * * * $CRON_CMD"
MARK="# aws_watch (hourly)"

echo "aws_watch installer"
echo "  repo:   $REPO"
echo "  python: $PY"
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

# 3. Cron entry (idempotent) ------------------------------------------------
current="$(crontab -l 2>/dev/null || true)"
if grep -Fq "$REPO/aws_watch.py" <<<"$current"; then
  echo "Refreshing existing aws_watch cron entry."
  current="$(grep -vF "$REPO/aws_watch.py" <<<"$current" | grep -vF "$MARK" || true)"
fi
{
  [[ -n "$current" ]] && printf '%s\n' "$current"
  printf '%s\n%s\n' "$MARK" "$CRON_LINE"
} | crontab -

echo
echo "Installed cron entry:"
echo "  $CRON_LINE"
echo
echo "Next steps:"
echo "  1. Ensure $REPO/.env has real AWS keys."
echo "  2. Test:   $PY $REPO/aws_watch.py report"
echo "  3. E-mail: $PY $REPO/aws_watch.py test-email"
