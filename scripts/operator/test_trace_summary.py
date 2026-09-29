"""Tests of trace-summary.py against fixtures/traces/traces.jsonl.

    cd scripts/operator && python3 -m unittest -v test_trace_summary

The fixture holds two traces of ingot PutObject, 35 seconds apart: the first
with a 5 ms bucket.lock wait, the second with a 1.5 s one; an otelpgx
pool.acquire under each; a sprue span in the same line as ingot's second
trace; a piri span and a piri span with no end time; and a truncated last
line.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "trace-summary.py"
FIXTURE = HERE / "fixtures" / "traces" / "traces.jsonl"


def summary(*args, path=FIXTURE):
    return subprocess.run([sys.executable, str(SCRIPT), str(path), *args],
                          capture_output=True, text=True, check=False)


def rows(out):
    """The first table's rows as {(service, span): [count, p50, p95, p99, total]}, in order."""
    table = out.split("\n\n")[1].splitlines()[1:]
    return {tuple(line.split()[:2]): line.split()[2:] for line in table}


def section(out, title):
    """The rows of the time-bucket table titled `title`, as lists of cells."""
    for block in out.split("\n\n"):
        lines = block.splitlines()
        if lines and lines[0] == title:
            return [line.split() for line in lines[2:]]
    raise AssertionError(f"no section {title!r} in:\n{out}")


class TraceSummaryTest(unittest.TestCase):
    def test_counts_spans_traces_and_skipped_input(self):
        got = summary()
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout.splitlines()[0],
                         "8 spans in 2 traces over 39.00s; 5 lines, 1 unreadable; "
                         "1 spans skipped for a missing time")

    def test_one_row_per_service_and_span_with_waits_first(self):
        table = rows(summary().stdout)
        self.assertEqual(list(table), [
            ("ingot", "bucket.lock"),
            ("ingot", "pool.acquire"),
            ("ingot", "PutObject"),
            ("piri", "objectstore.put"),
            ("sprue", "/space/blob/add"),
        ])
        self.assertEqual(table[("ingot", "bucket.lock")], ["2", "5.0ms", "1.50s", "1.50s", "1.50s"])
        self.assertEqual(table[("ingot", "pool.acquire")], ["2", "1.0ms", "3.0ms", "3.0ms", "4.0ms"])
        self.assertEqual(table[("ingot", "PutObject")], ["2", "2.00s", "4.00s", "4.00s", "6.00s"])
        self.assertEqual(table[("piri", "objectstore.put")], ["1", "500.0ms", "500.0ms", "500.0ms", "500.0ms"])

    def test_buckets_from_the_first_span_show_a_wait_that_grows_after_30_seconds(self):
        out = summary().stdout
        self.assertEqual(section(out, "ingot bucket.lock, by 10-second bucket of span start"), [
            ["0s", "1", "5.0ms", "5.0ms", "5.0ms", "5.0ms"],
            ["30s", "1", "1.50s", "1.50s", "1.50s", "1.50s"],
        ])
        self.assertEqual(section(out, "sprue /space/blob/add, by 10-second bucket of span start"), [
            ["30s", "1", "200.0ms", "200.0ms", "200.0ms", "200.0ms"],
        ])
        titles = [b.splitlines()[0] for b in out.split("\n\n")[2:]]
        self.assertEqual([t.split(",")[0] for t in titles], [
            "ingot bucket.lock", "ingot pool.acquire", "ingot PutObject", "piri objectstore.put",
            "sprue /space/blob/add",
        ])

    def test_bucket_width_and_top_count_are_options(self):
        out = summary("--bucket", "60", "--top", "1").stdout
        titles = [b.splitlines()[0] for b in out.split("\n\n")[2:]]
        self.assertEqual(titles, [
            "ingot bucket.lock, by 60-second bucket of span start",
            "ingot pool.acquire, by 60-second bucket of span start",
            "ingot PutObject, by 60-second bucket of span start",
        ])
        self.assertEqual(section(out, titles[0]), [["0s", "2", "5.0ms", "1.50s", "1.50s", "1.50s"]])

    def test_a_file_with_no_spans(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "traces.jsonl"
            path.write_text("\n")
            got = summary(path=path)
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, "0 lines, 0 unreadable, no spans\n")

    def test_a_missing_file_is_an_error(self):
        got = summary(path=HERE / "fixtures" / "traces" / "absent.jsonl")
        self.assertEqual(got.returncode, 1)
        self.assertIn("cannot read", got.stderr)


if __name__ == "__main__":
    unittest.main()
