#!/usr/bin/env python3
"""Checks JSON documents against schema/run-record.v1.json.

    schemacheck.py <schema.json> <record.json>...

Standard library only, so the box, CI and the publish Action run the same
check without installing anything. It implements the subset of JSON Schema
2020-12 the record schema uses, and refuses a schema that uses any other
keyword: a keyword this checker ignored would pass records the schema meant
to reject.

Two rules are stricter than JSON Schema, because records are hashed: an
integer must be written as one (4, never 4.0), and a number must be finite.

Errors name the JSON path and the rule, never the value, because a rejected
record may hold text that must not reach a public log.
"""

import json
import math
import re
import sys

ANNOTATIONS = {"$schema", "$id", "title", "description", "$defs"}
KEYWORDS = ANNOTATIONS | {
    "type", "enum", "const", "pattern", "minimum", "maximum", "maxLength",
    "minItems", "maxItems", "uniqueItems", "items", "required", "properties",
    "additionalProperties", "$ref", "oneOf",
}


class SchemaError(Exception):
    """The schema uses something this checker does not implement."""


def _is_type(value, name):
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        if isinstance(value, bool):
            return False
        return isinstance(value, int)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    raise SchemaError(f"unknown type {name}")


def _canonical(value):
    # JSON equality: true is not 1, and 1 equals 1.0.
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _equal(a, b):
    if isinstance(a, bool) or isinstance(b, bool) or a is None or b is None:
        return type(a) is type(b) and a == b
    if _is_type(a, "number") and _is_type(b, "number"):
        return a == b
    return _canonical(a) == _canonical(b)


def _compile(pattern):
    # A trailing $ in Python also matches before a final newline; \Z does not.
    if pattern.endswith("$") and not pattern.endswith("\\$"):
        pattern = pattern[:-1] + r"\Z"
    return re.compile(pattern)


class Checker:
    def __init__(self, schema):
        self.root = schema
        self._patterns = {}
        self._audit(schema, "#")

    def _audit(self, node, where):
        if not isinstance(node, dict):
            raise SchemaError(f"{where}: a schema must be an object")
        unknown = sorted(set(node) - KEYWORDS)
        if unknown:
            raise SchemaError(f"{where}: unsupported keyword(s) {', '.join(unknown)}")
        if node.get("additionalProperties", False) is not False:
            raise SchemaError(f"{where}: additionalProperties must be false")
        if "pattern" in node:
            self._patterns[node["pattern"]] = _compile(node["pattern"])
        for key in ("properties", "$defs"):
            for name, child in node.get(key, {}).items():
                self._audit(child, f"{where}/{key}/{name}")
        if "items" in node:
            self._audit(node["items"], f"{where}/items")
        for i, child in enumerate(node.get("oneOf", [])):
            self._audit(child, f"{where}/oneOf/{i}")
        if "$ref" in node:
            self._resolve(node["$ref"])

    def _resolve(self, ref):
        if not ref.startswith("#/"):
            raise SchemaError(f"only local references are supported: {ref}")
        node = self.root
        for part in ref[2:].split("/"):
            if not isinstance(node, dict) or part not in node:
                raise SchemaError(f"unresolved reference {ref}")
            node = node[part]
        return node

    def errors(self, value):
        """Returns a list of 'path: rule' strings; empty when the value is valid."""
        out = []
        self._check(value, self.root, "$", out)
        return out

    def _check(self, value, schema, path, out):
        if "$ref" in schema:
            self._check(value, self._resolve(schema["$ref"]), path, out)
        if "oneOf" in schema:
            results = [self._sub(value, s, path) for s in schema["oneOf"]]
            matches = results.count([])
            if matches != 1:
                # With one branch of the value's type, say why that branch failed.
                typed = [r for s, r in zip(schema["oneOf"], results) if self._admits_type(value, s)]
                if matches == 0 and len(typed) == 1:
                    out.extend(typed[0])
                else:
                    out.append(f"{path}: matches {matches} of oneOf's schemas, not exactly one")
                return
        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(_is_type(value, n) for n in names):
                out.append(f"{path}: not of type {'/'.join(names)}")
                return
        if "const" in schema and not _equal(value, schema["const"]):
            out.append(f"{path}: not the constant the schema requires")
        if "enum" in schema and not any(_equal(value, e) for e in schema["enum"]):
            out.append(f"{path}: not one of the allowed values")
        if isinstance(value, str):
            if "pattern" in schema and not self._patterns[schema["pattern"]].search(value):
                out.append(f"{path}: does not match the pattern {schema['pattern']}")
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                out.append(f"{path}: longer than {schema['maxLength']}")
        if _is_type(value, "number"):
            if "minimum" in schema and value < schema["minimum"]:
                out.append(f"{path}: below the minimum {schema['minimum']}")
            if "maximum" in schema and value > schema["maximum"]:
                out.append(f"{path}: above the maximum {schema['maximum']}")
        if isinstance(value, list):
            if "minItems" in schema and len(value) < schema["minItems"]:
                out.append(f"{path}: fewer than {schema['minItems']} items")
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                out.append(f"{path}: more than {schema['maxItems']} items")
            if schema.get("uniqueItems") and len({_canonical(v) for v in value}) != len(value):
                out.append(f"{path}: items are not unique")
            if "items" in schema:
                for i, item in enumerate(value):
                    self._check(item, schema["items"], f"{path}[{i}]", out)
        if isinstance(value, dict):
            for name in schema.get("required", []):
                if name not in value:
                    out.append(f"{path}: missing required field {name}")
            props = schema.get("properties", {})
            for name, item in value.items():
                if name in props:
                    self._check(item, props[name], f"{path}.{name}", out)
                elif "additionalProperties" in schema:
                    # The field name may itself be the text to keep out of logs.
                    out.append(f"{path}: has a field the schema does not define")

    def _admits_type(self, value, schema):
        while "$ref" in schema and "type" not in schema:
            schema = self._resolve(schema["$ref"])
        names = schema.get("type")
        if names is None:
            return True
        names = names if isinstance(names, list) else [names]
        return any(_is_type(value, n) for n in names)

    def _sub(self, value, schema, path):
        out = []
        self._check(value, schema, path, out)
        return out


def _no_constant(name):
    raise ValueError(f"{name} is not JSON")


def _no_duplicates(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate field")
        obj[key] = value
    return obj


def _finite(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("a number is out of range")
    return value


def load(f):
    """json.load that refuses NaN, Infinity, numbers too large for a float
    and duplicate fields."""
    return json.load(f, parse_constant=_no_constant, parse_float=_finite,
                     object_pairs_hook=_no_duplicates)


def main(argv):
    if len(argv) < 3:
        print("usage: schemacheck.py <schema.json> <record.json>...", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as f:
            checker = Checker(load(f))
    except (OSError, ValueError, SchemaError) as e:
        print(f"schemacheck: cannot use schema {argv[1]}: {e}", file=sys.stderr)
        return 2
    failed = 0
    for name in argv[2:]:
        try:
            with open(name, encoding="utf-8") as f:
                errors = checker.errors(load(f))
        except (OSError, ValueError):
            errors = ["$: not readable as JSON"]
        for error in errors:
            print(f"{name}: {error}", file=sys.stderr)
        if errors:
            failed += 1
        else:
            print(f"{name}: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
