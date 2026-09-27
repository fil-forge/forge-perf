"""Tests of ingest.py and build-site.py against a stubbed AWS CLI.

    cd scripts/publish && python3 -m unittest -v test_publish
"""

import contextlib
import copy
import datetime
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HOST_FIXTURES = ROOT / "scripts" / "host" / "fixtures"
NOW = "2026-10-02T00:00:00Z"

# Serves `s3api list-objects-v2` and `s3 cp s3://<bucket>/<key> -` from
# $FAKE_BUCKET, a directory whose paths are the object keys and whose file
# times are the objects' LastModified.
AWS_STUB = textwrap.dedent("""\
    #!/usr/bin/env python3
    import datetime, json, os, sys
    from pathlib import Path
    root = Path(os.environ["FAKE_BUCKET"])
    args = sys.argv[1:]
    if args[:2] == ["s3api", "list-objects-v2"]:
        prefix = args[args.index("--prefix") + 1]
        keys = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
        print(json.dumps({"Contents": [
            {"Key": k, "Size": (root / k).stat().st_size,
             "LastModified": datetime.datetime.fromtimestamp((root / k).stat().st_mtime,
                                                             datetime.timezone.utc).isoformat()}
            for k in keys if k.startswith(prefix)]}))
    elif args[:2] == ["s3", "cp"] and args[3] == "-":
        key = args[2].split("/", 3)[3]
        sys.stdout.buffer.write((root / key).read_bytes())
    else:
        sys.exit(f"aws stub: unexpected {args}")
    """)


def fixture_record(case, hour, series=None, reasons=None):
    """A host fixture's expected record, moved to 2026-10-01 <hour>:00."""
    record = json.loads((HOST_FIXTURES / case / "expected.json").read_text(encoding="utf-8"))
    record["run_id"] = f"main-20261001t{hour:02d}0000z"
    record["time"]["run_started_at"] = f"2026-10-01T{hour:02d}:00:00Z"
    record["time"]["run_finished_at"] = f"2026-10-01T{hour:02d}:20:00Z"
    if series:
        record["series"] = series
    if reasons is not None:
        record["outcome"]["reasons"] = reasons
    return record


class FakeBucket:
    """ingest.Bucket in memory, for tests that call ingest() directly."""

    def __init__(self, records):
        self.objects = {k: json.dumps(v).encode("utf-8") for k, v in records.items()}

    def list(self):
        return {k: {"Key": k, "Size": len(v), "LastModified": NOW} for k, v in self.objects.items()}

    def get(self, key):
        return self.objects[key]


def outputs(path):
    text = Path(path).read_text(encoding="utf-8")
    return {m.group(1): m.group(3) for m in re.finditer(r"^(\w+)<<(EOF_\w+)\n(.*?)\n?\2$", text, re.M | re.S)}


