#!/usr/bin/env python3
"""The Lambda that starts the persistent box after it put itself to sleep.

With SLEEP_WHEN_IDLE=1 the box powers off when a poll pass finds nothing to
do, after writing a heartbeat with state `asleep`. This function runs every
five minutes and starts the box again for one of three reasons, in order:

    wake_at   the heartbeat's wake time has come (the nightly run, or the day
              a queued experiment's daily cap lifts)
    request   the requests bucket holds a requests/<id>.json the box has not
              seen: one modified later than five minutes before its heartbeat
              (a request it left queued at the daily cap waits for wake_at)
    set       smelt's main or a tracked image moved to a set the box has not
              seen (the heartbeat's seen_keys)

It starts only a stopped instance whose heartbeat says `asleep`, so a box an
operator stopped stays stopped once it has reported after its last start (the
heartbeat still says `asleep` until the woken box's first pass). Each attempt
is written to
published/<box>/waker.json, which publish reads and which keeps one reason
from starting the box twice within six hours.

The harness repository is private, so the waker compares sets by the waker
key, {smelt, images}, and a harness merge waits for the next wake.

Environment: BOX (default main), RESULTS_BUCKET, REQUESTS_BUCKET. The package
carries images.tracked and smelt.conf beside this file; in the repository
they are read from config/. Standard library only, plus boto3 from the Lambda
runtime, imported where a client is made so the tests run without it.

What the function needs from its infrastructure:

- s3:ListBucket on the results bucket for published/<box>/*. Without it S3
  answers AccessDenied for a missing waker.json, which only the waker creates,
  and every tick raises before it starts anything.
- A timeout of 90 s or more: resolving the set can take about 70 s (10 s for
  smelt, the 40 s budget, an image in flight).
- A redeploy whenever images.tracked or smelt.conf changes. With a stale copy
  the resolved set is never in seen_keys and starts the box every six hours.

    cd scripts/waker && python3 -m unittest -v test_waker
"""

import datetime
import hashlib
import json
import logging
import os
import re
import shlex
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = "forge-perf.waker/v1"
# The states of an instance that exists; a terminated one is not the box.
LIVE_STATES = ["pending", "running", "stopping", "stopped"]
# A reason that started the box does not start it again within this long.
WOKE_FOR_WINDOW = datetime.timedelta(hours=6)
WOKE_FOR_KEPT = 20
# requests/<id>.json as poll.sh accepts it; it deletes any other object there.
REQUEST_KEY = re.compile(r"requests/[a-z0-9][a-z0-9-]{0,99}\.json")
REQUEST_KEYS_LISTED = 20
# The box lists requests and then writes its heartbeat within one pass, which
# takes under 240 s. A request older than the heartbeat by more than this was
# in that listing.
REQUEST_SEEN_MARGIN = datetime.timedelta(seconds=300)
# The Accept header of ghcr_digest in scripts/host/poll.sh.
MANIFEST_TYPES = ("application/vnd.oci.image.index.v1+json, "
                  "application/vnd.docker.distribution.manifest.list.v2+json, "
                  "application/vnd.oci.image.manifest.v1+json, "
                  "application/vnd.docker.distribution.manifest.v2+json")
# One HTTP call, and the whole resolution (21 calls today), in seconds.
CALL_TIMEOUT_S = 10
RESOLVE_BUDGET_S = 40

log = logging.getLogger("waker")
log.setLevel(logging.INFO)


# --- the waker key ---------------------------------------------------------------------

def waker_key(a_set):
    """The bytes `jq -cS '{smelt, images}'` prints for a set, without the newline."""
    return json.dumps({"smelt": a_set["smelt"], "images": a_set["images"]},
                      sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def waker_key_hash(a_set):
    return hashlib.sha256(waker_key(a_set)).hexdigest()


# --- config ----------------------------------------------------------------------------

def config_dir(here=HERE):
    """Beside this file when packaged, else the repository's config/."""
    for directory in (here, here / "config"):
        if (directory / "images.tracked").is_file():
            return directory
    return here.parent.parent / "config"


def tracked_images(text):
    """The repo:tag of each images.tracked line, as `sed 's/#.*//' | awk 'NF == 2'` reads it."""
    refs = []
    for line in text.splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) == 2:
            refs.append(fields[1])
    return refs


