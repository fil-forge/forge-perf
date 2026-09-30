#!/usr/bin/env python3
"""The steps of .github/workflows/pr-run.yml that are more than one command.

A service repository calls pr-run.yml when someone comments `/forge-perf` on a
pull request. This script parses that comment, writes the request the box
polls for, waits on the box's status file and renders the pull request comment
and the job summary. Standard library only; the AWS CLI and gh do the calls.

    pr_run.py check        comment and PR JSON -> outputs match, error, pairs, head_sha, tag
    pr_run.py build-args   the caller's build-args with {commit}, {sha7}, {pr}, {tag} filled in
    pr_run.py request      write requests/<id>.json -> output id
    pr_run.py comment      render the comment for a phase to a file
    pr_run.py wait         poll status/<id>.json, update the comment, write the summary

Inputs arrive in environment variables named below (FP_*), so no value from a
comment or a status file is ever spliced into a shell command.

    python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py'
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

REQUEST_SCHEMA = "forge-perf.request/v1"
STATUS_SCHEMA = "forge-perf.status/v1"
REGION = "us-east-2"
REQUESTS_BUCKET = "forge-perf-requests-654654381893"
ROLE_ARN = "arn:aws:iam::654654381893:role/forge-perf-ci-request"
PAGE = "https://fil-forge.github.io/forge-perf/"
# The same stack and Tempo data source as traceLink in site/model.js.
GRAFANA = "https://filecoinfoundation.grafana.net"
TEMPO_UID = "grafanacloud-traces"
TRACE_MARGIN_S = 5 * 60

POLL_S = 60
WAIT_LIMIT_S = 5 * 3600 + 30 * 60

SERVICE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
RUN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{0,127}$")
TIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
COMMAND_RE = re.compile(r"^/forge-perf(?:\s+(.*))?$")
# What a reason or flag from the status file may contain before it goes into a
# comment. Anything else is replaced, so a status file cannot inject markdown.
SAFE_TEXT_RE = re.compile(r"[^A-Za-z0-9 _.:,=/()+-]")

STATES = ("queued", "running", "done", "failed", "refused")
VERDICTS = ("faster", "slower", "within noise")
USAGE = "`/forge-perf` on the first line of the comment, optionally followed by `pairs=1` or `pairs=2`."


# ---------------------------------------------------------------------------
# The comment and the pull request


def parse_command(body):
    """Return (matched, pairs, error) for a comment body.

    matched is False when the first line is not a /forge-perf command at all,
    such as /forge-perfect; the workflow then does nothing.
    """
    first = (body or "").lstrip().split("\n", 1)[0].strip()
    if first != "/forge-perf" and not first.startswith(("/forge-perf ", "/forge-perf\t")):
        return False, None, None
    m = COMMAND_RE.match(first)
    args = (m.group(1) or "").split()
    pairs = 1
    for arg in args:
        am = re.fullmatch(r"pairs=([12])", arg)
        if not am:
            return True, None, f"Unknown argument. Use {USAGE}"
        pairs = int(am.group(1))
    if len(args) > 1:
        return True, None, f"Too many arguments. Use {USAGE}"
    return True, pairs, None


def check_pr(pr, repository, service):
    """Return (head_sha, error) for `gh pr view --json state,headRefOid,headRepository,headRepositoryOwner`."""
    if not SERVICE_RE.match(service or ""):
        return None, f"The caller's `service` input `{safe(service)}` is not a repository name."
    if repository.split("/")[-1] != service:
        return None, f"The `service` input must be this repository's name, `{safe(repository.split('/')[-1])}`."
    if pr.get("state") != "OPEN":
        return None, "The pull request is not open."
    head = f"{(pr.get('headRepositoryOwner') or {}).get('login', '')}/{(pr.get('headRepository') or {}).get('name', '')}"
    if head.lower() != repository.lower():
        return None, "The pull request comes from a fork. forge-perf builds only branches of this repository."
    sha = pr.get("headRefOid") or ""
    if not COMMIT_RE.match(sha):
        return None, "The pull request's head commit could not be read."
    return sha, None


def pr_tag(pr_number, commit):
    return f"pr-{int(pr_number)}-{commit[:7]}"


def fill_build_args(text, commit, pr_number):
    fills = {"{commit}": commit, "{sha7}": commit[:7], "{pr}": str(int(pr_number)), "{tag}": pr_tag(pr_number, commit)}
    out = []
    for line in (text or "").splitlines():
        for k, v in fills.items():
            line = line.replace(k, v)
        out.append(line)
    return "\n".join(out)


# ---------------------------------------------------------------------------
# The request


def request_id(service, pr_number, commit, run_id):
    return f"{service}-pr{int(pr_number)}-{commit[:12]}-{int(run_id)}"


def build_request(*, service, digest, commit, repository, pr_number, requested_by, pairs, run_id,
                  server_url="https://github.com", now=None):
    if not SERVICE_RE.match(service):
        raise ValueError("service is not a repository name")
    if not DIGEST_RE.match(digest):
        raise ValueError("digest is not sha256:<64 hex>")
    if not COMMIT_RE.match(commit):
        raise ValueError("commit is not 40 hex")
    if int(pairs) not in (1, 2):
        raise ValueError("pairs is not 1 or 2")
    now = now or datetime.datetime.now(datetime.timezone.utc)
    rid = request_id(service, pr_number, commit, run_id)
    return {
        "schema": REQUEST_SCHEMA,
        "id": rid,
        "service": service,
        "image": f"ghcr.io/fil-forge/{service}",
        "digest": digest,
        "tag": pr_tag(pr_number, commit),
        "commit": commit,
        "repository": repository,
        "pr": int(pr_number),
        "requested_by": requested_by,
        "requested_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pairs": int(pairs),
        "pr_url": f"{server_url}/{repository}/pull/{int(pr_number)}",
        "workflow_run_url": f"{server_url}/{repository}/actions/runs/{int(run_id)}",
    }


# ---------------------------------------------------------------------------
# Rendering


def safe(text, limit=200):
    text = SAFE_TEXT_RE.sub("?", str(text if text is not None else ""))
    return text if len(text) <= limit else text[: limit - 3] + "..."


def gbps(v):
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return "–"
    g = v / 1e9
    return f"{g:.2f} GB/s" if g >= 0.1 or g == 0 else f"{g:.2g} GB/s"


def pct(v):
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return "–"
    return f"{v:+.1f}%"


def ordinal(n):
    return {1: "next", 2: "2nd", 3: "3rd"}.get(n, f"{n}th")


def parse_time(s):
    if not isinstance(s, str) or not TIME_RE.match(s):
        return None
    return datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)


def page_link(run_id):
    return f"{PAGE}#run={run_id}"


def trace_link(run):
    """A Tempo search for the run in Grafana Explore, as traceLink in site/model.js."""
    flags = run.get("flags") or []
    if not run.get("traced") or "trace_missing" in flags:
        return None
    start, end = parse_time(run.get("started_at")), parse_time(run.get("finished_at"))
    if not start or not end:
        return None
    pane = {
        "datasource": TEMPO_UID,
        "queries": [{"refId": "A", "datasource": {"type": "tempo", "uid": TEMPO_UID}, "queryType": "traceql",
                     "query": f'{{ resource.forge_perf.run_id = "{run["run_id"]}" }}', "limit": 20}],
        "range": {"from": str(int(start.timestamp() - TRACE_MARGIN_S) * 1000),
                  "to": str(int(end.timestamp() + TRACE_MARGIN_S) * 1000)},
    }
    panes = urllib.parse.quote(json.dumps({"a": pane}, separators=(",", ":")), safe="-_.!~*'()")
    return f"{GRAFANA}/explore?schemaVersion=1&orgId=1&panes={panes}"


def check_status(status, expected_id):
    """Return the status with only the fields the renderer trusts, or raise ValueError."""
    if not isinstance(status, dict) or status.get("schema") != STATUS_SCHEMA:
        raise ValueError("status file has the wrong schema")
    if status.get("id") != expected_id:
        raise ValueError("status file is for another request")
    if status.get("state") not in STATES:
        raise ValueError("status file has an unknown state")
    runs = []
    for run in status.get("runs") or []:
        if not isinstance(run, dict) or run.get("role") not in ("main", "branch") \
                or not RUN_ID_RE.match(str(run.get("run_id", ""))):
            raise ValueError("status file has a malformed run")
        runs.append(run)
    comp = status.get("comparison")
    if comp is not None and (not isinstance(comp, dict) or comp.get("verdict") not in VERDICTS):
        raise ValueError("status file has a malformed comparison")
    return dict(status, runs=runs)


def header_rows(ctx):
    rows = [("Commit", f"`{ctx['commit']}`")]
    image = f"`ghcr.io/fil-forge/{ctx['service']}:{ctx['tag']}`"
    if ctx.get("digest"):
        image += f" (`{ctx['digest'][:19]}`)"
    rows.append(("Image", image))
    rows.append(("Pairs", f"{ctx['pairs']} ({'main, branch' if int(ctx['pairs']) == 1 else 'main, branch, branch, main'})"))
    return rows


def state_text(phase, status=None, waited_s=0):
    if phase == "started":
        return "Building the image"
    if phase == "build_failed":
        return "Failed: the image did not build"
    if phase == "request_failed":
        return "Failed: the request could not be sent to the box"
    if phase == "stopped":
        return "Stopped: the workflow ended before a result"
    if phase == "submitted":
        return "Requested; the box picks requests up within 5 minutes"
    if phase == "timeout":
        last = f" (last state: {status['state']})" if status else ""
        return (f"Stopped waiting after {waited_s // 3600} h {waited_s % 3600 // 60} min{last}. "
                "The box may still run it; the runs then appear on the page")
    state = status["state"]
    if state == "queued":
        pos = status.get("position")
        if isinstance(pos, int) and not isinstance(pos, bool) and pos >= 1:
            return f"Queued, {ordinal(pos)} in line"
        return "Queued"
    if state == "running":
        return f"Running ({len(status['runs'])} run(s) recorded)"
    if state == "done":
        return f"Done: {status['comparison']['verdict']}" if status.get("comparison") else "Done"
    return f"{state.capitalize()}: {safe(status.get('reason') or 'no reason given')}"


def runs_table(runs):
    lines = ["| Run | Role | Class | Median | p5 | Traces |", "|---|---|---|---|---|---|"]
    for run in runs:
        rid = run["run_id"]
        tl = trace_link(run)
        flags = [safe(f, 40) for f in (run.get("flags") or []) if isinstance(f, str)]
        klass = safe(run.get("class") or "–", 40) + (f" ({', '.join(flags)})" if flags else "")
        lines.append(f"| [{rid}]({page_link(rid)}) | {run['role']} | {klass} | {gbps(run.get('median_bytes_per_s'))} "
                     f"| {gbps(run.get('p5_bytes_per_s'))} | {f'[Grafana]({tl})' if tl else '–'} |")
    return lines


def comparison_lines(comp):
    noise_m, noise_p = comp.get("noise_median_pct"), comp.get("noise_p5_pct")
    return [
        "| | Median | p5 |",
        "|---|---|---|",
        f"| Branch against main | {pct(comp.get('median_delta_pct'))} | {pct(comp.get('p5_delta_pct'))} |",
        f"| Noise band | ±{noise_m if isinstance(noise_m, (int, float)) else '–'}% "
        f"| ±{noise_p if isinstance(noise_p, (int, float)) else '–'}% |",
        "",
        f"**Verdict: {comp['verdict']}**, judged on the median against its noise band. "
        "Positive deltas mean the branch ingests faster.",
    ]


def render(ctx, phase, status=None, waited_s=0):
    """The comment body. ctx holds service, commit, tag, pairs, run_url and optionally digest."""
    lines = ["## forge-perf", "", "| | |", "|---|---|"]
    for k, v in header_rows(ctx):
        lines.append(f"| **{k}** | {v} |")
    lines.append(f"| **State** | {state_text(phase, status, waited_s)} |")
    if status and status.get("pairing_id") and RUN_ID_RE.match(str(status["pairing_id"])):
        lines.append(f"| **Pairing** | `{status['pairing_id']}` |")
    lines.append(f"| **Logs** | [workflow run]({ctx['run_url']}) |")
    if status and status["runs"]:
        lines += ["", *runs_table(status["runs"])]
    if status and status["state"] == "done" and status.get("comparison"):
        lines += ["", *comparison_lines(status["comparison"])]
    lines += ["", "Main runs the current main set; branch swaps in this commit's image. "
              "The runs table on the [forge-perf page](" + PAGE + ") lists each run."]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Waiting


def outcome_of(phase, status):
    if phase == "timeout":
        return "timeout"
    return status["state"]


def wait(ctx, fetch, update, sleep=time.sleep, clock=time.monotonic, poll_s=POLL_S, limit_s=WAIT_LIMIT_S, log=print):
    """Poll until done, failed or refused, or until limit_s passes.

    fetch() returns the parsed status file or None when it is not there yet;
    update(body) replaces the comment. The comment changes only when its text
    does. Returns (outcome, final body).
    """
    start = clock()
    last_body, status = None, None
    while True:
        waited = int(clock() - start)
        try:
            raw = fetch()
            if raw is not None:
                status = check_status(raw, ctx["id"])
        except ValueError as e:
            log(f"status: {e}; ignored")
        phase = "status" if status else "submitted"
        if status is None or status["state"] not in ("done", "failed", "refused"):
            if waited >= limit_s:
                phase = "timeout"
        body = render(ctx, phase, status, waited)
        if body != last_body:
            update(body)
            last_body = body
        if phase == "timeout" or (status and status["state"] in ("done", "failed", "refused")):
            return outcome_of(phase, status), body
        sleep(poll_s)


class S3Status:
    """Reads status/<id>.json as the request role, assuming it afresh for each read.

    Each read fetches a new GitHub OIDC token and hands it to the AWS CLI as a
    web identity token file, so the credentials never outlive the role's
    maximum session length however long the wait.
    """

    def __init__(self, request_id, bucket=REQUESTS_BUCKET, role=ROLE_ARN, run=subprocess.run):
        self.key = f"status/{request_id}.json"
        self.bucket, self.role, self.run = bucket, role, run
        self.dir = tempfile.mkdtemp(prefix="forge-perf-")

    def token(self):
        url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=sts.amazonaws.com"
        req = urllib.request.Request(url, headers={"Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)["value"]

    def __call__(self):
        token_file = os.path.join(self.dir, "token")
        with open(os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            f.write(self.token())
        out = os.path.join(self.dir, "status.json")
        env = dict(os.environ, AWS_ROLE_ARN=self.role, AWS_WEB_IDENTITY_TOKEN_FILE=token_file,
                   AWS_ROLE_SESSION_NAME="forge-perf-pr-run", AWS_REGION=REGION, AWS_DEFAULT_REGION=REGION)
        for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE"):
            env.pop(k, None)
        res = self.run(["aws", "s3api", "get-object", "--bucket", self.bucket, "--key", self.key, out],
                       env=env, capture_output=True, text=True)
        if res.returncode != 0:
            # The role may not list the bucket, so a status file the box has not
            # written yet reads as AccessDenied rather than NoSuchKey.
            if "NoSuchKey" in res.stderr or "AccessDenied" in res.stderr or "Not Found" in res.stderr:
                return None
            raise RuntimeError(res.stderr.strip()[-300:])
        with open(out, encoding="utf-8") as f:
            try:
                return json.load(f)
            except json.JSONDecodeError:
                raise ValueError("status file is not JSON")


def gh_update_comment(repository, comment_id, run=subprocess.run):
    def update(body):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
            f.write(body)
        res = run(["gh", "api", "--method", "PATCH", f"repos/{repository}/issues/comments/{int(comment_id)}",
                   "-F", f"body=@{f.name}", "--silent"], capture_output=True, text=True)
        os.unlink(f.name)
        if res.returncode != 0:
            print(f"comment: update failed: {res.stderr.strip()[-300:]}", file=sys.stderr)
    return update


# ---------------------------------------------------------------------------
# Command line


def env(name):
    v = os.environ.get(name, "")
    if not v:
        sys.exit(f"pr_run: {name} is not set")
    return v


def output(pairs):
    path = os.environ.get("GITHUB_OUTPUT")
    lines = []
    for k, v in pairs.items():
        v = "" if v is None else str(v)
        if "\n" in v:
            lines.append(f"{k}<<FORGE_PERF_EOF\n{v}\nFORGE_PERF_EOF")
        else:
            lines.append(f"{k}={v}")
    text = "\n".join(lines) + "\n"
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


def context_from_env():
    return {
        "id": os.environ.get("FP_ID", ""),
        "service": env("FP_SERVICE"),
        "commit": env("FP_COMMIT"),
        "tag": pr_tag(env("FP_PR"), env("FP_COMMIT")),
        "digest": os.environ.get("FP_DIGEST", ""),
        "pairs": env("FP_PAIRS"),
        "run_url": env("FP_RUN_URL"),
    }


def cmd_check(_):
    matched, pairs, error = parse_command(os.environ.get("FP_COMMENT_BODY", ""))
    if not matched:
        output({"match": "false"})
        return
    head = None
    if error is None:
        try:
            pr = json.loads(env("FP_PR_JSON"))
        except json.JSONDecodeError:
            pr = {}
        head, error = check_pr(pr, env("FP_REPOSITORY"), env("FP_SERVICE"))
    if error:
        print(f"::error::{error}")
        output({"match": "true", "error": error})
        return
    output({"match": "true", "error": "", "pairs": pairs, "head_sha": head, "tag": pr_tag(env("FP_PR"), head)})


def cmd_build_args(_):
    output({"build_args": fill_build_args(os.environ.get("FP_BUILD_ARGS", ""), env("FP_COMMIT"), env("FP_PR"))})


def cmd_request(a):
    req = build_request(service=env("FP_SERVICE"), digest=env("FP_DIGEST"), commit=env("FP_COMMIT"),
                        repository=env("FP_REPOSITORY"), pr_number=env("FP_PR"), requested_by=env("FP_REQUESTED_BY"),
                        pairs=env("FP_PAIRS"), run_id=env("FP_RUN_ID"),
                        server_url=os.environ.get("FP_SERVER_URL", "https://github.com"))
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(req, f, indent=2)
        f.write("\n")
    output({"id": req["id"]})


def cmd_comment(a):
    body = render(context_from_env(), a.phase)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(body)


def cmd_wait(_):
    ctx = context_from_env()
    ctx["id"] = env("FP_ID")
    fetch_s3 = S3Status(ctx["id"])

    def fetch():
        try:
            return fetch_s3()
        except (RuntimeError, OSError) as e:
            print(f"status: read failed, will retry: {e}", file=sys.stderr)
            return None

    outcome, body = wait(ctx, fetch, gh_update_comment(env("FP_REPOSITORY"), env("FP_COMMENT_ID")))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(body)
    output({"outcome": outcome})
    print(f"forge-perf: {outcome}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check").set_defaults(fn=cmd_check)
    sub.add_parser("build-args").set_defaults(fn=cmd_build_args)
    r = sub.add_parser("request")
    r.add_argument("--out", required=True)
    r.set_defaults(fn=cmd_request)
    c = sub.add_parser("comment")
    c.add_argument("--phase", required=True, choices=["started", "build_failed", "request_failed", "stopped"])
    c.add_argument("--out", required=True)
    c.set_defaults(fn=cmd_comment)
    sub.add_parser("wait").set_defaults(fn=cmd_wait)
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
