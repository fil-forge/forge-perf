"""Tests of record.py against the fixtures and docs/record.md.

    cd scripts/host && python3 -m unittest -v test_record
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import record

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
MARKER = "FIXTURE-FREE-TEXT"


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, doc):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f)


class Case:
    """A fixture copied into a scratch directory, so a test can change it."""

    def __init__(self, test, name):
        self.dir = Path(tempfile.mkdtemp(prefix="record-test."))
        test.addCleanup(shutil.rmtree, self.dir)
        shutil.copytree(FIXTURES / name, self.dir / "case")
        self.case = self.dir / "case"
        self.expected = load(self.case / "expected.json")
        self.denylist = self.dir / "denylist"
        self.denylist.write_text("does-not-occur-anywhere\n", encoding="utf-8")
        self.out = self.dir / "record.json"

    def edit(self, rel, change):
        path = self.case / rel
        doc = load(path)
        change(doc)
        save(path, doc)

    def evidence(self):
        return next((self.case / "run" / "drill" / "evidence").glob("drill-*.json")).relative_to(self.case)

    def build(self):
        latency = self.case / "netem" / "latency.json"
        return record.build(load(self.case / "runner.json"), self.case / "run",
                            load(latency) if latency.exists() else None, record.read_env(record.LATENCY_ENV))

    def cli(self, *extra, command="build"):
        args = [sys.executable, str(HERE / "record.py"), command, "--runner", str(self.case / "runner.json"),
                "--run-dir", str(self.case / "run"), "--latency", str(self.case / "netem" / "latency.json"),
                "--denylist", str(self.denylist), "--out", str(self.out), *extra]
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run(args, capture_output=True, text=True, env=env)


class Fixtures(unittest.TestCase):
    def test_each_fixture_yields_its_expected_record(self):
        for fixture in sorted(p.name for p in FIXTURES.iterdir()):
            with self.subTest(fixture=fixture):
                case = Case(self, fixture)
                result = case.cli()
                want = 3 if fixture == "record-build-failed" else 0
                self.assertEqual(result.returncode, want, result.stderr)
                got = load(case.out)
                self.assertEqual(got["outcome"], case.expected["outcome"])
                self.assertEqual(got, case.expected)

    def test_each_fixture_survives_go_omitempty(self):
        # The harness marshals drill.failures, windows and facts with
        # omitempty, so an empty one is absent rather than [] or {}.
        def omit_empty(doc):
            for key in ("failures", "windows", "facts"):
                if key in doc.get("drill", {}) and not doc["drill"][key]:
                    del doc["drill"][key]

        for fixture in sorted(p.name for p in FIXTURES.iterdir()):
            with self.subTest(fixture=fixture):
                case = Case(self, fixture)
                evidence = case.case / "run" / "drill" / "evidence"
                for path in evidence.glob("drill-*.json") if evidence.is_dir() else []:
                    case.edit(path.relative_to(case.case), omit_empty)
                result = case.cli()
                self.assertEqual(result.returncode, 3 if fixture == "record-build-failed" else 0, result.stderr)
                self.assertEqual(load(case.out), case.expected)

    def test_the_minimal_command_ignores_the_run(self):
        case = Case(self, "record-build-failed")
        result = case.cli(command="minimal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(load(case.out), case.expected)


class FreeText(unittest.TestCase):
    def test_free_text_never_reaches_the_record(self):
        for fixture in ("valid", "availability-errors", "integrity-failure", "wrote-nothing", "exit2"):
            with self.subTest(fixture=fixture):
                case = Case(self, fixture)

                def mark_evidence(doc):
                    doc["downgrades"].append(MARKER)
                    doc["failures"].append({"code": "availability_error", "detail": MARKER})
                    for failure in doc["drill"].get("failures", []):
                        failure["detail"] = f"{MARKER} {failure['detail']}"
                    doc["drill"]["facts"]["notes"].append(MARKER)
                    doc["drill"]["facts"][MARKER] = MARKER
                    doc["provider"]["bucket_prefix"] = MARKER

                def mark_metadata(doc):
                    doc["host"] = doc["manifest"] = MARKER
                    doc["suite"]["tenant"] = doc["suite"]["config_note"] = MARKER
                    doc["extra"]["notes"] = MARKER
                    doc["images"][0]["created"] = MARKER

                case.edit(case.evidence(), mark_evidence)
                case.edit("run/metadata.json", mark_metadata)
                with open(case.case / "run" / "logs" / "piri-0.log", "a", encoding="utf-8") as f:
                    f.write(f"piri-0  | {MARKER} failed to put object {MARKER}\n")
                self.assertEqual(case.cli().returncode, 0)
                text = case.out.read_text(encoding="utf-8")
                self.assertNotIn(MARKER, text)
                got = load(case.out)
                self.assertIn("availability_error", got["outcome"]["failure_codes"])


class PublicChecks(unittest.TestCase):
    def test_a_record_matching_the_denylist_is_refused(self):
        case = Case(self, "valid")
        # The Go version comes from the evidence only, so the minimal record
        # stands in for the refused one.
        case.denylist.write_text("\nGO1\\.26\n", encoding="utf-8")
        result = case.cli()
        self.assertEqual(result.returncode, 3)
        self.assertIn("matches the denylist", result.stderr)
        self.assertNotIn("go1.26", result.stderr)
        got = load(case.out)
        self.assertEqual(got["outcome"]["reasons"], ["record_build_failed"])
        self.assertNotIn("go1.26", case.out.read_text(encoding="utf-8"))

    def test_nothing_is_written_when_the_minimal_record_matches_too(self):
        case = Case(self, "valid")
        case.denylist.write_text("perf-piri-[0-9]+-postgres\n", encoding="utf-8")
        result = case.cli()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(case.out.exists())
        self.assertNotIn("perf-piri", result.stderr)

    def test_a_forbidden_string_is_refused(self):
        case = Case(self, "valid")
        forbid = case.dir / "forbid"
        forbid.write_text("perf-piri-1-postgres-s3\n", encoding="utf-8")
        self.assertEqual(case.cli("--forbid", str(forbid)).returncode, 1)
        self.assertFalse(case.out.exists())

    def test_a_denylist_python_reads_unlike_grep_is_refused(self):
        for pattern in ("\\<go1", "go[[:digit:]]", "go1(", "("):
            with self.subTest(pattern=pattern):
                case = Case(self, "valid")
                case.denylist.write_text(pattern + "\n", encoding="utf-8")
                result = case.cli()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertRegex(result.stderr, "ERE-only form|does not compile")
                self.assertFalse(case.out.exists())

    def test_forbidden_strings_ignore_surrounding_space(self):
        case = Case(self, "valid")
        forbid = case.dir / "forbid"
        forbid.write_text("perf-piri-1-postgres-s3 \r\n", encoding="utf-8")
        self.assertEqual(case.cli("--forbid", str(forbid)).returncode, 1)
        self.assertFalse(case.out.exists())

    def test_a_failed_write_leaves_no_temp_file(self):
        case = Case(self, "valid")
        with self.assertRaises(TypeError):
            record.write({"x": object()}, case.out)
        self.assertEqual(list(case.dir.glob(".record.*")), [])
        self.assertFalse(case.out.exists())

    def test_an_empty_denylist_is_refused(self):
        case = Case(self, "valid")
        case.denylist.write_text("\n  \n", encoding="utf-8")
        result = case.cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn("the denylist is empty", result.stderr)
        self.assertFalse(case.out.exists())

    def test_a_record_outside_the_schema_falls_back(self):
        case = Case(self, "valid")
        case.edit(case.evidence(), lambda d: d["drill"].setdefault("failures", []).append({"code": "made_up", "detail": ""}))
        self.assertEqual(case.cli().returncode, 3)
        self.assertEqual(load(case.out)["outcome"]["reasons"], ["record_build_failed"])

    def test_an_unreadable_input_falls_back(self):
        case = Case(self, "valid")
        case.edit(case.evidence(), lambda d: d["drill"].pop("availability"))
        result = case.cli()
        self.assertEqual(result.returncode, 3)
        self.assertIn("KeyError", result.stderr)


class Fingerprints(unittest.TestCase):
    def test_fingerprints_are_stable_across_runs(self):
        case = Case(self, "valid")
        outputs = []
        for seed in ("1", "2"):
            env = dict(os.environ, PYTHONHASHSEED=seed, PYTHONDONTWRITEBYTECODE="1")
            subprocess.run([sys.executable, str(HERE / "record.py"), "build", "--runner",
                            str(case.case / "runner.json"), "--run-dir", str(case.case / "run"), "--latency",
                            str(case.case / "netem" / "latency.json"), "--denylist", str(case.denylist),
                            "--out", str(case.out)], check=True, env=env, capture_output=True)
            outputs.append(case.out.read_bytes())
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(load(case.out)["instrument"], case.expected["instrument"])

    def test_the_fingerprint_follows_the_settings_and_not_the_run(self):
        case = Case(self, "valid")
        case.edit("runner.json", lambda d: d.update(run_id="main-20261002t120000z", series="nightly"))
        case.edit("run/metadata.json", lambda d: d["extra"]["forge_perf"].update(run_id="main-20261002t120000z"))
        self.assertEqual(case.build()["instrument"], case.expected["instrument"])
        case.edit("runner.json", lambda d: d["settings"].update(manifest="perf-other"))
        self.assertNotEqual(case.build()["instrument"]["fingerprint"], case.expected["instrument"]["fingerprint"])


class Classification(unittest.TestCase):
    def outcome(self, case):
        return case.build()["outcome"]

    def test_settings_that_disagree_with_argv_stop_the_build(self):
        case = Case(self, "valid")
        case.edit("runner.json", lambda d: d["settings"].update(workers=8))
        with self.assertRaises(record.Stop):
            case.build()

    def test_argv_parsing(self):
        argv = ["drill", "--profile", "import", "--window=1m30s", "--ramp", "500ms", "--duration", "1h",
                "--progress", "0s", "--verify-lag-min", "30s", "--verify-lag-max", "1m", "--workers", "4",
                "--accounts", "2", "--rate-target", "1.5GiB", "--stop-ingest-at", "1000", "--restore-scale",
                "0.001", "--keep-objects=false", "--enforce-floor"]
        got = record.argv_settings(argv)
        self.assertEqual(got["window_s"], 90)
        self.assertEqual(got["ramp_s"], 0)
        self.assertEqual(got["duration_s"], 3600)
        self.assertEqual(got["rate_target_bytes_per_s"], 3 << 29)
        self.assertEqual(got["stop_ingest_at_bytes"], 1000)
        self.assertEqual(got["restore_scale_permille"], 1)
        self.assertEqual((got["keep_objects"], got["enforce_floor"]), (False, True))
        with self.assertRaises(record.Stop):
            record.argv_settings(argv[:3])
        self.assertEqual(record.parse_duration("0"), 0)

    def test_exit_1_without_a_code_is_a_drill_failure(self):
        case = Case(self, "valid")
        case.edit("run/metadata.json", lambda d: d["suite"].update(drill_exit=1))
        outcome = self.outcome(case)
        self.assertEqual((outcome["class"], outcome["reasons"]), ("failed", ["drill_failure"]))

    def test_an_unlisted_code_is_a_drill_failure(self):
        case = Case(self, "valid")
        case.edit(case.evidence(),
                  lambda d: d["drill"].setdefault("failures", []).append({"code": "put_failed", "detail": ""}))
        self.assertEqual(self.outcome(case)["reasons"], ["drill_failure"])

    def test_a_watchdog_kill_without_an_exit_status_is_a_watchdog_timeout(self):
        case = Case(self, "exit2")
        case.edit("runner.json", lambda d: d.update(watchdog_fired=True))
        case.edit("run/metadata.json", lambda d: d["suite"].pop("drill_exit"))
        outcome = self.outcome(case)
        self.assertEqual(outcome["reasons"], ["watchdog_timeout"])
        self.assertIsNone(outcome["drill_exit"])

    def test_a_watchdog_kill_after_the_drill_recorded_the_interrupt_keeps_both(self):
        case = Case(self, "exit2")
        case.edit("runner.json", lambda d: d.update(watchdog_fired=True))
        self.assertEqual(sorted(self.outcome(case)["reasons"]), ["drill_interrupted", "watchdog_timeout"])

    def test_a_drill_without_a_pre_pass_is_a_runner_error(self):
        case = Case(self, "valid")
        os.remove(case.case / "netem" / "latency.json")
        outcome = self.outcome(case)
        self.assertEqual((outcome["class"], outcome["reasons"]), ("no_data", ["runner_error"]))

    def test_drill_numbers_without_a_post_pass_are_a_runner_error(self):
        case = Case(self, "valid")
        case.edit("netem/latency.json", lambda d: d.update(post=None))
        outcome = self.outcome(case)
        self.assertEqual((outcome["class"], outcome["reasons"]), ("no_data", ["runner_error"]))

    def test_a_latency_path_that_does_not_exist_is_a_runner_error(self):
        case = Case(self, "valid")
        os.remove(case.case / "netem" / "latency.json")
        result = case.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        outcome = load(case.out)["outcome"]
        self.assertEqual((outcome["class"], outcome["reasons"]), ("no_data", ["runner_error"]))

    def test_an_out_of_range_exit_is_a_runner_error(self):
        case = Case(self, "valid")
        case.edit("run/metadata.json", lambda d: d["suite"].update(drill_exit=137))
        record_ = case.build()
        self.assertEqual(record_["outcome"]["reasons"], ["runner_error"])
        self.assertIsNone(record_["drill"]["results"])

    def test_exit_2_with_evidence_is_an_interruption(self):
        outcome = Case(self, "exit2").build()["outcome"]
        self.assertEqual((outcome["class"], outcome["reasons"]), ("no_data", ["drill_interrupted"]))

    def test_exit_2_without_evidence_is_a_runner_error(self):
        case = Case(self, "exit2")
        (case.case / case.evidence()).unlink()
        self.assertEqual(case.build()["outcome"]["reasons"], ["runner_error"])

    def test_an_interrupt_the_runner_caused_is_not_a_runner_error(self):
        case = Case(self, "valid")
        case.edit("runner.json", lambda d: d["reasons"].append("drill_interrupted"))
        case.edit("run/metadata.json", lambda d: d["suite"].pop("drill_exit"))
        self.assertEqual(case.build()["outcome"]["reasons"], ["drill_interrupted"])

    def test_a_runner_interrupt_without_netem_passes_is_not_a_runner_error(self):
        # Recovery after a reboot builds the record without --latency or --run-dir.
        case = Case(self, "valid")
        case.edit("runner.json", lambda d: d["reasons"].append("drill_interrupted"))
        os.remove(case.case / "netem" / "latency.json")
        shutil.rmtree(case.case / "run")
        runner = load(case.case / "runner.json")
        self.assertIsNotNone(runner["time"]["drill_started_at"])
        outcome = record.build(runner, None, None, record.read_env(record.LATENCY_ENV))["outcome"]
        self.assertEqual((outcome["class"], outcome["reasons"]), ("no_data", ["drill_interrupted"]))

    def test_a_runner_interrupt_after_the_pre_pass_is_not_a_runner_error(self):
        case = Case(self, "valid")
        case.edit("runner.json", lambda d: d["reasons"].append("drill_interrupted"))
        case.edit("run/metadata.json", lambda d: d["suite"].pop("drill_exit"))
        case.edit("netem/latency.json", lambda d: d.update(post=None))
        self.assertEqual(case.build()["outcome"]["reasons"], ["drill_interrupted"])

    def test_image_labels_come_from_the_runner(self):
        case = Case(self, "stack-boot-failed")
        images = {i["repo"]: i for i in case.build()["provenance"]["images"]}
        self.assertEqual(images["ghcr.io/fil-forge/piri"]["revision"], "fdead2488d81815b443903d9a4a7a21236c73728")
        self.assertEqual(images["ghcr.io/fil-forge/piri"]["source"], "https://github.com/fil-forge/piri")
        # An instrument image keeps its commit but never its source.
        self.assertIsNone(images["ghcr.io/fil-forge/minio"]["source"])

    def test_a_malformed_runner_label_is_null(self):
        case = Case(self, "stack-boot-failed")

        def change(d):
            d["images"][0].update(revision="main", source="https://example.com/fork")
        case.edit("runner.json", change)
        repo = load(case.case / "runner.json")["images"][0]["repo"]
        entry = next(i for i in case.build()["provenance"]["images"] if i["repo"] == repo)
        self.assertEqual((entry["revision"], entry["source"]), (None, None))

    def test_metadata_labels_that_disagree_stop_the_build(self):
        for field, value in (("revision", "0" * 40), ("source", "https://github.com/fil-forge/other")):
            with self.subTest(field=field):
                case = Case(self, "valid")
                case.edit("run/metadata.json", lambda d: d["images"][1].update({field: value}))
                with self.assertRaises(record.Stop):
                    case.build()

    def test_missing_settings_are_null(self):
        case = Case(self, "stack-boot-failed")
        case.edit("runner.json", lambda d: d.update(settings=None, reasons=["preflight_failed"]))
        record_ = case.build()
        self.assertIsNone(record_["drill"]["settings"])
        self.assertEqual(record_["outcome"]["reasons"], ["preflight_failed"])
        self.assertEqual(record.schemacheck.Checker(record.SCHEMA).errors(record_), [])

    def test_missing_settings_with_a_run_directory_stop_the_build(self):
        case = Case(self, "valid")
        case.edit("runner.json", lambda d: d.update(settings=None))
        with self.assertRaises(record.Stop):
            case.build()

    def test_a_run_whose_drill_never_started_has_no_nic_numbers(self):
        case = Case(self, "stack-boot-failed")

        def change(d):
            d["nic"] = {"allowance_exceeded": {k: 1 for k in record.ALLOWANCE},
                        "egress_bytes_per_s_median": 5.0, "seconds_above_baseline": 3}
        case.edit("runner.json", change)
        record_ = case.build()
        self.assertEqual(record_["network"], {"allowance_exceeded": None, "egress_bytes_per_s_median": None,
                                              "seconds_above_baseline": None})
        self.assertNotIn("nic_allowance_exceeded", record_["outcome"]["flags"])

    def test_broken_host_facts_are_null(self):
        case = Case(self, "stack-boot-failed")

        def change(d):
            d["box"].update(docker_server=None, docker_compose=None)
            d["box"]["nvme"] = {"model": None, "size_bytes": None, "filesystem": None}
        case.edit("runner.json", change)
        record_ = case.build()
        self.assertEqual(record.schemacheck.Checker(record.SCHEMA).errors(record_), [])
        self.assertIsNone(record_["box"]["nvme"]["filesystem"])

    def test_integral_float_facts_are_written_as_integers(self):
        case = Case(self, "valid")

        def change(d):
            facts = d["drill"]["facts"]
            for k in ("sustained_windows", "ingest_sent_bytes", "blobs_written"):
                facts[k] = float(facts[k])
        case.edit(case.evidence(), change)
        result = case.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(load(case.out), case.expected)

    def test_runner_reasons_stay_on_a_no_data_run(self):
        case = Case(self, "stack-boot-failed")
        case.edit("runner.json", lambda d: d["reasons"].append("dirty_start"))
        outcome = case.build()["outcome"]
        self.assertEqual((outcome["class"], outcome["reasons"]), ("no_data", ["stack_boot_failed", "dirty_start"]))

    def test_a_no_data_run_without_a_reason_is_a_runner_error(self):
        case = Case(self, "stack-boot-failed")
        case.edit("runner.json", lambda d: d.update(reasons=[]))
        self.assertEqual(case.build()["outcome"]["reasons"], ["runner_error"])

    def test_an_image_other_than_the_pinned_one_is_image_changed(self):
        case = Case(self, "valid")
        case.edit("run/metadata.json", lambda d: d["images"][0].update(digest="sha256:" + "0" * 64))
        outcome = self.outcome(case)
        self.assertEqual((outcome["class"], outcome["reasons"]), ("invalid", ["image_changed"]))

    def test_unreadable_harness_facts_are_null(self):
        case = Case(self, "valid")
        case.edit(case.evidence(), lambda d: d["provenance"].update(binary_sha256="", go_version=""))
        result = case.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        harness = load(case.out)["provenance"]["harness"]
        self.assertEqual((harness["binary_sha256"], harness["go_version"]), (None, None))

    def test_an_unknown_harness_revision_is_a_mismatch(self):
        case = Case(self, "valid")
        case.edit(case.evidence(), lambda d: d["provenance"].update(harness_revision=""))
        self.assertEqual(self.outcome(case)["reasons"], ["harness_mismatch"])

    def test_a_modified_harness_is_a_mismatch(self):
        case = Case(self, "valid")
        case.edit(case.evidence(), lambda d: d["provenance"].update(harness_modified=True))
        self.assertEqual(self.outcome(case)["reasons"], ["harness_mismatch"])

    def test_runner_flags(self):
        case = Case(self, "valid")

        def change(d):
            d.update(superseded=2, raw_missing=True)
            d["nic"]["allowance_exceeded"]["pps"] = 3
        case.edit("runner.json", change)
        outcome = self.outcome(case)
        self.assertEqual(outcome["flags"], ["few_windows", "nic_allowance_exceeded", "superseded", "raw_missing"])
        self.assertEqual(outcome["class"], "valid")


class NetemLines(unittest.TestCase):
    KNOWN = record.services()

    def test_each_documented_line(self):
        cases = {
            "harness error: docker inspect failed": ("runner_error", None),
            "upload restarted after apply (a node loses its qdisc)": ("container_restarted", "upload"),
            "upload address changed from 172.30.0.12 to 172.30.0.19; the filters no longer match it":
                ("central_ip_changed", None),
            "hilt: container 0123abcd is gone": ("container_restarted", "hilt"),
            "ingot is not running; its round trips were not measured": ("container_restarted", "ingot"),
            "piri-0: die event after apply": ("container_restarted", "piri-0"),
            "piri-0: cannot read its qdiscs": ("netem_missing", None),
            "ingot: no prio root qdisc": ("netem_missing", None),
            "ingot: netem delay is not 15 ms": ("netem_missing", None),
            "ingot: filters do not match the central addresses recorded at apply": ("netem_missing", None),
            "no reply from upload to ingot": ("rtt_out_of_band", None),
            "no TCP connection from ingot to upload:80": ("rtt_out_of_band", None),
            "ingot -> upload median round trip 18.2 ms is outside 13.5-16.5 ms": ("rtt_out_of_band", None),
            "ingot -> piri-0 median round trip 1.4 ms is not under 1 ms": ("rtt_out_of_band", None),
            "ingot -> upload median connect 19 ms is outside 13.5-16.5 ms": ("rtt_out_of_band", None),
            "redis is exited": ("container_restarted", "redis"),
            "something nobody wrote a rule for": ("runner_error", None),
            "made-up-service is exited": ("runner_error", None),
            "upload-init restarted after apply": ("runner_error", None),
        }
        for line, want in cases.items():
            with self.subTest(line=line):
                self.assertEqual(record.netem_reason(line, self.KNOWN), want)

    def test_a_failed_pre_pass_makes_the_run_invalid(self):
        case = Case(self, "valid")

        def change(d):
            d["pre"]["ok"] = False
            d["pre"]["reasons"] = ["no reply from upload to ingot"]
            d["pre"]["pairs"][0]["median_ms"] = None
        case.edit("netem/latency.json", change)
        record_ = case.build()
        self.assertEqual((record_["outcome"]["class"], record_["outcome"]["reasons"]), ("invalid", ["rtt_out_of_band"]))
        self.assertIs(record_["latency"]["before"]["ok"], False)
        self.assertEqual(record_["latency"]["pairs"], 9)

    def test_without_netem_the_targets_come_from_latency_env(self):
        case = Case(self, "valid")
        os.remove(case.case / "netem" / "latency.json")
        latency = case.build()["latency"]
        self.assertEqual((latency["target_rtt_ms"], latency["tolerance_pct"]), (15, 10))
        self.assertEqual((latency["before"], latency["after"], latency["central_ips_stable"]), (None, None, None))

    def test_without_a_pre_pass_the_targets_come_from_the_post_pass(self):
        case = Case(self, "valid")
        case.edit("netem/latency.json", lambda d: d.update(pre=None) or d["post"].update(rtt_ms=20))
        latency = case.build()["latency"]
        self.assertEqual((latency["target_rtt_ms"], latency["tolerance_pct"]), (20, 10))


if __name__ == "__main__":
    unittest.main()
