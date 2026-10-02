"""Tests of calibration-summary.py against small fixture records.

    cd scripts/operator && python3 -m unittest -v test_calibration_summary
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "calibration-summary.py"
MB = 1_000_000


def record(run_id, p5, median, workers=32, cls="valid", reasons=(), flags=(),
           instance_type="m9gd.2xlarge", cap=100_000_000_000, ingot="d", reads=None):
    """The record fields the summary reads, and no others."""
    stamp = run_id.split("-")[1]
    return {
        "run_id": run_id,
        "series": "calibration",
        "time": {"run_started_at": f"{stamp[:4]}-{stamp[4:6]}-{stamp[6:8]}T{stamp[9:11]}:00:00Z"},
        "box": {"id": run_id.split("-")[0], "instance_type": instance_type},
        "outcome": {"class": cls, "reasons": list(reasons), "flags": list(flags)},
        "instrument": {"fingerprint": "e" * 64},
        "drill": {
            "settings": {"workers": workers, "stop_ingest_at_bytes": cap},
            "results": {"ingest_p5_bytes_per_s": p5, "ingest_median_bytes_per_s": median,
                        **({"cache_served": reads} if reads is not None else {})},
        },
        "provenance": {
            "forge_perf": {"sha": "a" * 40},
            "smelt": {"sha": "b" * 40},
            "harness": {"sha": "c" * 40},
            "images": [{"repo": "ghcr.io/fil-forge/ingot", "digest": "sha256:" + ingot * 64,
                        "role": "under_test"}],
        },
    }


def rid(n):
    return f"main-20260927t1{n:05d}z"


class Summary(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="calsum-test."))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.records = self.tmp / "runs" / "2026" / "09"
        self.records.mkdir(parents=True)
        self.out = self.tmp / "out"

    def add(self, *recs):
        for rec in recs:
            (self.records / f"{rec['run_id']}.json").write_text(json.dumps(rec))
        return [rec["run_id"] for rec in recs]

    def run_cli(self, *args, records=True, cwd=None, ok=True):
        cmd = [sys.executable, str(SCRIPT), "--out-dir", str(self.out)]
        if records:
            cmd += ["--records", str(self.tmp / "runs")]
        got = subprocess.run(cmd + list(args), capture_output=True, text=True, cwd=cwd)
        self.assertEqual(got.returncode, 0 if ok else 2, got.stderr)
        return got

    def output(self, rel):
        return json.loads((self.out / rel).read_text())

    def sweep(self, *specs):
        """specs: (workers, p5 MB/s, median MB/s[, record kwargs]) per run."""
        def rate(mb):
            return None if mb is None else mb * MB
        recs = [record(rid(i), rate(s[1]), rate(s[2]), workers=s[0], **(s[3] if len(s) > 3 else {}))
                for i, s in enumerate(specs)]
        self.run_cli("workers", "--runs", *self.add(*recs))
        return self.output("workers/2026-09-27-m9gd.2xlarge.json")

    def test_workers_picks_smallest_value_within_five_percent(self):
        doc = self.sweep((16, 400, 450), (32, 530, 580), (64, 550, 600),
                         (64, 550, 600), (32, 530, 580), (16, 420, 470))
        self.assertEqual(doc["winner"], 32)
        by = {v["workers"]: v for v in doc["values"]}
        self.assertEqual(by[16]["mean_p5_bytes_per_s"], 410 * MB)
        self.assertEqual(by[64]["mean_median_bytes_per_s"], 600 * MB)
        self.assertEqual(doc["best_mean_p5_bytes_per_s"], 550 * MB)
        self.assertEqual(by[32]["run_ids"], [rid(1), rid(4)])

    def test_workers_needs_median_within_five_percent_too(self):
        doc = self.sweep((32, 540, 500), (32, 540, 500), (64, 550, 600), (64, 550, 600))
        self.assertEqual(doc["winner"], 64)

    def test_workers_availability_error_disqualifies_a_value(self):
        doc = self.sweep((16, 600, 650, {"cls": "availability_warning",
                                         "reasons": ["availability_errors"]}),
                         (16, 600, 650), (32, 550, 600), (32, 550, 600))
        by = {v["workers"]: v for v in doc["values"]}
        self.assertFalse(by[16]["qualified"])
        self.assertEqual(by[16]["disqualifying_run_ids"], [rid(0)])
        self.assertEqual(doc["best_mean_p5_bytes_per_s"], 550 * MB)
        self.assertEqual(doc["winner"], 32)

    def test_workers_run_not_valid_disqualifies_a_value(self):
        doc = self.sweep((16, None, None, {"cls": "no_data", "reasons": ["wrote_nothing"]}),
                         (16, 560, 610), (32, 550, 600))
        self.assertEqual(doc["winner"], 32)

    def test_workers_output_is_reproducible_and_carries_provenance(self):
        ids = self.add(record(rid(0), 550 * MB, 600 * MB), record(rid(1), 540 * MB, 590 * MB))
        self.run_cli("workers", "--runs", *ids)
        path = self.out / "workers/2026-09-27-m9gd.2xlarge.json"
        first = path.read_bytes()
        self.run_cli("workers", "--runs", *ids)
        self.assertEqual(path.read_bytes(), first)
        run = json.loads(first)["runs"][0]
        self.assertEqual(run["run_id"], rid(0))
        self.assertEqual(run["provenance"], {
            "forge_perf_sha": "a" * 40, "smelt_sha": "b" * 40, "harness_sha": "c" * 40,
            "images": {"ghcr.io/fil-forge/ingot": "sha256:" + "d" * 64}})

    def test_workers_refuses_mixed_instance_types(self):
        ids = self.add(record(rid(0), 1, 1), record(rid(1), 1, 1, instance_type="m9gd.8xlarge"))
        got = self.run_cli("workers", "--runs", *ids, ok=False)
        self.assertIn("instance types", got.stderr)

    def test_workers_refuses_mixed_ingest_caps(self):
        ids = self.add(record(rid(0), 1, 1), record(rid(1), 1, 1, cap=350_000_000_000))
        got = self.run_cli("workers", "--runs", *ids, ok=False)
        self.assertIn("ingest caps", got.stderr)

    def test_workers_refuses_a_sweep_with_no_qualified_value(self):
        ids = self.add(record(rid(0), None, None, cls="no_data"),
                       record(rid(1), None, None, workers=64, cls="no_data"))
        got = self.run_cli("workers", "--runs", *ids, ok=False)
        self.assertIn("no workers value qualified", got.stderr)
        self.assertIn(rid(1), got.stderr)

    def test_options_go_after_the_subcommand_too(self):
        ids = self.add(record(rid(0), 5, 6))
        out = self.tmp / "after"
        got = subprocess.run([sys.executable, str(SCRIPT), "workers", "--runs", *ids,
                              "--records", str(self.tmp / "runs"), "--out-dir", str(out)],
                             capture_output=True, text=True)
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertTrue((out / "workers/2026-09-27-m9gd.2xlarge.json").exists())

    def test_noise_refuses_mixed_image_digests(self):
        ids = self.add(record(rid(0), 5, 5), record(rid(1), 5, 5, ingot="f"))
        got = self.run_cli("noise", "--series", "nightly", "--runs", *ids, ok=False)
        self.assertIn("image digests", got.stderr)

    def test_noise_band_and_pass(self):
        ids = self.add(*[record(rid(i), p * MB, (p + 50) * MB)
                         for i, p in enumerate([500, 510, 520, 530, 540])])
        self.run_cli("noise", "--series", "per-trigger", "--runs", *ids)
        doc = self.output("noise/main-m9gd.2xlarge-per-trigger.json")
        self.assertEqual(doc["p5"]["count"], 5)
        self.assertEqual(doc["p5"]["mean"], 520 * MB)
        self.assertEqual((doc["p5"]["min"], doc["p5"]["max"]), (500 * MB, 540 * MB))
        self.assertAlmostEqual(doc["p5"]["stdev"], 15811388.3, places=0)
        self.assertAlmostEqual(doc["p5"]["cv"], 15811388.3 / (520 * MB), places=6)
        self.assertEqual(doc["median"]["mean"], 570 * MB)
        self.assertTrue(doc["pass"])
        self.assertEqual([r["run_id"] for r in doc["runs"]], ids)

    def test_noise_fails_above_ten_percent_cv(self):
        ids = self.add(*[record(rid(i), p * MB, p * MB) for i, p in enumerate([300, 500, 700])])
        self.run_cli("noise", "--series", "nightly", "--runs", *ids)
        doc = self.output("noise/main-m9gd.2xlarge-nightly.json")
        self.assertGreater(doc["p5"]["cv"], 0.10)
        self.assertFalse(doc["pass"])

    def test_noise_summarizes_each_read_stream(self):
        def reads(i):
            return {"read_back_p5_bytes_per_s": (500 + 10 * i) * MB, "read_back_median_bytes_per_s": 550 * MB,
                    "restore_p5_bytes_per_s": 200 * MB, "restore_median_bytes_per_s": (200 + 100 * i) * MB}
        ids = self.add(*[record(rid(i), 500 * MB, 550 * MB, reads=reads(i)) for i in range(3)])
        self.run_cli("noise", "--series", "per-trigger", "--runs", *ids)
        doc = self.output("noise/main-m9gd.2xlarge-per-trigger.json")
        self.assertEqual([doc[s][k]["mean"] for s in ("read_back", "restore") for k in ("p5", "median")],
                         [510 * MB, 550 * MB, 200 * MB, 300 * MB])

    def test_a_noisy_restore_leaves_the_ingest_pass_alone(self):
        ids = self.add(*[record(rid(i), 500 * MB, 550 * MB, reads={"restore_median_bytes_per_s": m * MB})
                         for i, m in enumerate([100, 300, 500])])
        self.run_cli("noise", "--series", "per-trigger", "--runs", *ids)
        doc = self.output("noise/main-m9gd.2xlarge-per-trigger.json")
        self.assertEqual((doc["restore"]["median"]["cv"] > 0.10, doc["pass"]), (True, True))

    def test_a_run_without_a_read_value_leaves_its_stats_null(self):
        ids = self.add(record(rid(0), 500 * MB, 550 * MB, reads={"restore_p5_bytes_per_s": 200 * MB}),
                       record(rid(1), 500 * MB, 550 * MB))
        self.run_cli("noise", "--series", "per-trigger", "--runs", *ids)
        doc = self.output("noise/main-m9gd.2xlarge-per-trigger.json")
        self.assertEqual((doc["restore"]["p5"], doc["read_back"]["median"]), (None, None))

    def test_noise_refuses_a_run_not_valid(self):
        ids = self.add(record(rid(0), 5, 5), record(rid(1), None, None, cls="invalid"))
        got = self.run_cli("noise", "--series", "nightly", "--runs", *ids, ok=False)
        self.assertIn(rid(1), got.stderr)

    def band(self, name="band.json", **over):
        band = self.tmp / name
        doc = {"kind": "noise", "pass": True, "box": "main", "series": "per-trigger",
               "instance_type": "m9gd.2xlarge", "workers": 32,
               "stop_ingest_at_bytes": 100_000_000_000,
               "p5": {"min": 500 * MB}, "runs": [{"run_id": rid(99)}]}
        doc.update(over)
        band.write_text(json.dumps(doc))
        return band

    def test_falsification_three_of_three(self):
        band = self.band()
        low = self.add(*[record(rid(i), 400 * MB, 450 * MB, flags=["cpu_capped"])
                         for i in range(3)])
        mixed = self.add(record(rid(10), 450 * MB, 1), record(rid(11), 499 * MB, 1),
                         record(rid(12), 500 * MB, 1))
        self.run_cli("falsification", "--band", str(band),
                     "--check", "cpu-cap=" + ",".join(low),
                     "--check", "older-digest=" + ",".join(mixed))
        doc = self.output("falsification/2026-09-27.json")
        checks = {c["name"]: c for c in doc["checks"]}
        self.assertTrue(checks["cpu-cap"]["pass"])
        self.assertEqual(checks["cpu-cap"]["runs"][0]["flags"], ["cpu_capped"])
        self.assertEqual(checks["cpu-cap"]["runs"][0]["ingest_p5_bytes_per_s"], 400 * MB)
        self.assertEqual((checks["older-digest"]["below"], checks["older-digest"]["of"]), (2, 3))
        self.assertFalse(checks["older-digest"]["pass"])
        self.assertFalse(doc["pass"])
        self.assertEqual(doc["band"]["run_ids"], [rid(99)])
        self.assertEqual(doc["band"]["workers"], 32)

    def test_falsification_check_takes_exactly_three_runs(self):
        low = self.add(*[record(rid(i), 400 * MB, 450 * MB) for i in range(2)])
        got = self.run_cli("falsification", "--band", str(self.band()),
                           "--check", "cpu-cap=" + ",".join(low), ok=False)
        self.assertIn("exactly 3", got.stderr)
        self.assertFalse(self.out.exists())

    def test_falsification_refuses_a_run_not_valid_or_off_the_band(self):
        band = str(self.band())
        bad = self.add(record(rid(0), 400 * MB, 1, cls="invalid"),
                       record(rid(1), 400 * MB, 1), record(rid(2), 400 * MB, 1))
        got = self.run_cli("falsification", "--band", band, "--check", "a=" + ",".join(bad),
                           ok=False)
        self.assertIn(rid(0), got.stderr)
        off = self.add(record(rid(3), 400 * MB, 1, workers=64),
                       record(rid(4), 400 * MB, 1), record(rid(5), 400 * MB, 1))
        got = self.run_cli("falsification", "--band", band, "--check", "a=" + ",".join(off),
                           ok=False)
        self.assertIn("workers", got.stderr)

    def test_falsification_refuses_a_run_in_two_checks(self):
        ids = self.add(*[record(rid(i), 400 * MB, 1) for i in range(5)])
        got = self.run_cli("falsification", "--band", str(self.band()),
                           "--check", "a=" + ",".join(ids[:3]),
                           "--check", "b=" + ",".join(ids[2:]), ok=False)
        self.assertIn("twice", got.stderr)

    def test_falsification_refuses_a_file_that_is_no_band(self):
        ids = ",".join(self.add(*[record(rid(i), 400 * MB, 1) for i in range(3)]))
        for band, want in ((self.tmp / "missing.json", "cannot read"),
                           (self.band("w.json", kind="workers"), "not a noise band"),
                           (self.band("f.json", **{"pass": False}), "CV test")):
            got = self.run_cli("falsification", "--band", str(band), "--check", "a=" + ids,
                               ok=False)
            self.assertIn(want, got.stderr)
            self.assertNotIn("Traceback", got.stderr)

    def test_falsification_refuses_free_text_check_name(self):
        band = self.tmp / "band.json"
        band.write_text("{}")
        got = self.run_cli("falsification", "--band", str(band),
                           "--check", f"Some Name={rid(0)}", ok=False)
        self.assertIn("NAME", got.stderr)

    def test_reads_records_from_results_branch(self):
        repo = self.tmp / "clone"
        rel = Path("runs/2026/09") / f"{rid(0)}.json"
        (repo / rel.parent).mkdir(parents=True)
        (repo / rel).write_text(json.dumps(record(rid(0), 5, 6)))
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.com"]
        for args in (["init", "-q", "-b", "results"], ["add", "."], ["commit", "-qm", "r"]):
            subprocess.run(git + args, cwd=repo, check=True, capture_output=True)
        self.run_cli("--ref", "results", "workers", "--runs", rid(0), records=False, cwd=repo)
        self.assertEqual(self.output("workers/2026-09-27-m9gd.2xlarge.json")["winner"], 32)
        self.run_cli("--ref", "results", "workers", "--runs", rid(1), records=False, cwd=repo,
                     ok=False)


if __name__ == "__main__":
    unittest.main()
