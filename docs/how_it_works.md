# How aws_watch Works

Back to the [README](../README.md).

## How load average is measured

For each running instance aws_watch first tries **AWS Systems Manager (SSM)**,
running `cat /proc/loadavg; nproc` on the box (no SSH, no inbound ports — the
instance just needs the SSM agent and an instance profile with
`AmazonSSMManagedInstanceCore`). That yields a true Unix load average.

If SSM is not available for an instance, it falls back to the **CloudWatch
`CPUUtilization`** average over the last hour. The report marks which source was
used (`ssm` or `cw`).

## When it e-mails you

It runs hourly from cron but is deliberately quiet:

- **Alert mail** — sent as soon as a *new* problem appears. The same resource is
  not re-reported more often than `renotify_hours` (default 24h), so a persistent
  idle box does not mail you 24 times a day.
- **Daily digest** — one full inventory e-mail per day at `digest.hour`.
- Otherwise it does nothing but log.

Reports are plain text with **tab-separated** columns (no box-drawing
characters) so they survive being pasted into e-mail.

