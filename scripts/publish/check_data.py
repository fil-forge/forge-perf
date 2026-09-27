#!/usr/bin/env python3
"""Checks the page's data files: data/gates.json, data/overrides.json, data/boxes.json.

    check_data.py [<data dir>]    default: data/ at the top of the repository

Each file must match its schema (scripts/host/schemacheck.py), and the gates
must also follow the rules a schema cannot state: gates numbered 1 to n in
order; every measurement's ceiling equal to the lower of its S3 PUT and NVMe
write rates; earlier measurements of a gate listed oldest first and older
than the current one. Standard library only.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "host"))
import schemacheck  # noqa: E402


def schema_errors(schema, path):
    with open(ROOT / "schema" / schema, encoding="utf-8") as f:
        checker = schemacheck.Checker(schemacheck.load(f))
    try:
        with open(path, encoding="utf-8") as f:
            value = schemacheck.load(f)
    except (OSError, ValueError):
        return None, ["$: not readable as JSON"]
    return value, checker.errors(value)


def branch_errors(doc, errors):
    """Replaces the schema's "matches 0 of oneOf's schemas" line for a gate with
    the errors of the branch that gate means: unmeasured when its ceiling is
    null, measured otherwise. A reader then sees which rule failed."""
    with open(ROOT / "schema" / "gates.v1.json", encoding="utf-8") as f:
        full = schemacheck.load(f)
    unmeasured, measured = full["$defs"]["gate"]["oneOf"]
    checkers = {kind: schemacheck.Checker({"$defs": full["$defs"], **branch})
                for kind, branch in (("unmeasured", unmeasured), ("measured", measured))}
    gates = doc.get("gates") if isinstance(doc, dict) else None
    out = []
    for e in errors:
        m = re.fullmatch(r"\$\.gates\[(\d+)\]: matches 0 of oneOf's schemas, not exactly one", e)
        gate = gates[int(m.group(1))] if m and isinstance(gates, list) else None
        if not isinstance(gate, dict):
            out.append(e)
            continue
        kind = "unmeasured" if gate.get("ceiling_bytes_per_s") is None else "measured"
        where = f"$.gates[{m.group(1)}]"
        found = checkers[kind].errors(gate)
        out += [f"{where} ({kind}): {x[2:] if x.startswith('$.') else x[1:].lstrip(': ')}" for x in found] or [e]
    return out


def gate_errors(doc):
    out = []
    for i, gate in enumerate(doc["gates"]):
        where = f"$.gates[{i}]"
        if gate["gate"] != i + 1:
            out.append(f"{where}: gate {gate['gate']} where {i + 1} was expected")
        if gate["ceiling_bytes_per_s"] is None:
            continue
        history = gate.get("previous", []) + [gate]
        for j, m in enumerate(history):
            lower = min(m["s3_put_bytes_per_s"], m["nvme_seq_write_bytes_per_s"])
            if abs(m["ceiling_bytes_per_s"] - lower) >= 0.5:
                name = where if m is gate else f"{where}.previous[{j}]"
                out.append(f"{name}: ceiling_bytes_per_s is not the lower of the S3 PUT and NVMe write rates")
        times = [m["measured_at"] for m in history]
        if times != sorted(set(times)) or len(set(times)) != len(times):
            out.append(f"{where}: previous measurements must be oldest first and older than the current one")
    return out


def check(data):
    data = Path(data)
    errors = []
    gates, errs = schema_errors("gates.v1.json", data / "gates.json")
    if errs and gates is not None:
        errs = branch_errors(gates, errs)
    errors += [f"gates.json: {e}" for e in errs]
    if gates is not None and not errs:
        errors += [f"gates.json: {e}" for e in gate_errors(gates)]
    overrides, errs = schema_errors("overrides.v1.json", data / "overrides.json")
    errors += [f"overrides.json: {e}" for e in errs]
    if overrides is not None and not errs:
        ids = [o["run_id"] for o in overrides]
        if len(set(ids)) != len(ids):
            errors.append("overrides.json: $: a run has more than one override")
    try:
        with open(data / "boxes.json", encoding="utf-8") as f:
            boxes = schemacheck.load(f)
    except (OSError, ValueError):
        boxes = None
    if not (isinstance(boxes, list) and boxes and len(set(boxes)) == len(boxes)
            and all(isinstance(b, str) and re.fullmatch(r"[a-z0-9]{2,12}", b) for b in boxes)):
        errors.append("boxes.json: $: not a list of distinct box IDs")
    return errors


def main(argv):
    data = argv[1] if len(argv) > 1 else ROOT / "data"
    errors = check(data)
    for e in errors:
        print(f"check_data: {e}", file=sys.stderr)
    if not errors:
        print(f"check_data: {data}: gates, overrides and boxes ok")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
