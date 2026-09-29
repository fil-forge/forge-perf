#!/usr/bin/env python3
"""Moves run records from the results bucket to the results branch, and alerts.

    ingest.py --bucket <name> --results <results checkout> [--repo <main checkout>]
              [--boxes data/boxes.json] [--now <UTC time>]
    ingest.py --self-test

Reads published/<box>/<run_id>.json and published/<box>/heartbeat.json with
the AWS CLI, checks each new record (docs/publishing.md), writes the ones that
pass to runs/<yyyy>/<mm>/<run_id>.json and the alert state to status/. The
workflow commits what changed. Slack text, the rejection count and the
heartbeat summaries go to $GITHUB_OUTPUT as `alerts`, `rejected` and
`heartbeats`.

Standard library only. Errors name the object key and the check, never
record contents: the workflow log is public.
"""

import argparse
import copy
import datetime as dt
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ in a checkout the denylist scans
sys.path.insert(0, str(HERE.parent / "host"))
import schemacheck  # noqa: E402

SCHEMA_PATH = "schema/run-record.v1.json"
PAGE = "https://fil-forge.github.io/forge-perf/"
MAX_RECORD = 64 * 1024
MAX_HEARTBEAT = 4 * 1024
RUN_ID = r"[a-z0-9]{2,12}-[0-9]{8}t[0-9]{6}z"
RECORD_KEY = re.compile(rf"^published/([a-z0-9]{{2,12}})/({RUN_ID})\.json\Z")
SHA1 = re.compile(r"^[0-9a-f]{40}\Z")
UTC = re.compile(r"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]{1,9})?Z\Z")
FUTURE = dt.timedelta(minutes=10)
INFRASTRUCTURE = {"image_pull_failed", "secrets_unavailable", "s3_unreachable",
                  "mirror_fetch_failed", "go_module_fetch_failed"}
LATENCY_OR_RESTART = {"rtt_out_of_band", "central_ip_changed", "netem_missing", "container_restarted"}
# Invalid for a fault on the box or in the instrument, not in Forge. Each needs
# an operator, and most would repeat on every run until one acts.
BOX_OR_INSTRUMENT = {"disk_low", "dirty_start", "image_changed", "instrument_modified", "box_type_mismatch"}
HEARTBEAT_STALE = dt.timedelta(minutes=30)
POLL_FAILURES = 6
LONG_RUN = dt.timedelta(hours=7)
NO_RECORD = dt.timedelta(hours=26)
MAX_NEW = 200  # new keys per run, so a backlog drains across runs


class Rejected(Exception):
    """A record failed a check; the argument names the check."""


def utc(text):
    """The UTC time, or None when the text is not one (including 2026-02-30)."""
    m = UTC.match(text) if isinstance(text, str) else None
    try:
        return dt.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc) \
            if m else None
    except ValueError:
        return None


def run_id_time(run_id):
    """The run ID's start time, or None when it is not a date."""
    try:
        return dt.datetime.strptime(run_id.rsplit("-", 1)[1], "%Y%m%dt%H%M%Sz").replace(tzinfo=dt.timezone.utc)
    except (ValueError, IndexError):
        return None


def listed_time(text):
    """An S3 listing's LastModified, or None."""
    try:
        t = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None
    return t.astimezone(dt.timezone.utc) if t.tzinfo else None


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
    # Only a traced run hashes its ratio, so an untraced fingerprint is unchanged.
    if record.get("trace") is not None:
        instrument["trace_ratio_ppm"] = round(record["trace"]["ratio"] * 1000000)
    box = record["box"]
    facts = {k: box[k] for k in ("instance_type", "arch", "ami_id", "kernel", "docker_server",
                                 "docker_compose", "cpu")}
    facts["nvme_model"] = box["nvme"]["model"]
    facts["nvme_filesystem"] = box["nvme"]["filesystem"]
    return canonical_sha256(instrument), canonical_sha256(facts)


