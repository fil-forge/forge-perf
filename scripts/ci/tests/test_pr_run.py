"""Tests of scripts/ci/pr_run.py against the sample status files in fixtures/status.

    python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py'
"""

import copy
import datetime
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
import unittest.mock
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pr_run", HERE.parent / "pr_run.py")
pr_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr_run)

COMMIT = "0123456789abcdef0123456789abcdef01234567"
DIGEST = "sha256:" + "ab" * 32
ID = "ingot-pr123-0123456789ab-987654321"
CTX = {"id": ID, "service": "ingot", "commit": COMMIT, "tag": "pr-123-0123456", "digest": DIGEST,
       "pairs": "1", "run_url": "https://github.com/fil-forge/ingot/actions/runs/987654321"}
PR = {"state": "OPEN", "headRefOid": COMMIT, "headRepository": {"name": "ingot"},
      "headRepositoryOwner": {"login": "fil-forge"}}


def fixture(name):
    return json.loads((HERE / "fixtures/status" / f"{name}.json").read_text(encoding="utf-8"))


class Command(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(pr_run.parse_command("/forge-perf"), (True, 1, None))

    def test_pairs(self):
        self.assertEqual(pr_run.parse_command("  /forge-perf pairs=2\nplease"), (True, 2, None))
        self.assertEqual(pr_run.parse_command("/forge-perf pairs=1"), (True, 1, None))

    def test_other_commands_do_not_match(self):
        for body in ("/forge-perfect", "please /forge-perf", "", "/deploy", "text\n/forge-perf"):
            self.assertEqual(pr_run.parse_command(body), (False, None, None), body)

    def test_bad_arguments(self):
        for body in ("/forge-perf pairs=3", "/forge-perf now", "/forge-perf pairs=1 pairs=2"):
            matched, pairs, err = pr_run.parse_command(body)
            self.assertTrue(matched)
            self.assertIsNone(pairs)
            self.assertIn("`/forge-perf`", err)


class PullRequest(unittest.TestCase):
    def test_open_same_repo(self):
        self.assertEqual(pr_run.check_pr(PR, "fil-forge/ingot", "ingot"), (COMMIT, None))

    def test_refusals(self):
        cases = [
            (dict(PR, state="CLOSED"), "ingot", "not open"),
            (dict(PR, headRepositoryOwner={"login": "someone"}), "ingot", "fork"),
            (dict(PR, headRefOid="main"), "ingot", "head commit"),
            (PR, "piri", "this repository's name"),
            (PR, "Ingot;rm", "not a repository name"),
        ]
        for pr, service, want in cases:
            sha, err = pr_run.check_pr(pr, "fil-forge/ingot", service)
            self.assertIsNone(sha)
            self.assertIn(want, err)

    def test_build_args(self):
        got = pr_run.fill_build_args("VERSION={tag}\nCOMMIT={commit}\nSHORT={sha7}\nPR={pr}", COMMIT, "123")
        self.assertEqual(got, f"VERSION=pr-123-0123456\nCOMMIT={COMMIT}\nSHORT=0123456\nPR=123")
        self.assertEqual(pr_run.fill_build_args("", COMMIT, "1"), "")


class Request(unittest.TestCase):
    def test_contract_shape(self):
        now = datetime.datetime(2026, 9, 29, 20, 0, 1, tzinfo=datetime.timezone.utc)
        req = pr_run.build_request(service="ingot", digest=DIGEST, commit=COMMIT, repository="fil-forge/ingot",
                                   pr_number="123", requested_by="octocat", pairs="2", run_id="987654321", now=now)
        self.assertEqual(req, {
            "schema": "forge-perf.request/v1", "id": ID, "service": "ingot", "image": "ghcr.io/fil-forge/ingot",
            "digest": DIGEST, "tag": "pr-123-0123456", "commit": COMMIT, "repository": "fil-forge/ingot",
            "pr": 123, "requested_by": "octocat", "requested_at": "2026-09-29T20:00:01Z", "pairs": 2,
            "pr_url": "https://github.com/fil-forge/ingot/pull/123",
            "workflow_run_url": "https://github.com/fil-forge/ingot/actions/runs/987654321",
        })

    def test_refuses_bad_values(self):
        good = dict(service="ingot", digest=DIGEST, commit=COMMIT, repository="fil-forge/ingot", pr_number=1,
                    requested_by="x", pairs=1, run_id=1)
        for k, v in (("digest", "sha256:abc"), ("commit", COMMIT[:12]), ("pairs", 3), ("service", "../x")):
            with self.assertRaises(ValueError, msg=k):
                pr_run.build_request(**dict(good, **{k: v}))


class Render(unittest.TestCase):
    def status(self, name):
        return pr_run.check_status(fixture(name), ID)

    def test_started(self):
        body = pr_run.render(dict(CTX, digest=""), "started")
        self.assertIn("| **Commit** | `" + COMMIT + "` |", body)
        self.assertIn("| **State** | Building the image |", body)
        self.assertIn("[workflow run](" + CTX["run_url"] + ")", body)
        self.assertNotIn("sha256", body)

    def test_queued(self):
        self.assertIn("| **State** | Queued, 2nd in line |", pr_run.render(CTX, "status", self.status("queued")))
        s = self.status("queued")
        s["position"] = 1
        self.assertIn("Queued, next in line", pr_run.render(CTX, "status", s))

    def test_running_lists_finished_runs(self):
        body = pr_run.render(CTX, "status", self.status("running"))
        self.assertIn("Running (1 run(s) recorded)", body)
        self.assertIn("[main-20260929t200500z](https://fil-forge.github.io/forge-perf/#run=main-20260929t200500z)", body)
        self.assertIn("| main | valid (traced) | 1.00 GB/s | 0.81 GB/s |", body)

    def test_done(self):
        body = pr_run.render(CTX, "status", self.status("done"))
        self.assertIn("| **State** | Done: ingest faster |", body)
        self.assertIn("| branch | valid | 1.05 GB/s | 0.79 GB/s | – |", body)
        self.assertIn("| Ingest | +4.7% | -2.7% | ±3.5% | faster |", body)
        self.assertIn("**Verdict: faster** on ingest", body)
        self.assertIn("`exp-" + ID + "`", body)

    def test_done_without_read_streams_has_only_the_ingest_row(self):
        body = pr_run.render(CTX, "status", self.status("done"))
        self.assertEqual([line for line in body.splitlines() if line.startswith(("| Read-back", "| Restore"))], [])

    def test_done_with_read_streams_gives_a_row_and_a_verdict_for_each(self):
        body = pr_run.render(CTX, "status", self.status("done-reads"))
        rows = [line for line in body.splitlines() if line.startswith(("| Ingest", "| Read-back", "| Restore", "| **State**"))]
        self.assertEqual(rows, ["| **State** | Done: ingest faster · read-back faster · restore within noise |",
                                "| Ingest | +4.7% | -2.7% | ±3.5% | faster |",
                                "| Read-back | +4.1% | +1.1% | ±3.5% | faster |",
                                "| Restore | -12.4% | – | ±34.0% | within noise |"])

    def test_done_with_a_stream_left_out_shows_dashes(self):
        s = fixture("done-reads")
        s["comparison"]["restore"] = None
        body = pr_run.render(CTX, "status", pr_run.check_status(s, ID))
        self.assertIn("| Restore | – | – | – | – |", body)

    def test_trace_link_matches_the_page(self):
        run = self.status("done")["runs"][0]
        url = pr_run.trace_link(run)
        self.assertTrue(url.startswith("https://filecoinfoundation.grafana.net/explore?schemaVersion=1&orgId=1&panes="))
        panes = json.loads(urllib.parse.unquote(url.split("panes=", 1)[1]))
        pane = panes["a"]
        self.assertEqual(pane["datasource"], "grafanacloud-traces")
        self.assertEqual(pane["queries"][0]["query"], '{ resource.forge_perf.run_id = "main-20260929t200500z" }')
        start = datetime.datetime(2026, 9, 29, 20, 5, tzinfo=datetime.timezone.utc).timestamp()
        end = datetime.datetime(2026, 9, 29, 20, 15, 30, tzinfo=datetime.timezone.utc).timestamp()
        self.assertEqual(pane["range"], {"from": str(int(start - 300) * 1000), "to": str(int(end + 300) * 1000)})
        self.assertIsNone(pr_run.trace_link(dict(run, flags=["traced", "trace_missing"])))
        self.assertIsNone(pr_run.trace_link(dict(run, traced=False)))
        self.assertIsNone(pr_run.trace_link(dict(run, finished_at=None)))

    def test_failed_and_refused_show_reason(self):
        self.assertIn("| **State** | Failed: run main-20260929t200500z: stack_unhealthy |",
                      pr_run.render(CTX, "status", self.status("failed")))
        self.assertIn("| **State** | Refused: digest cannot be pulled |",
                      pr_run.render(CTX, "status", self.status("refused")))

    def test_reason_cannot_inject_markdown(self):
        s = fixture("failed")
        s["reason"] = "x | [click](https://evil) <img>\n## hi"
        body = pr_run.render(CTX, "status", pr_run.check_status(s, ID))
        self.assertNotIn("[click]", body)
        self.assertNotIn("<img>", body)
        self.assertNotIn("\n## hi", body)

    def test_check_status_refusals(self):
        bad = []
        s = fixture("done"); s["id"] = "other"; bad.append(s)
        s = fixture("done"); s["schema"] = "v2"; bad.append(s)
        s = fixture("done"); s["state"] = "exploded"; bad.append(s)
        s = fixture("done"); s["runs"][0]["run_id"] = "x](http://evil)"; bad.append(s)
        s = fixture("done"); s["runs"][0]["role"] = "candidate"; bad.append(s)
        s = fixture("done"); s["comparison"]["verdict"] = "great"; bad.append(s)
        s = fixture("done-reads"); s["comparison"]["restore"]["verdict"] = "great"; bad.append(s)
        s = fixture("done-reads"); s["comparison"]["read_back"] = "faster"; bad.append(s)
        for s in bad:
            with self.assertRaises(ValueError):
                pr_run.check_status(s, ID)


class Wait(unittest.TestCase):
    def run_wait(self, seq, limit_s=3600):
        seq = list(seq)
        clock = {"t": 0.0}
        updates = []

        def fetch():
            item = seq.pop(0) if len(seq) > 1 else seq[0]
            return copy.deepcopy(fixture(item)) if isinstance(item, str) else item

        def sleep(s):
            clock["t"] += s

        outcome, body = pr_run.wait(CTX, fetch, updates.append, sleep=sleep, clock=lambda: clock["t"],
                                    poll_s=60, limit_s=limit_s, log=lambda *_: None)
        return outcome, body, updates, clock["t"]

    def test_updates_only_on_change(self):
        outcome, body, updates, _ = self.run_wait([None, None, "queued", "queued", "running", "running", "done"])
        self.assertEqual(outcome, "done")
        self.assertEqual(len(updates), 4)
        self.assertIn("picks requests up", updates[0])
        self.assertIn("Queued", updates[1])
        self.assertIn("Running", updates[2])
        self.assertEqual(updates[3], body)
        self.assertIn("Verdict: faster", body)

    def test_terminal_states(self):
        for name in ("failed", "refused"):
            outcome, body, _, _ = self.run_wait(["queued", name])
            self.assertEqual(outcome, name)
            self.assertIn(name.capitalize() + ":", body)

    def test_timeout(self):
        outcome, body, _, t = self.run_wait(["queued"], limit_s=5 * 3600 + 1800)
        self.assertEqual(outcome, "timeout")
        self.assertEqual(t, 5 * 3600 + 1800)
        self.assertIn("Stopped waiting after 5 h 30 min (last state: queued)", body)

    def test_status_for_another_request_is_ignored(self):
        other = fixture("done")
        other["id"] = "piri-pr1-aaaaaaaaaaaa-1"
        outcome, _, _, _ = self.run_wait([other, "done"])
        self.assertEqual(outcome, "done")


class S3(unittest.TestCase):
    def test_missing_status_reads_as_none(self):
        def run(cmd, **kw):
            self.assertEqual(cmd[:3], ["aws", "s3api", "get-object"])
            self.assertEqual(kw["env"]["AWS_ROLE_ARN"], pr_run.ROLE_ARN)
            self.assertNotIn("AWS_ACCESS_KEY_ID", kw["env"])
            return subprocess.CompletedProcess(cmd, 254, "", "An error occurred (AccessDenied) when calling GetObject")

        s = pr_run.S3Status(ID, run=run)
        s.token = lambda: "jwt"
        with unittest.mock.patch.dict(os.environ, {"AWS_ACCESS_KEY_ID": "stale"}):
            self.assertIsNone(s())

    def test_reads_status(self):
        def run(cmd, **kw):
            Path(cmd[-1]).write_text(json.dumps(fixture("queued")), encoding="utf-8")
            self.assertEqual(Path(kw["env"]["AWS_WEB_IDENTITY_TOKEN_FILE"]).read_text(), "jwt")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        s = pr_run.S3Status(ID, run=run)
        s.token = lambda: "jwt"
        self.assertEqual(s()["state"], "queued")


class CommandLine(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.out = self.tmp / "out"
        self.out.write_text("")

    def run_cmd(self, args, extra):
        e = {"GITHUB_OUTPUT": str(self.out), "FP_SERVICE": "ingot", "FP_REPOSITORY": "fil-forge/ingot", "FP_PR": "123"}
        e.update(extra)
        with unittest.mock.patch.dict(os.environ, e, clear=False):
            pr_run.main(args)
        return self.out.read_text()

    def test_check_outputs(self):
        got = self.run_cmd(["check"], {"FP_COMMENT_BODY": "/forge-perf pairs=2", "FP_PR_JSON": json.dumps(PR)})
        self.assertEqual(got, f"match=true\nerror=\npairs=2\nhead_sha={COMMIT}\ntag=pr-123-0123456\n")

    def test_check_no_match(self):
        self.assertEqual(self.run_cmd(["check"], {"FP_COMMENT_BODY": "lgtm"}), "match=false\n")

    def test_build_args_multiline_output(self):
        got = self.run_cmd(["build-args"], {"FP_COMMIT": COMMIT, "FP_BUILD_ARGS": "A={sha7}\nB=2"})
        self.assertEqual(got, "build_args<<FORGE_PERF_EOF\nA=0123456\nB=2\nFORGE_PERF_EOF\n")

    def test_request_file(self):
        req_file = self.tmp / "req.json"
        got = self.run_cmd(["request", "--out", str(req_file)], {
            "FP_DIGEST": DIGEST, "FP_COMMIT": COMMIT, "FP_REQUESTED_BY": "octocat", "FP_PAIRS": "1",
            "FP_RUN_ID": "987654321"})
        self.assertEqual(got, f"id={ID}\n")
        self.assertEqual(json.loads(req_file.read_text())["id"], ID)


if __name__ == "__main__":
    unittest.main()
