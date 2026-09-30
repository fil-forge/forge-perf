#!/usr/bin/env python3
"""Checks experiment requests, plans an experiment and writes its status.

    experiment.py validate --request FILE --id ID [--tracked FILE]
    experiment.py plan --request FILE --set FILE [--at TIME]
    experiment.py status --id ID --state STATE [--position N] [--reason TEXT]
                         [--experiment FILE --records DIR] [--noise-dir DIR]
                         [--box ID] [--instance-type TYPE] [--now TIME]

docs/runner.md ("Experiments") is the contract. A request is
requests/<id>.json in the requests bucket, written by a service repository's
`/forge-perf` workflow; the status is status/<id>.json beside it, which that
workflow reads back.

`validate` prints the request as the box keeps it, one JSON line with only
the fields the box uses, and exits 0; a request that breaks a rule prints one
sentence saying which and exits 1. The sentence goes to the pull request, so
it names a request's value only when the value has already passed its
pattern. `plan` prints state/experiment.json for a checked request and the
poller's resolved main set: set A is that set, set B the same with the one
image's digest replaced, and the runs' order. `status` prints status/<id>.json.
STATE `final` reads the experiment's records and writes `done` with the
comparison when every run recorded rates, else `failed` with the reason.

Exit status 2 is a usage error or an input that cannot be read. Standard
library only.
"""

import argparse
import datetime as dt
import json
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
TRACKED = ROOT / "config" / "images.tracked"
MAX_REQUEST = 8192
SERVICE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}\Z")
ID = re.compile(r"^(?P<service>[a-z0-9][a-z0-9-]{0,39})-pr(?P<pr>[1-9][0-9]{0,6})-(?P<sha>[0-9a-f]{12})"
                r"-(?P<run>[1-9][0-9]{0,19})\Z")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}\Z")
SHA1 = re.compile(r"^[0-9a-f]{40}\Z")
UTC = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z\Z")
# Noise used when no tier noise band is committed for the box's type: the
# spread of valid 500 GB per-trigger runs on the tier 2 box, 28 to 29 Sep 2026.
DEFAULT_NOISE = {"median": 3.5, "p5": 11.0}
COUNTED = ("valid", "availability_warning")
ORDER = {1: ["main", "branch"], 2: ["main", "branch", "branch", "main"]}


class Refused(Exception):
    """The request breaks a rule; the argument is the sentence for the pull request."""


def tracked(path):
    """service -> (variable, repo, tracked ref), from config/images.tracked."""
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) != 2:
            continue
        variable, ref = fields
        repo = ref.rsplit(":", 1)[0]
        out[repo.rsplit("/", 1)[1]] = (variable, repo, ref)
    return out


