#!/usr/bin/env python3
# lease_cmd.py - the ONLY thing the aws-lease SSH key may run.
#
# It is the forced-command target for a locked-down key in ~wohl/.ssh/
# authorized_keys, so a holder of that key can do nothing on awohl.com except
# register / heartbeat / release / inspect instance leases.  It is also a plain
# local CLI (run it directly with the same verbs).
#
# Request source:
#   * over SSH  -> the request is in $SSH_ORIGINAL_COMMAND (sshd sets this to the
#                  command the client asked for; the forced command ignores it
#                  for execution but we read+validate it here);
#   * local CLI -> the request is sys.argv.
#
# Protocol (whitespace-delimited; note may be base64 as `b64:<...>` to stay
# space/quote-safe across SSH):
#   register <iid> [region] [project] [owner] [note] [lease_until_epoch]
#   beat     <iid> [region] [project] [owner] [note]
#   release  <iid>
#   fresh    [stale_minutes]      # print live instance_ids (read-only)
#   list                          # dump all lease rows (read-only)
#
# Every value is strictly validated; SQL is fully parameterized in lease_db.
from __future__ import annotations

import base64
import os
import re
import shlex
import sys
from datetime import datetime, timezone

import lease_db

IID_RE     = re.compile(r"^i-[0-9a-f]{6,40}$")
TOKEN_RE   = re.compile(r"^[A-Za-z0-9._:@/-]{0,64}$")   # region/project/owner
VERBS      = {"register", "beat", "release", "fresh", "list"}
NOTE_MAX   = 255


def _die(msg, code=2):
    sys.stderr.write("lease: %s\n" % msg)
    return code


def _decode_note(tok):
    if tok is None:
        return ""
    if tok.startswith("b64:"):
        try:
            tok = base64.b64decode(tok[4:], validate=True).decode("utf-8", "replace")
        except Exception:
            tok = ""
    return tok[:NOTE_MAX]


def _check_token(name, val):
    if val and not TOKEN_RE.match(val):
        raise ValueError("bad %s %r" % (name, val))
    return val or ""


def run(argv):
    if not argv:
        return _die("no command (verbs: %s)" % ", ".join(sorted(VERBS)))
    verb = argv[0]
    if verb not in VERBS:
        return _die("unknown verb %r" % verb)

    if verb in ("register", "beat", "release"):
        if len(argv) < 2 or not IID_RE.match(argv[1]):
            return _die("%s needs a valid instance id (i-...)" % verb)
        iid = argv[1]

    try:
        if verb == "release":
            n = lease_db.release(iid)
            print("released %s (%d row%s)" % (iid, n, "" if n == 1 else "s"))
            return 0

        if verb in ("register", "beat"):
            region  = _check_token("region",  argv[2] if len(argv) > 2 else "")
            project = _check_token("project", argv[3] if len(argv) > 3 else "")
            owner   = _check_token("owner",   argv[4] if len(argv) > 4 else "")
            note    = _decode_note(argv[5] if len(argv) > 5 else "")
            lease_until = None
            if verb == "register" and len(argv) > 6 and argv[6].isdigit():
                lease_until = datetime.fromtimestamp(int(argv[6]), timezone.utc).replace(tzinfo=None)
            lease_db.upsert(iid, region=region, project=project, owner=owner,
                            note=note, lease_until=lease_until)
            print("%s %s%s" % (verb, iid, (" [%s]" % project) if project else ""))
            return 0

        if verb == "fresh":
            mins = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 30
            ids = sorted(lease_db.fresh_ids(mins))
            print("\n".join(ids) if ids else "(no live leases within %dm)" % mins)
            return 0

        if verb == "list":
            rows = lease_db.all_rows()
            if not rows:
                print("(no leases)")
                return 0
            print("instance_id\tproject\tregion\tbeat_age\tlease_until\tnote")
            for r in rows:
                age = r["beat_age_s"]
                age_s = "%dm%02ds" % (age // 60, age % 60) if age is not None else "?"
                print("\t".join(str(x) for x in (
                    r["instance_id"], r["project"] or "-", r["region"] or "-",
                    age_s, r["lease_until"] or "-", (r["note"] or "")[:40])))
            return 0
    except Exception as exc:   # noqa: BLE001 - report cleanly, never traceback to a key holder
        return _die("%s failed: %s: %s" % (verb, type(exc).__name__, exc))
    return _die("unhandled verb %r" % verb)


def main():
    orig = os.environ.get("SSH_ORIGINAL_COMMAND")
    if orig is not None:
        try:
            argv = shlex.split(orig)
        except ValueError:
            return _die("unparseable command")
    else:
        argv = sys.argv[1:]
    return run(argv)


if __name__ == "__main__":
    sys.exit(main())
