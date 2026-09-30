#!/usr/bin/env python3
"""Builds the site against fixture scenarios and serves it on localhost.

    preview.py [--out _preview] [--port 8000] [--build-only]

Each scenario is a set of records made from the host fixtures'
expected records, dated relative to now, plus its own gates and heartbeat.
build-site.py builds each into <out>/<scenario>/, and <out>/index.html links
them. `make site-preview` runs this. Standard library only.
"""

import argparse
import copy
import datetime as dt
import functools
import http.server
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FIXTURES = ROOT / "scripts" / "host" / "fixtures"
spec = importlib.util.spec_from_file_location("build_site", HERE / "build-site.py")
build_site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_site)

CASE = {"valid": "valid", "availability_warning": "availability-errors", "invalid": "read-back-incomplete",
        "failed": "integrity-failure", "no_data": "stack-boot-failed"}
TITLE = "<title>Site preview</title>"
TYPES = {1: "m9gd.2xlarge", 2: "m9gd.8xlarge", 3: "m9gd.16xlarge"}


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


@functools.cache
def fixture_case(case):
    return json.loads((FIXTURES / case / "expected.json").read_text(encoding="utf-8"))


def fixture(cls):
    return fixture_case(CASE[cls])


def record(start, cls="valid", series="per-trigger", p5=None, tier=1, pairing=None, smelt=None,
           postgres=None, kernel=None, windows=None, changed=("ingot",), broken=False, traced=False):
    r = copy.deepcopy(fixture(cls))
    if traced:
        # The traced fixture's trace block and flag, so the page shows a trace link.
        r["trace"] = copy.deepcopy(fixture_case("traced")["trace"])
        r["outcome"]["flags"] = sorted(set(r["outcome"]["flags"]) | {"traced"})
    r["run_id"] = "main-" + start.strftime("%Y%m%dt%H%M%Sz")
    r["series"], r["pairing_id"] = series, pairing
    r["trigger"]["changed"] = list(changed)
    r["time"] = {"run_started_at": iso(start), "stack_up_at": iso(start + dt.timedelta(minutes=3)),
                 "drill_started_at": iso(start + dt.timedelta(minutes=5)),
                 "drill_finished_at": iso(start + dt.timedelta(minutes=50)),
                 "run_finished_at": iso(start + dt.timedelta(minutes=55))}
    r["box"].update(tier=tier, instance_type=TYPES[tier])
    if broken:
        # No settings file, NVMe unmounted, Docker down: a schema-valid preflight_failed record.
        r["outcome"]["reasons"] = ["preflight_failed"]
        r["drill"]["settings"] = None
        r["box"].update(docker_server=None, docker_compose=None)
        r["box"]["nvme"] = {"model": None, "size_bytes": None, "filesystem": None}
    else:
        r["drill"]["settings"]["stop_ingest_at_bytes"] = 500 * 10**9 if series == "nightly" else 100 * 10**9
    res = r["drill"]["results"]
    if res and p5 is not None:
        res.update(ingest_p5_bytes_per_s=p5, ingest_median_bytes_per_s=round(p5 * 1.18),
                   writes_median_per_s=round(p5 * 1.18 / 134217728, 2))
        if windows is not None:
            res["sustained_windows"] = windows
            r["outcome"]["flags"] = [f for f in r["outcome"]["flags"] if f != "few_windows"] + \
                (["few_windows"] if windows < 20 else [])
    fp = r["instrument"]
    if smelt:
        r["provenance"]["smelt"]["sha"] = smelt
        fp["fingerprint"] = smelt + "0" * 24
    if postgres:
        next(i for i in r["provenance"]["images"] if i["repo"] == "postgres")["digest"] = postgres
    if kernel or tier != 1:
        r["box"]["kernel"] = kernel or r["box"]["kernel"]
        fp["box_fingerprint"] = f"{tier}{kernel or ''}".encode().hex().ljust(64, "0")[:64]
    return r