def strict_json(text):
    def refuse_constant(name):
        raise ValueError(name)
    return json.loads(text, parse_constant=refuse_constant)


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate(raw, key_id, services):
    """The request the box keeps, or Refused."""
    if len(raw) > MAX_REQUEST:
        raise Refused("the request is larger than 8 KiB")
    try:
        req = strict_json(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise Refused("the request is not JSON") from None
    if not isinstance(req, dict) or req.get("schema") != "forge-perf.request/v1":
        raise Refused("the request is not a forge-perf.request/v1 object")
    if req.get("id") != key_id:
        raise Refused("the request's id differs from its object key")
    service = req.get("service")
    if not isinstance(service, str) or not SERVICE.match(service):
        raise Refused("service is not a repository name")
    if service not in services:
        raise Refused(f"service {service} is not an image forge-perf tracks (config/images.tracked)")
    variable, repo, ref = services[service]
    if req.get("image") != repo:
        raise Refused(f"image must be {repo} for service {service}")
    digest = req.get("digest")
    if not isinstance(digest, str) or not DIGEST.match(digest):
        raise Refused("digest is not sha256:<64 hex>")
    pairs = req.get("pairs", 1)
    if not is_int(pairs) or pairs not in ORDER:
        raise Refused("pairs must be 1 or 2")
    commit, pr = req.get("commit"), req.get("pr")
    if not isinstance(commit, str) or not SHA1.match(commit):
        raise Refused("commit is not a 40-hex SHA")
    if not is_int(pr) or not 1 <= pr <= 9999999:
        raise Refused("pr is not a pull request number")
    if req.get("tag") != f"pr-{pr}-{commit[:7]}":
        raise Refused(f"tag must be pr-{pr}-{commit[:7]}")
    if req.get("repository") != f"fil-forge/{service}":
        raise Refused(f"repository must be fil-forge/{service}")
    m = ID.match(key_id)
    if not m or (m["service"], m["pr"], m["sha"]) != (service, str(pr), commit[:12]):
        raise Refused(f"id must be {service}-pr{pr}-{commit[:12]}-<workflow run id>")
    at = req.get("requested_at")
    if not isinstance(at, str) or not UTC.match(at):
        raise Refused("requested_at is not an RFC 3339 UTC time")
    return {"id": key_id, "service": service, "variable": variable, "tracked_ref": ref, "image": repo,
            "digest": digest, "tag": req["tag"], "commit": commit, "repository": req["repository"], "pr": pr,
            "pairs": pairs, "requested_at": at}


def plan(request, main_set, at):
    """state/experiment.json: the two sets, the order and the provenance override."""
    ref = request["tracked_ref"]
    if not isinstance(main_set, dict) or ref not in (main_set.get("images") or {}):
        raise ValueError(f"the main set has no {ref}")
    branch = json.loads(json.dumps(main_set))
    branch["images"][ref] = request["digest"]
    return {
        "id": request["id"], "pairing_id": f"exp-{request['id']}", "started_at": at, "request": request,
        "experiment": {k: request[k] for k in ("service", "repository", "pr", "commit")}
        | {"request_id": request["id"]},
        "sets": {"main": main_set, "branch": branch},
        # The branch image's provenance: its pull request tag as the ref, the
        # requested commit as the revision, the service repository as the source.
        "overrides": {ref: {"ref": request["tag"], "revision": request["commit"],
                            "source": f"https://github.com/{request['repository']}"}},
        "order": ORDER[request["pairs"]],
        "runs": [],
    }


def run_summary(role, run_id, record):
    if record is None:
        return {"role": role, "run_id": run_id, "class": "no_data", "flags": [], "size_bytes": None,
                "p5_bytes_per_s": None, "median_bytes_per_s": None, "traced": None,
                "started_at": None, "finished_at": None}
    results = record["drill"]["results"] or {}
    return {"role": role, "run_id": run_id, "class": record["outcome"]["class"],
            "flags": record["outcome"]["flags"],
            "size_bytes": (record["drill"]["settings"] or {}).get("stop_ingest_at_bytes"),
            "p5_bytes_per_s": results.get("ingest_p5_bytes_per_s"),
            "median_bytes_per_s": results.get("ingest_median_bytes_per_s"),
            "traced": record.get("trace") is not None,
            "started_at": record["time"]["run_started_at"], "finished_at": record["time"]["run_finished_at"]}


def noise_band(noise_dir, box, instance_type):
    """{median, p5} in percent: twice the coefficients of variation of the box's
    committed per-trigger noise band on its instance type, or DEFAULT_NOISE."""
    if noise_dir and box and instance_type:
        for path in sorted(Path(noise_dir).glob("*.json")):
            try:
                band = json.loads(path.read_text(encoding="utf-8"))
                if (band.get("kind"), band.get("series"), band.get("box"), band.get("instance_type"),
                        band.get("pass")) == ("noise", "per-trigger", box, instance_type, True):
                    return {k: round(2 * 100 * band[k]["cv"], 1) for k in ("median", "p5")}
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
    return dict(DEFAULT_NOISE)


def comparison(runs, noise):
    def med(role, key):
        return statistics.median(r[key] for r in runs if r["role"] == role)
    delta = {k: round((med("branch", f"{k}_bytes_per_s") / med("main", f"{k}_bytes_per_s") - 1) * 100, 2)
             for k in ("median", "p5")}
    verdict = "within noise" if abs(delta["median"]) <= noise["median"] else \
        "faster" if delta["median"] > 0 else "slower"
    return {"median_delta_pct": delta["median"], "p5_delta_pct": delta["p5"],
            "noise_median_pct": noise["median"], "noise_p5_pct": noise["p5"], "verdict": verdict}


def instrument(record):
    """The run's instrument and box fingerprints, or None without a record."""
    if record is None:
        return None
    inst = record.get("instrument") or {}
    return inst.get("fingerprint"), inst.get("box_fingerprint")


def unusable(runs, order, instruments):
    """Why the runs cannot be compared, or None."""
    if len(runs) < len(order):
        return f"{len(runs)} of {len(order)} runs finished"
    for r in runs:
        if r["class"] not in COUNTED or r["median_bytes_per_s"] is None or r["p5_bytes_per_s"] is None:
            return f"the {r['role']} run {r['run_id']} ended {r['class']}"
        # The schema allows a zero rate, and the comparison divides by main's.
        if r["median_bytes_per_s"] <= 0 or r["p5_bytes_per_s"] <= 0:
            return f"the {r['role']} run {r['run_id']} recorded a zero ingest rate"
    # The instrument (forge-perf's instrument tree, smelt, harness, settings,
    # tracing) or the box changed between runs, as after an update mid-pair.
    for r, inst in zip(runs[1:], instruments[1:]):
        if inst != instruments[0]:
            return f"the {r['role']} run {r['run_id']} ran on a different instrument from {runs[0]['run_id']}"
    return None


def status(args):
    doc = {"schema": "forge-perf.status/v1", "id": args.id, "state": args.state,
           "updated_at": args.now or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "position": None, "reason": None, "pairing_id": f"exp-{args.id}", "runs": []}
    exp = None
    instruments = []
    if args.experiment:
        exp = json.loads(Path(args.experiment).read_text(encoding="utf-8"))
        for r in exp["runs"]:
            path = Path(args.records) / f"{r['run_id']}.json" if args.records else None
            record = json.loads(path.read_text(encoding="utf-8")) if path and path.exists() else None
            doc["runs"].append(run_summary(r["role"], r["run_id"], record))
            instruments.append(instrument(record))
    if args.state == "queued":
        doc["position"] = args.position
    elif args.state in ("refused", "failed"):
        doc["reason"] = args.reason or "no reason recorded"
    elif args.state == "final":
        why = unusable(doc["runs"], exp["order"], instruments) if exp else "no experiment"
        if why:
            doc.update(state="failed", reason=why)
        else:
            doc.update(state="done", comparison=comparison(doc["runs"], noise_band(
                args.noise_dir, args.box, args.instance_type)))
    return doc


def main(argv):
    p = argparse.ArgumentParser(prog="experiment.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="command", required=True)
    v = sub.add_parser("validate")
    v.add_argument("--request", required=True)
    v.add_argument("--id", required=True)
    v.add_argument("--tracked", default=str(TRACKED))
    pl = sub.add_parser("plan")
    pl.add_argument("--request", required=True)
    pl.add_argument("--set", required=True)
    pl.add_argument("--at")
    s = sub.add_parser("status")
    s.add_argument("--id", required=True)
    s.add_argument("--state", required=True, choices=["queued", "running", "refused", "failed", "done", "final"])
    s.add_argument("--position", type=int)
    s.add_argument("--reason")
    s.add_argument("--experiment")
    s.add_argument("--records")
    s.add_argument("--noise-dir")
    s.add_argument("--box")
    s.add_argument("--instance-type")
    s.add_argument("--now")
    args = p.parse_args(argv)
    try:
        if args.command == "validate":
            raw = Path(args.request).read_bytes()
            services = tracked(args.tracked)
            try:
                print(json.dumps(validate(raw, args.id, services), sort_keys=True, separators=(",", ":")))
            except Refused as e:
                print(e.args[0])
                return 1
        elif args.command == "plan":
            request = json.loads(Path(args.request).read_text(encoding="utf-8"))
            main_set = json.loads(Path(args.set).read_text(encoding="utf-8"))
            at = args.at or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            print(json.dumps(plan(request, main_set, at), indent=2, sort_keys=True))
        else:
            print(json.dumps(status(args), indent=2, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"experiment.py: {args.command}: {type(e).__name__}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