class Publish(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.bucket = self.tmp / "bucket"
        self.results = self.tmp / "results"
        self.bucket.mkdir()
        self.results.mkdir()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "aws").write_text(AWS_STUB, encoding="utf-8")
        (bin_dir / "aws").chmod(0o755)
        (self.tmp / "denylist.regex").write_text("d3add3add3ad\n", encoding="utf-8")
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_BUCKET=str(self.bucket),
                        DENYLIST_FILE=str(self.tmp / "denylist.regex"), PYTHONDONTWRITEBYTECODE="1")
        self.env.pop("PUBLIC_DENYLIST_REGEX", None)
        self.heartbeat("2026-10-01T23:55:00Z")

    def put(self, key, value, uploaded=NOW):
        path = self.bucket / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")
        t = datetime.datetime.fromisoformat(uploaded.replace("Z", "+00:00")).timestamp()
        os.utime(path, (t, t))

    def record(self, record, uploaded=NOW):
        self.put(f"published/main/{record['run_id']}.json", record, uploaded)

    def heartbeat(self, at, **fields):
        self.put("published/main/heartbeat.json", dict({"box": "main", "at": at, "state": "idle",
                                                          "poll_failures": 0, "run_started_at": None}, **fields))

    def ingest(self, now=NOW, expect_status=0):
        out = self.tmp / "github_output"
        out.write_text("", encoding="utf-8")
        proc = subprocess.run([sys.executable, str(HERE / "ingest.py"), "--bucket", "b",
                               "--results", str(self.results), "--now", now],
                              env=dict(self.env, GITHUB_OUTPUT=str(out)), capture_output=True, text=True)
        self.assertEqual(proc.returncode, expect_status, proc.stderr)
        got = outputs(out)
        got["alerts"] = [a for a in got.get("alerts", "").split("\n") if a]
        return got

    def test_a_record_is_committed_and_other_names_are_ignored(self):
        record = fixture_record("valid", 12)
        self.record(record)
        self.put("published/probe.json", "{}")
        got = self.ingest()
        path = self.results / "runs/2026/10/main-20261001t120000z.json"
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), record)
        self.assertTrue(path.read_text(encoding="utf-8").endswith("}\n"))
        self.assertEqual(sorted(p.name for p in (self.results / "runs").rglob("*.json")), ["main-20261001t120000z.json"])
        self.assertEqual((got["alerts"], got["rejected"]), ([], "0"))
        self.assertEqual(json.loads(got["heartbeats"])["main"]["state"], "idle")

    def test_one_alert_per_class_until_recovery(self):
        self.record(fixture_record("exit2", 12))
        first = self.ingest()["alerts"]
        self.assertEqual(len(first), 1)
        self.assertIn("main-20261001t120000z ended no_data (reasons drill_interrupted).", first[0])
        self.record(fixture_record("exit1-no-evidence", 13))
        self.assertEqual(self.ingest()["alerts"], [])
        self.record(fixture_record("container-restart", 14))
        self.assertIn("restarted", self.ingest()["alerts"][0])
        self.record(fixture_record("valid", 15))
        recovered = self.ingest()["alerts"]
        self.assertEqual(len(recovered), 1)
        self.assertIn("recovered from invalid, no_data", recovered[0])
        self.record(fixture_record("valid", 16))
        self.assertEqual(self.ingest()["alerts"], [])

    def test_an_integrity_failure_names_its_failure_codes(self):
        self.record(fixture_record("integrity-failure", 12))
        alerts = self.ingest()["alerts"]
        self.assertEqual(len(alerts), 1)
        self.assertIn("ended failed (reasons integrity_failure; failure codes integrity_failure)", alerts[0])

    def test_classes_that_do_not_alert(self):
        self.record(fixture_record("read-back-incomplete", 12))
        self.record(fixture_record("availability-errors", 13))
        self.record(fixture_record("stack-boot-failed", 14))  # calibration
        self.assertEqual(self.ingest()["alerts"], [])

    def test_infrastructure_failures_alert_on_the_third_in_a_row(self):
        for hour in (12, 13):
            self.record(fixture_record("exit2", hour, reasons=["image_pull_failed"]))
            self.assertEqual(self.ingest()["alerts"], [])
        self.record(fixture_record("exit2", 14, reasons=["image_pull_failed"]))
        self.assertEqual(len(self.ingest()["alerts"]), 1)

    def test_stale_heartbeat_alerts_once(self):
        self.record(fixture_record("valid", 12))
        self.heartbeat("2026-10-01T23:00:00Z")
        alerts = self.ingest()["alerts"]
        self.assertEqual(alerts, ["forge-perf main: no heartbeat for 60 minutes. https://fil-forge.github.io/forge-perf/"])
        self.assertEqual(self.ingest()["alerts"], [])
        self.heartbeat("2026-10-01T23:58:00Z")
        self.assertEqual(self.ingest()["alerts"], [])
        self.assertEqual(json.loads((self.results / "status/main.json").read_text())["conditions"], [])

    def test_heartbeat_conditions(self):
        self.heartbeat("2026-10-01T23:55:00Z", state="running", poll_failures=6,
                       run_started_at="2026-10-01T16:00:00Z")
        alerts = self.ingest()["alerts"]
        self.assertEqual(len(alerts), 3)
        self.assertTrue(any("6 polls in a row failed" in a for a in alerts))
        self.assertTrue(any("since 2026-10-01T16:00:00Z" in a for a in alerts))
        self.assertTrue(any("no record yet" in a for a in alerts))
        (self.bucket / "published/main/heartbeat.json").unlink()
        self.assertEqual(self.ingest()["alerts"], ["forge-perf main: no heartbeat. https://fil-forge.github.io/forge-perf/"])

    def test_no_record_in_26_hours(self):
        self.record(fixture_record("valid", 12))
        self.assertEqual(self.ingest()["alerts"], [])
        self.heartbeat("2026-10-02T14:55:00Z")
        self.assertEqual(self.ingest(now="2026-10-02T15:00:00Z")["alerts"],
                         ["forge-perf main: no record in 26 hours. https://fil-forge.github.io/forge-perf/"])

    def test_no_record_waits_for_a_run_in_progress(self):
        self.record(fixture_record("valid", 12))
        self.assertEqual(self.ingest()["alerts"], [])
        # A quiet day: the next nightly has run for three hours past the 26.
        self.heartbeat("2026-10-02T14:55:00Z", state="running", run_started_at="2026-10-02T12:00:00Z")
        self.assertEqual(self.ingest(now="2026-10-02T15:00:00Z")["alerts"], [])
        # A stale heartbeat that last said running does not hold it off.
        self.heartbeat("2026-10-02T14:00:00Z", state="running", run_started_at="2026-10-02T12:00:00Z")
        self.assertEqual(self.ingest(now="2026-10-02T15:00:00Z")["alerts"],
                         ["forge-perf main: no heartbeat for 60 minutes. https://fil-forge.github.io/forge-perf/",
                          "forge-perf main: no record in 26 hours. https://fil-forge.github.io/forge-perf/"])
        # Once raised, it holds through the next run without posting again.
        self.heartbeat("2026-10-02T15:55:00Z", state="running", run_started_at="2026-10-02T15:30:00Z")
        self.assertEqual(self.ingest(now="2026-10-02T16:00:00Z")["alerts"], [])
        status = json.loads((self.results / "status/main.json").read_text(encoding="utf-8"))
        self.assertEqual(status["conditions"], ["no_record"])

    def test_a_run_that_ends_without_a_record_raises_no_record(self):
        self.record(fixture_record("valid", 12))
        self.heartbeat("2026-10-02T14:55:00Z", state="running", run_started_at="2026-10-02T12:00:00Z")
        self.assertEqual(self.ingest(now="2026-10-02T15:00:00Z")["alerts"], [])
        self.heartbeat("2026-10-02T15:55:00Z")
        self.assertEqual(self.ingest(now="2026-10-02T16:00:00Z")["alerts"],
                         ["forge-perf main: no record in 26 hours. https://fil-forge.github.io/forge-perf/"])

    def test_box_and_instrument_faults_alert_invalid(self):
        hour = 1
        for reason in ("disk_low", "dirty_start", "image_changed", "instrument_modified", "box_type_mismatch"):
            with self.subTest(reason=reason):
                self.record(fixture_record("container-restart", hour, reasons=[reason]))
                alerts = self.ingest()["alerts"]
                self.assertEqual(len(alerts), 1)
                self.assertIn(f"ended invalid (reasons {reason};", alerts[0])
                self.record(fixture_record("valid", hour + 1))
                self.assertIn("recovered from invalid", self.ingest()["alerts"][0])
                hour += 2

    def test_a_rejection_alerts_once_and_the_rest_are_committed(self):
        bad = fixture_record("valid", 12)
        bad["note"] = 1
        self.record(bad)
        self.record(fixture_record("valid", 13))
        got = self.ingest()
        self.assertEqual(got["rejected"], "1")
        self.assertEqual(got["alerts"], ["forge-perf publish rejected published/main/main-20261001t120000z.json: schema"])
        self.assertTrue((self.results / "runs/2026/10/main-20261001t130000z.json").exists())
        again = self.ingest()
        self.assertEqual((again["rejected"], again["alerts"]), ("0", []))

    def test_every_host_fixture_is_committed(self):
        cases = sorted(p.name for p in HOST_FIXTURES.iterdir() if (p / "expected.json").exists())
        self.assertEqual(len(cases), 10)
        for hour, case in enumerate(cases):
            self.record(fixture_record(case, hour))
        got = self.ingest()
        self.assertEqual(got["rejected"], "0")
        self.assertEqual(len(list((self.results / "runs").rglob("*.json"))), 10)

    def test_a_record_that_wrote_nothing_posts_no_data(self):
        self.record(fixture_record("wrote-nothing", 12))
        got = self.ingest()
        self.assertEqual(got["rejected"], "0")
        self.assertEqual(len(got["alerts"]), 1)
        self.assertIn("ended no_data (reasons wrote_nothing, no_steady_windows;", got["alerts"][0])

    def test_a_heartbeat_with_an_impossible_date_counts_as_missing(self):
        self.record(fixture_record("valid", 12))
        self.heartbeat("2026-02-30T00:00:00Z")
        got = self.ingest()
        self.assertEqual(got["alerts"], ["forge-perf main: no heartbeat. https://fil-forge.github.io/forge-perf/"])
        self.assertTrue((self.results / "runs/2026/10/main-20261001t120000z.json").exists())

    def test_a_run_id_ahead_of_its_upload_stays_rejected(self):
        self.record(fixture_record("valid", 12), uploaded="2026-10-01T11:45:00Z")
        self.assertEqual(self.ingest()["rejected"], "1")
        self.assertFalse((self.results / "runs").exists())
        self.assertEqual(json.loads((self.results / "status/rejected.json").read_text()),
                         {"published/main/main-20261001t120000z.json": "future_run_id"})

    def test_an_unexpected_error_rejects_one_key_only(self):
        sys.path.insert(0, str(HERE))
        import ingest

        class Checks(ingest.Checks):
            def check(self, key, raw, uploaded=None):
                if key.endswith("t120000z.json"):
                    raise TypeError("boom")
                return super().check(key, raw, uploaded)

        bucket = FakeBucket({f"published/main/{r['run_id']}.json": r
                             for r in (fixture_record("valid", 12), fixture_record("valid", 13))})
        checks = Checks(ROOT, "HEAD", "d3add3add3ad\n", ingest.utc(NOW))
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            _, rejected, _ = ingest.ingest(bucket, self.results, ["main"], checks)
        self.assertEqual(rejected, ["published/main/main-20261001t120000z.json"])
        self.assertTrue((self.results / "runs/2026/10/main-20261001t130000z.json").exists())
        self.assertEqual(json.loads((self.results / "status/rejected.json").read_text()),
                         {"published/main/main-20261001t120000z.json": "internal"})

    def test_a_backlog_commits_oldest_first_in_slices(self):
        sys.path.insert(0, str(HERE))
        import ingest
        records = {f"published/main/{r['run_id']}.json": r for r in
                   (fixture_record("valid", h) for h in (14, 12, 13))}
        checks = ingest.Checks(ROOT, "HEAD", "d3add3add3ad\n", ingest.utc(NOW))
        old = ingest.MAX_NEW
        ingest.MAX_NEW = 2
        self.addCleanup(setattr, ingest, "MAX_NEW", old)
        with contextlib.redirect_stdout(io.StringIO()):
            ingest.ingest(FakeBucket(records), self.results, ["main"], checks)
            self.assertEqual(sorted(p.stem for p in (self.results / "runs").rglob("*.json")),
                             ["main-20261001t120000z", "main-20261001t130000z"])
            ingest.ingest(FakeBucket(records), self.results, ["main"], checks)
        self.assertEqual(len(list((self.results / "runs").rglob("*.json"))), 3)

    def test_rejection_logs_never_carry_record_text(self):
        bad = fixture_record("valid", 12)
        bad["FIXTURE-FREE-TEXT"] = "FIXTURE-FREE-TEXT"
        self.record(bad)
        proc = subprocess.run([sys.executable, str(HERE / "ingest.py"), "--bucket", "b", "--results",
                               str(self.results), "--now", NOW], env=self.env, capture_output=True, text=True)
        self.assertNotIn("FIXTURE-FREE-TEXT", proc.stdout + proc.stderr)

    def test_no_denylist_pattern_refuses_to_publish(self):
        self.env.pop("DENYLIST_FILE")
        self.record(fixture_record("valid", 12))
        self.ingest(expect_status=2)
        self.assertFalse((self.results / "runs").exists())

    def test_self_test(self):
        proc = subprocess.run([sys.executable, str(HERE / "ingest.py"), "--self-test"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("16 of 16 cases as expected", proc.stdout)


class BuildSite(unittest.TestCase):
    def test_index_rows_and_instrument_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            runs = tmp / "results/runs/2026/10"
            runs.mkdir(parents=True)
            first = fixture_record("valid", 12)
            second = copy.deepcopy(fixture_record("valid", 13))
            second["provenance"]["smelt"]["sha"] = "0" * 40
            third = fixture_record("stack-boot-failed", 14)
            for r in (first, second, third):
                (runs / f"{r['run_id']}.json").write_text(json.dumps(r), encoding="utf-8")
            subprocess.run([sys.executable, str(HERE / "build-site.py"), "--site", str(ROOT / "site"),
                            "--data", str(ROOT / "data"), "--results", str(tmp / "results"),
                            "--out", str(tmp / "_site"), "--now", NOW,
                            "--heartbeats", '{"main":null}'], check=True, capture_output=True)
            index = json.loads((tmp / "_site/data/index.json").read_text(encoding="utf-8"))
            self.assertEqual(index["published_at"], NOW)
            self.assertEqual([r["run_id"] for r in index["runs"]],
                             [first["run_id"], second["run_id"], third["run_id"]])
            self.assertEqual([r["instrument_changes"] for r in index["runs"]], [None, ["smelt"], None])
            self.assertEqual(index["runs"][0]["p5_bytes_per_s"], 25360000.0)
            self.assertIsNone(index["runs"][2]["p5_bytes_per_s"])
            gates = json.loads((ROOT / "data/gates.json").read_text(encoding="utf-8"))
            self.assertEqual((index["overrides"], index["gates"], index["heartbeats"]), ([], gates, {"main": None}))
            self.assertEqual([(r["pairing_id"], r["changed"], r["size_bytes"]) for r in index["runs"]][0],
                             (None, first["trigger"]["changed"], first["drill"]["settings"]["stop_ingest_at_bytes"]))
            self.assertTrue((tmp / "_site/index.html").exists())
            self.assertEqual(json.loads((tmp / f"_site/data/runs/{second['run_id']}.json").read_text()), second)

    def test_a_broken_host_record_builds(self):
        # A schema-valid record with no settings file, no NVMe and no Docker
        # (as in scripts/host/test_schema.py). The next run compares against
        # the last run that had settings, so it gets no false instrument change.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            runs = tmp / "results/runs/2026/10"
            runs.mkdir(parents=True)
            broken = fixture_record("stack-boot-failed", 13, series="per-trigger", reasons=["preflight_failed"])
            broken["drill"]["settings"] = None
            broken["box"].update(docker_server=None, docker_compose=None)
            broken["box"]["nvme"] = {"model": None, "size_bytes": None, "filesystem": None}
            broken["instrument"]["box_fingerprint"] = "e" * 64
            records = (fixture_record("valid", 12), broken, fixture_record("valid", 14))
            for r in records:
                (runs / f"{r['run_id']}.json").write_text(json.dumps(r), encoding="utf-8")
            proc = subprocess.run([sys.executable, str(HERE / "build-site.py"), "--site", str(ROOT / "site"),
                                   "--data", str(ROOT / "data"), "--results", str(tmp / "results"),
                                   "--out", str(tmp / "_site"), "--now", NOW], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            index = json.loads((tmp / "_site/data/index.json").read_text(encoding="utf-8"))
            self.assertEqual([(r["size_bytes"] is None, r["instrument_changes"]) for r in index["runs"]],
                             [(False, None), (True, []), (False, [])])


class Data(unittest.TestCase):
    def test_data_files_match_their_schemas(self):
        proc = subprocess.run([sys.executable, str(ROOT / "scripts/host/schemacheck.py"),
                               str(ROOT / "schema/overrides.v1.json"), str(ROOT / "data/overrides.json")],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        boxes = json.loads((ROOT / "data/boxes.json").read_text(encoding="utf-8"))
        self.assertTrue(boxes and all(re.fullmatch(r"[a-z0-9]{2,12}", b) for b in boxes))


class Workflow(unittest.TestCase):
    """publish.yml's ordering, read as text: the standard library has no YAML."""

    def setUp(self):
        self.text = (ROOT / ".github/workflows/publish.yml").read_text(encoding="utf-8")
        self.ingest, self.deploy = self.text.split("\n  deploy:\n")

    def test_deploy_follows_only_an_ingest_that_reached_its_commit(self):
        commit = self.ingest.index("name: commit to results")
        marker = self.ingest.index("id: ingested")
        self.assertLess(commit, marker)
        self.assertLess(marker, self.ingest.index("id: rejected"))
        self.assertIn("ingested: ${{ steps.ingested.outputs.ingested }}", self.ingest)
        condition = re.search(r"^    if: (.*)$", self.deploy, re.M).group(1)
        self.assertIn("needs.ingest.outputs.ingested == 'true'", condition)
        self.assertIn("!cancelled()", condition)

    def test_a_failed_ingest_posts_unless_it_already_posted(self):
        steps = self.ingest.split("\n      - ")
        last = steps[-1]
        self.assertIn("if: failure() && steps.slack.outcome != 'failure' && steps.rejected.outcome != 'failure'",
                      last)
        self.assertIn("publish failed", last)
        self.assertIn("errors: true", last)
        self.assertIn("id: slack", self.ingest)


if __name__ == "__main__":
    unittest.main()
