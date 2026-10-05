#!/usr/bin/env python3
"""Builds the Pages site from site/, data/ and the committed records.

    build-site.py --site site --data data --results <results checkout> --out _site
                  [--heartbeats '<JSON>'] [--now <UTC time>]

Copies site/, copies each record to data/runs/<run_id>.json and writes
data/index.json: one compact row per run, the gates and overrides, the
heartbeat summaries the ingest job read, and the time of this publish.
Standard library only.
"""

import argparse
import datetime as dt
import json
import shutil
import sys
from pathlib import Path


def changes(record, previous):
    """Instrument components that differ from the previous run in the series on the box.

    `previous` is the latest earlier run there with drill settings. A run
    without settings (a broken host) has no settings or box to compare.
    """
    if previous is None:
        return None
    cur, old = record["provenance"], previous["provenance"]
    out = []
    if cur["forge_perf"]["instrument_tree"] != old["forge_perf"]["instrument_tree"]:
        out.append("forge-perf")
    for name in ("smelt", "harness"):
        if cur[name]["sha"] != old[name]["sha"]:
            out.append(name)
    images = [{i["repo"]: i["digest"] for i in p["images"] if i["role"] == "instrument"} for p in (cur, old)]
    out += sorted(r for r in images[0].keys() | images[1].keys() if images[0].get(r) != images[1].get(r))
    broken = record["drill"]["settings"] is None
    if not broken and record["drill"]["settings"] != previous["drill"]["settings"]:
        out.append("settings")
    if record["latency"]["target_rtt_ms"] != previous["latency"]["target_rtt_ms"]:
        out.append("latency")
    # A record from before tracing has no `trace`; it was untraced.
    if (record.get("trace") or {}).get("ratio") != (previous.get("trace") or {}).get("ratio"):
        out.append("trace")
    if not broken and record["instrument"]["box_fingerprint"] != previous["instrument"]["box_fingerprint"]:
        out.append("box")
    return out


def row(record, previous):
    results = record["drill"]["results"] or {}
    # A record from before the read-back and restore p5 lacks those keys.
    reads = results.get("cache_served") or {}
    before = record["latency"]["before"] or {}
    return {
        "run_id": record["run_id"],
        "series": record["series"],
        "pairing_id": record["pairing_id"],
        # An experiment's run: which pull request and which of its two sets.
        # A record from before experiments has no block.
        "experiment": record.get("experiment"),
        "changed": record["trigger"]["changed"],
        "size_bytes": (record["drill"]["settings"] or {}).get("stop_ingest_at_bytes"),
        "box": {k: record["box"][k] for k in ("id", "tier", "instance_type")},
        "run_started_at": record["time"]["run_started_at"],
        "run_finished_at": record["time"]["run_finished_at"],
        "class": record["outcome"]["class"],
        "reasons": record["outcome"]["reasons"],
        "flags": record["outcome"]["flags"],
        "p5_bytes_per_s": results.get("ingest_p5_bytes_per_s"),
        "median_bytes_per_s": results.get("ingest_median_bytes_per_s"),
        "writes_median_per_s": results.get("writes_median_per_s"),
        "read_back_p5_bytes_per_s": reads.get("read_back_p5_bytes_per_s"),
        "read_back_median_bytes_per_s": reads.get("read_back_median_bytes_per_s"),
        "restore_p5_bytes_per_s": reads.get("restore_p5_bytes_per_s"),
        "restore_median_bytes_per_s": reads.get("restore_median_bytes_per_s"),
        "restore_ranged_gets_median_per_s": reads.get("restore_ranged_gets_median_per_s"),
        "sustained_windows": results.get("sustained_windows"),
        "rtt_median_ms": before.get("node_to_central_median_ms"),
        "fingerprint": record["instrument"]["fingerprint"],
        "box_fingerprint": record["instrument"]["box_fingerprint"],
        "instrument_changes": changes(record, previous),
    }


def load(path, default=None):
    path = Path(path)
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def build(site, data, results, out, heartbeats, now):
    out = Path(out)
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(site, out)
    runs = out / "data" / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    records = [(load(p), p) for p in (Path(results) / "runs").glob("*/*/*.json")]
    records.sort(key=lambda rp: (rp[0]["time"]["run_started_at"], rp[0]["run_id"]))
    rows, last = [], {}
    for record, path in records:
        shutil.copyfile(path, runs / f"{record['run_id']}.json")
        series = (record["box"]["id"], record["series"])
        rows.append(row(record, last.get(series)))
        if record["drill"]["settings"] is not None:
            last[series] = record
    index = {
        "published_at": now,
        "runs": rows,
        "gates": load(Path(data) / "gates.json"),
        "overrides": load(Path(data) / "overrides.json", []),
        "heartbeats": heartbeats,
    }
    (out / "data" / "index.json").write_text(
        json.dumps(index, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return len(rows)


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--site", required=True)
    p.add_argument("--data", required=True)
    p.add_argument("--results", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--heartbeats", default="", help="the ingest job's heartbeats output")
    p.add_argument("--now", help="UTC time, for tests; default the clock")
    args = p.parse_args(argv)
    now = args.now or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        heartbeats = json.loads(args.heartbeats) if args.heartbeats else {}
    except ValueError:
        heartbeats = {}
    count = build(args.site, args.data, args.results, args.out, heartbeats, now)
    print(f"build-site: {count} run(s) in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