def parse_conf(text):
    """The NAME=value lines of a file the box sources, such as smelt.conf."""
    conf = {}
    for line in text.splitlines():
        words = shlex.split(line, comments=True)
        if len(words) == 1 and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0], re.DOTALL):
            name, value = words[0].split("=", 1)
            conf[name] = value
    return conf


# --- times -----------------------------------------------------------------------------

def stamp(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value):
    """An RFC 3339 UTC time at second precision, or None for anything else."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


# --- the decision ----------------------------------------------------------------------

def gate(state, heartbeat):
    """Why this box is not the waker's to start, or None when it is asleep."""
    if state != "stopped":
        return "awake"
    if not isinstance(heartbeat, dict) or heartbeat.get("state") != "asleep":
        return "stopped, not asleep"
    return None


def woke_for(previous):
    """The usable token-to-time entries of the previous waker.json."""
    entries = previous.get("woke_for") if isinstance(previous, dict) else None
    if not isinstance(entries, dict):
        return {}
    return {token: at for token, at in entries.items() if parse_time(at)}


def new_request_keys(requests, heartbeat):
    """The keys of the listed (key, modified) requests the sleeping box has not seen.

    The box keeps a queued request's object and may sleep with it queued when
    the daily cap blocks it; wake_at covers that one. A request with no usable
    time, or a heartbeat with none, counts as new.
    """
    at = parse_time(heartbeat.get("at"))
    keys = []
    for key, modified in requests:
        if at and isinstance(modified, datetime.datetime):
            if modified.tzinfo is None:
                modified = modified.replace(tzinfo=datetime.timezone.utc)
            if modified <= at - REQUEST_SEEN_MARGIN:
                continue
        keys.append(key)
    return keys


def reasons(heartbeat, request_keys, key_hash, now):
    """Every reason to wake that holds now, in the order they are tried."""
    found = []
    wake_at = parse_time(heartbeat.get("wake_at"))
    if wake_at and now >= wake_at:
        found.append(("wake_at", heartbeat["wake_at"]))
    if request_keys:
        found.append(("request", request_keys[0]))
    seen = heartbeat.get("seen_keys")
    if key_hash and isinstance(seen, list) and key_hash not in seen:
        found.append(("set", key_hash))
    return found


def decide(box, state, heartbeat, request_keys, key_hash, previous, now):
    """(action, waker.json) for one tick.

    state is the instance's, heartbeat the parsed heartbeat.json or None,
    request_keys the requests/<id>.json keys the box has not seen, key_hash the resolved
    waker key hash or None when resolution failed, previous the parsed
    waker.json or None. The action is `awake`, `stopped, not asleep`,
    `asleep, nothing to do` or `start`. Only `start` carries a record, the one
    to write when StartInstances succeeds; failed() turns it into the one for
    a start that failed.
    """
    closed = gate(state, heartbeat)
    if closed:
        return closed, None
    recent = woke_for(previous)
    for reason, detail in reasons(heartbeat, request_keys, key_hash, now):
        token = f"{reason}:{detail}"
        if token in recent and now - parse_time(recent[token]) < WOKE_FOR_WINDOW:
            continue
        recent[token] = stamp(now)
        newest = sorted(recent.items(), key=lambda item: (item[1], item[0]))[-WOKE_FOR_KEPT:]
        return "start", {"schema": SCHEMA, "box": box, "requested_at": stamp(now), "reason": reason,
                         "detail": detail, "result": "started", "error": None, "first_failed_at": None,
                         "woke_for": dict(newest)}
    return "asleep, nothing to do", None


