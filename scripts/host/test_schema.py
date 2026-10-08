"""Tests of schema/run-record.v1.json, docs/record.md and schemacheck.py.

    cd scripts/host && python3 -m unittest -v test_schema
"""

import copy
import hashlib
import io
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

import schemacheck

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCHEMA_PATH = ROOT / "schema" / "run-record.v1.json"
RECORD_MD = (ROOT / "docs" / "record.md").read_text(encoding="utf-8")
FIXTURES = sorted(p for p in (HERE / "fixtures").iterdir() if p.is_dir())
MARKER = "FIXTURE-FREE-TEXT"
CLASS_ORDER = ["no_data", "failed", "invalid", "availability_warning"]


def load(path):
    with open(path, encoding="utf-8") as f:
        return schemacheck.load(f)


SCHEMA = load(SCHEMA_PATH)
CHECKER = schemacheck.Checker(SCHEMA)


def expected(fixture):
    return load(fixture / "expected.json")


def objects(value, path="$"):
    """Yields (path, dict) for every object inside value."""
    if isinstance(value, dict):
        yield path, value
        for k, v in value.items():
            yield from objects(v, f"{path}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from objects(v, f"{path}[{i}]")


def schema_nodes(node, where="#"):
    """Yields (where, node) for every subschema, following nothing by $ref."""
    yield where, node
    for key in ("properties", "$defs"):
        for name, child in node.get(key, {}).items():
            yield from schema_nodes(child, f"{where}/{key}/{name}")
    if "items" in node:
        yield from schema_nodes(node["items"], f"{where}/items")
    for i, child in enumerate(node.get("oneOf", [])):
        yield from schema_nodes(child, f"{where}/oneOf/{i}")


def section(title):
    m = re.search(rf"^## {re.escape(title)}\n(.*?)(?=^## |\Z)", RECORD_MD, re.M | re.S)
    if not m:
        raise AssertionError(f"docs/record.md has no section {title}")
    return m.group(1)


def reasons_table():
    """Reason -> class, from the first table of the Reasons section."""
    rows = re.findall(r"^\| `([a-z0-9_]+)` \| `([a-z0-9_]+)` \|", section("Reasons"), re.M)
    return dict(rows)


def canonical_sha256(obj):
    text = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def fingerprints(record):
    """(fingerprint, box_fingerprint) by the recipe in docs/record.md."""
    prov = record["provenance"]
    instrument = {
        "forge_perf_instrument_tree": prov["forge_perf"]["instrument_tree"],
        "smelt_sha": prov["smelt"]["sha"],
        "harness_sha": prov["harness"]["sha"],
        "instrument_images": [[i["repo"], i["digest"]] for i in prov["images"] if i["role"] == "instrument"],
        "settings": record["drill"]["settings"],
        "target_rtt_us": round(record["latency"]["target_rtt_ms"] * 1000),
        "jitter_us": 0,
    }
    if record["trace"] is not None:
        instrument["trace_ratio_ppm"] = round(record["trace"]["ratio"] * 1000000)
    if record["ingot_local_blob_max_bytes"] is not None:
        instrument["ingot_local_blob_max_bytes"] = record["ingot_local_blob_max_bytes"]
    box = record["box"]
    box_facts = {k: box[k] for k in ("instance_type", "arch", "ami_id", "kernel", "docker_server",
                                     "docker_compose", "cpu")}
    box_facts["nvme_model"] = box["nvme"]["model"]
    box_facts["nvme_filesystem"] = box["nvme"]["filesystem"]
    return canonical_sha256(instrument), canonical_sha256(box_facts)


class FixtureRecords(unittest.TestCase):
    def test_there_is_a_fixture_for_every_case(self):
        names = {p.name for p in FIXTURES}
        self.assertEqual(names, {"valid", "availability-errors", "integrity-failure", "wrote-nothing",
                                 "read-back-incomplete", "container-restart", "exit1-no-evidence", "exit2",
                                 "stack-boot-failed", "record-build-failed", "cpu-capped", "traced"})
        classes = {expected(p)["outcome"]["class"] for p in FIXTURES}
        self.assertEqual(classes, set(CLASS_ORDER) | {"valid"})

    def test_every_expected_record_validates(self):
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                self.assertEqual(CHECKER.errors(expected(fixture)), [])

    def test_an_unknown_field_anywhere_is_rejected(self):
        record = expected(FIXTURES[0])
        paths = [path for path, _ in objects(record)]
        self.assertGreater(len(paths), 10)
        for path in paths:
            with self.subTest(path=path):
                bad = copy.deepcopy(record)
                target = dict(objects(bad))[path]
                target["size_seed"] = 1
                errors = CHECKER.errors(bad)
                self.assertIn(f"{path}: has a field the schema does not define", errors)

    def test_classes_follow_the_documented_order(self):
        table = reasons_table()
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                record = expected(fixture)
                outcome = record["outcome"]
                if record["drill"]["results"] is None:
                    want = "no_data"
                else:
                    classes = {table[r] for r in outcome["reasons"]}
                    want = next((c for c in CLASS_ORDER if c in classes), "valid")
                self.assertEqual(outcome["class"], want)
                self.assertEqual(outcome["reasons"], [r for r in table if r in outcome["reasons"]])
                self.assertEqual(bool(outcome["restarted_services"]), "container_restarted" in outcome["reasons"])
                if outcome["class"] == "no_data":
                    self.assertNotEqual(outcome["reasons"], [])
                if outcome["class"] == "valid":
                    self.assertEqual(outcome["drill_exit"], 0)

    def test_fingerprints_follow_the_documented_recipe(self):
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                record = expected(fixture)
                got = (record["instrument"]["fingerprint"], record["instrument"]["box_fingerprint"])
                self.assertEqual(got, fingerprints(record))

    def test_runs_on_one_instrument_share_fingerprints(self):
        # Every untraced fixture runs the same instrument on the same box,
        # whether or not its drill wrote evidence.
        untraced = [p for p in FIXTURES if expected(p)["trace"] is None]
        self.assertEqual(len(untraced), len(FIXTURES) - 1)
        seen = {(expected(p)["instrument"]["fingerprint"], expected(p)["instrument"]["box_fingerprint"])
                for p in untraced}
        self.assertEqual(len(seen), 1)

    def test_tracing_changes_the_instrument_fingerprint_alone(self):
        traced = expected(HERE / "fixtures" / "traced")
        valid = expected(HERE / "fixtures" / "valid")
        self.assertEqual(traced["instrument"]["box_fingerprint"], valid["instrument"]["box_fingerprint"])
        self.assertNotEqual(traced["instrument"]["fingerprint"], valid["instrument"]["fingerprint"])
        self.assertEqual(fingerprints(dict(traced, trace=None))[0], valid["instrument"]["fingerprint"])

    def test_traced_and_trace_missing_follow_the_trace(self):
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                record = expected(fixture)
                flags = record["outcome"]["flags"]
                self.assertEqual("traced" in flags, record["trace"] is not None)
                if record["trace"] is not None:
                    self.assertEqual("trace_missing" in flags, record["trace"]["file_sha256"] is None)
                    self.assertEqual(sum(record["trace"]["spans_by_service"].values()), record["trace"]["spans"])

    def test_image_services_come_from_the_runner(self):
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                runner = load(fixture / "runner.json")
                want = {i["digest"]: i["services"] for i in runner["images"]}
                got = {i["digest"]: i["services"] for i in expected(fixture)["provenance"]["images"]}
                self.assertEqual(got, want)

    def test_image_commits_come_from_the_runner(self):
        # A run that stops before the drill still publishes every commit.
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                runner = {i["digest"]: i for i in load(fixture / "runner.json")["images"]}
                for image in expected(fixture)["provenance"]["images"]:
                    self.assertEqual(image["revision"], runner[image["digest"]]["revision"])
                    if image["role"] == "under_test":
                        self.assertIsNotNone(image["revision"])
                        self.assertEqual(image["source"], runner[image["digest"]]["source"])
                    else:
                        self.assertIsNone(image["source"])

    def test_a_run_that_never_booted_has_a_record(self):
        fixture = HERE / "fixtures" / "stack-boot-failed"
        self.assertFalse((fixture / "run").exists())
        record = expected(fixture)
        self.assertEqual(CHECKER.errors(record), [])
        self.assertEqual(record["outcome"]["reasons"], ["stack_boot_failed"])
        self.assertEqual(record["trigger"]["reason"], "manual")

    def test_free_text_stays_in_the_inputs(self):
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                self.assertNotIn(MARKER, (fixture / "expected.json").read_text(encoding="utf-8"))
                if not (fixture / "run").exists():
                    continue
                self.assertIn(MARKER, (fixture / "run" / "drill.out").read_text(encoding="utf-8"))
                for evidence in (fixture / "run" / "drill" / "evidence").glob("drill-*.json"):
                    doc = load(evidence)
                    self.assertIn(MARKER, doc["provider"]["config_note"])
                    self.assertTrue(all(MARKER in f["detail"] for f in doc["drill"].get("failures", [])))
                    self.assertTrue(all(MARKER in n for n in doc["drill"]["facts"]["notes"]))
                for name in ("traces.jsonl", "collector-metrics.txt", "collector.log"):
                    path = fixture / "traces" / name
                    self.assertTrue(not path.exists() or MARKER in path.read_text(encoding="utf-8"))


TRACE = expected(HERE / "fixtures" / "traced")["trace"]


class Rejections(unittest.TestCase):
    def setUp(self):
        self.record = expected(FIXTURES[0])

    def rejected(self, change):
        bad = copy.deepcopy(self.record)
        change(bad)
        return CHECKER.errors(bad)

    def test_values_outside_the_schema(self):
        cases = {
            "series": lambda r: r.update(series="dev"),
            "run_id case": lambda r: r.update(run_id=r["run_id"].upper()),
            "failure code": lambda r: r["outcome"]["failure_codes"].append("made_up"),
            "service": lambda r: r["outcome"]["restarted_services"].append("grafana"),
            "reason": lambda r: r["outcome"]["reasons"].append("cap_not_reached"),
            "trailing newline": lambda r: r["provenance"]["smelt"].update(sha=r["provenance"]["smelt"]["sha"] + "\n"),
            "boolean as tier": lambda r: r["box"].update(tier=True),
            "float settings": lambda r: r["drill"]["settings"].update(workers=4.5),
            "negative count": lambda r: r["drill"]["requests"].update(total=-1),
            "duplicate flag": lambda r: r["outcome"].update(flags=["few_windows", "few_windows"]),
            "missing field": lambda r: r["latency"].pop("pairs"),
            "trace": lambda r: r.update(trace={}),
            "trace ratio 0": lambda r: r.update(trace=dict(TRACE, ratio=0)),
            "trace ratio above 1": lambda r: r.update(trace=dict(TRACE, ratio=1.5)),
            "trace ratio as text": lambda r: r.update(trace=dict(TRACE, ratio="0.1")),
            "negative span count": lambda r: r.update(trace=dict(TRACE, spans=-1)),
            "span count as float": lambda r: r.update(trace=dict(TRACE, spans=8.5)),
            "a service outside the list": lambda r: r.update(
                trace=dict(TRACE, spans_by_service=dict(TRACE["spans_by_service"], grafana=1))),
            "a service missing": lambda r: r.update(trace=dict(TRACE, spans_by_service={"ingot": 8})),
            "trace file hash": lambda r: r.update(trace=dict(TRACE, file_sha256="e80284")),
            "free text": lambda r: r["provenance"]["images"][0].update(ref="has spaces in it"),
        }
        for name, change in cases.items():
            with self.subTest(case=name):
                self.assertNotEqual(self.rejected(change), [])

    def test_a_trace_with_unread_files_validates(self):
        missing = dict(TRACE, traces=0, spans=0, spans_by_service=dict.fromkeys(TRACE["spans_by_service"], 0),
                       dropped_spans=None, file_bytes=0, file_sha256=None)
        self.assertEqual(self.rejected(lambda r: r.update(trace=missing)), [])

    def test_errors_never_carry_the_value(self):
        errors = self.rejected(lambda r: r.update(run_id=MARKER, **{MARKER: MARKER}))
        self.assertEqual(len(errors), 2)
        self.assertNotIn(MARKER, "\n".join(errors))

    def test_json_outside_the_standard_is_refused(self):
        for text in ('{"a": NaN}', '{"a": Infinity}', '{"a": 1e400}', '{"a": -1e400}', '{"a": 1, "a": 2}'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                schemacheck.load(io.StringIO(text))

    def test_integers_written_as_floats_are_rejected(self):
        # 4.0 and 4 hash differently, so a float in a fingerprint input would
        # show a false instrument change.
        record = schemacheck.load(io.StringIO(json.dumps(self.record).replace('"workers": 4,', '"workers": 4.0,')))
        self.assertEqual(record["drill"]["settings"]["workers"], 4.0)
        self.assertEqual(CHECKER.errors(record), ["$.drill.settings.workers: not of type integer"])

    def test_a_broken_host_still_has_a_record(self):
        # The settings file is gone and the instance store is unmounted, so
        # Docker cannot start: the run is no_data with preflight_failed.
        record = expected(HERE / "fixtures" / "stack-boot-failed")
        record["outcome"]["reasons"] = ["preflight_failed"]
        record["drill"]["settings"] = None
        record["box"].update(docker_server=None, docker_compose=None)
        record["box"]["nvme"] = {"model": None, "size_bytes": None, "filesystem": None}
        self.assertEqual(CHECKER.errors(record), [])
        self.assertEqual(len(fingerprints(record)), 2)


class SchemaRules(unittest.TestCase):
    def test_every_string_is_constrained(self):
        for where, node in schema_nodes(SCHEMA):
            types = node.get("type")
            types = types if isinstance(types, list) else [types]
            if "string" in types:
                with self.subTest(where=where):
                    self.assertTrue({"pattern", "enum", "const"} & set(node))

    def test_every_object_is_closed(self):
        for where, node in schema_nodes(SCHEMA):
            if node.get("type") == "object":
                with self.subTest(where=where):
                    self.assertIs(node.get("additionalProperties"), False)
                    self.assertEqual(set(node.get("required", [])), set(node.get("properties", {})))

    def test_the_checker_refuses_keywords_it_does_not_implement(self):
        for schema in ({"type": "string", "format": "date-time"},
                       {"type": "object", "additionalProperties": True},
                       {"$ref": "https://example.com/x.json"}):
            with self.subTest(schema=schema), self.assertRaises(schemacheck.SchemaError):
                schemacheck.Checker(schema)

    def test_services_are_the_groups_conf_services(self):
        conf = (ROOT / "config" / "groups.conf").read_text(encoding="utf-8")
        groups = dict(re.findall(r'^([A-Z]+)="([^"]*)"', conf, re.M))
        want = set((groups["NODE"] + " " + groups["CENTRAL"] + " " + groups["OTHER"]).split())
        self.assertEqual(set(SCHEMA["$defs"]["service"]["enum"]), want)


class RecordDoc(unittest.TestCase):
    def leaves(self, node, path, out, defs):
        if "$ref" in node:
            name = node["$ref"].rsplit("/", 1)[-1]
            target = SCHEMA["$defs"][name]
            if target.get("type") == "object":
                out.add(path)
                defs.add(name)
                return
            node = target
        for alt in node.get("oneOf", []):
            if alt.get("type") == "object" or "$ref" in alt:
                self.leaves(alt, path, out, defs)
                return
        if node.get("type") == "object":
            for name, child in node["properties"].items():
                self.leaves(child, f"{path}.{name}" if path else name, out, defs)
        elif node.get("type") == "array" and node["items"].get("type") == "object":
            for name, child in node["items"]["properties"].items():
                self.leaves(child, f"{path}[].{name}", out, defs)
        else:
            out.add(path)

    def test_every_field_has_a_documented_source(self):
        paths, defs = set(), set()
        self.leaves(SCHEMA, "", paths, defs)
        for name in defs:
            for field in SCHEMA["$defs"][name]["properties"]:
                paths.add(f"{name}.{field}")
        self.assertGreater(len(paths), 90)
        for path in sorted(paths):
            with self.subTest(path=path):
                self.assertTrue(f"`{path}`" in RECORD_MD, f"{path} is not in docs/record.md")

    def test_the_reasons_table_is_the_schema_enum(self):
        table = reasons_table()
        enum = SCHEMA["properties"]["outcome"]["properties"]["reasons"]["items"]["enum"]
        self.assertEqual(list(table), enum)
        self.assertTrue(set(table.values()) <= set(CLASS_ORDER))

    def test_the_triggers_table_is_the_schema_enum(self):
        rows = re.findall(r"^\| `([a-z0-9-]+)` \|", section("Triggers"), re.M)
        enum = SCHEMA["properties"]["trigger"]["properties"]["reason"]["enum"]
        self.assertEqual(rows, enum)

    def test_the_instrument_tree_hash_skips_comments_and_blank_lines(self):
        lines = (ROOT / "config" / "not-instrument").read_text(encoding="utf-8").splitlines()
        self.assertIn("", lines)
        prefixes = [line.strip() for line in lines if line.strip() and not line.strip().startswith("#")]
        self.assertIn("docs/", prefixes)
        blob = "100644 blob " + "0" * 40 + "\t"
        tree = [blob + path for path in ("Makefile", "config/groups.conf", "docs/record.md",
                                          "host/versions.env", "scripts/host/netem.sh",
                                          "scripts/host/test_schema.py", "scripts/host/fixtures/valid/runner.json")]
        kept = "".join(line + "\n" for line in tree
                       if not any(line.split("\t", 1)[1].startswith(p) for p in prefixes))
        self.assertEqual(kept, "".join(blob + path + "\n" for path in
                                       ("config/groups.conf", "host/versions.env", "scripts/host/netem.sh")))
        self.assertEqual(hashlib.sha256(kept.encode("utf-8")).hexdigest(),
                         "a97508748ecf422227e85182f13f5154f8b2cdce09d228ea26fc488e33cd81c4")

    def test_the_flags_table_is_the_schema_enum(self):
        rows = re.findall(r"^\| `([a-z0-9_]+)` \|", section("Flags"), re.M)
        enum = SCHEMA["properties"]["outcome"]["properties"]["flags"]["items"]["enum"]
        self.assertEqual(rows, enum)


class CommandLine(unittest.TestCase):
    def run_check(self, *files):
        return subprocess.run([sys.executable, str(HERE / "schemacheck.py"), str(SCHEMA_PATH), *map(str, files)],
                              capture_output=True, text=True)

    def test_exit_status(self):
        good = FIXTURES[0] / "expected.json"
        self.assertEqual(self.run_check(good).returncode, 0)
        bad = FIXTURES[0] / "runner.json"
        result = self.run_check(good, bad)
        self.assertEqual(result.returncode, 1)
        self.assertIn("runner.json: $: has a field the schema does not define", result.stderr)
        self.assertEqual(subprocess.run([sys.executable, str(HERE / "schemacheck.py")],
                                        capture_output=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
