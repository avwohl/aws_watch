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
                public_ip=None, private_ip=None, region="us-east-2", tags=None,
                load=None, cpu=None, vcpus=16, metric_src=None,
                launch=aw.now_utc() - timedelta(hours=2))
    base.update(kw)
    if base.get("tags") is None:
        base["tags"] = {"Name": base["name"]} if base["name"] else {}
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


class TestReaper(unittest.TestCase):
    """The reaper TERMINATES instances -- these tests pin down exactly which
    ones it will and (more importantly) will NOT touch.  Pure logic, no AWS."""

    def cfg(self, **reap):
        base = {"enabled": True, "name_prefixes": ["iospharo-*"]}
        base.update(reap)
        return aw.deep_merge(aw.CONFIG_DEFAULTS, {"reap": base})

    def act(self, inst, cfg=None):
        return aw.reap_evaluate(inst, cfg or self.cfg())["action"]

    # --- the allowlist gate -------------------------------------------------
    def test_name_prefix_match_idle_is_reaped(self):
        i = inst(name="iospharo-build-1", cpu=1.0)
        self.assertEqual(self.act(i), "reap")

    def test_project_tag_prefix_match(self):
        i = inst(name="x64-builder", tags={"Name": "x64-builder", "Project": "iospharo-x64"}, cpu=1.0)
        self.assertEqual(self.act(i), "reap")

    def test_non_candidate_is_skipped(self):
        # A box that matches no reap prefix is never even a candidate ...
        self.assertEqual(self.act(inst(name="prod-db")), "skip")

    def test_non_candidate_idle_is_never_reaped(self):
        # ... not even when it is bone idle.  This is THE safety property.
        i = inst(name="prod-db", cpu=0.0,
                 load={"load1": 0.0, "load5": 0.0, "load15": 0.0, "nproc": 16})
        self.assertEqual(self.act(i), "skip")

    def test_empty_allowlist_reaps_nothing(self):
        # No name_prefixes => nothing matches => nothing is a candidate.
        cfg = self.cfg(name_prefixes=[])
        self.assertEqual(self.act(inst(name="iospharo-build", cpu=0.0), cfg), "skip")

    # --- reasons to reap ----------------------------------------------------
    def test_idle_candidate_reaped(self):
        i = inst(name="iospharo-x", load={"load1": 0.0, "load5": 0.1, "load15": 0.0, "nproc": 16})
        self.assertEqual(self.act(i), "reap")

    def test_old_busy_candidate_reaped_on_age(self):
        i = inst(name="iospharo-x", launch=aw.now_utc() - timedelta(hours=20),
                 load={"load1": 14.0, "load5": 15.0, "load15": 13.0, "nproc": 16})
        self.assertEqual(self.act(i), "reap")

    def test_age_reaping_can_be_disabled(self):
        i = inst(name="iospharo-x", launch=aw.now_utc() - timedelta(hours=20),
                 load={"load1": 14.0, "load5": 15.0, "load15": 13.0, "nproc": 16})
        self.assertEqual(self.act(i, self.cfg(max_age_hours=None)), "keep")

    # --- reasons to keep a candidate ---------------------------------------
    def test_busy_candidate_kept(self):
        i = inst(name="iospharo-x", load={"load1": 14.0, "load5": 15.0, "load15": 13.0, "nproc": 16})
        self.assertEqual(self.act(i), "keep")

    def test_grace_keeps_young_candidate(self):
        i = inst(name="iospharo-x", cpu=0.0, launch=aw.now_utc() - timedelta(minutes=5))
        self.assertEqual(self.act(i), "keep")

    def test_unknown_age_kept(self):
        i = inst(name="iospharo-x", cpu=0.0, launch=None)
        self.assertEqual(self.act(i), "keep")

    def test_not_running_skipped(self):
        i = inst(name="iospharo-x", state="stopped", cpu=0.0)
        self.assertEqual(self.act(i), "skip")

    def test_no_metric_idle_not_reaped(self):
        # No load and no CPU datapoint => cannot conclude idle => kept.
        i = inst(name="iospharo-x", load=None, cpu=None)
        self.assertEqual(self.act(i), "keep")

    # --- protections veto a reap -------------------------------------------
    def test_protect_id(self):
        i = inst(name="iospharo-x", id="i-keep", cpu=0.0)
        self.assertEqual(self.act(i, self.cfg(protect_ids=["i-keep"])), "keep")

    def test_protect_name_glob(self):
        i = inst(name="iospharo-prod-1", cpu=0.0)
        self.assertEqual(self.act(i, self.cfg(protect_name_globs=["*-prod-*"])), "keep")

    def test_protect_region(self):
        i = inst(name="iospharo-x", region="us-west-2", cpu=0.0)
        self.assertEqual(self.act(i, self.cfg(protect_regions=["us-west-2"])), "keep")

    def test_protect_zone(self):
        i = inst(name="iospharo-x", az="us-east-2c", cpu=0.0)
        self.assertEqual(self.act(i, self.cfg(protect_zones=["us-east-2c"])), "keep")

    def test_protect_tag_value(self):
        i = inst(name="iospharo-x", tags={"Name": "iospharo-x", "Reap": "skip"}, cpu=0.0)
        self.assertEqual(self.act(i), "keep")  # default protect_tag is "Reap=skip"

    def test_protect_tag_wrong_value_not_protected(self):
        i = inst(name="iospharo-x", tags={"Name": "iospharo-x", "Reap": "yes"}, cpu=0.0)
        self.assertEqual(self.act(i), "reap")

    def test_protect_tag_key_only(self):
        # protect_tag "Reap" (no =value) protects on key presence, any value.
        i = inst(name="iospharo-x", tags={"Name": "iospharo-x", "Reap": "whatever"}, cpu=0.0)
        self.assertEqual(self.act(i, self.cfg(protect_tag="Reap")), "keep")

    def test_suppress_list_protects(self):
        cfg = self.cfg()
        cfg["suppress"] = ["i-1"]
        i = inst(name="iospharo-x", cpu=0.0)
        self.assertEqual(aw.reap_evaluate(i, cfg)["action"], "keep")

    def test_suppress_name_glob_protects(self):
        cfg = self.cfg()
        cfg["suppress"] = ["name:iospharo-keep-*"]
        i = inst(name="iospharo-keep-7", cpu=0.0)
        self.assertEqual(aw.reap_evaluate(i, cfg)["action"], "keep")

    # --- robustness / fail-safe (from the safety review) -------------------
    def test_partial_idle_config_does_not_crash(self):
        # reap.idle: null (=> {}) must not KeyError; falls back to defaults.
        cfg = self.cfg(idle=None)
        i = inst(name="iospharo-x", cpu=1.0)
        self.assertEqual(aw.reap_evaluate(i, cfg)["action"], "reap")
        cfg2 = self.cfg(idle={"enabled": True})  # missing thresholds
        self.assertEqual(aw.reap_evaluate(inst(name="iospharo-x", cpu=1.0), cfg2)["action"], "reap")

    def test_empty_match_tag_keys_reaps_nothing(self):
        # Explicit [] means "match no keys" => fail closed (never a candidate).
        cfg = self.cfg(match_tag_keys=[])
        self.assertEqual(self.act(inst(name="iospharo-x", cpu=0.0), cfg), "skip")

    def test_idle_reason_robust_to_empty_cfg(self):
        i = inst(name="x", cpu=1.0)
        self.assertIsNotNone(aw.idle_reason(i, {}))          # uses defaults, no crash
        self.assertIsNone(aw.idle_reason(inst(cpu=99.0), {}))

    def test_preflight_warns_on_bare_wildcard(self):
        warns = aw.reap_preflight_warnings({"name_prefixes": ["*"]}, ["us-east-2"])
        self.assertTrue(any("wildcard" in w for w in warns))
        warns = aw.reap_preflight_warnings({"name_prefixes": ["**"]}, ["us-east-2"])
        self.assertTrue(warns)

    def test_preflight_no_warn_on_narrow_prefix(self):
        self.assertEqual(
            aw.reap_preflight_warnings({"name_prefixes": ["iospharo-*"]}, ["us-east-2"]), [])

    def test_preflight_warns_on_many_regions(self):
        many = ["r%d" % n for n in range(12)]
        warns = aw.reap_preflight_warnings({"name_prefixes": ["iospharo-*"]}, many)
        self.assertTrue(any("region" in w for w in warns))

    # --- report is e-mail safe ---------------------------------------------
    def test_reap_report_no_line_drawing(self):
        d = aw.reap_evaluate(inst(name="iospharo-x", cpu=0.0), self.cfg())
        d["inst"] = inst(name="iospharo-x", cpu=0.0)
        d["outcome"] = "would-reap"
        body = aw.reap_report([d])
        for ch in "─│┌┐└┘├┤┬┴┼":
            self.assertNotIn(ch, body)
        self.assertIn("\t", body)


if __name__ == "__main__":
    unittest.main()