def failed(record, previous, error, heartbeat=None):
    """decide()'s record for a start that failed: the token is not recorded, so the next tick retries.

    The waker writes only on attempts, so a failed record outlives a box an
    operator woke. A heartbeat newer than that attempt means the box ran since,
    and this failure is the first of a new run.
    """
    first = None
    if isinstance(previous, dict) and previous.get("result") == "failed" and parse_time(previous.get("first_failed_at")):
        attempted = parse_time(previous.get("requested_at"))
        slept = parse_time(heartbeat.get("at")) if isinstance(heartbeat, dict) else None
        if not (attempted and slept and slept > attempted):
            first = previous["first_failed_at"]
    return dict(record, result="failed", error=error, first_failed_at=first or record["requested_at"],
                woke_for=woke_for(previous))


def error_code(exc):
    """The AWS error code of an exception, else its class name. Never its message: waker.json is published."""
    try:
        code = exc.response["Error"]["Code"]
    except (AttributeError, KeyError, TypeError):
        code = type(exc).__name__
    return code if isinstance(code, str) and re.fullmatch(r"[A-Za-z0-9.]{1,64}", code) else "Unknown"


# --- resolving the set -----------------------------------------------------------------

def main_head(advertisement):
    """refs/heads/main's commit in a git smart-HTTP refs advertisement."""
    head, at = None, 0
    while at < len(advertisement):
        try:
            length = int(advertisement[at:at + 4].decode("ascii"), 16)
        except ValueError:
            raise ValueError("not a refs advertisement") from None
        if length == 0:  # a flush packet
            at += 4
            continue
        if length < 4 or at + length > len(advertisement):
            raise ValueError("a truncated refs advertisement")
        # <sha> <ref>, and on the first ref a NUL and the capabilities.
        line = advertisement[at + 4:at + length].split(b"\0", 1)[0].rstrip(b"\n")
        at += length
        sha, _, ref = line.partition(b" ")
        if ref == b"refs/heads/main":
            head = sha.decode("ascii", "replace")
    if not advertisement.endswith(b"0000"):
        raise ValueError("a truncated refs advertisement")
    if head is None or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("no refs/heads/main in the refs advertisement")
    return head


def fetch(opener, url, method="GET", headers=None):
    request = urllib.request.Request(url, method=method, headers=headers or {})
    with opener(request, timeout=CALL_TIMEOUT_S) as response:
        return response.read(), response.headers


def smelt_head(repo, opener):
    body, _ = fetch(opener, f"https://github.com/{repo}.git/info/refs?service=git-upload-pack")
    return main_head(body)


def ghcr_digest(ref, opener):
    """The digest REPO:TAG points at, anonymously, as ghcr_digest in scripts/host/poll.sh."""
    repo = ref.removeprefix("ghcr.io/").rpartition(":")[0]
    tag = ref.rpartition(":")[2]
    body, _ = fetch(opener, f"https://ghcr.io/token?scope=repository:{repo}:pull")
    token = json.loads(body).get("token")
    if not isinstance(token, str) or not token:
        raise ValueError(f"no pull token for {ref}")
    _, headers = fetch(opener, f"https://ghcr.io/v2/{repo}/manifests/{tag}", method="HEAD",
                       headers={"Authorization": f"Bearer {token}", "Accept": MANIFEST_TYPES})
    digest = (headers.get("Docker-Content-Digest") or "").strip()
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError(f"no digest for {ref}")
    return digest