class Checks:
    """The record checks, in order. `repo` is a git checkout of main."""

    def __init__(self, repo, main_ref, patterns, now):
        self.repo, self.main_ref, self.patterns, self.now = repo, main_ref, patterns, now
        self._checkers = {}

    def _git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True)

    def checker(self, sha):
        # The schema the box built the record against: its own commit's, when
        # that commit is on main; otherwise main's.
        ref = self.main_ref
        if isinstance(sha, str) and SHA1.match(sha) and \
                self._git("merge-base", "--is-ancestor", sha, self.main_ref).returncode == 0:
            ref = sha
        if ref not in self._checkers:
            shown = self._git("show", f"{ref}:{SCHEMA_PATH}")
            try:
                if shown.returncode != 0:
                    raise ValueError("no schema")
                self._checkers[ref] = schemacheck.Checker(json.loads(shown.stdout))
            except (ValueError, schemacheck.SchemaError):
                self._checkers[ref] = None
        if self._checkers[ref] is None:
            raise Rejected("schema_unavailable")
        return self._checkers[ref]

    def denied(self, raw):
        with tempfile.NamedTemporaryFile("w", suffix=".regex") as f:
            f.write(self.patterns)
            f.flush()
            status = subprocess.run(["grep", "-q", "-a", "-i", "-E", "-f", f.name], input=raw).returncode
        return status != 1  # 0 is a match; above 1 is an error, which fails closed

    def check(self, key, raw, uploaded=None):
        """The parsed record, or Rejected. `uploaded` is S3's LastModified."""
        m = RECORD_KEY.match(key)
        if not m:
            raise Rejected("key")
        if len(raw) > MAX_RECORD:
            raise Rejected("size")
        if self.denied(raw):
            raise Rejected("denylist")
        try:
            record = schemacheck.load(io.BytesIO(raw))
        except ValueError:
            raise Rejected("json")
        if not isinstance(record, dict):
            raise Rejected("json")
        # Escapes such as \\u0064 pass the raw grep and decode on the way to
        # the committed file, so the committed bytes are checked too.
        if self.denied(dump(record).encode("utf-8")):
            raise Rejected("denylist")
        prov = record.get("provenance")
        forge_perf = prov.get("forge_perf") if isinstance(prov, dict) else None
        sha = forge_perf.get("sha") if isinstance(forge_perf, dict) else None
        if self.checker(sha).errors(record):
            raise Rejected("schema")
        box, run_id, t = record["box"]["id"], record["run_id"], record["time"]
        if (m.group(1), m.group(2)) != (box, run_id) or not run_id.startswith(box + "-"):
            raise Rejected("key")
        started, finished, named = utc(t["run_started_at"]), utc(t["run_finished_at"]), run_id_time(run_id)
        if started is None or finished is None or named is None:
            raise Rejected("time")
        if named != started:
            raise Rejected("run_id_time")
        # S3's upload time gives the same answer on every run; the clock
        # covers a listing without one.
        if named > min(self.now, uploaded or self.now) + FUTURE:
            raise Rejected("future_run_id")
        if finished < started:
            raise Rejected("finished_before_started")
        results, out = record["drill"]["results"], record["outcome"]
        p5 = results["ingest_p5_bytes_per_s"] if results else None
        median = results["ingest_median_bytes_per_s"] if results else None
        if p5 is not None and median is not None and p5 > median:
            raise Rejected("p5_above_median")
        if out["class"] == "valid" and (out["drill_exit"] != 0 or out["reasons"] or results is None
                                        or record["drill"]["requests"] is None):
            raise Rejected("valid_inconsistent")
        # A CPU-capped run is a check run; as any other series it could light a gate.
        if "cpu_capped" in out["flags"] and record["series"] != "calibration":
            raise Rejected("capped_not_calibration")
        stored = (record["instrument"]["fingerprint"], record["instrument"]["box_fingerprint"])
        if stored != fingerprints(record):
            raise Rejected("fingerprint")
        return record


def dump(obj):
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def record_path(results, run_id):
    t = run_id_time(run_id)
    return Path(results) / "runs" / f"{t:%Y}" / f"{t:%m}" / f"{run_id}.json"


def committed(results):
    """run_id -> path of every committed record."""
    return {p.stem: p for p in (Path(results) / "runs").glob("*/*/*.json")}


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def write_if_changed(path, obj):
    path = Path(path)
    if read_json(path, None) != obj:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(dump(obj), encoding="utf-8")


