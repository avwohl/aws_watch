# aws_watch

An hourly watchdog that scans **every** AWS region for EC2 instances, spot
requests, EBS volumes and Elastic IPs, reports their creation time and current
load, and e-mails you when something looks like wasted spend — an idle instance
left running, an unattached volume, an unassociated Elastic IP, or a box that
has been up far too long.

It exists because it is easy to leave a big test instance running and quietly
burn money. aws_watch nags you about exactly that, and stays quiet otherwise.

It can also, **optionally**, *clean up* a narrowly allowlisted class of
throwaway instances for you — see [Reaping orphaned
instances](#reaping-orphaned-instances-optional-️-destructive). That feature is
destructive and off by default; the core watchdog is strictly read-only.

## What it reports

- **Instances** — id, Name tag, type, architecture, lifecycle (spot/on-demand),
  state, **creation (launch) time**, age, public IP, and **current load
  average** (1/5/15-min) pulled live from the instance.
- **Spot requests** — id, state, status code, type, creation time.
- **Volumes** — id, state, size, type, **creation time**, age, attachment.
- **Elastic IPs** — address, allocation id, association.

## What it flags as waste

- **Idle running instances** — 5-minute load-average per vCPU (or CloudWatch CPU%
  as a fallback) below a threshold, after a startup grace period.
- **Unattached volumes** — EBS volumes in the `available` state.
- **Unassociated Elastic IPs** — allocated but attached to nothing (AWS bills these).
- **Old long-running instances** — on-demand instances running longer than a
  configurable age (default 24h).

Anything in your **suppress** list is still shown in the inventory but never
triggers an alert — use it for resources you intend to run long-term.

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

## Reaping orphaned instances (optional, ⚠️ DESTRUCTIVE)

> **⚠️ THIS TERMINATES EC2 INSTANCES.** It is the only part of aws_watch that
> deletes anything. It is **off by default**, runs as a **separate `reap`
> command** (the hourly watcher never terminates anything), and **previews by
> default** — it only destroys when you add `--apply`. Read this whole section
> before enabling it. A careless allowlist or a missing protect rule can delete
> production. When unsure, leave it disabled.

Automated build/CI flows sometimes launch a throwaway EC2 box and then crash or
get killed before deleting it, leaving it to run (and bill) forever. The reaper
sweeps for exactly those orphans and terminates them — **while refusing to touch
anything that isn't on an explicit allowlist.**

### The safety model

An instance is terminated **only when every one of these is true**:

1. `reap.enabled: true` in `config.yaml`.
2. Its **`Name` (or `Project`) tag matches one of `reap.name_prefixes`** — the
   allowlist. With an empty list, **nothing is ever a candidate** and the reaper
   is a no-op. This is the primary gate: keep it narrow (e.g. `iospharo-*`).
   Matching is **case-sensitive** (`Iospharo-*` will not match `iospharo-…`), and
   a bare `*` matches *everything* — never use one; the reaper warns if you do.
3. It matches **none** of the protect rules — `protect_ids`,
   `protect_name_globs`, `protect_regions`, `protect_zones`, the `protect_tag`
   (default `Reap=skip`) — **and is not in your `suppress` list.** Any single
   match spares it, even if it looks idle and old.
4. It is older than `min_age_minutes` (grace — never reap a box still booting).
5. It is **idle** (low load/CPU, measured exactly like the idle *alert*) **or**
   older than `max_age_hours` (a hard cap).

And even with all of that, **`aws_watch.py reap` only prints what it would do.**
Termination requires `aws_watch.py reap --apply`. The `--apply` is itself refused
unless `reap.enabled` is true *and* `reap.name_prefixes` is non-empty, so a
default or half-configured install can never delete anything.

A box with no load/CPU metric at all, or an undeterminable launch time, is
**kept** — the reaper never acts on missing data.

### How to use it safely

```sh
# 1. Configure the allowlist + protections in config.yaml (see config.example.yaml).
# 2. PREVIEW — terminates nothing, shows the REAP and KEPT tables:
python3 aws_watch.py reap

# 3. Read both tables carefully. Confirm everything under REAP is genuinely
#    disposable and nothing production is missing from KEPT.
# 4. Only then, terminate for real:
python3 aws_watch.py reap --apply

# 5. Install it on a 15-minute cron (also retires any old reaper cron line):
./install.sh --with-reaper
```

`reap --apply` e-mails you a summary whenever it actually terminates something
(`reap.email_on_reap`). To exempt one specific box without editing config, tag
it `Reap=skip` (or add it to `suppress`).

> **Tip:** prefer narrow `name_prefixes` and explicit `regions` over `regions:
> all`. The allowlist makes an all-region sweep safe in principle, but an
> explicit region list is one less way to be surprised.

### Reaper configuration (`config.yaml`)

```yaml
reap:
  enabled: false                 # master switch
  name_prefixes: ["iospharo-*"]  # ALLOWLIST — only these can ever be reaped
  match_tag_keys: [Name, Project]
  regions: [us-east-2]           # [] => use the top-level `regions`
  min_age_minutes: 30            # grace period
  max_age_hours: 12              # hard age cap (null => idle-only)
  idle: {enabled: true, load_per_vcpu: 0.10, cpu_percent: 5.0}
  protect_ids: []                # never-reap instance ids
  protect_name_globs: []         # never-reap Name globs, e.g. "*-prod-*"
  protect_regions: []
  protect_zones: []
  protect_tag: "Reap=skip"       # key=value tag that exempts a box ("" => off)
  delete_alarm_template: null    # e.g. "iospharo-idle-terminate-{id}"
  email_on_reap: true
```

## Requirements

- Python 3.9+
- `boto3` and `PyYAML` (`pip install -r requirements.txt`)
- A local MTA for `sendmail` (e.g. postfix), **or** configure SMTP in the config.
- AWS credentials for a read-only IAM user (below).

## Quick start

```sh
git clone <this repo> aws_watch && cd aws_watch
cp .env.example .env            # then put your AWS keys in .env
cp config.example.yaml config.yaml   # then set email + thresholds
chmod 600 .env

python3 aws_watch.py report     # one-off: print the full inventory
python3 aws_watch.py test-email # confirm e-mail delivery works
./install.sh                    # install the hourly cron job
```

`install.sh` installs dependencies if needed, creates `config.yaml`/`.env` from
the examples if missing, and adds an idempotent hourly crontab entry.

## IAM policy (least privilege, read-only)

Create a dedicated IAM user and attach this policy. Everything is read-only
except `ssm:SendCommand`, which only runs the load-average probe; drop the SSM
statement if you prefer and aws_watch will use the CloudWatch fallback.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Inventory",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRegions",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeVolumes",
        "ec2:DescribeSpotInstanceRequests",
        "ec2:DescribeAddresses",
        "cloudwatch:GetMetricStatistics",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LoadAverageProbe",
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeInstanceInformation",
        "ssm:SendCommand",
        "ssm:GetCommandInvocation"
      ],
      "Resource": "*"
    }
  ]
}
```

### Extra permissions for the reaper (only if you enable it)

The read-only policy above is enough for the watcher. The **reaper** additionally
needs the power to terminate instances (and, optionally, delete the per-instance
idle alarm). This is a privileged grant — add it only if you use `reap`, and
prefer a separate credential scoped to the regions/resources you actually reap:

```json
{
  "Sid": "Reaper",
  "Effect": "Allow",
  "Action": [
    "ec2:TerminateInstances",
    "cloudwatch:DeleteAlarms"
  ],
  "Resource": "*"
}
```

Drop the `cloudwatch:DeleteAlarms` action if you leave `reap.delete_alarm_template`
unset. You can tighten `Resource`/add `Condition` keys (e.g. a tag condition that
mirrors your `name_prefixes`) for defense in depth.

## Configuration

Credentials live in `.env` (git-ignored). Everything else is in `config.yaml`
(also git-ignored); see `config.example.yaml` for the fully documented template.
Key settings:

- `email.to` / `email.method` (`sendmail` or `smtp`)
- `regions` — `all` or an explicit list
- `digest.hour` — local hour for the daily inventory
- `renotify_hours` — alert de-duplication window
- `alerts.*` — enable/disable each check and tune its thresholds
- `suppress` — resource ids or `name:<glob>` to exclude from alerts

## CLI

```
aws_watch.py run          # the hourly cron logic (alerts + daily digest)
aws_watch.py report       # print full inventory to stdout, send nothing
aws_watch.py digest       # force-send a digest now
aws_watch.py test-email   # send a test e-mail
aws_watch.py reap         # DESTRUCTIVE: preview orphaned-instance reaping
aws_watch.py reap --apply # DESTRUCTIVE: actually terminate (see the reaper section)
```

Useful flags: `--dry-run` (print what would be e-mailed; for `reap`, forces
preview even with `--apply`), `--apply` (`reap` only — really terminate),
`--regions us-east-1,us-east-2`, `--config PATH`, `--env PATH`, `-v`.

## A note on S3-compatible endpoints

If the host is configured to use an S3-compatible service (e.g. Wasabi) via
`AWS_ENDPOINT_URL` or `~/.aws/config`, that would otherwise hijack these API
calls. aws_watch ignores the machine-wide AWS config and uses **only** the
credentials in its own `.env`, talking to real AWS endpoints.

## Security

- `.env` is git-ignored and should be `chmod 600`. Never commit real keys.
- Use a dedicated, least-privilege IAM user (policy above).
- If a key is ever pasted somewhere it shouldn't be, rotate it in IAM.

## Development

```sh
python3 -m unittest discover -s tests -v
```

The tests cover the pure logic (alerting, suppression, de-dup, age/load parsing,
the reaper's allowlist/protect/grace/idle decisions, and the no-line-drawing
report guarantee) and make no AWS calls.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
