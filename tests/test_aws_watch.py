"""Unit tests for aws_watch pure logic (no AWS calls, no network)."""
import os
import sys
import unittest
from datetime import timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import aws_watch as aw  # noqa: E402


def inst(**kw):
    base = dict(id="i-1", name="", type="c7g.4xlarge", arch="arm64",
                lifecycle="on-demand", state="running", az="us-east-2a",
                public_ip=None, private_ip=None, region="us-east-2",
                load=None, cpu=None, vcpus=16, metric_src=None,
                launch=aw.now_utc() - timedelta(hours=2))
    base.update(kw)
    return base


def inventory(instances=None, volumes=None, spot=None, eips=None):
    return {"instances": instances or [], "volumes": volumes or [],
            "spot": spot or [], "eips": eips or [], "errors": {}}


class TestHelpers(unittest.TestCase):
    def test_fmt_age(self):
        self.assertEqual(aw.fmt_age(0), "0m")
        self.assertEqual(aw.fmt_age(125), "2m")
        self.assertEqual(aw.fmt_age(3600 + 120), "1h2m")
        self.assertEqual(aw.fmt_age(2 * 86400 + 3 * 3600), "2d3h")
        self.assertEqual(aw.fmt_age(None), "-")

    def test_parse_loadavg(self):
        out = aw.parse_loadavg("0.52 0.58 0.59 2/1234 5678\n16\n")
        self.assertEqual(out["load5"], 0.58)
        self.assertEqual(out["nproc"], 16)
        self.assertIsNone(aw.parse_loadavg(""))
        self.assertIsNone(aw.parse_loadavg("garbage"))

    def test_deep_merge(self):
        merged = aw.deep_merge({"a": {"x": 1, "y": 2}}, {"a": {"y": 9}})
        self.assertEqual(merged, {"a": {"x": 1, "y": 9}})

    def test_suppress(self):
        cfg = {"suppress": ["i-1", "name:build-*"]}
        self.assertTrue(aw.is_suppressed("i-1", "", cfg))
        self.assertTrue(aw.is_suppressed("i-2", "build-farm-3", cfg))
        self.assertFalse(aw.is_suppressed("i-2", "web", cfg))


class TestAlerts(unittest.TestCase):
    def setUp(self):
        self.cfg = aw.deep_merge(aw.CONFIG_DEFAULTS, {})

    def test_idle_by_load(self):
        i = inst(load={"load1": 0.1, "load5": 0.2, "load15": 0.3, "nproc": 16}, vcpus=16)
        alerts = aw.compute_alerts(inventory([i]), self.cfg)
        self.assertTrue(any(a["type"] == "idle_instance" for a in alerts))

    def test_busy_not_idle(self):
        i = inst(load={"load1": 14.0, "load5": 15.0, "load15": 13.0, "nproc": 16}, vcpus=16)
        alerts = aw.compute_alerts(inventory([i]), self.cfg)
        self.assertFalse(any(a["type"] == "idle_instance" for a in alerts))

    def test_idle_by_cpu_fallback(self):
        i = inst(load=None, cpu=1.2)
        alerts = aw.compute_alerts(inventory([i]), self.cfg)
        self.assertTrue(any(a["type"] == "idle_instance" for a in alerts))

    def test_fresh_instance_not_idle(self):
        i = inst(load={"load1": 0.0, "load5": 0.0, "load15": 0.0, "nproc": 16},
                 launch=aw.now_utc() - timedelta(minutes=5))
        alerts = aw.compute_alerts(inventory([i]), self.cfg)
        self.assertFalse(any(a["type"] == "idle_instance" for a in alerts))

    def test_suppressed_instance_no_alert(self):
        self.cfg["suppress"] = ["i-1"]
        i = inst(load={"load1": 0.0, "load5": 0.0, "load15": 0.0, "nproc": 16})
        alerts = aw.compute_alerts(inventory([i]), self.cfg)
        self.assertEqual(alerts, [])

    def test_old_instance(self):
        i = inst(load={"load1": 14.0, "load5": 15.0, "load15": 13.0, "nproc": 16},
                 launch=aw.now_utc() - timedelta(hours=30))
        alerts = aw.compute_alerts(inventory([i]), self.cfg)
        self.assertTrue(any(a["type"] == "old_instance" for a in alerts))

    def test_unattached_volume(self):
        v = {"id": "vol-1", "state": "available", "size": 80, "vtype": "gp3",
             "create": aw.now_utc(), "az": "us-east-2a", "attached_to": None,
             "region": "us-east-2"}
        alerts = aw.compute_alerts(inventory(volumes=[v]), self.cfg)
        self.assertTrue(any(a["type"] == "unattached_volume" for a in alerts))

    def test_unassociated_eip(self):
        e = {"id": "eipalloc-1", "public_ip": "1.2.3.4", "assoc": None,
             "instance_id": None, "region": "us-east-2"}
        alerts = aw.compute_alerts(inventory(eips=[e]), self.cfg)
        self.assertTrue(any(a["type"] == "unassociated_eip" for a in alerts))


class TestState(unittest.TestCase):
    def test_is_new_alert(self):
        ref = aw.now_utc()
        state = {"alerts": {}}
        self.assertTrue(aw.is_new_alert("idle:i-1", state, ref, 24))
        state = {"alerts": {"idle:i-1": (ref - timedelta(hours=1)).isoformat()}}
        self.assertFalse(aw.is_new_alert("idle:i-1", state, ref, 24))
        state = {"alerts": {"idle:i-1": (ref - timedelta(hours=25)).isoformat()}}
        self.assertTrue(aw.is_new_alert("idle:i-1", state, ref, 24))


class TestFormatting(unittest.TestCase):
    """The user pastes reports into e-mail: tabs only, never line-drawing."""
    BOX_CHARS = "─│┌┐└┘├┤┬┴┼━┃┏┓┗┛╋"

    def test_no_line_drawing(self):
        i = inst(load={"load1": 0.1, "load5": 0.2, "load15": 0.3, "nproc": 16})
        body = aw.build_body(inventory([i]), aw.compute_alerts(inventory([i]),
                             aw.CONFIG_DEFAULTS), aw.CONFIG_DEFAULTS, "123", "digest")
        for ch in self.BOX_CHARS:
            self.assertNotIn(ch, body, "line-drawing char %r leaked into report" % ch)
        self.assertIn("\t", body)  # columns are tab-separated


if __name__ == "__main__":
    unittest.main()