class Bucket:
    """The published/ prefix through the AWS CLI."""

    def __init__(self, name):
        self.name = name

    def _aws(self, *args):
        return subprocess.run(["aws", *args], capture_output=True)

    def list(self):
        out = self._aws("s3api", "list-objects-v2", "--bucket", self.name, "--prefix", "published/",
                        "--output", "json")
        if out.returncode != 0:
            raise RuntimeError("listing published/ failed")
        listing = json.loads(out.stdout or b"{}") or {}
        return {o["Key"]: o for o in listing.get("Contents") or []}

    def get(self, key):
        out = self._aws("s3", "cp", f"s3://{self.name}/{key}", "-")
        if out.returncode != 0:
            raise RuntimeError(f"reading {key} failed")
        return out.stdout


def compare_links(record, previous):
    """Changed components with GitHub compare links, from public fields only."""
    if previous is None:
        return []
    cur, prev = record["provenance"], previous["provenance"]
    links = []
    for name in record["trigger"]["changed"]:
        if name == "smelt":
            links.append(f"smelt https://github.com/fil-forge/smelt/compare/"
                         f"{prev['smelt']['sha']}...{cur['smelt']['sha']}")
        elif name == "harness":
            links.append(f"harness {cur['harness']['sha']}")
        else:
            now_i = [i for i in cur["images"] if i["repo"].endswith("/" + name) and i["role"] == "under_test"]
            old_i = [i for i in prev["images"] if now_i and i["repo"] == now_i[0]["repo"]]
            if now_i and old_i and now_i[0]["source"] and now_i[0]["revision"] and old_i[0]["revision"]:
                links.append(f"{name} {now_i[0]['source']}/compare/{old_i[0]['revision']}...{now_i[0]['revision']}")
            else:
                links.append(name)
    return links


def record_alerts(record, previous, status):
    """Alert lines for one record; updates the box's status in place."""
    if record["series"] == "calibration":
        return []
    box, run_id, out = record["box"]["id"], record["run_id"], record["outcome"]
    cls, reasons = out["class"], set(out["reasons"])
    link = f"{PAGE}#run={run_id}"
    infra_only = cls == "no_data" and reasons and reasons <= INFRASTRUCTURE
    status["infra_streak"] = status.get("infra_streak", 0) + 1 if infra_only else 0
    alerted = status.setdefault("alerted_classes", [])
    if cls in ("valid", "availability_warning"):
        if not alerted:
            return []
        was = ", ".join(alerted)
        status["alerted_classes"] = []
        return [f"forge-perf {box}: {run_id} ended {cls}; the box has recovered from {was}. {link}"]
    if cls == "no_data":
        alerts = not infra_only or status["infra_streak"] >= 3
    elif cls == "failed":
        alerts = "integrity_failure" in reasons
    else:
        alerts = bool(reasons & (LATENCY_OR_RESTART | BOX_OR_INSTRUMENT))
    if not alerts or cls in alerted:
        return []
    alerted.append(cls)
    alerted.sort()
    parts = [f"reasons {', '.join(out['reasons'])}"]
    if out["restarted_services"]:
        parts.append(f"restarted {', '.join(out['restarted_services'])}")
    if out["failure_codes"]:
        parts.append(f"failure codes {', '.join(out['failure_codes'])}")
    changed = compare_links(record, previous)
    if changed:
        parts.append(f"changed {'; '.join(changed)}")
    return [f"forge-perf {box}: {run_id} ended {cls} ({'; '.join(parts)}). {link}"]


def heartbeat_summary(raw):
    """The allowlisted heartbeat fields, or None when it is unusable."""
    try:
        hb = json.loads(raw) if raw is not None and len(raw) <= MAX_HEARTBEAT else None
    except ValueError:
        hb = None
    if not isinstance(hb, dict) or utc(hb.get("at")) is None:
        return None
    failures = hb.get("poll_failures")
    return {
        "at": hb["at"],
        "state": hb.get("state") if hb.get("state") in ("idle", "running", "held") else None,
        "poll_failures": failures if isinstance(failures, int) and not isinstance(failures, bool)
        and 0 <= failures < 10**6 else None,
        "run_started_at": hb.get("run_started_at") if utc(hb.get("run_started_at")) else None,
    }


