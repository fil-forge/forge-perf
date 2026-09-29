"""Tests of check_data.py: the committed data files, and gates files it must refuse.

    cd scripts/publish && python3 -m unittest -v test_data
"""

import copy
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
spec = importlib.util.spec_from_file_location("check_data", HERE / "check_data.py")
check_data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_data)

MEASURED = {
    "gate": 1, "instance_type": "m9gd.2xlarge", "nic_reference_gbps": 4.25,
    "ceiling_bytes_per_s": 360000000, "s3_put_bytes_per_s": 530000000,
    "nvme_seq_write_bytes_per_s": 360000000, "measured_at": "2026-10-01T00:00:00Z",
    "forge_perf_sha": "a" * 40, "method": "calibration/README.md#ceilings",
}


class Data(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        for name in ("gates.json", "overrides.json", "boxes.json"):
            shutil.copy(ROOT / "data" / name, self.tmp / name)
        self.gates = json.loads((ROOT / "data/gates.json").read_text(encoding="utf-8"))

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def errors(self, gates=None, overrides=None):
        if gates is not None:
            (self.tmp / "gates.json").write_text(json.dumps(gates), encoding="utf-8")
        if overrides is not None:
            (self.tmp / "overrides.json").write_text(json.dumps(overrides), encoding="utf-8")
        return check_data.check(self.tmp)

    def with_gate1(self, gate):
        gates = copy.deepcopy(self.gates)
        gates["gates"][0] = gate
        return gates

    def test_committed_data_passes(self):
        self.assertEqual(check_data.check(ROOT / "data"), [])
        for g in self.gates["gates"]:
            if g["ceiling_bytes_per_s"] is None:
                continue
            self.assertEqual(g["ceiling_bytes_per_s"],
                             min(g["s3_put_bytes_per_s"], g["nvme_seq_write_bytes_per_s"]))
            self.assertTrue((ROOT / g["method"].split("#")[0]).exists(), g["method"])
            summary = ROOT / g["method"] / "summary.json"
            if summary.exists():
                self.assertEqual(g["ceiling_bytes_per_s"],
                                 round(json.loads(summary.read_text(encoding="utf-8"))["ceiling"]))

    def test_a_measured_gate_passes(self):
        self.assertEqual(self.errors(self.with_gate1(MEASURED)), [])

    def test_a_zero_ceiling_is_refused(self):
        gate = dict(MEASURED, ceiling_bytes_per_s=0, nvme_seq_write_bytes_per_s=0)
        self.assertTrue(self.errors(self.with_gate1(gate)))

    def test_a_refused_gate_names_the_rule_it_broke(self):
        gate = dict(MEASURED, ceiling_bytes_per_s=0, nvme_seq_write_bytes_per_s=0)
        self.assertIn("gates.json: $.gates[0] (measured): ceiling_bytes_per_s: below the minimum 1",
                      self.errors(self.with_gate1(gate)))
        gate = dict(MEASURED, method="javascript:alert(1)")
        self.assertEqual([e.split(": ")[2] for e in self.errors(self.with_gate1(gate))], ["method"])
        gate = dict(MEASURED, method="calibration/../../../../evil/repo")
        self.assertEqual([e.split(": ")[2] for e in self.errors(self.with_gate1(gate))], ["method"])
        gate = dict(MEASURED, ceiling_bytes_per_s=None)
        self.assertTrue(all("(unmeasured)" in e for e in self.errors(self.with_gate1(gate))))

    def test_a_ceiling_above_the_lower_measurement_is_refused(self):
        gate = dict(MEASURED, ceiling_bytes_per_s=530000000)
        self.assertEqual(self.errors(self.with_gate1(gate)), [
            "gates.json: $.gates[0]: ceiling_bytes_per_s is not the lower of the S3 PUT and NVMe write rates"])

    def test_a_null_ceiling_with_measurements_is_refused(self):
        gate = dict(MEASURED, ceiling_bytes_per_s=None)
        self.assertTrue(self.errors(self.with_gate1(gate)))

    def test_gates_out_of_order_are_refused(self):
        gates = copy.deepcopy(self.gates)
        gates["gates"].reverse()
        self.assertTrue(any("where 1 was expected" in e for e in self.errors(gates)))

    def test_previous_measurements_follow_the_same_rules(self):
        old = {k: MEASURED[k] for k in ("s3_put_bytes_per_s", "forge_perf_sha", "method")}
        old.update(ceiling_bytes_per_s=300000000, nvme_seq_write_bytes_per_s=300000000,
                   measured_at="2026-09-01T00:00:00Z")
        self.assertEqual(self.errors(self.with_gate1(dict(MEASURED, previous=[old]))), [])
        wrong = dict(old, ceiling_bytes_per_s=310000000)
        self.assertEqual(len(self.errors(self.with_gate1(dict(MEASURED, previous=[wrong])))), 1)
        later = dict(old, measured_at="2026-11-01T00:00:00Z")
        self.assertTrue(self.errors(self.with_gate1(dict(MEASURED, previous=[later]))))

    def test_two_overrides_for_one_run_are_refused(self):
        o = {"run_id": "main-20261001t120000z", "class": "invalid",
             "issue": "https://github.com/fil-forge/forge-perf/issues/1"}
        self.assertEqual(self.errors(overrides=[o]), [])
        self.assertTrue(self.errors(overrides=[o, dict(o, **{"class": "failed"})]))


class Preview(unittest.TestCase):
    def test_every_scenario_builds(self):
        spec = importlib.util.spec_from_file_location("preview", HERE / "preview.py")
        preview = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(preview)
        now = preview.dt.datetime(2026, 10, 10, 12, tzinfo=preview.dt.timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            names = preview.build(tmp, now)
            self.assertEqual(names, ["box-change", "calibration-only", "gate-lit", "instrument-change",
                                     "no-runs", "one-run", "outcomes"])
            index = {n: json.loads((Path(tmp) / n / "data/index.json").read_text(encoding="utf-8")) for n in names}
            for name in names:
                errors = check_data.gate_errors(index[name]["gates"])
                self.assertEqual(errors, [], name)
            self.assertEqual(index["no-runs"]["runs"], [])
            self.assertEqual({r["series"] for r in index["calibration-only"]["runs"]}, {"calibration"})
            self.assertEqual({r["class"] for r in index["outcomes"]["runs"]},
                             {"valid", "availability_warning", "invalid", "failed", "no_data"})
            changes = [r["instrument_changes"] for r in index["instrument-change"]["runs"]]
            self.assertIn(["smelt", "postgres"], changes)
            box = index["box-change"]["runs"]
            self.assertEqual({r["box"]["instance_type"] for r in box}, {"m9gd.2xlarge", "m9gd.8xlarge"})
            self.assertTrue(any(r["pairing_id"] for r in box))
            self.assertEqual(box[0]["size_bytes"], 100 * 10**9)
            self.assertEqual([(r["class"], "traced" in r["flags"]) for r in index["one-run"]["runs"]], [("valid", True)])
            outcomes = index["outcomes"]["runs"]
            broken = [i for i, r in enumerate(outcomes) if r["size_bytes"] is None]
            self.assertEqual(len(broken), 1)
            self.assertEqual(outcomes[broken[0] + 1]["instrument_changes"], [])
            with self.assertRaises(SystemExit):
                preview.build(HERE, now)


if __name__ == "__main__":
    unittest.main()