def resolve_key_hash(opener, directory=None):
    """The waker key hash of the set as it is now, or None when any part of it cannot be resolved."""
    directory = directory or config_dir()
    deadline = time.monotonic() + RESOLVE_BUDGET_S
    try:
        conf = parse_conf((directory / "smelt.conf").read_text())
        smelt = conf.get("SMELT_REF") or smelt_head(conf["SMELT_REPO"], opener)
        images = {}
        for ref in tracked_images((directory / "images.tracked").read_text()):
            if time.monotonic() > deadline:
                raise TimeoutError(f"over {RESOLVE_BUDGET_S} s")
            images[ref] = ghcr_digest(ref, opener)
    except Exception as exc:  # any failure is "no set reason this tick"
        log.warning("cannot resolve the set: %r", exc)
        return None
    return waker_key_hash({"smelt": smelt, "images": images})


# --- AWS -------------------------------------------------------------------------------

def client(name):
    import boto3
    return boto3.client(name)


def box_instances(ec2, box):
    """(id, state) of each instance tagged as this box that is not terminated."""
    answer = ec2.describe_instances(Filters=[
        {"Name": "tag:Project", "Values": ["forge-perf"]},
        {"Name": "tag:Box", "Values": [box]},
        {"Name": "instance-state-name", "Values": LIVE_STATES}])
    return [(instance["InstanceId"], instance["State"]["Name"])
            for reservation in answer.get("Reservations", []) for instance in reservation.get("Instances", [])]


def read_json(s3, bucket, key):
    """The object parsed, or None when it is missing or not JSON. Any other failure raises."""
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    except Exception as exc:
        if error_code(exc) in ("NoSuchKey", "404"):
            return None
        raise
    try:
        return json.loads(body)
    except ValueError:
        return None


def list_requests(s3, bucket):
    """(key, modified) of the requests/<id>.json among the first few objects, or [] when the listing fails."""
    try:
        answer = s3.list_objects_v2(Bucket=bucket, Prefix="requests/", MaxKeys=REQUEST_KEYS_LISTED)
    except Exception as exc:
        log.warning("cannot list requests: %r", exc)
        return []
    return [(item["Key"], item.get("LastModified")) for item in answer.get("Contents", [])
            if REQUEST_KEY.fullmatch(item["Key"])]


def run(env, now, ec2, s3, opener):
    """One tick. Returns what it found or did, which the Lambda reports as its result."""
    box = env.get("BOX") or "main"
    instances = box_instances(ec2, box)
    if len(instances) != 1:
        outcome = "several instances" if instances else "no instance"
        log.warning("%s tagged Box=%s", outcome, box)
        return outcome
    instance_id, state = instances[0]
    closed = gate(state, None)
    if closed == "awake":
        return closed
    heartbeat = read_json(s3, env["RESULTS_BUCKET"], f"published/{box}/heartbeat.json")
    closed = gate(state, heartbeat)
    if closed:
        log.info("%s is stopped and its heartbeat does not say asleep; leaving it", instance_id)
        return closed
    record_key = f"published/{box}/waker.json"
    previous = read_json(s3, env["RESULTS_BUCKET"], record_key)
    request_keys = new_request_keys(list_requests(s3, env["REQUESTS_BUCKET"]), heartbeat)
    # The set costs 21 HTTP calls and is the last reason tried, so it is
    # resolved only when no earlier reason starts the box.
    action, record = decide(box, state, heartbeat, request_keys, None, previous, now)
    if action != "start":
        action, record = decide(box, state, heartbeat, request_keys, resolve_key_hash(opener), previous, now)
    if action != "start":
        return action
    try:
        ec2.start_instances(InstanceIds=[instance_id])
    except Exception as exc:
        log.warning("cannot start %s for %s %s: %r", instance_id, record["reason"], record["detail"], exc)
        record = failed(record, previous, error_code(exc), heartbeat)
    else:
        log.info("started %s for %s %s", instance_id, record["reason"], record["detail"])
    s3.put_object(Bucket=env["RESULTS_BUCKET"], Key=record_key, Body=json.dumps(record).encode(),
                  ContentType="application/json")
    return record["result"]


def handler(event, context):
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    return run(os.environ, now, client("ec2"), client("s3"), urllib.request.urlopen)