def heartbeat_alerts(box, hb, latest_run, now, status):
    """Alert lines for the box's heartbeat conditions, each once while it holds."""
    conditions = {}
    if hb is None or now - utc(hb["at"]) > HEARTBEAT_STALE:
        conditions["heartbeat_stale"] = "no heartbeat" if hb is None else \
            f"no heartbeat for {int((now - utc(hb['at'])).total_seconds() // 60)} minutes"
    if hb and (hb["poll_failures"] or 0) >= POLL_FAILURES:
        conditions["poll_failures"] = f"{hb['poll_failures']} polls in a row failed"
    if hb and hb["state"] == "running" and hb["run_started_at"] and \
            now - utc(hb["run_started_at"]) > LONG_RUN:
        conditions["long_run"] = f"one run has held the box since {hb['run_started_at']}"
    before = set(status.get("conditions", []))
    # While a fresh heartbeat says a run is in progress, that run has not
    # written its record yet, so the 26 hours are judged when it ends;
    # long_run covers a run that never does. A condition already raised holds
    # without posting again.
    running = latest_run is not None and "heartbeat_stale" not in conditions and hb["state"] == "running"
    if latest_run is None or now - run_id_time(latest_run) > NO_RECORD:
        if not running or "no_record" in before:
            conditions["no_record"] = "no record in 26 hours" if latest_run else "no record yet"
    status["conditions"] = sorted(conditions)
    return [f"forge-perf {box}: {text}. {PAGE}" for name, text in sorted(conditions.items())
            if name not in before]


def ingest(bucket, results, boxes, checks):
    """Returns (alerts, rejected keys, heartbeat summaries)."""
    results = Path(results)
    have = committed(results)
    rejected_path = results / "status" / "rejected.json"
    known_rejected = read_json(rejected_path, {})
    rejected, alerts, fresh = {}, [], []
    listing = bucket.list()
    # Heartbeats, probes and records already committed are skipped. Keys
    # rejected before are checked again on every run; at most MAX_NEW others
    # are read per run, oldest first, so a backlog commits in slices.
    new = sorted((k for k in listing if RECORD_KEY.match(k) and RECORD_KEY.match(k).group(2) not in have),
                 key=lambda k: (RECORD_KEY.match(k).group(2).rsplit("-", 1)[1], k))
    new = [k for k in new if k in known_rejected] + [k for k in new if k not in known_rejected][:MAX_NEW]
    for key in new:
        try:
            if listing[key].get("Size", 0) > MAX_RECORD:
                raise Rejected("size")
            raw = bucket.get(key)
            try:
                record = checks.check(key, raw, listed_time(listing[key].get("LastModified")))
            except Rejected:
                raise
            except Exception as e:  # one object must never stop the queue
                print(f"ingest: {key}: {type(e).__name__} in the checks", file=sys.stderr)
                raise Rejected("internal")
        except Rejected as e:
            rejected[key] = e.args[0]
            print(f"ingest: rejected {key}: {e.args[0]}", file=sys.stderr)
            if known_rejected.get(key) != e.args[0]:
                alerts.append(f"forge-perf publish rejected {key}: {e.args[0]}")
            continue
        path = record_path(results, record["run_id"])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(dump(record), encoding="utf-8")
        have[record["run_id"]] = path
        fresh.append(record)
        print(f"ingest: added {key}")
    if rejected or known_rejected:
        write_if_changed(rejected_path, rejected)

    by_box = {}
    for run_id in sorted(have, key=lambda r: (r.rsplit("-", 1)[1], r)):
        by_box.setdefault(run_id.rsplit("-", 1)[0], []).append(run_id)
    fresh.sort(key=lambda r: (run_id_time(r["run_id"]), r["run_id"]))
    statuses, heartbeats = {}, {}
    for record in fresh:
        box = record["box"]["id"]
        status = statuses.setdefault(box, read_json(results / "status" / f"{box}.json", {}))
        runs = by_box[box]
        i = runs.index(record["run_id"])
        previous = read_json(have[runs[i - 1]], None) if i > 0 else None
        alerts += record_alerts(record, previous, status)
    for box in boxes:
        status = statuses.setdefault(box, read_json(results / "status" / f"{box}.json", {}))
        key = f"published/{box}/heartbeat.json"
        hb = heartbeat_summary(bucket.get(key) if key in listing else None)
        heartbeats[box] = hb
        latest = by_box.get(box, [None])[-1]
        alerts += heartbeat_alerts(box, hb, latest, checks.now, status)
    for box, status in statuses.items():
        write_if_changed(results / "status" / f"{box}.json", status)
    new_rejections = [k for k in rejected if known_rejected.get(k) != rejected[k]]
    return alerts, new_rejections, heartbeats