def gate(n, ceiling=None, measured=None, previous=()):
    g = {"gate": n, "instance_type": TYPES[n], "nic_reference_gbps": {1: 4.25, 2: 17, 3: 34}[n],
         "ceiling_bytes_per_s": None, "s3_put_bytes_per_s": None, "nvme_seq_write_bytes_per_s": None,
         "measured_at": None, "forge_perf_sha": None, "method": None}
    if ceiling:
        g.update(ceiling_bytes_per_s=ceiling, s3_put_bytes_per_s=round(ceiling * 1.4),
                 nvme_seq_write_bytes_per_s=ceiling, measured_at=iso(measured), forge_perf_sha="d" * 40,
                 method="calibration/README.md#ceilings")
        if previous:
            g["previous"] = [{k: v for k, v in gate(n, c, m).items()
                              if k not in ("gate", "instance_type", "nic_reference_gbps")} for c, m in previous]
    return g


def scenarios(now):
    hours = lambda n: now - dt.timedelta(hours=n)  # noqa: E731
    unmeasured = [gate(1), gate(2), gate(3)]
    idle = {"at": iso(now - dt.timedelta(minutes=3)), "state": "idle", "poll_failures": 0, "run_started_at": None}
    out = {}
    out["no-runs"] = ("No runs yet", [], unmeasured, [], idle)
    out["one-run"] = ("One valid traced run", [record(hours(3), p5=0.31e9, windows=22, traced=True)], unmeasured, [], idle)
    out["calibration-only"] = ("Calibration runs only", [
        record(hours(40 - 6 * i), series="calibration", p5=p) for i, p in enumerate([0.24e9, 0.25e9, 0.23e9, 0.26e9])
    ] + [record(hours(4), "no_data", series="calibration")], unmeasured, [], idle)

    measured = [gate(1, 0.36e9, hours(48), [(0.30e9, hours(480))]), gate(2, 2.05e9, hours(48)), gate(3)]
    per = [record(hours(240 - 18 * i), p5=p, windows=6) for i, p in
           enumerate([0.22e9, 0.24e9, 0.27e9, 0.31e9, 0.29e9, 0.30e9, 0.32e9, 0.31e9, 0.33e9, 0.34e9, 0.33e9, 0.33e9])]
    nightly = [record(hours(230 - 48 * i) + dt.timedelta(minutes=5), series="nightly", p5=p, windows=22, changed=())
               for i, p in enumerate([0.26e9, 0.28e9, 0.29e9, 0.30e9, 0.31e9])]
    out["gate-lit"] = ("Valid runs, gate 1 lit before a recalibration", sorted(per + nightly, key=lambda r: r["run_id"]),
                       measured, [], dict(idle, state="held"))

    classes = ["valid", "valid", "availability_warning", "invalid", "valid", "failed", "no_data", "valid",
               "availability_warning", "valid"]
    mixed = [record(hours(60 - 6 * i), c, p5=0.3e9 + 0.004e9 * i, broken=i == 6) for i, c in enumerate(classes)]
    override = [{"run_id": mixed[4]["run_id"], "class": "invalid",
                 "issue": "https://github.com/fil-forge/forge-perf/issues/1"}]
    out["outcomes"] = ("Invalid, failed, no-data (one on a broken host) and availability-warning runs, one override", mixed, unmeasured,
                       override, {"at": iso(now - dt.timedelta(minutes=6)), "state": "running", "poll_failures": 2,
                                  "run_started_at": iso(now - dt.timedelta(minutes=40))})

    runs = []
    for i in range(10):
        later = i >= 5
        runs.append(record(hours(100 - 10 * i), p5=(0.30e9 if not later else 0.27e9) + 0.003e9 * (i % 3),
                           smelt="9c2e" * 10 if later else None,
                           postgres=("sha256:" + "5" * 64) if later else None, kernel="6.14.0-1017-aws" if i >= 8 else None))
    out["instrument-change"] = ("An instrument change (smelt, postgres) and a kernel change", runs,
                                [gate(1, 0.36e9, hours(200)), gate(2, 2.05e9, hours(200)), gate(3)], [], idle)

    runs = [record(hours(200 - 12 * i), p5=0.30e9 + 0.015e9 * i) for i in range(6)]
    for i in range(3):
        for tier in (1, 2):
            runs.append(record(hours(120 - 12 * i - 6 * (tier - 1)), p5=(0.33e9 if tier == 1 else 1.05e9) + 0.01e9 * i,
                               tier=tier, pairing="pair-20261010-tier2", changed=()))
    runs += [record(hours(60 - 12 * i), p5=1.1e9 + 0.02e9 * i, tier=2) for i in range(5)]
    out["box-change"] = ("A box change with paired runs", sorted(runs, key=lambda r: r["run_id"]),
                         [gate(1, 0.36e9, hours(300)), gate(2, 2.05e9, hours(300)), gate(3, 3.9e9, hours(300))], [],
                         dict(idle, at=iso(now - dt.timedelta(hours=2, minutes=4))))
    exp = {"request_id": "ingot-pr123-0123456789ab-17000000001", "service": "ingot",
           "repository": "fil-forge/ingot", "pr": 123, "commit": "0123456789abcdef0123456789abcdef01234567"}
    runs = [record(hours(30 - 6 * i), p5=0.30e9 + 0.004e9 * i, windows=22) for i in range(3)]
    for i, role in enumerate(("main", "branch", "branch", "main")):
        r = record(hours(10 - i) + dt.timedelta(minutes=5), series="experiment", p5=0.31e9 if role == "main" else 0.34e9,
                   windows=22, pairing=f"exp-{exp['request_id']}", changed=("ingot",) if role == "branch" else ())
        r["experiment"] = dict(exp, role=role)
        r["trigger"]["reason"] = "experiment"
        runs.append(r)
    out["experiment"] = ("A two-pair experiment beside per-trigger runs", runs,
                         [gate(1, 0.36e9, hours(200)), gate(2), gate(3)], [], idle)
    return out


