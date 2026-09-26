#!/usr/bin/env python3
"""Builds the public run record, forge-perf.run/v1, from one run's inputs.

    record.py build --runner runner.json [--run-dir DIR] [--latency latency.json]
                    --denylist FILE [--forbid FILE] --out record.json
    record.py minimal --runner runner.json --denylist FILE [--forbid FILE] --out record.json

docs/record.md is the contract: which input each field comes from, the
classification order, the reasons and the flags. The builder copies named
fields and nothing else. It never reads the drill's report, drill.out, the
other service logs, or the free-text parts of the evidence and metadata.

`build` falls back to the minimal record when the run directory belongs to
another run, when any input cannot be read as expected, or when the full
record fails the schema or the public-text check. `minimal` writes that
record directly, for a runner whose `build` call died. Before writing, every
record is checked against the schema, the denylist patterns (extended
regular expressions, one per line, matched without regard to case) and the
literal strings in --forbid (piri's S3 key ID); a record that fails is never
written. Messages name the stage that failed, never an input's value.

Exit status: 0 the full record was written; 3 the minimal record was written
in its place; 1 nothing was written; 2 usage.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

import schemacheck

ROOT = Path(__file__).resolve().parent.parent.parent
SCHEMA_PATH = ROOT / "schema" / "run-record.v1.json"
LATENCY_ENV = ROOT / "config" / "latency.env"
GROUPS_CONF = ROOT / "config" / "groups.conf"

SCHEMA = schemacheck.load(open(SCHEMA_PATH, encoding="utf-8"))
REASONS = SCHEMA["properties"]["outcome"]["properties"]["reasons"]["items"]["enum"]
FLAGS = SCHEMA["properties"]["outcome"]["properties"]["flags"]["items"]["enum"]
CLASS_OF = {}  # reason -> class, docs/record.md "Reasons"
for _cls, _first, _last in (("no_data", "runner_error", "record_build_failed"),
                            ("failed", "integrity_failure", "drill_failure"),
                            ("invalid", "rtt_out_of_band", "box_type_mismatch"),
                            ("availability_warning", "availability_errors", "availability_errors")):
    for _r in REASONS[REASONS.index(_first):REASONS.index(_last) + 1]:
        CLASS_OF[_r] = _cls
CLASS_ORDER = ["no_data", "failed", "invalid", "availability_warning"]
# Failure codes with a reason of their own; any other code is drill_failure.
OWN_REASON = {"availability_error": "availability_errors", "read_back_incomplete": "read_back_incomplete",
              "ingest_cutoff_before_measurement": "ingest_cutoff_before_measurement",
              "wrote_nothing": "wrote_nothing", "integrity_failure": "integrity_failure", "interrupted": None}
SETTINGS = ["profile", "manifest", "window_s", "ramp_s", "workers", "duration_s", "rate_target_bytes_per_s",
            "stop_ingest_at_bytes", "verify_lag_min_s", "verify_lag_max_s", "accounts", "restore_scale_permille",
            "enforce_floor", "progress_s", "keep_objects"]
ALLOWANCE = ["bw_in", "bw_out", "pps", "conntrack", "linklocal"]
SHA1 = re.compile(r"^[0-9a-f]{40}$")
SOURCE = re.compile(r"^https://github\.com/fil-forge/[A-Za-z0-9._-]+$")


class Stop(Exception):
    """The builder cannot produce the full record; the minimal one follows."""


class Refused(Exception):
    """The record failed a check and must not be written."""


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return schemacheck.load(f)


def read_env(path):
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z_]+)=\"?([^\"#]*?)\"?\s*$", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def number(text):
    value = float(text)
    return int(value) if value.is_integer() else value


def services():
    """Services a reason may name: every group in groups.conf but ONESHOT."""
    conf = read_env(GROUPS_CONF)
    return set(" ".join(conf[g] for g in ("NODE", "CENTRAL", "OTHER")).split())


def canonical_sha256(obj):
    text = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --- smelt's suite.argv against the runner's settings -----------------------

def parse_size(text):
    """storage-qualification internal/config ParseSize."""
    s = text.strip()
    units = [("KiB", 1 << 10), ("MiB", 1 << 20), ("GiB", 1 << 30), ("TiB", 1 << 40), ("KB", 10**3),
             ("MB", 10**6), ("GB", 10**9), ("TB", 10**12), ("K", 1 << 10), ("M", 1 << 20), ("G", 1 << 30),
             ("T", 1 << 40), ("B", 1)]
    for suffix, mult in units:
        if s.upper().endswith(suffix.upper()):
            return int(float(s[:-len(suffix)].strip()) * mult)
    return int(s)


def parse_duration(text):
    """A Go duration in whole seconds."""
    scale = {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6, "µs": 1e-6, "ns": 1e-9}
    if text == "0":
        return 0
    parts = re.findall(r"([0-9.]+)(h|ms|us|µs|ns|m|s)", text)
    if not parts or "".join(n + u for n, u in parts) != text:
        raise Stop("argv: not a duration")
    return round(sum(float(n) * scale[u] for n, u in parts))


def argv_settings(argv):
    flags = {}
    i = 1
    while i < len(argv):
        arg = argv[i]
        i += 1
        if not arg.startswith("-"):
            continue
        name, eq, value = arg.lstrip("-").partition("=")
        if not eq:
            if name in ("keep-objects", "enforce-floor"):
                value = "true"
            elif i < len(argv):
                value, i = argv[i], i + 1
        flags[name] = value
    durations = {"window_s": "window", "ramp_s": "ramp", "duration_s": "duration", "progress_s": "progress",
                 "verify_lag_min_s": "verify-lag-min", "verify_lag_max_s": "verify-lag-max"}
    try:
        out = {k: parse_duration(flags[f]) for k, f in durations.items()}
        out.update(profile=flags["profile"], workers=int(flags["workers"]), accounts=int(flags["accounts"]),
                   rate_target_bytes_per_s=parse_size(flags["rate-target"]),
                   stop_ingest_at_bytes=parse_size(flags["stop-ingest-at"]),
                   restore_scale_permille=round(float(flags["restore-scale"]) * 1000),
                   enforce_floor=flags.get("enforce-floor", "false") == "true",
                   keep_objects=flags.get("keep-objects", "false") == "true")
    except (KeyError, ValueError):
        raise Stop("argv: a drill setting is missing or unreadable") from None
    return out


# --- netem check lines -------------------------------------------------------

NETEM_RULES = [
    (r"^harness error: ", "runner_error", False),
    (r"^(\S+) restarted after apply", "container_restarted", True),
    (r"^(\S+) address changed from ", "central_ip_changed", False),
    (r"^(\S+): container \S+ is gone", "container_restarted", True),
    (r"^(\S+) is not running; ", "container_restarted", True),
    (r"^(\S+): (die|start|restart) event after apply", "container_restarted", True),
    (r"^\S+: (cannot read its qdiscs|no prio root qdisc|netem delay is not |filters do not match )",
     "netem_missing", False),
    (r"^no reply from |^no TCP connection from | median round trip .* is outside | is not under "
     r"| median connect .* is outside ", "rtt_out_of_band", False),
    (r"^(\S+) is \S+$", "container_restarted", True),
]


def netem_reason(line, known):
    """(reason, service or None) for one check line; the first rule wins."""
    for pattern, reason, names in NETEM_RULES:
        m = re.search(pattern, line)
        if m:
            if names and m.group(1) not in known:
                return "runner_error", None
            return reason, (m.group(1) if names else None)
    return "runner_error", None


def rtt_summary(p):
    if p is None:
        return None
    connects = [c["connect_median_ms"] for c in p["connects"] if c["connect_median_ms"] is not None]
    return {"ok": p["ok"], "node_to_central_median_ms": p["node_to_central_median_ms"],
            "central_to_node_median_ms": p["central_to_node_median_ms"],
            "intra_group_max_ms": p["intra_group_max_ms"], "host_to_ingot_ms": p["host_to_ingot_ms"],
            "connect_median_max_ms": max(connects) if connects else None}


def latency_block(latency, env):
    pre, post = (latency or {}).get("pre"), (latency or {}).get("post")
    first = pre or post
    target = first["rtt_ms"] if first else number(env["RTT_MS"])
    tolerance = first["tolerance_pct"] if first else number(env["RTT_TOLERANCE_PCT"])
    drifts = [abs(x["median_ms"] - p["rtt_ms"]) / p["rtt_ms"] * 100 for p in (pre, post) if p
              for x in p["pairs"] if x["kind"] == "cross" and x["median_ms"] is not None]
    stable = None
    if post:
        stable = not any(netem_reason(line, set())[0] == "central_ip_changed" for line in post["reasons"])
    return {"target_rtt_ms": target, "tolerance_pct": tolerance, "jitter_ms": 0,
            "pairs": sum(1 for x in pre["pairs"] if x["kind"] == "cross") if pre else 0,
            "before": rtt_summary(pre), "after": rtt_summary(post),
            "max_drift_pct": round(max(drifts), 2) if drifts else None, "central_ips_stable": stable}


# --- the record ----------------------------------------------------------------

def base_record(runner, env):
    """Every field runner.json alone decides, with the drill and netem absent."""
    box = runner["box"]
    cpu = box["cpu"]
    prov = runner["provenance"]
    nic = runner["nic"]
    allowance = nic["allowance_exceeded"]
    images = sorted(runner["images"], key=lambda i: i["repo"])
    return {
        "schema": "forge-perf.run/v1",
        "run_id": runner["run_id"],
        "series": runner["series"],
        "pairing_id": runner["pairing_id"],
        "trigger": {"reason": runner["trigger"]["reason"], "changed": sorted(runner["trigger"]["changed"])},
        "box": {**{k: box[k] for k in ("id", "tier", "instance_type", "arch")}, "region": "us-east-2",
                **{k: box[k] for k in ("availability_zone", "ami_id", "kernel", "docker_server", "docker_compose")},
                "cpu": {k: cpu[k] for k in ("implementer", "part", "cores")} | {"features": list(cpu["features"])},
                "mem_total_bytes": box["mem_total_bytes"],
                "nvme": {k: box["nvme"][k] for k in ("model", "size_bytes", "filesystem")}},
        "time": {k: runner["time"][k] for k in ("run_started_at", "stack_up_at", "drill_started_at",
                                                 "drill_finished_at", "run_finished_at")},
        "outcome": {"class": "no_data", "reasons": [], "restarted_services": [], "flags": [], "drill_exit": None,
                    "failure_codes": []},
        "drill": {"settings": {k: runner["settings"][k] for k in SETTINGS}, "results": None, "requests": None},
        "latency": latency_block(None, env),
        "network": {"allowance_exceeded": None if allowance is None else {k: allowance[k] for k in ALLOWANCE},
                    "egress_bytes_per_s_median": nic["egress_bytes_per_s_median"],
                    "seconds_above_baseline": nic["seconds_above_baseline"]},
        "provenance": {
            "forge_perf": {"sha": prov["forge_perf"]["sha"], "instrument_tree": prov["forge_perf"]["instrument_tree"]},
            "smelt": {"sha": prov["smelt"]["sha"]},
            "harness": {"sha": prov["harness"]["sha"], "modified": None, "go_version": None, "binary_sha256": None},
            "images": [{"repo": i["repo"], "ref": i["ref"], "digest": i["digest"], "revision": None, "source": None,
                        "role": i["role"], "services": sorted(i["services"])} for i in images]},
        "instrument": {"fingerprint": "", "box_fingerprint": ""},
        "trace": None,
    }


def finish(record, reasons, restarted, flags):
    """Orders reasons and flags, picks the class, computes the fingerprints."""
    out = record["outcome"]
    has_numbers = record["drill"]["results"] is not None
    if not has_numbers and not reasons:
        reasons.add("runner_error")
    out["reasons"] = [r for r in REASONS if r in reasons]
    out["restarted_services"] = sorted(restarted)
    if record["network"]["allowance_exceeded"] and any(record["network"]["allowance_exceeded"].values()):
        flags.add("nic_allowance_exceeded")
    out["flags"] = [f for f in FLAGS if f in flags]
    classes = {CLASS_OF[r] for r in reasons}
    out["class"] = "no_data" if not has_numbers else next((c for c in CLASS_ORDER if c in classes), "valid")
    prov = record["provenance"]
    record["instrument"]["fingerprint"] = canonical_sha256({
        "forge_perf_instrument_tree": prov["forge_perf"]["instrument_tree"],
        "smelt_sha": prov["smelt"]["sha"], "harness_sha": prov["harness"]["sha"],
        "instrument_images": [[i["repo"], i["digest"]] for i in prov["images"] if i["role"] == "instrument"],
        "settings": record["drill"]["settings"],
        "target_rtt_us": round(record["latency"]["target_rtt_ms"] * 1000), "jitter_us": 0})
    box = record["box"]
    facts = {k: box[k] for k in ("instance_type", "arch", "ami_id", "kernel", "docker_server", "docker_compose", "cpu")}
    facts.update(nvme_model=box["nvme"]["model"], nvme_filesystem=box["nvme"]["filesystem"])
    record["instrument"]["box_fingerprint"] = canonical_sha256(facts)
    return record


def runner_flags(runner):
    flags = set()
    if runner["superseded"] > 0:
        flags.add("superseded")
    if runner["raw_missing"]:
        flags.add("raw_missing")
    return flags


def minimal(runner, env):
    record = base_record(runner, env)
    reasons = set(runner["reasons"]) | {"record_build_failed"}
    if runner["watchdog_fired"]:
        reasons.add("watchdog_timeout")
    return finish(record, reasons, set(runner["restarted_services"]), runner_flags(runner))


def build(runner, run_dir, latency, env):
    record = base_record(runner, env)
    reasons, restarted, flags = set(runner["reasons"]), set(runner["restarted_services"]), runner_flags(runner)
    record["latency"] = latency_block(latency, env)
    known = services()
    for p in ((latency or {}).get("pre"), (latency or {}).get("post")):
        for line in (p["reasons"] if p else []):
            reason, svc = netem_reason(line, known)
            reasons.add(reason)
            if svc:
                restarted.add(svc)
    if runner["watchdog_fired"]:
        reasons.add("watchdog_timeout")

    meta = evidence = None
    if run_dir is not None and (Path(run_dir) / "metadata.json").exists():
        meta = read_json(Path(run_dir) / "metadata.json")
        if meta["extra"]["forge_perf"]["run_id"] != runner["run_id"]:
            raise Stop("the run directory belongs to another run")
        if argv_settings(meta["suite"]["argv"]) != {k: v for k, v in runner["settings"].items() if k != "manifest"}:
            raise Stop("suite.argv disagrees with the runner's settings")
        found = glob.glob(os.path.join(glob.escape(str(run_dir)), "drill", "evidence", "drill-*.json"))
        if len(found) > 1:
            raise Stop("more than one evidence file")
        evidence = read_json(found[0]) if found else None

    exit_code = meta["suite"].get("drill_exit") if meta else None
    if isinstance(exit_code, bool) or exit_code not in (0, 1, 2):
        exit_code = None
    record["outcome"]["drill_exit"] = exit_code
    started = runner["time"]["drill_started_at"] is not None
    if started and not runner["watchdog_fired"] and exit_code not in (0, 1):
        reasons.add("drill_interrupted")
    if exit_code in (0, 1) and evidence is None:
        reasons.add("no_evidence")

    if meta:
        pinned = {s: i["digest"] for i in runner["images"] for s in i["services"]}
        labels = {}
        for image in meta["images"]:
            labels.setdefault(image["digest"], image)
            if image["service"] in pinned and image["digest"] != pinned[image["service"]]:
                reasons.add("image_changed")
        for entry in record["provenance"]["images"]:
            image = labels.get(entry["digest"])
            if image is None:
                continue
            if isinstance(image.get("revision"), str) and SHA1.match(image["revision"]):
                entry["revision"] = image["revision"]
            if entry["role"] == "under_test" and isinstance(image.get("source"), str) and SOURCE.match(image["source"]):
                entry["source"] = image["source"]

    if evidence is not None:
        # The harness omits an empty drill.failures, windows or facts (omitempty).
        drill, ev_prov = evidence["drill"], evidence["provenance"]
        facts = drill.get("facts") or {}
        codes = {f["code"] for f in (evidence.get("failures") or []) + (drill.get("failures") or [])}
        record["outcome"]["failure_codes"] = sorted(codes)
        for code in codes:
            reasons.add(OWN_REASON.get(code, "drill_failure"))
        reasons.discard(None)
        harness = record["provenance"]["harness"]
        # The harness writes "" for a value it could not read.
        harness.update(modified=ev_prov["harness_modified"], go_version=ev_prov["go_version"] or None,
                       binary_sha256=ev_prov["binary_sha256"] or None)
        if not ev_prov["harness_revision"] or ev_prov["harness_revision"] != harness["sha"] \
                or ev_prov["harness_modified"]:
            reasons.add("harness_mismatch")
        avail = drill["availability"]
        if drill["integrity_failures"] > 0:
            reasons.add("integrity_failure")
        if any(avail[k] > 0 for k in ("transport_errors", "status_408", "status_429", "status_5xx")):
            reasons.add("availability_errors")

        if exit_code in (0, 1):
            sustained = facts.get("sustained_windows", 0)
            cap = facts.get("ingest_cutoff_reached") is True
            median = facts.get("sustained_ingest_median_bytes_per_second")
            record["drill"]["results"] = {
                "sustained_windows": sustained,
                "total_windows": len(drill.get("windows") or []),
                "ingest_p5_bytes_per_s": facts.get("sustained_ingest_p5_bytes_per_second"),
                "ingest_median_bytes_per_s": median,
                "writes_median_per_s": facts.get("sustained_writes_median_per_second"),
                "window_ingest_bytes_per_s": [w["ingest_bytes_per_second"] for w in drill.get("windows") or []],
                "cache_served": {
                    "read_back_median_bytes_per_s": facts.get("sustained_read_median_bytes_per_second"),
                    "restore_median_bytes_per_s": facts.get("sustained_restore_median_bytes_per_second")},
                "ingest_sent_bytes": facts["ingest_sent_bytes"],
                "bytes_ingested": drill["bytes_ingested"], "bytes_read_back": drill["bytes_read_back"],
                "bytes_restored": drill["bytes_restored"], "blobs_written": facts["blobs_written"],
                "cap_reached": cap, "ingest_cutoff_s": facts.get("ingest_cutoff_seconds") if cap else None}
            piri_log = Path(run_dir) / "logs" / "piri-0.log"
            s3_errors = None
            if piri_log.exists():
                with open(piri_log, "rb") as f:
                    s3_errors = sum(1 for line in f if b"failed to put object" in line)
            record["drill"]["requests"] = {
                "total": avail["requests"], **{k: avail[k] for k in ("transport_errors", "status_408",
                                                                     "status_429", "status_5xx")},
                "integrity_failures": drill["integrity_failures"], "backend_s3_errors": s3_errors}
            if not sustained:
                reasons.add("no_steady_windows")
            if sustained < 20:
                flags.add("few_windows")
            if not cap:
                flags.add("cap_not_reached")
            target = record["drill"]["settings"]["rate_target_bytes_per_s"]
            if median is not None and target > 0 and median >= 0.9 * target:
                flags.add("offered_rate_near_median")
            if exit_code == 1 and not codes and drill["integrity_failures"] == 0:
                reasons.add("drill_failure")
            if exit_code == 1 and not reasons:
                reasons.add("drill_failure")
    return finish(record, reasons, restarted, flags)


# --- checks and output ---------------------------------------------------------

ERE_ONLY = ("\\<", "\\>", "[[:")


def read_denylist(path):
    patterns = [line for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]
    if not patterns:
        raise Refused("the denylist is empty")
    # CI reads the same file with grep -E. Refuse the ERE forms Python reads differently.
    if any(tok in p for p in patterns for tok in ERE_ONLY):
        raise Refused("the denylist uses an ERE-only form")
    try:
        return [re.compile(p, re.I) for p in patterns]
    except re.error:
        raise Refused("the denylist holds a pattern that does not compile") from None


def check_public(record, denylist, forbidden):
    if schemacheck.Checker(SCHEMA).errors(record):
        raise Refused("the record fails the schema")
    text = json.dumps(record, ensure_ascii=False)
    if any(p.search(text) for p in denylist):
        raise Refused("the record matches the denylist")
    if any(s in text for s in forbidden):
        raise Refused("the record holds a forbidden string")


def write(record, out):
    out = Path(out)
    fd, tmp = tempfile.mkstemp(dir=out.parent, prefix=".record.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, out)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    dfd = os.open(out.parent, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def main(argv):
    parser = argparse.ArgumentParser(prog="record.py", description="Builds the public run record.")
    parser.add_argument("command", choices=["build", "minimal"])
    parser.add_argument("--runner", required=True)
    parser.add_argument("--run-dir")
    parser.add_argument("--latency")
    parser.add_argument("--latency-env", default=str(LATENCY_ENV))
    parser.add_argument("--denylist", required=True)
    parser.add_argument("--forbid", help="file of literal strings, one per line, that must not appear")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        denylist = read_denylist(args.denylist)
        forbidden = []
        if args.forbid:
            forbidden = [s.strip() for s in Path(args.forbid).read_text(encoding="utf-8").splitlines() if s.strip()]
        runner = read_json(args.runner)
        env = read_env(args.latency_env)
    except (OSError, ValueError, Refused) as e:
        print(f"record: cannot read an input: {type(e).__name__}", file=sys.stderr)
        return 1
    if args.command == "build":
        try:
            latency = read_json(args.latency) if args.latency and Path(args.latency).exists() else None
            record = build(runner, args.run_dir, latency, env)
            check_public(record, denylist, forbidden)
            write(record, args.out)
            return 0
        except Refused as e:
            print(f"record: {e}; writing the minimal record", file=sys.stderr)
        except Stop as e:
            print(f"record: {e}; writing the minimal record", file=sys.stderr)
        except Exception as e:  # noqa: BLE001 - any failure ends in the minimal record
            print(f"record: the build failed ({type(e).__name__}); writing the minimal record", file=sys.stderr)
    try:
        record = minimal(runner, env)
        check_public(record, denylist, forbidden)
        write(record, args.out)
    except Exception as e:  # noqa: BLE001
        print(f"record: the minimal record failed too ({e if isinstance(e, Refused) else type(e).__name__})",
              file=sys.stderr)
        return 1
    return 3 if args.command == "build" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
