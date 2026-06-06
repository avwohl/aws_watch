#!/usr/bin/env python3
# aws_watch - hourly watchdog for idle / wasteful EC2 resources.
# Copyright (C) 2026  Aaron Wohl
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
"""aws_watch - scan every region for EC2 instances, spot requests, volumes and
Elastic IPs; report their creation time and (for instances) current load
average; and e-mail an alert when something looks like wasted spend.

Designed to run hourly from cron.  It sends an e-mail only when there is
something worth flagging, plus one full-inventory "digest" once a day.

The host this runs on uses Wasabi for S3 (AWS_ENDPOINT_URL / ~/.aws/config point
at wasabisys.com).  This tool deliberately ignores that machine-wide config and
talks to *real* AWS using only the credentials in its own .env file.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import json
import logging
import os
import smtplib
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formatdate

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ENV = os.path.join(HERE, ".env")
DEFAULT_CONFIG = os.path.join(HERE, "config.yaml")
DEFAULT_STATE = os.path.join(HERE, "state", "aws_watch_state.json")
DEFAULT_LOG = os.path.join(HERE, "state", "aws_watch.log")

# SSM RunShellScript polling budget (seconds) per region.
SSM_TIMEOUT = 25
SSM_POLL = 2

SEVERITY_ORDER = {"HIGH": 0, "WARN": 1, "LOW": 2, "INFO": 3}

log = logging.getLogger("aws_watch")


# --------------------------------------------------------------------------- #
# Configuration                                                               #
# --------------------------------------------------------------------------- #

CONFIG_DEFAULTS = {
    "email": {
        "to": "xawsx@awohl.com",
        "from": None,                       # default: aws_watch@<fqdn>
        "subject_prefix": "[aws_watch]",
        "method": "sendmail",               # "sendmail" or "smtp"
        "sendmail_path": "/usr/sbin/sendmail",
        "smtp": {
            "host": "localhost",
            "port": 25,
            "use_tls": False,
            "username": None,
            "password": None,
        },
    },
    "regions": "all",                       # "all" or explicit list
    "digest": {"hour": 8},                  # local hour (0-23) for daily inventory
    "renotify_hours": 24,                   # re-alert about the same resource at most this often
    "alerts": {
        "idle_instances": {
            "enabled": True,
            "min_age_minutes": 30,          # ignore freshly launched boxes
            "load_per_vcpu": 0.10,          # 5-min load / vCPU below this => idle
            "cpu_percent": 5.0,             # CloudWatch CPU% fallback below this => idle
        },
        "unattached_volumes": {"enabled": True},
        "unassociated_eips": {"enabled": True},
        "old_instances": {
            "enabled": True,
            "max_age_hours": 24,
            "include_spot": False,
        },
    },
    "suppress": [],                         # resource ids or "name:<glob>" excluded from alerts
}


def deep_merge(base: dict, override: dict) -> dict:
    """Recursively merge *override* into a copy of *base*."""
    out = dict(base)
    for key, val in (override or {}).items():
        if isinstance(val, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], val)
        else:
            out[key] = val
    return out


def load_env_file(path: str) -> dict:
    """Parse a simple KEY=VALUE .env file (no shell expansion)."""
    creds = {}
    if not os.path.exists(path):
        return creds
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key:
                creds[key] = val
    return creds


def load_config(path: str) -> dict:
    import yaml
    user = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            user = yaml.safe_load(fh) or {}
    else:
        log.warning("config %s not found; using built-in defaults", path)
    cfg = deep_merge(CONFIG_DEFAULTS, user)
    if not cfg["email"].get("from"):
        cfg["email"]["from"] = "aws_watch@%s" % socket.getfqdn()
    return cfg


def isolate_aws_env():
    """Stop boto3 from inheriting this machine's Wasabi-oriented AWS config.

    The host sets AWS_ENDPOINT_URL and a default ~/.aws/config endpoint_url that
    point at Wasabi.  We want real AWS, so strip those influences before any
    client is built.  Credentials are supplied explicitly from our own .env.
    """
    for var in (
        "AWS_ENDPOINT_URL",
        "AWS_ENDPOINT_URL_EC2",
        "AWS_ENDPOINT_URL_S3",
        "AWS_ENDPOINT_URL_SSM",
        "AWS_ENDPOINT_URL_CLOUDWATCH",
        "AWS_PROFILE",
        "AWS_DEFAULT_PROFILE",
    ):
        os.environ.pop(var, None)
    os.environ["AWS_CONFIG_FILE"] = os.devnull
    os.environ["AWS_SHARED_CREDENTIALS_FILE"] = os.devnull


def make_session(creds: dict):
    import boto3
    key = creds.get("AWS_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID")
    secret = creds.get("AWS_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY")
    token = creds.get("AWS_SESSION_TOKEN") or os.environ.get("AWS_SESSION_TOKEN")
    if not key or not secret:
        raise SystemExit(
            "No AWS credentials found.  Put AWS_ACCESS_KEY_ID / "
            "AWS_SECRET_ACCESS_KEY in %s" % DEFAULT_ENV
        )
    return boto3.Session(
        aws_access_key_id=key,
        aws_secret_access_key=secret,
        aws_session_token=token,
    )


# --------------------------------------------------------------------------- #
# Time helpers                                                                 #
# --------------------------------------------------------------------------- #

def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def fmt_dt(dt) -> str:
    if not dt:
        return "-"
    if isinstance(dt, str):
        return dt
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def age_seconds(dt, ref=None) -> float | None:
    if not dt:
        return None
    ref = ref or now_utc()
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return (ref - dt).total_seconds()


def fmt_age(seconds) -> str:
    if seconds is None:
        return "-"
    seconds = int(seconds)
    if seconds < 0:
        seconds = 0
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m, _ = divmod(rem, 60)
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"


# --------------------------------------------------------------------------- #
# Collection                                                                   #
# --------------------------------------------------------------------------- #

def get_regions(session, cfg) -> list:
    regions = cfg.get("regions", "all")
    if isinstance(regions, list) and regions:
        return regions
    ec2 = session.client("ec2", region_name="us-east-1")
    resp = ec2.describe_regions(AllRegions=True)
    return sorted(
        r["RegionName"]
        for r in resp["Regions"]
        if r.get("OptInStatus") in ("opt-in-not-required", "opted-in")
    )


def _name_tag(tags) -> str:
    for t in tags or []:
        if t.get("Key") == "Name":
            return t.get("Value", "")
    return ""


def get_vcpus(ec2, itypes: set, cache: dict, lock: threading.Lock) -> None:
    """Populate *cache* with {instance_type: vcpus} for any missing types."""
    with lock:
        missing = [t for t in itypes if t not in cache]
    if not missing:
        return
    try:
        resp = ec2.describe_instance_types(InstanceTypes=missing)
        found = {
            it["InstanceType"]: it.get("VCpuInfo", {}).get("DefaultVCpus")
            for it in resp.get("InstanceTypes", [])
        }
    except Exception as exc:  # noqa: BLE001 - best-effort enrichment
        log.debug("describe_instance_types failed: %s", exc)
        found = {}
    with lock:
        for t in missing:
            cache[t] = found.get(t)


def parse_loadavg(output: str):
    """Parse the combined stdout of `cat /proc/loadavg; nproc`."""
    lines = [ln.strip() for ln in (output or "").splitlines() if ln.strip()]
    if not lines:
        return None
    parts = lines[0].split()
    try:
        load = (float(parts[0]), float(parts[1]), float(parts[2]))
    except (IndexError, ValueError):
        return None
    nproc = None
    if len(lines) > 1 and lines[-1].isdigit():
        nproc = int(lines[-1])
    return {"load1": load[0], "load5": load[1], "load15": load[2], "nproc": nproc}


def load_via_ssm(session, region, instance_ids):
    """Return {instance_id: {load1,load5,load15,nproc}} via SSM RunShellScript."""
    if not instance_ids:
        return {}
    ssm = session.client("ssm", region_name=region)
    # Which of these instances are actually managed and online?
    online = set()
    try:
        paginator = ssm.get_paginator("describe_instance_information")
        for page in paginator.paginate():
            for info in page.get("InstanceInformationList", []):
                if info.get("PingStatus") == "Online":
                    online.add(info["InstanceId"])
    except Exception as exc:  # noqa: BLE001
        log.debug("[%s] ssm describe_instance_information failed: %s", region, exc)
        return {}
    targets = [i for i in instance_ids if i in online]
    if not targets:
        return {}
    try:
        cmd = ssm.send_command(
            InstanceIds=targets,
            DocumentName="AWS-RunShellScript",
            Comment="aws_watch load average probe",
            Parameters={"commands": ["cat /proc/loadavg", "nproc"]},
        )
        command_id = cmd["Command"]["CommandId"]
    except Exception as exc:  # noqa: BLE001
        log.debug("[%s] ssm send_command failed: %s", region, exc)
        return {}

    results = {}
    deadline = time.monotonic() + SSM_TIMEOUT
    pending = set(targets)
    while pending and time.monotonic() < deadline:
        time.sleep(SSM_POLL)
        for iid in list(pending):
            try:
                inv = ssm.get_command_invocation(CommandId=command_id, InstanceId=iid)
            except Exception:  # invocation may not exist yet
                continue
            status = inv.get("Status")
            if status in ("Pending", "InProgress", "Delayed"):
                continue
            pending.discard(iid)
            if status == "Success":
                parsed = parse_loadavg(inv.get("StandardOutputContent", ""))
                if parsed:
                    results[iid] = parsed
    return results


def cpu_via_cloudwatch(session, region, instance_id):
    """Average CPUUtilization (%) over the last hour, or None."""
    cw = session.client("cloudwatch", region_name=region)
    end = now_utc()
    start = datetime.fromtimestamp(end.timestamp() - 3600, tz=timezone.utc)
    try:
        resp = cw.get_metric_statistics(
            Namespace="AWS/EC2",
            MetricName="CPUUtilization",
            Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
            StartTime=start,
            EndTime=end,
            Period=300,
            Statistics=["Average"],
        )
    except Exception as exc:  # noqa: BLE001
        log.debug("[%s] cloudwatch failed for %s: %s", region, instance_id, exc)
        return None
    points = resp.get("Datapoints", [])
    if not points:
        return None
    return sum(p["Average"] for p in points) / len(points)


def collect_region(session, region, cfg, vcpu_cache, lock):
    """Collect all resources of interest in one region."""
    out = {"region": region, "instances": [], "volumes": [], "spot": [], "eips": [], "error": None}
    try:
        ec2 = session.client("ec2", region_name=region)

        # --- instances ---
        instances = []
        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate():
            for resv in page.get("Reservations", []):
                for inst in resv.get("Instances", []):
                    state = inst.get("State", {}).get("Name")
                    if state == "terminated":
                        continue
                    instances.append({
                        "id": inst["InstanceId"],
                        "name": _name_tag(inst.get("Tags")),
                        "type": inst.get("InstanceType"),
                        "arch": inst.get("Architecture"),
                        "lifecycle": inst.get("InstanceLifecycle", "on-demand"),
                        "state": state,
                        "launch": inst.get("LaunchTime"),
                        "az": inst.get("Placement", {}).get("AvailabilityZone"),
                        "public_ip": inst.get("PublicIpAddress"),
                        "private_ip": inst.get("PrivateIpAddress"),
                        "region": region,
                        "load": None,       # filled below
                        "cpu": None,
                        "vcpus": None,
                        "metric_src": None,
                    })

        running = [i for i in instances if i["state"] == "running"]
        if running:
            get_vcpus(ec2, {i["type"] for i in running}, vcpu_cache, lock)
            with lock:
                for i in running:
                    i["vcpus"] = vcpu_cache.get(i["type"])
            # Real load average via SSM where possible ...
            loads = load_via_ssm(session, region, [i["id"] for i in running])
            for i in running:
                if i["id"] in loads:
                    i["load"] = loads[i["id"]]
                    if not i["vcpus"] and loads[i["id"]].get("nproc"):
                        i["vcpus"] = loads[i["id"]]["nproc"]
                    i["metric_src"] = "ssm"
            # ... CloudWatch CPU fallback for the rest.
            for i in running:
                if i["load"] is None:
                    cpu = cpu_via_cloudwatch(session, region, i["id"])
                    if cpu is not None:
                        i["cpu"] = cpu
                        i["metric_src"] = "cloudwatch"
        out["instances"] = instances

        # --- volumes ---
        vpag = ec2.get_paginator("describe_volumes")
        for page in vpag.paginate():
            for vol in page.get("Volumes", []):
                attach = vol.get("Attachments", [])
                out["volumes"].append({
                    "id": vol["VolumeId"],
                    "state": vol.get("State"),
                    "size": vol.get("Size"),
                    "vtype": vol.get("VolumeType"),
                    "create": vol.get("CreateTime"),
                    "az": vol.get("AvailabilityZone"),
                    "attached_to": attach[0]["InstanceId"] if attach else None,
                    "region": region,
                })

        # --- spot requests ---
        spot = ec2.describe_spot_instance_requests().get("SpotInstanceRequests", [])
        for sr in spot:
            out["spot"].append({
                "id": sr["SpotInstanceRequestId"],
                "state": sr.get("State"),
                "status": sr.get("Status", {}).get("Code"),
                "itype": sr.get("LaunchSpecification", {}).get("InstanceType"),
                "instance_id": sr.get("InstanceId"),
                "create": sr.get("CreateTime"),
                "region": region,
            })

        # --- elastic IPs ---
        for addr in ec2.describe_addresses().get("Addresses", []):
            out["eips"].append({
                "id": addr.get("AllocationId") or addr.get("PublicIp"),
                "public_ip": addr.get("PublicIp"),
                "assoc": addr.get("AssociationId"),
                "instance_id": addr.get("InstanceId"),
                "region": region,
            })

    except Exception as exc:  # noqa: BLE001 - record and continue other regions
        out["error"] = str(exc)
        log.warning("[%s] collection error: %s", region, exc)
    return out


def collect_all(session, cfg, regions):
    vcpu_cache: dict = {}
    lock = threading.Lock()
    inventory = {"instances": [], "volumes": [], "spot": [], "eips": [], "errors": {}}
    workers = min(16, max(4, len(regions)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {
            ex.submit(collect_region, session, r, cfg, vcpu_cache, lock): r
            for r in regions
        }
        for fut in concurrent.futures.as_completed(futs):
            res = fut.result()
            if res["error"]:
                inventory["errors"][res["region"]] = res["error"]
            for key in ("instances", "volumes", "spot", "eips"):
                inventory[key].extend(res[key])
    for key in ("instances", "volumes", "spot", "eips"):
        inventory[key].sort(key=lambda x: (x["region"], x.get("id") or ""))
    return inventory


# --------------------------------------------------------------------------- #
# Suppression + alerts                                                         #
# --------------------------------------------------------------------------- #

def is_suppressed(resource_id, name, cfg) -> bool:
    for entry in cfg.get("suppress") or []:
        entry = str(entry)
        if entry == resource_id:
            return True
        if entry.startswith("name:") and name and fnmatch.fnmatch(name, entry[5:]):
            return True
    return False


def instance_load5_per_vcpu(inst):
    if inst.get("load") and inst.get("vcpus"):
        return inst["load"]["load5"] / max(1, inst["vcpus"])
    return None


def compute_alerts(inventory, cfg) -> list:
    alerts = []
    acfg = cfg["alerts"]

    idle = acfg["idle_instances"]
    old = acfg["old_instances"]
    for inst in inventory["instances"]:
        if inst["state"] != "running":
            continue
        if is_suppressed(inst["id"], inst["name"], cfg):
            continue
        age = age_seconds(inst["launch"])
        label = inst["name"] or inst["id"]

        # idle detection
        if idle.get("enabled") and age is not None and age >= idle["min_age_minutes"] * 60:
            per = instance_load5_per_vcpu(inst)
            if per is not None and per < idle["load_per_vcpu"]:
                alerts.append({
                    "type": "idle_instance", "severity": "HIGH",
                    "resource_id": inst["id"], "name": inst["name"], "region": inst["region"],
                    "reason": "load5/vCPU %.2f < %.2f (load %.2f on %s vCPU, %s)" % (
                        per, idle["load_per_vcpu"], inst["load"]["load5"],
                        inst["vcpus"], inst["type"]),
                })
            elif per is None and inst.get("cpu") is not None and inst["cpu"] < idle["cpu_percent"]:
                alerts.append({
                    "type": "idle_instance", "severity": "HIGH",
                    "resource_id": inst["id"], "name": inst["name"], "region": inst["region"],
                    "reason": "CPU %.1f%% < %.1f%% over last hour (%s)" % (
                        inst["cpu"], idle["cpu_percent"], inst["type"]),
                })

        # old long-running instance
        if old.get("enabled") and age is not None and age >= old["max_age_hours"] * 3600:
            if inst["lifecycle"] != "spot" or old.get("include_spot"):
                alerts.append({
                    "type": "old_instance", "severity": "WARN",
                    "resource_id": inst["id"], "name": inst["name"], "region": inst["region"],
                    "reason": "running %s (> %dh), %s %s" % (
                        fmt_age(age), old["max_age_hours"], inst["lifecycle"], inst["type"]),
                })

    if acfg["unattached_volumes"].get("enabled"):
        for vol in inventory["volumes"]:
            if vol["state"] == "available" and not is_suppressed(vol["id"], None, cfg):
                alerts.append({
                    "type": "unattached_volume", "severity": "WARN",
                    "resource_id": vol["id"], "name": "", "region": vol["region"],
                    "reason": "available (unattached) %s GiB %s, created %s" % (
                        vol["size"], vol["vtype"], fmt_dt(vol["create"])),
                })

    if acfg["unassociated_eips"].get("enabled"):
        for eip in inventory["eips"]:
            if not eip["assoc"] and not is_suppressed(eip["id"], None, cfg):
                alerts.append({
                    "type": "unassociated_eip", "severity": "WARN",
                    "resource_id": eip["id"], "name": "", "region": eip["region"],
                    "reason": "Elastic IP %s not associated with anything" % eip["public_ip"],
                })

    alerts.sort(key=lambda a: (SEVERITY_ORDER.get(a["severity"], 9), a["region"], a["resource_id"]))
    return alerts


# --------------------------------------------------------------------------- #
# State (alert de-duplication + digest tracking)                              #
# --------------------------------------------------------------------------- #

def fingerprint(alert) -> str:
    return "%s:%s" % (alert["type"], alert["resource_id"])


def load_state(path) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"alerts": {}, "last_digest_date": None}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, path)


def is_new_alert(fp, state, ref, renotify_hours) -> bool:
    last = state.get("alerts", {}).get(fp)
    if not last:
        return True
    try:
        last_dt = datetime.fromisoformat(last)
    except ValueError:
        return True
    if last_dt.tzinfo is None:
        last_dt = last_dt.replace(tzinfo=timezone.utc)
    return (ref - last_dt).total_seconds() >= renotify_hours * 3600


# --------------------------------------------------------------------------- #
# Report formatting (tabs only - no line-drawing characters; e-mail safe)     #
# --------------------------------------------------------------------------- #

def _section(title, header, rows) -> str:
    lines = ["=== %s (%d) ===" % (title, len(rows))]
    if not rows:
        lines.append("(none)")
    else:
        lines.append("\t".join(header))
        for row in rows:
            lines.append("\t".join("" if c is None else str(c) for c in row))
    return "\n".join(lines)


def _instance_metric(inst) -> str:
    if inst.get("load"):
        l = inst["load"]
        return "load %.2f %.2f %.2f/%sv(ssm)" % (
            l["load1"], l["load5"], l["load15"], inst.get("vcpus") or "?")
    if inst.get("cpu") is not None:
        return "cpu %.1f%%(cw)" % inst["cpu"]
    if inst["state"] == "running":
        return "n/a"
    return "-"


def format_inventory(inventory, cfg) -> str:
    ref = now_utc()
    chunks = []

    inst_rows = []
    for i in inventory["instances"]:
        sup = " (suppressed)" if is_suppressed(i["id"], i["name"], cfg) else ""
        inst_rows.append([
            i["region"], i["id"], (i["name"] or "-") + sup, i["type"], i["arch"],
            i["lifecycle"], i["state"], fmt_dt(i["launch"]),
            fmt_age(age_seconds(i["launch"], ref)), _instance_metric(i),
            i.get("public_ip") or "-",
        ])
    chunks.append(_section(
        "INSTANCES", ["region", "id", "name", "type", "arch", "lifecycle",
                      "state", "created", "age", "metric", "public_ip"], inst_rows))

    spot_rows = [[
        s["region"], s["id"], s["state"], s["status"], s.get("itype") or "-",
        s.get("instance_id") or "-", fmt_dt(s["create"]),
    ] for s in inventory["spot"]]
    chunks.append(_section(
        "SPOT REQUESTS", ["region", "id", "state", "status", "type", "instance", "created"],
        spot_rows))

    vol_rows = []
    for v in inventory["volumes"]:
        sup = " (suppressed)" if is_suppressed(v["id"], None, cfg) else ""
        vol_rows.append([
            v["region"], v["id"] + sup, v["state"], v["size"], v["vtype"],
            fmt_dt(v["create"]), fmt_age(age_seconds(v["create"], ref)),
            v.get("attached_to") or "UNATTACHED",
        ])
    chunks.append(_section(
        "VOLUMES", ["region", "id", "state", "GiB", "type", "created", "age", "attached_to"],
        vol_rows))

    eip_rows = [[
        e["region"], e["public_ip"], e["id"],
        e.get("instance_id") or ("ASSOCIATED" if e["assoc"] else "UNASSOCIATED"),
    ] for e in inventory["eips"]]
    chunks.append(_section(
        "ELASTIC IPS", ["region", "public_ip", "alloc_id", "association"], eip_rows))

    if inventory["errors"]:
        err_rows = [[r, msg] for r, msg in sorted(inventory["errors"].items())]
        chunks.append(_section("REGION ERRORS", ["region", "error"], err_rows))

    return "\n\n".join(chunks)


def format_alerts(alerts) -> str:
    rows = [[a["severity"], a["type"], a["region"], a["resource_id"],
             (a["name"] or "-"), a["reason"]] for a in alerts]
    return _section("ALERTS", ["severity", "type", "region", "resource", "name", "reason"], rows)


def summary_line(inventory, alerts, account) -> str:
    running = sum(1 for i in inventory["instances"] if i["state"] == "running")
    return ("account %s | %d running / %d instances | %d spot | %d volumes | "
            "%d eips | %d alerts | %s" % (
                account, running, len(inventory["instances"]), len(inventory["spot"]),
                len(inventory["volumes"]), len(inventory["eips"]), len(alerts),
                now_utc().strftime("%Y-%m-%d %H:%M UTC")))


def build_body(inventory, alerts, cfg, account, mode) -> str:
    head = [summary_line(inventory, alerts, account), ""]
    if alerts:
        head.append(format_alerts(alerts))
        head.append("")
    if mode in ("digest", "report"):
        head.append(format_inventory(inventory, cfg))
    else:  # alert e-mail: keep it focused, full inventory comes in the digest
        head.append("(full inventory is sent in the daily digest)")
    return "\n".join(head).rstrip() + "\n"


# --------------------------------------------------------------------------- #
# E-mail                                                                       #
# --------------------------------------------------------------------------- #

def send_email(cfg, subject, body):
    ecfg = cfg["email"]
    msg = EmailMessage()
    msg["Subject"] = "%s %s" % (ecfg["subject_prefix"], subject)
    msg["From"] = ecfg["from"]
    msg["To"] = ecfg["to"]
    msg["Date"] = formatdate(localtime=True)
    msg.set_content(body)

    method = ecfg.get("method", "sendmail")
    if method == "sendmail":
        path = ecfg.get("sendmail_path", "/usr/sbin/sendmail")
        proc = subprocess.run(
            [path, "-t", "-oi"], input=msg.as_bytes(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise RuntimeError("sendmail failed: %s" % proc.stderr.decode("utf-8", "replace"))
    elif method == "smtp":
        s = ecfg["smtp"]
        server = smtplib.SMTP(s["host"], int(s["port"]), timeout=30)
        try:
            if s.get("use_tls"):
                server.starttls()
            if s.get("username"):
                server.login(s["username"], s["password"])
            server.send_message(msg)
        finally:
            server.quit()
    else:
        raise ValueError("unknown email method %r" % method)
    log.info("e-mail sent to %s: %s", ecfg["to"], subject)


# --------------------------------------------------------------------------- #
# Orchestration                                                                #
# --------------------------------------------------------------------------- #

def get_account_id(session):
    try:
        return session.client("sts", region_name="us-east-1").get_caller_identity()["Account"]
    except Exception:  # noqa: BLE001
        return "unknown"


def run(cfg, session, state_path, *, force_digest=False, dry_run=False, no_email=False):
    account = get_account_id(session)
    regions = get_regions(session, cfg)
    log.info("scanning %d regions for account %s", len(regions), account)
    inventory = collect_all(session, cfg, regions)
    alerts = compute_alerts(inventory, cfg)

    state = load_state(state_path)
    ref = now_utc()
    today = datetime.now().date().isoformat()
    renotify = cfg.get("renotify_hours", 24)

    digest_due = force_digest or (
        datetime.now().hour == int(cfg["digest"]["hour"])
        and state.get("last_digest_date") != today
    )
    active = {fingerprint(a): a for a in alerts}
    new_alerts = [a for a in alerts if is_new_alert(fingerprint(a), state, ref, renotify)]

    # Decide what (if anything) to send.
    action = "none"
    subject = body = None
    if digest_due:
        action = "digest"
        subject = "daily inventory - %d alerts, %d running (acct %s)" % (
            len(alerts), sum(1 for i in inventory["instances"] if i["state"] == "running"),
            account)
        body = build_body(inventory, alerts, cfg, account, "digest")
    elif new_alerts:
        action = "alert"
        subject = "%d alert(s): %s" % (
            len(new_alerts),
            ", ".join(sorted({a["type"] for a in new_alerts})))
        body = build_body(inventory, new_alerts, cfg, account, "alert")

    log.info(summary_line(inventory, alerts, account))
    log.info("decision: %s (digest_due=%s, new_alerts=%d)", action, digest_due, len(new_alerts))

    if action != "none":
        if dry_run or no_email:
            print("--- would send e-mail ---")
            print("Subject:", subject)
            print(body)
        else:
            send_email(cfg, subject, body)

    if not dry_run:
        # Re-base de-dup state on what is currently active so resolved-then-
        # recurring issues alert again; mark notified ones with 'now'.
        new_state_alerts = {}
        for fp, alert in active.items():
            if action == "digest" or (action == "alert" and alert in new_alerts):
                new_state_alerts[fp] = ref.isoformat()
            else:
                new_state_alerts[fp] = state.get("alerts", {}).get(fp, ref.isoformat())
        state["alerts"] = new_state_alerts
        if action == "digest":
            state["last_digest_date"] = today
        save_state(state_path, state)

    return inventory, alerts, action


# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #

def setup_logging(verbose, log_path):
    level = logging.DEBUG if verbose else logging.INFO
    handlers = [logging.StreamHandler(sys.stderr)]
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        handlers.append(logging.FileHandler(log_path))
    except OSError:
        pass
    logging.basicConfig(
        level=level, handlers=handlers,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    # Keep third-party chatter (botocore/urllib3) out of our logs, even with -v.
    for noisy in ("botocore", "boto3", "urllib3", "s3transfer"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Watch AWS for idle / wasteful resources.")
    parser.add_argument("command", nargs="?", default="run",
                        choices=["run", "report", "digest", "test-email"],
                        help="run: hourly logic; report: print full inventory; "
                             "digest: force a digest now; test-email: send a test message")
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--env", default=DEFAULT_ENV)
    parser.add_argument("--state", default=DEFAULT_STATE)
    parser.add_argument("--regions", help="comma-separated region override")
    parser.add_argument("--dry-run", action="store_true", help="never send e-mail; print instead")
    parser.add_argument("--no-email", action="store_true", help="alias for --dry-run output")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    setup_logging(args.verbose, DEFAULT_LOG)
    isolate_aws_env()
    creds = load_env_file(args.env)
    cfg = load_config(args.config)
    if args.regions:
        cfg["regions"] = [r.strip() for r in args.regions.split(",") if r.strip()]
    session = make_session(creds)

    if args.command == "test-email":
        send_email(cfg, "test message", "aws_watch test e-mail - if you got this, delivery works.\n")
        print("test e-mail sent to", cfg["email"]["to"])
        return 0

    if args.command == "report":
        account = get_account_id(session)
        regions = get_regions(session, cfg)
        inventory = collect_all(session, cfg, regions)
        alerts = compute_alerts(inventory, cfg)
        print(build_body(inventory, alerts, cfg, account, "report"))
        return 0

    force_digest = args.command == "digest"
    run(cfg, session, args.state,
        force_digest=force_digest, dry_run=args.dry_run, no_email=args.no_email)
    return 0


if __name__ == "__main__":
    sys.exit(main())
