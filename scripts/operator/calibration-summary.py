#!/usr/bin/env python3
"""Summarizes tier calibration runs (docs/DESIGN.md section 9) from their run records.

    scripts/operator/calibration-summary.py workers --runs ID...
    scripts/operator/calibration-summary.py noise --series per-trigger --runs ID...
    scripts/operator/calibration-summary.py falsification --band FILE \\
        --check NAME=ID,ID,ID...

Records come from the public results branch, runs/<yyyy>/<mm>/<run_id>.json,
read with `git show <ref>:<path>` in the current forge-perf clone (--ref,
default origin/results), or from a directory given with --records. Every run
is named explicitly. Outputs land under calibration/ (--out-dir replaces it)
and hold only record fields and statistics computed from them, never a clock
reading, so the same runs always give the same file. calibration/README.md
documents the files.
"""

import argparse
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN_ID = re.compile(r"^[a-z0-9]{2,12}-([0-9]{4})([0-9]{2})[0-9]{2}t[0-9]{6}z$")
CHECK_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
WORKERS_MARGIN = 0.05  # DESIGN section 9: within 5% of the best mean p5 and median
NOISE_MAX_CV = 0.10  # DESIGN section 9: above 10% CV the series stays unpublished


class Refused(Exception):
    pass


def load_record(run_id, records=None, ref="origin/results"):
    m = RUN_ID.match(run_id)
    if not m:
        raise Refused(f"'{run_id}' is not a run ID")
    if records:
        found = sorted(Path(records).rglob(f"{run_id}.json"))
        if not found:
            raise Refused(f"no record for {run_id} under {records}")
        text = found[0].read_text(encoding="utf-8")
    else:
        path = f"runs/{m.group(1)}/{m.group(2)}/{run_id}.json"
        got = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
        if got.returncode != 0:
            raise Refused(f"no record for {run_id} at {ref}:{path}")
        text = got.stdout
    rec = json.loads(text)
    if rec.get("run_id") != run_id:
        raise Refused(f"record for {run_id} carries run_id {rec.get('run_id')}")
    return rec


def provenance(rec):
    p = rec["provenance"]
    return {
        "forge_perf_sha": p["forge_perf"]["sha"],
        "smelt_sha": p["smelt"]["sha"],
        "harness_sha": p["harness"]["sha"],
        "images": {i["repo"]: i["digest"] for i in p["images"]},
    }


def run_entry(rec):
    settings = (rec.get("drill") or {}).get("settings") or {}
    results = (rec.get("drill") or {}).get("results") or {}
    return {
        "run_id": rec["run_id"],
        "run_started_at": rec["time"]["run_started_at"],
        "class": rec["outcome"]["class"],
        "reasons": rec["outcome"]["reasons"],
        "flags": rec["outcome"]["flags"],
        "workers": settings.get("workers"),
        "stop_ingest_at_bytes": settings.get("stop_ingest_at_bytes"),
        "ingest_p5_bytes_per_s": results.get("ingest_p5_bytes_per_s"),
        "ingest_median_bytes_per_s": results.get("ingest_median_bytes_per_s"),
        "provenance": provenance(rec),
    }


def one(recs, get, what):
    values = {get(r) for r in recs}
    if len(values) != 1:
        raise Refused(f"the runs mix {what}: {', '.join(sorted(map(str, values)))}")
    return values.pop()


def run_date(recs):
    return max(r["time"]["run_started_at"] for r in recs)[:10]


def mean_or_none(values):
    return None if not values or None in values else statistics.fmean(values)


def within(value, best):
    return value is not None and best - value <= WORKERS_MARGIN * best


def summarize_workers(recs):
    groups = {}
    for entry in map(run_entry, recs):
        if entry["workers"] is None:
            raise Refused(f"{entry['run_id']} records no drill settings")
        groups.setdefault(entry["workers"], []).append(entry)
    values = []
    for workers in sorted(groups):
        runs = groups[workers]
        bad = [r["run_id"] for r in runs
               if r["class"] != "valid" or "availability_errors" in r["reasons"]]
        values.append({
            "workers": workers,
            "run_ids": [r["run_id"] for r in runs],
            "mean_p5_bytes_per_s": mean_or_none([r["ingest_p5_bytes_per_s"] for r in runs]),
            "mean_median_bytes_per_s": mean_or_none([r["ingest_median_bytes_per_s"] for r in runs]),
            "qualified": not bad,
            "disqualifying_run_ids": bad,
        })
    qualified = [v for v in values if v["qualified"] and v["mean_p5_bytes_per_s"] is not None]
    best_p5 = max((v["mean_p5_bytes_per_s"] for v in qualified), default=None)
    best_median = max((v["mean_median_bytes_per_s"] for v in qualified), default=None)
    winner = next((v["workers"] for v in qualified
                   if within(v["mean_p5_bytes_per_s"], best_p5)
                   and within(v["mean_median_bytes_per_s"], best_median)), None)
    return {
        "kind": "workers",
        "instance_type": one(recs, lambda r: r["box"]["instance_type"], "instance types"),
        "box": one(recs, lambda r: r["box"]["id"], "boxes"),
        "margin": WORKERS_MARGIN,
        "best_mean_p5_bytes_per_s": best_p5,
        "best_mean_median_bytes_per_s": best_median,
        "winner": winner,
        "values": values,
        "runs": [run_entry(r) for r in recs],
    }