def load_patterns():
    if os.environ.get("PUBLIC_DENYLIST_REGEX"):
        text = os.environ["PUBLIC_DENYLIST_REGEX"]
    elif os.environ.get("DENYLIST_FILE"):
        text = Path(os.environ["DENYLIST_FILE"]).read_text(encoding="utf-8")
    else:
        return None
    lines = [line for line in text.splitlines() if line.strip()]
    return "\n".join(lines) + "\n" if lines else None


def github_output(values):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        for name, value in values.items():
            delimiter = f"EOF_{os.urandom(8).hex()}"
            f.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")


def set_path(obj, dotted, value):
    parts = dotted.split(".")
    for part in parts[:-1]:
        obj = obj[int(part)] if isinstance(obj, list) else obj[part]
    last = parts[-1]
    if isinstance(obj, list):
        obj[int(last)] = value
    else:
        obj[last] = value


def self_test():
    """Runs scripts/publish/fixtures/cases.json against a scratch repository."""
    fixtures = HERE / "fixtures"
    cases = json.loads((fixtures / "cases.json").read_text(encoding="utf-8"))
    root = HERE.parent.parent
    base = json.loads((root / "scripts/host/fixtures/valid/expected.json").read_text(encoding="utf-8"))
    schema = json.loads((root / SCHEMA_PATH).read_text(encoding="utf-8"))
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        # Two commits: an older schema without `trace`, then today's.
        def git(*args):
            return subprocess.run(["git", "-C", tmp, "-c", "user.name=self-test", "-c",
                                   "user.email=self-test@invalid", "-c", "commit.gpgsign=false", *args],
                                  check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        older = copy.deepcopy(schema)
        del older["properties"]["trace"]
        older["required"].remove("trace")
        (Path(tmp) / "schema").mkdir()
        for version in (older, schema):
            (Path(tmp) / SCHEMA_PATH).write_text(json.dumps(version), encoding="utf-8")
            git("add", "-A")
            git("commit", "-q", "-m", "schema")
        shas = {"older": git("rev-parse", "HEAD~1"), "main": git("rev-parse", "HEAD")}
        patterns = (fixtures / "denylist.regex").read_text(encoding="utf-8")
        checks = Checks(tmp, "HEAD", patterns, utc(cases["now"]))
        for case in cases["cases"]:
            record = copy.deepcopy(base)
            for dotted, value in case.get("set", {}).items():
                if isinstance(value, str) and value.startswith("sha:"):
                    value = shas[value[4:]]
                set_path(record, dotted, value)
            key = case.get("key", f"published/{record['box']['id']}/{record['run_id']}.json")
            raw = dump(record)
            if "raw" in case:  # text the builder would not write, such as escapes
                raw = raw.replace(*case["raw"])
            try:
                checks.check(key, raw.encode("utf-8"))
                got = None
            except Rejected as e:
                got = e.args[0]
            ok = got == case["reject"]
            failed += not ok
            print(f"{'ok' if ok else 'FAIL'} {case['name']}: "
                  f"{'accepted' if got is None else 'rejected by ' + got}"
                  f"{'' if ok else ', expected ' + str(case['reject'])}")
    print(f"self-test: {len(cases['cases']) - failed} of {len(cases['cases'])} cases as expected")
    return 1 if failed else 0


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--bucket")
    p.add_argument("--results")
    p.add_argument("--repo", default=str(HERE.parent.parent))
    p.add_argument("--main-ref", default="HEAD")
    p.add_argument("--boxes", default=str(HERE.parent.parent / "data" / "boxes.json"))
    p.add_argument("--now", help="UTC time, for tests; default the clock")
    args = p.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.bucket or not args.results:
        p.error("--bucket and --results are required")
    patterns = load_patterns()
    if patterns is None:
        print("ingest: no denylist pattern (PUBLIC_DENYLIST_REGEX or DENYLIST_FILE); refusing to publish",
              file=sys.stderr)
        return 2
    now = utc(args.now) if args.now else dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    boxes = json.loads(Path(args.boxes).read_text(encoding="utf-8"))
    checks = Checks(args.repo, args.main_ref, patterns, now)
    alerts, rejected, heartbeats = ingest(Bucket(args.bucket), args.results, boxes, checks)
    github_output({"alerts": "\n".join(alerts), "rejected": str(len(rejected)),
                   "heartbeats": json.dumps(heartbeats, sort_keys=True, separators=(",", ":"))})
    for line in alerts:
        print(f"alert: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
