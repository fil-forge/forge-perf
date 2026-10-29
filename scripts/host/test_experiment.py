"""Tests of experiment.py: request checks, the plan and the status file.

    cd scripts/host && python3 -m unittest -v test_experiment
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import experiment

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SERVICES = experiment.tracked(ROOT / "config" / "images.tracked")
COMMIT = "0123456789abcdef0123456789abcdef01234567"
ID = "ingot-pr123-0123456789ab-17000000001"
VALID = json.loads((HERE / "fixtures" / "valid" / "expected.json").read_text(encoding="utf-8"))


def request(**change):
    req = {"schema": "forge-perf.request/v1", "id": ID, "service": "ingot", "image": "ghcr.io/fil-forge/ingot",
           "digest": "sha256:" + "a" * 64, "tag": "pr-123-0123456", "commit": COMMIT,
           "repository": "fil-forge/ingot", "pr": 123, "requested_by": "someone",
           "requested_at": "2026-10-01T12:00:00Z", "pairs": 1,
           "pr_url": "https://github.com/fil-forge/ingot/pull/123", "workflow_run_url": "https://example.test/run"}
    req.update(change)
    return {k: v for k, v in req.items() if v is not None}


def check(req, key_id=ID):
    raw = req if isinstance(req, bytes) else json.dumps(req).encode()
    return experiment.validate(raw, key_id, SERVICES)


def main_set():
    return {"smelt": "1" * 40, "harness": {"sha": "2" * 40, "pinned": True, "main": None},
            "images": {ref: "sha256:" + "0" * 64 for _, _, ref in SERVICES.values()},
            "resolved_at": "2026-10-01T12:00:00Z"}


def record(run_id, median, p5, klass="valid", fingerprint=None, reads=None):
    rec = json.loads(json.dumps(VALID))
    rec["drill"]["results"]["cache_served"].update(reads or {})
    if fingerprint:
        rec["instrument"]["fingerprint"] = fingerprint
    rec["run_id"] = run_id
    rec["outcome"]["class"] = klass
    rec["drill"]["results"]["ingest_median_bytes_per_s"] = median
    rec["drill"]["results"]["ingest_p5_bytes_per_s"] = p5
    return rec


class Validate(unittest.TestCase):
    def test_the_tracked_services_are_the_repository_names(self):
        self.assertEqual(SERVICES["guppy"], ("GUPPY_IMAGE", "ghcr.io/fil-forge/guppy", "ghcr.io/fil-forge/guppy:main-dev"))
        self.assertIn("piri-signing-service", SERVICES)

    def test_only_the_services_with_a_caller_take_requests(self):
        # guppy is tracked but has no /forge-perf caller and no trusted subject.
        with self.assertRaisesRegex(experiment.Refused, "takes no /forge-perf requests"):
            check(request(service="guppy"))
        text = (Path(__file__).resolve().parents[2] / "terraform/envs/bootstrap/account/main.tf").read_text()
        block = re.search(r"request_repositories = \{(.*?)\n  \}", text, re.S).group(1)
        self.assertEqual(sorted(re.findall(r'^\s*"([a-z0-9-]+)"\s*=', block, re.M)),
                         sorted(experiment.REQUEST_SERVICES))

    def test_a_valid_request_keeps_only_what_the_box_uses(self):
        got = check(request())
        self.assertEqual(got["tracked_ref"], "ghcr.io/fil-forge/ingot:main")
        self.assertEqual((got["variable"], got["pairs"], got["tag"]), ("INGOT_IMAGE", 1, "pr-123-0123456"))
        for private in ("requested_by", "pr_url", "workflow_run_url"):
            self.assertNotIn(private, got)

    def test_pairs_defaults_to_one(self):
        self.assertEqual(check(request(pairs=None))["pairs"], 1)
        self.assertEqual(check(request(pairs=2))["pairs"], 2)

    def test_requests_that_break_a_rule_are_refused(self):
        cases = {
            "not JSON": b"{nope",
            "NaN": b'{"schema": NaN}',
            "not an object": b"[]",
            "too large": b" " * 9000,
            "schema": request(schema="forge-perf.request/v2"),
            "untracked service": request(service="minio"),
            "service with a slash": request(service="fil-forge/ingot"),
            "image": request(image="ghcr.io/someone/ingot"),
            "digest": request(digest="sha256:abc"),
            "pairs 3": request(pairs=3),
            "pairs as text": request(pairs="1"),
            "pairs as bool": request(pairs=True),
            "commit": request(commit="0123"),
            "pr as text": request(pr="123"),
            "tag": request(tag="main"),
            "repository": request(repository="someone/ingot"),
            "requested_at": request(requested_at="yesterday"),
        }
        for name, req in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(experiment.Refused):
                    check(req)

    def test_the_id_must_match_the_key_and_the_request(self):
        with self.assertRaises(experiment.Refused):
            check(request(), key_id="ingot-pr123-0123456789ab-17000000002")
        other = "ingot-pr124-0123456789ab-17000000001"
        with self.assertRaises(experiment.Refused):
            check(request(id=other), key_id=other)

    def test_a_refusal_names_no_unchecked_value(self):
        with self.assertRaises(experiment.Refused) as e:
            check(request(service="<script>"))
        self.assertNotIn("<script>", e.exception.args[0])


class Plan(unittest.TestCase):
    def test_set_b_is_set_a_with_the_one_digest_replaced(self):
        req = check(request(pairs=2))
        a = main_set()
        plan = experiment.plan(req, a, "2026-10-01T12:05:00Z")
        self.assertEqual(plan["sets"]["main"], a)
        b = plan["sets"]["branch"]
        self.assertEqual(b["images"].pop("ghcr.io/fil-forge/ingot:main"), "sha256:" + "a" * 64)
        self.assertEqual({k: v for k, v in a["images"].items() if k != "ghcr.io/fil-forge/ingot:main"}, b["images"])
        self.assertEqual(plan["order"], ["main", "branch", "branch", "main"])
        self.assertEqual(plan["pairing_id"], f"exp-{ID}")
        self.assertEqual(plan["overrides"], {"ghcr.io/fil-forge/ingot:main": {
            "ref": "pr-123-0123456", "revision": COMMIT, "source": "https://github.com/fil-forge/ingot"}})
        self.assertEqual(plan["experiment"], {"request_id": ID, "service": "ingot", "repository": "fil-forge/ingot",
                                              "pr": 123, "commit": COMMIT})

    def test_one_pair_runs_main_then_branch(self):
        self.assertEqual(experiment.plan(check(request()), main_set(), "t")["order"], ["main", "branch"])


class Status(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="experiment-test."))
        self.addCleanup(shutil.rmtree, self.dir)
        (self.dir / "records").mkdir()
        (self.dir / "noise").mkdir()

    def run_cli(self, *args):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        out = subprocess.run([sys.executable, str(HERE / "experiment.py"), *args], capture_output=True, text=True,
                             env=env)
        return out.returncode, out.stdout

    def experiment(self, pairs, runs):
        plan = experiment.plan(check(request(pairs=pairs)), main_set(), "2026-10-01T12:05:00Z")
        shutil.rmtree(self.dir / "records")
        (self.dir / "records").mkdir()
        for role, run_id, median, p5, *rest in runs:
            plan["runs"].append({"role": role, "run_id": run_id})
            if median is not None:
                path = self.dir / "records" / f"{run_id}.json"
                path.write_text(json.dumps(record(run_id, median, p5, *rest)), encoding="utf-8")
        path = self.dir / "experiment.json"
        path.write_text(json.dumps(plan), encoding="utf-8")
        return path

    def status(self, state, path=None, *extra):
        args = ["status", "--id", ID, "--state", state, "--now", "2026-10-01T13:00:00Z",
                "--noise-dir", str(self.dir / "noise"), "--box", "main", "--instance-type", "m9gd.8xlarge", *extra]
        if path:
            args += ["--experiment", str(path), "--records", str(self.dir / "records")]
        code, out = self.run_cli(*args)
        self.assertEqual(code, 0)
        return json.loads(out)

    def test_queued_carries_its_position(self):
        doc = self.status("queued", None, "--position", "2")
        self.assertEqual(doc, {"schema": "forge-perf.status/v1", "id": ID, "state": "queued",
                               "updated_at": "2026-10-01T13:00:00Z", "position": 2, "reason": None,
                               "pairing_id": f"exp-{ID}", "runs": []})

    def test_refused_carries_its_reason(self):
        doc = self.status("refused", None, "--reason", "pairs must be 1 or 2")
        self.assertEqual((doc["state"], doc["reason"], doc["position"]), ("refused", "pairs must be 1 or 2", None))
        self.assertNotIn("comparison", doc)

    def test_running_lists_the_runs_so_far(self):
        path = self.experiment(1, [("main", "main-20261001t120500z", 1.0e9, 0.8e9)])
        doc = self.status("running", path)
        self.assertEqual(doc["runs"], [{
            "role": "main", "run_id": "main-20261001t120500z", "class": "valid", "flags": ["few_windows"],
            "size_bytes": VALID["drill"]["settings"]["stop_ingest_at_bytes"], "p5_bytes_per_s": 0.8e9,
            "median_bytes_per_s": 1.0e9, **VALID["drill"]["results"]["cache_served"],
            "traced": False, "started_at": VALID["time"]["run_started_at"],
            "finished_at": VALID["time"]["run_finished_at"]}])
        self.assertNotIn("comparison", doc)

    def test_done_compares_the_medians_of_each_role(self):
        path = self.experiment(2, [("main", "m1", 1.00e9, 0.80e9), ("branch", "b1", 1.10e9, 0.90e9),
                                   ("branch", "b2", 1.20e9, 0.86e9), ("main", "m2", 1.02e9, 0.84e9)])
        doc = self.status("final", path)
        self.assertEqual(doc["state"], "done")
        # Branch medians 1.15 and p5 0.88 against main's 1.01 and 0.82.
        # Every run reads at the valid fixture's rates, so the read streams hold level.
        self.assertEqual(doc["comparison"], {
            "median_delta_pct": 13.86, "p5_delta_pct": 7.32, "noise_median_pct": 3.5, "noise_p5_pct": 11.0,
            "verdict": "faster",
            "read_back": {"median_delta_pct": 0.0, "p5_delta_pct": 0.0, "noise_median_pct": 3.5,
                          "noise_p5_pct": 11.0, "verdict": "within noise"},
            "restore": {"median_delta_pct": 0.0, "p5_delta_pct": 0.0, "noise_median_pct": 34.0,
                        "noise_p5_pct": None, "verdict": "within noise"}})

    def test_each_read_stream_is_judged_on_its_own_median(self):
        main = {"read_back_median_bytes_per_s": 1.0e9, "restore_median_bytes_per_s": 1.0e9}
        branch = {"read_back_median_bytes_per_s": 1.05e9, "restore_median_bytes_per_s": 0.5e9}
        path = self.experiment(1, [("main", "m1", 1.0e9, 0.8e9, "valid", None, main),
                                   ("branch", "b1", 1.0e9, 0.8e9, "valid", None, branch)])
        comp = self.status("final", path)["comparison"]
        self.assertEqual([(comp[k]["median_delta_pct"], comp[k]["verdict"]) for k in ("read_back", "restore")],
                         [(5.0, "faster"), (-50.0, "slower")])

    def test_a_run_without_a_read_p5_leaves_that_p5_delta_out(self):
        old = {"read_back_p5_bytes_per_s": None, "restore_p5_bytes_per_s": None}
        path = self.experiment(1, [("main", "m1", 1.0e9, 0.8e9, "valid", None, old),
                                   ("branch", "b1", 1.0e9, 0.8e9)])
        comp = self.status("final", path)["comparison"]
        self.assertEqual([(comp[k]["p5_delta_pct"], comp[k]["verdict"]) for k in ("read_back", "restore")],
                         [(None, "within noise"), (None, "within noise")])

    def test_a_run_without_a_positive_read_median_leaves_that_stream_out(self):
        for desc, reads in (("zero", {"restore_median_bytes_per_s": 0.0}),
                            ("null", {"restore_median_bytes_per_s": None})):
            with self.subTest(median=desc):
                path = self.experiment(1, [("main", "m1", 1.0e9, 0.8e9, "valid", None, reads),
                                           ("branch", "b1", 1.0e9, 0.8e9)])
                comp = self.status("final", path)["comparison"]
                self.assertEqual((comp["restore"], comp["read_back"]["verdict"]), (None, "within noise"))

    def test_a_small_difference_is_within_noise_and_a_large_drop_is_slower(self):
        for branch, verdict in ((0.98e9, "within noise"), (0.90e9, "slower")):
            with self.subTest(verdict=verdict):
                path = self.experiment(1, [("main", "m1", 1.0e9, 0.8e9), ("branch", "b1", branch, 0.8e9)])
                self.assertEqual(self.status("final", path)["comparison"]["verdict"], verdict)

    def test_a_committed_noise_band_for_the_box_sets_the_noise(self):
        band = {"box": "main", "instance_type": "m9gd.8xlarge", "kind": "noise", "series": "per-trigger",
                "pass": True, "median": {"cv": 0.01}, "p5": {"cv": 0.025}}
        (self.dir / "noise" / "main-per-trigger.json").write_text(json.dumps(band), encoding="utf-8")
        other = dict(band, instance_type="m9gd.2xlarge", median={"cv": 0.5}, p5={"cv": 0.5})
        (self.dir / "noise" / "main-nightly.json").write_text(json.dumps(other), encoding="utf-8")
        path = self.experiment(1, [("main", "m1", 1.0e9, 0.8e9), ("branch", "b1", 0.97e9, 0.8e9)])
        comp = self.status("final", path)["comparison"]
        self.assertEqual((comp["noise_median_pct"], comp["noise_p5_pct"], comp["verdict"]), (2.0, 5.0, "slower"))

    def test_a_band_without_read_streams_leaves_them_on_the_fallback(self):
        band = {"box": "main", "instance_type": "m9gd.8xlarge", "kind": "noise", "series": "per-trigger",
                "pass": True, "median": {"cv": 0.01}, "p5": {"cv": 0.025}}
        (self.dir / "noise" / "main-per-trigger.json").write_text(json.dumps(band), encoding="utf-8")
        got = experiment.noise_band(self.dir / "noise", "main", "m9gd.8xlarge")
        self.assertEqual(got, dict(experiment.DEFAULT_NOISE, ingest={"median": 2.0, "p5": 5.0}))

    def test_the_repository_bands_are_not_for_the_tier_2_box(self):
        self.assertEqual(experiment.noise_band(ROOT / "calibration" / "noise", "main", "m9gd.8xlarge"),
                         experiment.DEFAULT_NOISE)

    def test_final_fails_when_a_run_has_no_rates(self):
        for runs, why in (
                ([("main", "m1", 1.0e9, 0.8e9)], "1 of 2 runs finished"),
                ([("main", "m1", 1.0e9, 0.8e9), ("branch", "b1", 1.0e9, 0.8e9, "failed")],
                 "the branch run b1 ended failed"),
                ([("main", "m1", None, None), ("branch", "b1", 1.0e9, 0.8e9)], "the main run m1 ended no_data"),
                ([("main", "m1", 1.0e9, 0.0), ("branch", "b1", 1.0e9, 0.8e9)],
                 "the main run m1 recorded a zero ingest rate")):
            with self.subTest(why=why):
                doc = self.status("final", self.experiment(1, runs))
                self.assertEqual((doc["state"], doc["reason"]), ("failed", why))
                self.assertNotIn("comparison", doc)

    def test_final_fails_when_the_instrument_changed_between_runs(self):
        path = self.experiment(1, [("main", "m1", 1.0e9, 0.8e9),
                                   ("branch", "b1", 1.0e9, 0.8e9, "valid", "f" * 64)])
        doc = self.status("final", path)
        self.assertEqual((doc["state"], doc["reason"]),
                         ("failed", "the branch run b1 ran on a different instrument from m1"))
        self.assertNotIn("comparison", doc)

    def test_an_availability_warning_still_compares(self):
        path = self.experiment(1, [("main", "m1", 1.0e9, 0.8e9, "availability_warning"),
                                   ("branch", "b1", 1.0e9, 0.8e9)])
        self.assertEqual(self.status("final", path)["state"], "done")

    def test_validate_cli_prints_the_request_or_the_reason(self):
        path = self.dir / "request.json"
        path.write_text(json.dumps(request()), encoding="utf-8")
        code, out = self.run_cli("validate", "--request", str(path), "--id", ID)
        self.assertEqual((code, json.loads(out)["id"]), (0, ID))
        path.write_text(json.dumps(request(pairs=3)), encoding="utf-8")
        self.assertEqual(self.run_cli("validate", "--request", str(path), "--id", ID), (1, "pairs must be 1 or 2\n"))


if __name__ == "__main__":
    unittest.main()