def stats(values):
    mean = statistics.fmean(values)
    stdev = statistics.stdev(values) if len(values) > 1 else None
    return {
        "count": len(values), "mean": mean, "min": min(values), "max": max(values),
        "stdev": stdev, "cv": None if stdev is None or mean == 0 else stdev / mean,
    }


def summarize_noise(recs, series):
    runs = [run_entry(r) for r in recs]
    for r in runs:
        if r["class"] != "valid" or r["ingest_p5_bytes_per_s"] is None:
            raise Refused(f"{r['run_id']} is {r['class']}; a noise band takes valid runs only")
    p5 = stats([r["ingest_p5_bytes_per_s"] for r in runs])
    return {
        "kind": "noise",
        "series": series,
        "box": one(recs, lambda r: r["box"]["id"], "boxes"),
        "instance_type": one(recs, lambda r: r["box"]["instance_type"], "instance types"),
        "workers": one(recs, lambda r: r["drill"]["settings"]["workers"], "workers"),
        "stop_ingest_at_bytes": one(
            recs, lambda r: r["drill"]["settings"]["stop_ingest_at_bytes"], "ingest caps"),
        "max_cv": NOISE_MAX_CV,
        "p5": p5,
        "median": stats([r["ingest_median_bytes_per_s"] for r in runs]),
        "pass": p5["cv"] is not None and p5["cv"] <= NOISE_MAX_CV,
        "runs": runs,
    }


def parse_check(text):
    name, sep, ids = text.partition("=")
    if not sep or not CHECK_NAME.match(name) or not ids:
        raise Refused(f"--check takes NAME=ID,ID,ID with NAME matching {CHECK_NAME.pattern}")
    return name, ids.split(",")


def summarize_falsification(band, checks):
    band_min = band["p5"]["min"]
    out, all_recs = [], []
    for name, recs in checks:
        all_recs += recs
        runs = [run_entry(r) for r in recs]
        below = [r for r in runs
                 if r["ingest_p5_bytes_per_s"] is not None and r["ingest_p5_bytes_per_s"] < band_min]
        out.append({"name": name, "below": len(below), "of": len(runs),
                    "pass": len(below) == len(runs), "runs": runs})
    return {
        "kind": "falsification",
        "band": {"box": band["box"], "series": band["series"], "p5_min_bytes_per_s": band_min,
                 "run_ids": [r["run_id"] for r in band["runs"]]},
        "checks": out,
        "pass": all(c["pass"] for c in out),
    }, run_date(all_recs)


def write(doc, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--records", help="directory of records instead of the results branch")
    ap.add_argument("--ref", default="origin/results", help="git ref of the results branch")
    ap.add_argument("--out-dir", default=str(ROOT / "calibration"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("workers")
    w.add_argument("--runs", nargs="+", required=True)
    n = sub.add_parser("noise")
    n.add_argument("--series", choices=["per-trigger", "nightly"], required=True)
    n.add_argument("--runs", nargs="+", required=True)
    f = sub.add_parser("falsification")
    f.add_argument("--band", required=True)
    f.add_argument("--check", action="append", required=True, metavar="NAME=ID,ID,ID")
    a = ap.parse_args(argv)
    out = Path(a.out_dir)

    def load(ids):
        if len(set(ids)) != len(ids):
            raise Refused("a run ID is given twice")
        return [load_record(i, a.records, a.ref) for i in ids]

    try:
        if a.cmd == "workers":
            recs = load(a.runs)
            doc = summarize_workers(recs)
            write(doc, out / "workers" / f"{run_date(recs)}-{doc['instance_type']}.json")
        elif a.cmd == "noise":
            doc = summarize_noise(load(a.runs), a.series)
            write(doc, out / "noise" / f"{doc['box']}-{a.series}.json")
        else:
            band = json.loads(Path(a.band).read_text(encoding="utf-8"))
            checks = [(name, load(ids)) for name, ids in map(parse_check, a.check)]
            if len({name for name, _ in checks}) != len(checks):
                raise Refused("a check name is given twice")
            doc, date = summarize_falsification(band, checks)
            write(doc, out / "falsification" / f"{date}.json")
    except Refused as e:
        print(f"calibration-summary: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
