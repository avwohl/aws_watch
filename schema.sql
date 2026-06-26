-- aws_watch instance-lease registry.
-- Central "keep-alive" table for temporary cloud instances created by any
-- project on this account.  Lives on awohl.com (MariaDB).
--
--   Register (creator, once, within the reaper's grace window):
--       a row keyed by instance_id, last_beat = registration time.
--   Heartbeat (ONLY an actively-working Claude, every <20 min):
--       UPDATE last_beat = UTC_TIMESTAMP().
--   Release (teardown / done):
--       DELETE the row.
--
-- aws_watch's reaper reads this table: a fresh last_beat spares an otherwise-
-- idle box; a stale/absent lease lets the normal idle/age rules reap it.
--
-- All timestamps are UTC (writers MUST use UTC_TIMESTAMP(), never NOW(), so the
-- comparison against aws_watch's UTC clock is correct regardless of server TZ).

CREATE DATABASE IF NOT EXISTS aws_watch
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS aws_watch.instance_lease (
    instance_id  VARCHAR(40)  NOT NULL PRIMARY KEY,   -- e.g. i-0123456789abcdef0
    region       VARCHAR(32)  NOT NULL DEFAULT '',     -- e.g. us-east-2
    project      VARCHAR(64)  NOT NULL DEFAULT '',     -- e.g. iospharo-x64
    owner        VARCHAR(128) NOT NULL DEFAULT '',     -- who/what registered it
    note         VARCHAR(255) NOT NULL DEFAULT '',     -- freeform ("x86 sunit a/b")
    created_at   DATETIME     NOT NULL,                -- when first registered (UTC)
    last_beat    DATETIME     NOT NULL,                -- last heartbeat (UTC)
    lease_until  DATETIME     NULL,                    -- optional hard expiry (UTC); NULL = none
    beats        INT          NOT NULL DEFAULT 0,      -- heartbeat counter (telemetry)
    INDEX idx_last_beat (last_beat)
) ENGINE=InnoDB;
