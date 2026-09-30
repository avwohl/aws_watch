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
instances](docs/reaper.md). That feature is
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

Load is measured over SSM, with a CloudWatch fallback; alerts are de-duplicated
and a daily digest is sent. See [docs/how_it_works.md](docs/how_it_works.md).

## Requirements

- Python 3.9+
- `boto3` and `PyYAML` (`pip install -r requirements.txt`)
- A local MTA for `sendmail` (e.g. postfix), **or** configure SMTP in the config.
- AWS credentials for a read-only IAM user (see [docs/setup.md](docs/setup.md)).

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

## CLI

```
aws_watch.py run          # the hourly cron logic (alerts + daily digest)
aws_watch.py report       # print full inventory to stdout, send nothing
aws_watch.py digest       # force-send a digest now
aws_watch.py test-email   # send a test e-mail
aws_watch.py reap         # DESTRUCTIVE: preview orphaned-instance reaping
aws_watch.py reap --apply # DESTRUCTIVE: actually terminate (see docs/reaper.md)
```

Useful flags: `--dry-run` (print what would be e-mailed; for `reap`, forces
preview even with `--apply`), `--apply` (`reap` only — really terminate),
`--regions us-east-1,us-east-2`, `--config PATH`, `--env PATH`, `-v`.

## Development

```sh
python3 -m unittest discover -s tests -v
```

The tests cover the pure logic (alerting, suppression, de-dup, age/load parsing,
the reaper's allowlist/protect/grace/idle decisions, and the no-line-drawing
report guarantee) and make no AWS calls.

## Documentation

- [How it works](docs/how_it_works.md) - load-average measurement and when aws_watch sends mail
- [Setup](docs/setup.md) - IAM policy, configuration, S3-compatible endpoints, security
- [Reaper and keep-alive leases](docs/reaper.md) - the optional DESTRUCTIVE orphan reaper, its safety model, config, IAM, and self-expiring leases
- [Spot box lifecycle](docs/spot_lifecycle.md) - the `spot/` scripts that save work on ephemeral build boxes

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
