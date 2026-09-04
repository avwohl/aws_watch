#!/usr/bin/env bash
# restore-autosave.sh — list and recover the crash dumps preserve.sh leaves in
# S3 when a box is reclaimed or idle-terminated.
#
#   restore-autosave.sh list [<instance-id>]   what dumps exist
#   restore-autosave.sh show <instance>/<ts>   manifest + diffstat, downloads nothing
#   restore-autosave.sh fetch <instance>/<ts>  pull the bundle into this repo
#
# Reads BUCKET (and optionally REPO, AUTOSAVE_PREFIX, BUCKET_REGION) from the
# environment, or from CONFIG_FILE=<a project's config.env>.
#
# `fetch` puts the dump's commits into refs/autosave/<instance>/<ts> and stops.
# It moves no branch and touches no working tree: recovering an autosave is a
# deliberate act, which is the entire reason these dumps are not pushed as
# branches in the first place.  Inspect it, then take what you want:
#
#     git log  refs/autosave/<instance>/<ts>
#     git diff <your-branch>..refs/autosave/<instance>/<ts>
#     git cherry-pick <sha>            # or: git checkout <ref> -- <path>
#     git update-ref -d refs/autosave/<instance>/<ts>    # when you're done
#
# Run it from a clone that already has origin's history — the bundle is a
# DELTA against what origin had when the dump was taken, so `git fetch origin`
# first if the box was ahead of your last fetch.  A dump you cannot unbundle is
# not lost: wip.diff beside it in S3 is a plain patch that needs no objects.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# A project points this at its own config (iospharo: scripts/aws/config.env),
# or exports BUCKET and REPO directly.  Nothing here is project-specific.
[ -n "${CONFIG_FILE:-}" ] && [ -r "$CONFIG_FILE" ] && source "$CONFIG_FILE"
BUCKET="${BUCKET:-}"
AUTOSAVE_PREFIX="${AUTOSAVE_PREFIX:-s3://${BUCKET}/autosave}"
# Default to the repo you are standing in, which is the normal case: you run
# this from the clone you want the work back in.
REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# The bucket lives in BUCKET_REGION; the instances may not.
export AWS_DEFAULT_REGION="${BUCKET_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -r "$HERE/load-creds.sh" ]; then
    source "$HERE/load-creds.sh" >/dev/null 2>&1 || true
fi

if [ -z "$BUCKET" ]; then
    echo "restore-autosave: set BUCKET (or CONFIG_FILE=<your config.env>)" >&2
    exit 2
fi

die() { echo "restore-autosave: $*" >&2; exit 1; }

cmd="${1:-list}"
case "$cmd" in
list)
    want="${2:-}"
    echo "dumps under ${AUTOSAVE_PREFIX}/"
    aws s3 ls "${AUTOSAVE_PREFIX}/${want}" --recursive \
        | awk '$4 ~ /autosave\.bundle$/ {
              n = split($4, p, "/");
              printf "  %-22s %-18s %10.1f KiB   %s %s\n",
                     p[n-2], p[n-1], $3/1024, $1, $2 }' \
        | sort -k2 || die "list failed (creds? bucket ${BUCKET}?)"
    echo
    echo "then: $(basename "$0") show <instance>/<timestamp>"
    ;;
show)
    id="${2:-}"; [ -n "$id" ] || die "usage: $(basename "$0") show <instance>/<ts>"
    aws s3 cp "${AUTOSAVE_PREFIX}/${id}/manifest.txt" - 2>/dev/null \
        || die "no manifest at ${AUTOSAVE_PREFIX}/${id}/"
    echo "--- uncommitted work in that dump (wip.diff) ---"
    aws s3 cp "${AUTOSAVE_PREFIX}/${id}/wip.diff" - 2>/dev/null \
        | git apply --numstat - 2>/dev/null \
        | awk '{printf "  +%-6s -%-6s %s\n", $1, $2, $3}' || echo "  (none)"
    ;;
fetch)
    id="${2:-}"; [ -n "$id" ] || die "usage: $(basename "$0") fetch <instance>/<ts>"
    [ -d "$REPO/.git" ] || die "$REPO is not a git repo (set REPO=...)"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    aws s3 cp "${AUTOSAVE_PREFIX}/${id}/autosave.bundle" "$tmp/a.bundle" \
        || die "no bundle at ${AUTOSAVE_PREFIX}/${id}/"
    aws s3 cp "${AUTOSAVE_PREFIX}/${id}/wip.diff" "$tmp/wip.diff" 2>/dev/null || true

    cd "$REPO"
    # Say plainly what is missing rather than letting `fetch` fail obscurely:
    # a bundle is a delta, and its prerequisites have to be here already.
    if ! git bundle verify "$tmp/a.bundle"; then
        echo
        echo "The bundle needs objects this clone does not have.  Try:"
        echo "    git fetch origin --prune"
        echo "and re-run.  If they are gone from origin too, the dump's"
        echo "uncommitted half is still readable as a plain patch:"
        echo "    $(basename "$0") show ${id}"
        exit 1
    fi
    dest="refs/autosave/${id}"
    # The bundle's own ref is timestamped by the box that wrote it, so read the
    # name out of the bundle rather than guessing (and a wildcard source needs a
    # wildcard destination, which would not give us the name we want here).
    src=$(git bundle list-heads "$tmp/a.bundle" | awk 'NR==1 {print $2}')
    [ -n "$src" ] || die "bundle carries no refs"
    git fetch "$tmp/a.bundle" "${src}:${dest}" \
        || die "fetch from bundle failed"
    got=$(git rev-parse "$dest" 2>/dev/null || echo "?")
    cp "$tmp/wip.diff" "${TMPDIR:-/tmp}/autosave-wip-$(basename "$id").diff" 2>/dev/null || true

    echo
    echo "landed: ${dest}  ->  ${got}"
    git --no-pager log --oneline -5 "$dest" | sed 's/^/    /'
    echo
    echo "nothing else has moved.  Inspect it with:"
    echo "    git log ${dest}"
    echo "    git diff ${WORK_BRANCH:-HEAD}..${dest}"
    echo "and when you are done:"
    echo "    git update-ref -d ${dest}"
    ;;
*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
