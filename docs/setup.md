# Setup: IAM, Configuration and Security

Back to the [README](../README.md).

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

The reaper needs extra permissions. See [reaper.md](reaper.md#extra-permissions-for-the-reaper-only-if-you-enable-it).

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

## A note on S3-compatible endpoints

If the host is configured to use an S3-compatible service (e.g. Wasabi) via
`AWS_ENDPOINT_URL` or `~/.aws/config`, that would otherwise hijack these API
calls. aws_watch ignores the machine-wide AWS config and uses **only** the
credentials in its own `.env`, talking to real AWS endpoints.

## Security

- `.env` is git-ignored and should be `chmod 600`. Never commit real keys.
- Use a dedicated, least-privilege IAM user (policy above).
- If a key is ever pasted somewhere it shouldn't be, rotate it in IAM.