def build(out, now):
    out = Path(out)
    if out.exists() and any(out.iterdir()):
        own = out / "index.html"
        if not own.is_file() or TITLE not in own.read_text(encoding="utf-8", errors="replace"):
            raise SystemExit(f"preview: {out} is not empty and is not an earlier preview; choose another --out")
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)
    links = []
    for name, (title, records, gates, overrides, heartbeat) in scenarios(now).items():
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "data").mkdir()
            (tmp / "data/gates.json").write_text(json.dumps({"schema": "forge-perf.gates/v1", "gates": gates}))
            (tmp / "data/overrides.json").write_text(json.dumps(overrides))
            for r in records:
                t = r["time"]["run_started_at"]
                path = tmp / "results/runs" / t[:4] / t[5:7] / f"{r['run_id']}.json"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(r))
            (tmp / "results/runs").mkdir(parents=True, exist_ok=True)
            build_site.build(ROOT / "site", tmp / "data", tmp / "results", out / name,
                             {"main": heartbeat}, iso(now - dt.timedelta(minutes=5)))
        links.append(f'<li><a href="{name}/">{title}</a> ({len(records)} runs)</li>')
    (out / "index.html").write_text(
        f"<!doctype html><meta charset=utf-8>{TITLE}"
        "<h1>Fixture scenarios</h1><ul>" + "".join(links) + "</ul>\n", encoding="utf-8")
    return sorted(scenarios(now))


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--out", default=str(ROOT / "_preview"))
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--build-only", action="store_true")
    args = p.parse_args()
    names = build(args.out, dt.datetime.now(dt.timezone.utc).replace(microsecond=0))
    print(f"preview: built {', '.join(names)} in {args.out}")
    if args.build_only:
        return
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=args.out)
    with http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler) as httpd:
        print(f"preview: serving http://127.0.0.1:{args.port}/ (Ctrl-C to stop)")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
