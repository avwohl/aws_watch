#!/usr/bin/env python3
# lease_db.py - shared MariaDB helpers for the aws_watch instance-lease registry.
#
# Both sides use this module:
#   * the WRITER  - lease_cmd.py, invoked by an actively-working Claude (via the
#                   forced-command SSH key) to register / heartbeat / release;
#   * the READER  - aws_watch.py's reaper, to learn which boxes have a live lease.
#
# Connection uses MariaDB unix_socket auth as the invoking OS user: no password,
# no credentials on disk.  Every timestamp is written and compared in UTC using
# the server's own UTC_TIMESTAMP(), so freshness is correct regardless of the
# server's @@time_zone and needs no clock agreement between writer and reader.
from __future__ import annotations

import os

# Defaults suit awohl.com (MariaDB, unix_socket auth for the OS user).  Override
# any of these from aws_watch config (reap.keepalive.db.*).
DEFAULTS = {
    "unix_socket": "/run/mysqld/mysqld.sock",
    "host": None,            # set host (+port) to use TCP instead of the socket
    "port": 3306,
    "user": None,            # None -> the invoking OS user (unix_socket auth)
    "password": None,        # None -> no password (socket auth)
    "database": "aws_watch",
    "table": "instance_lease",
    "read_default_file": None,   # e.g. "~/.my.cnf" (an alternative to the above)
}


def _cfg(overrides):
    c = dict(DEFAULTS)
    if overrides:
        c.update({k: v for k, v in overrides.items() if v is not None})
    if not c.get("user"):
        import getpass
        c["user"] = getpass.getuser()
    return c


def connect(cfg=None):
    """Open an autocommit connection.  Raises on failure (callers decide policy)."""
    import pymysql
    c = _cfg(cfg)
    kw = dict(user=c["user"], database=c["database"], autocommit=True,
              charset="utf8mb4", connect_timeout=10)
    if c.get("read_default_file"):
        kw["read_default_file"] = os.path.expanduser(c["read_default_file"])
    if c.get("unix_socket") and not c.get("host"):
        kw["unix_socket"] = c["unix_socket"]
    else:
        kw["host"] = c.get("host") or "127.0.0.1"
        kw["port"] = int(c.get("port") or 3306)
    if c.get("password"):
        kw["password"] = c["password"]
    return pymysql.connect(**kw)


def _table(cfg):
    # Table/db come only from config, never from a request; still, restrict to a
    # safe identifier charset so they can be interpolated (binds can't name them).
    c = _cfg(cfg)
    db = "".join(ch for ch in str(c["database"]) if ch.isalnum() or ch == "_")
    tb = "".join(ch for ch in str(c["table"]) if ch.isalnum() or ch == "_")
    return "`%s`.`%s`" % (db, tb)


def upsert(instance_id, region="", project="", owner="", note="",
           lease_until=None, cfg=None):
    """Register or heartbeat one instance.

    Sets last_beat = UTC now and bumps the beat counter; on first insert also
    sets created_at = UTC now.  A non-empty field overwrites the stored value; an
    empty string leaves the existing value untouched (so a bare `beat <id>` keeps
    the metadata a richer `register` provided).  lease_until is a naive-UTC
    datetime hard-expiry, or None for no expiry.
    """
    t = _table(cfg)
    sql = (
        "INSERT INTO %s "
        "(instance_id, region, project, owner, note, created_at, last_beat, lease_until, beats) "
        "VALUES (%%s, %%s, %%s, %%s, %%s, UTC_TIMESTAMP(), UTC_TIMESTAMP(), %%s, 1) "
        "ON DUPLICATE KEY UPDATE "
        "  last_beat   = UTC_TIMESTAMP(), "
        "  beats       = beats + 1, "
        "  region      = IF(VALUES(region)  = '', region,  VALUES(region)), "
        "  project     = IF(VALUES(project) = '', project, VALUES(project)), "
        "  owner       = IF(VALUES(owner)   = '', owner,   VALUES(owner)), "
        "  note        = IF(VALUES(note)    = '', note,    VALUES(note)), "
        "  lease_until = IF(VALUES(lease_until) IS NULL, lease_until, VALUES(lease_until))"
    ) % t
    con = connect(cfg)
    try:
        with con.cursor() as cur:
            cur.execute(sql, (instance_id, region, project, owner, note, lease_until))
    finally:
        con.close()


def release(instance_id, cfg=None):
    """Delete a lease row.  Returns the number of rows removed (0 or 1)."""
    t = _table(cfg)
    con = connect(cfg)
    try:
        with con.cursor() as cur:
            cur.execute("DELETE FROM %s WHERE instance_id = %%s" % t, (instance_id,))
            return cur.rowcount
    finally:
        con.close()


def fresh_ids(stale_after_minutes, cfg=None):
    """Set of instance_ids whose lease is LIVE right now: heartbeat within the
    stale window AND not past lease_until.  Evaluated entirely against the
    server's UTC clock (UTC_TIMESTAMP)."""
    t = _table(cfg)
    sql = (
        "SELECT instance_id FROM %s "
        "WHERE last_beat >= UTC_TIMESTAMP() - INTERVAL %%s MINUTE "
        "  AND (lease_until IS NULL OR lease_until > UTC_TIMESTAMP())"
    ) % t
    con = connect(cfg)
    try:
        with con.cursor() as cur:
            cur.execute(sql, (int(stale_after_minutes),))
            return {row[0] for row in cur.fetchall()}
    finally:
        con.close()


def all_rows(cfg=None):
    """Every lease row with a computed heartbeat age in seconds, for reporting."""
    t = _table(cfg)
    sql = (
        "SELECT instance_id, region, project, note, last_beat, lease_until, "
        "       TIMESTAMPDIFF(SECOND, last_beat, UTC_TIMESTAMP()) AS beat_age_s "
        "FROM %s ORDER BY last_beat DESC"
    ) % t
    con = connect(cfg)
    try:
        with con.cursor() as cur:
            cur.execute(sql)
            cols = [d[0] for d in cur.description]
            return [dict(zip(cols, r)) for r in cur.fetchall()]
    finally:
        con.close()
