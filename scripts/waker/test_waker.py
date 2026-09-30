"""Tests of waker.py with stubbed AWS clients and a stubbed HTTP opener.

    cd scripts/waker && python3 -m unittest -v test_waker
"""

import copy
import datetime
import io
import json
import logging
import tempfile
import unittest
import urllib.error
from unittest import mock
from pathlib import Path

import waker

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NOW = datetime.datetime(2026, 10, 1, 2, 55, 3, tzinfo=datetime.timezone.utc)
SMELT = "09216cde0d6e01e22dda3dfb3b4d4dbba94fb6c3"
KEY_HASH = "fcc24b38e5e7d98d5194106d971053bdcd015e3ba3cea03c4ec7dffa7dcf203c"
OTHER_HASH = "ab" * 32
ENV = {"BOX": "main", "RESULTS_BUCKET": "results", "REQUESTS_BUCKET": "requests"}


def setUpModule():
    # The waker logs each decision; the tests assert on what it returns.
    logging.disable(logging.CRITICAL)


def tearDownModule():
    logging.disable(logging.NOTSET)


def rebaseline():
    return json.loads((ROOT / "calibration" / "sets" / "rebaseline-1.json").read_text())


def heartbeat(**fields):
    beat = {"box": "main", "at": "2026-09-30T20:00:00Z", "state": "asleep", "run_id": None,
            "run_started_at": None, "poll_failures": 0, "seen_keys": [KEY_HASH],
            "wake_at": "2026-10-01T02:55:00Z"}
    beat.update(fields)
    return beat


def pkt(payload):
    return b"%04x" % (len(payload) + 4) + payload


def advertisement(main=SMELT):
    """What GitHub answers to info/refs?service=git-upload-pack."""
    return (pkt(b"# service=git-upload-pack\n") + b"0000"
            + pkt(b"1111111111111111111111111111111111111111 HEAD\0multi_ack symref=HEAD:refs/heads/main\n")
            + pkt(main.encode() + b" refs/heads/main\n")
            + pkt(b"2222222222222222222222222222222222222222 refs/heads/main-old\n")
            + pkt(b"3333333333333333333333333333333333333333 refs/tags/v1\n") + b"0000")


class AwsError(Exception):
    """Shaped like botocore's ClientError."""

    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code, "Message": "text that must not be published"}}


class FakeEc2:
    def __init__(self, instances=(("i-0abc", "stopped"),), start_error=None):
        self.instances, self.start_error = list(instances), start_error
        self.filters, self.started = None, []

    def describe_instances(self, Filters):
        self.filters = {f["Name"]: f["Values"] for f in Filters}
        return {"Reservations": [{"Instances": [{"InstanceId": i, "State": {"Name": s}}]}
                                 for i, s in self.instances]}

    def start_instances(self, InstanceIds):
        self.started.append(InstanceIds)
        if self.start_error:
            raise self.start_error
        return {}


class FakeS3:
    """request_keys holds keys, modified at NOW, or (key, modified) pairs."""

    def __init__(self, objects=None, request_keys=(), denied=()):
        self.objects = dict(objects or {})
        self.request_keys, self.listed, self.puts = list(request_keys), [], []
        self.denied = denied

    def get_object(self, Bucket, Key):
        if Key in self.denied:
            raise AwsError("AccessDenied")
        if (Bucket, Key) not in self.objects:
            raise AwsError("NoSuchKey")
        return {"Body": io.BytesIO(self.objects[(Bucket, Key)])}

    def list_objects_v2(self, **kwargs):
        self.listed.append(kwargs)
        items = [k if isinstance(k, tuple) else (k, NOW) for k in self.request_keys]
        return {"Contents": [{"Key": k, "LastModified": at} for k, at in items]} if items else {}

    def put_object(self, Bucket, Key, Body, ContentType):
        self.puts.append((Bucket, Key, ContentType))
        self.objects[(Bucket, Key)] = Body


class FakeResponse:
    def __init__(self, body=b"", headers=None):
        self.body, self.headers = body, headers or {}

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeWeb:
    """An opener serving GHCR and GitHub for the rebaseline-1 set."""

    def __init__(self, digests=None, main=SMELT, down=()):
        self.digests = rebaseline()["images"] if digests is None else digests
        self.main, self.down, self.calls, self.timeouts = main, down, [], []

    def __call__(self, request, timeout):
        self.timeouts.append(timeout)
        url, method = request.full_url, request.get_method()
        self.calls.append((method, url, dict(request.header_items())))
        if any(part in url for part in self.down):
            raise urllib.error.URLError("down")
        if url.startswith("https://ghcr.io/token?"):
            return FakeResponse(json.dumps({"token": "anon"}).encode())
        if url.startswith("https://ghcr.io/v2/"):
            repo, tag = url[len("https://ghcr.io/v2/"):].split("/manifests/")
            return FakeResponse(headers={"Docker-Content-Digest": self.digests[f"ghcr.io/{repo}:{tag}"] + "\r"})
        if url.startswith("https://github.com/"):
            return FakeResponse(advertisement(self.main))
        raise AssertionError(f"unexpected {method} {url}")


def s3_with(beat=None, record=None, request_keys=()):
    objects = {}
    if beat is not None:
        objects[("results", "published/main/heartbeat.json")] = json.dumps(beat).encode()
    if record is not None:
        objects[("results", "published/main/waker.json")] = json.dumps(record).encode()
    return FakeS3(objects, request_keys)


def written(s3):
    return json.loads(s3.objects[("results", "published/main/waker.json")])


class KeyTests(unittest.TestCase):
    def test_contract_vector(self):
        self.assertEqual(waker.waker_key_hash(rebaseline()), KEY_HASH)

    def test_key_is_smelt_and_images_only(self):
        a = rebaseline()
        b = copy.deepcopy(a)
        b["harness"]["sha"], b["resolved_at"] = "f" * 40, "2027-01-01T00:00:00Z"
        self.assertEqual(waker.waker_key(a), waker.waker_key(b))
        self.assertTrue(waker.waker_key(a).startswith(b'{"images":{"ghcr.io/fil-forge/delegator:main":"sha256:'))
        self.assertTrue(waker.waker_key(a).endswith(b'"smelt":"' + SMELT.encode() + b'"}'))

    def test_key_does_not_escape_non_ascii(self):
        self.assertIn("é".encode(), waker.waker_key({"smelt": "é", "images": {}}))


class ConfigTests(unittest.TestCase):
    def test_tracked_images(self):
        text = "# a comment\n\nA_IMAGE  ghcr.io/o/a:main   # where\nbad line of four\nB_IMAGE\tghcr.io/o/b:main-dev\nC\n"
        self.assertEqual(waker.tracked_images(text), ["ghcr.io/o/a:main", "ghcr.io/o/b:main-dev"])

    def test_conf(self):
        conf = waker.parse_conf("SMELT_REPO=fil-forge/smelt\n# SMELT_REF=nope\nSMELT_REF=\nQ='a b' # c\nD=\"x\"\n")
        self.assertEqual(conf, {"SMELT_REPO": "fil-forge/smelt", "SMELT_REF": "", "Q": "a b", "D": "x"})

    def test_repository_config_matches_the_vector(self):
        directory = waker.config_dir()
        self.assertEqual(directory, ROOT / "config")
        refs = waker.tracked_images((directory / "images.tracked").read_text())
        self.assertEqual(sorted(refs), sorted(rebaseline()["images"]))

    def test_packaged_config_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "images.tracked").write_text("")
            (tmp / "smelt.conf").write_text("")
            self.assertEqual(waker.config_dir(tmp), tmp)


class RefsTests(unittest.TestCase):
    def test_main_head(self):
        self.assertEqual(waker.main_head(advertisement()), SMELT)

    def test_main_as_the_first_ref_with_capabilities(self):
        data = pkt(b"# service=git-upload-pack\n") + b"0000" + pkt(SMELT.encode() + b" refs/heads/main\0caps\n") + b"0000"
        self.assertEqual(waker.main_head(data), SMELT)

    def test_no_main_or_bad_data(self):
        for data in (b"", b"<html>", pkt(b"# service=git-upload-pack\n") + b"0000" + b"0000",
                     advertisement("z" * 40), advertisement(SMELT[:39]), advertisement()[:-30]):
            with self.assertRaises(ValueError):
                waker.main_head(data)


class ResolveTests(unittest.TestCase):
    def test_ghcr_digest_exchange(self):
        web = FakeWeb()
        ref = "ghcr.io/fil-forge/guppy:main-dev"
        self.assertEqual(waker.ghcr_digest(ref, web), rebaseline()["images"][ref])
        (m1, u1, h1), (m2, u2, h2) = web.calls
        self.assertEqual((m1, u1), ("GET", "https://ghcr.io/token?scope=repository:fil-forge/guppy:pull"))
        self.assertNotIn("Authorization", h1)
        self.assertEqual((m2, u2), ("HEAD", "https://ghcr.io/v2/fil-forge/guppy/manifests/main-dev"))
        self.assertEqual(h2["Authorization"], "Bearer anon")
        self.assertEqual(h2["Accept"], "application/vnd.oci.image.index.v1+json, "
                         "application/vnd.docker.distribution.manifest.list.v2+json, "
                         "application/vnd.oci.image.manifest.v1+json, "
                         "application/vnd.docker.distribution.manifest.v2+json")

    def test_ghcr_digest_rejects(self):
        def no_token(request, timeout):
            return FakeResponse(b"{}")
        with self.assertRaises(ValueError):
            waker.ghcr_digest("ghcr.io/o/a:main", no_token)
        for bad in ("", "sha256:abc", "md5:" + "a" * 64):
            with self.assertRaises(ValueError):
                waker.ghcr_digest("ghcr.io/o/a:main", FakeWeb({"ghcr.io/o/a:main": bad}))

    def test_resolved_key_hash_is_the_vector(self):
        web = FakeWeb()
        self.assertEqual(waker.resolve_key_hash(web), KEY_HASH)
        self.assertEqual(len(web.calls), 21)
        self.assertEqual(web.calls[0][:2],
                         ("GET", "https://github.com/fil-forge/smelt.git/info/refs?service=git-upload-pack"))
        self.assertEqual(web.timeouts, [10] * 21)

    def test_resolution_stops_at_its_budget(self):
        # Each look at the clock is 9 s after the last: the deadline is set at 0 s
        # and the fifth image is reached past 40 s.
        web = FakeWeb()
        with mock.patch.object(waker.time, "monotonic", side_effect=range(0, 9000, 9)):
            self.assertIsNone(waker.resolve_key_hash(web))
        self.assertEqual(len(web.calls), 1 + 2 * 4)

    def test_smelt_pin_skips_the_lookup(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "images.tracked").write_text((ROOT / "config" / "images.tracked").read_text())
            (tmp / "smelt.conf").write_text(f"SMELT_REPO=fil-forge/smelt\nSMELT_REF={SMELT}\n")
            web = FakeWeb(main="4" * 40)
            self.assertEqual(waker.resolve_key_hash(web, tmp), KEY_HASH)
            self.assertFalse([c for c in web.calls if "github.com" in c[1]])

    def test_any_failure_is_none(self):
        for down in ("github.com", "ghcr.io/token?scope=repository:fil-forge/piri:", "/hilt/manifests/"):
            self.assertIsNone(waker.resolve_key_hash(FakeWeb(down=(down,))))
        digests = dict(rebaseline()["images"], **{"ghcr.io/fil-forge/piri:main": "junk"})
        self.assertIsNone(waker.resolve_key_hash(FakeWeb(digests)))


class DecideTests(unittest.TestCase):
    def decide(self, state="stopped", beat=None, request_keys=(), key_hash=KEY_HASH, previous=None, now=NOW):
        return waker.decide("main", state, heartbeat() if beat is None else beat,
                            list(request_keys), key_hash, previous, now)

    def test_any_state_but_stopped_is_awake(self):
        for state in ("pending", "running", "stopping"):
            self.assertEqual(self.decide(state=state), ("awake", None))

    def test_only_a_box_that_put_itself_to_sleep(self):
        for beat in ({}, heartbeat(state="idle"), heartbeat(state="running"), [], "asleep"):
            self.assertEqual(waker.decide("main", "stopped", beat, ["requests/a.json"], OTHER_HASH, None, NOW),
                             ("stopped, not asleep", None))
        self.assertEqual(waker.decide("main", "stopped", None, [], None, None, NOW), ("stopped, not asleep", None))

    def test_nothing_to_do(self):
        self.assertEqual(self.decide(now=NOW - datetime.timedelta(minutes=1)), ("asleep, nothing to do", None))
        self.assertEqual(self.decide(beat=heartbeat(wake_at=None)), ("asleep, nothing to do", None))

    def test_wake_at_writes_the_contract_record(self):
        action, record = self.decide()
        self.assertEqual(action, "start")
        self.assertEqual(record, {
            "schema": "forge-perf.waker/v1", "box": "main", "requested_at": "2026-10-01T02:55:03Z",
            "reason": "wake_at", "detail": "2026-10-01T02:55:00Z", "result": "started", "error": None,
            "first_failed_at": None, "woke_for": {"wake_at:2026-10-01T02:55:00Z": "2026-10-01T02:55:03Z"}})

    def test_wake_at_exactly_now(self):
        self.assertEqual(self.decide(now=NOW.replace(second=0))[0], "start")

    def test_unusable_wake_at_is_no_reason(self):
        for value in ("soon", 5, "2026-10-01 02:55:00", "2026-10-01T02:55:00+00:00"):
            self.assertEqual(self.decide(beat=heartbeat(wake_at=value)), ("asleep, nothing to do", None))

    def test_request(self):
        action, record = self.decide(beat=heartbeat(wake_at="2026-10-02T02:55:00Z"),
                                     request_keys=["requests/ingot-pr1-0123456789ab-1.json", "requests/b.json"])
        self.assertEqual((action, record["reason"], record["detail"]),
                         ("start", "request", "requests/ingot-pr1-0123456789ab-1.json"))
        self.assertEqual(list(record["woke_for"]), ["request:requests/ingot-pr1-0123456789ab-1.json"])

    def test_set(self):
        action, record = self.decide(beat=heartbeat(wake_at=None, seen_keys=[OTHER_HASH]))
        self.assertEqual((action, record["reason"], record["detail"]), ("start", "set", KEY_HASH))
        self.assertEqual(record["woke_for"], {f"set:{KEY_HASH}": "2026-10-01T02:55:03Z"})
        self.assertEqual(self.decide(beat=heartbeat(wake_at=None, seen_keys=[]))[0], "start")

    def test_unresolved_set_or_unusable_seen_keys_is_no_reason(self):
        self.assertEqual(self.decide(beat=heartbeat(wake_at=None, seen_keys=[OTHER_HASH]), key_hash=None),
                         ("asleep, nothing to do", None))
        beat = heartbeat(wake_at=None)
        del beat["seen_keys"]
        self.assertEqual(self.decide(beat=beat), ("asleep, nothing to do", None))

    def test_reasons_in_order(self):
        beat = heartbeat(seen_keys=[])
        keys = ["requests/a.json"]
        self.assertEqual(self.decide(beat=beat, request_keys=keys)[1]["reason"], "wake_at")
        previous = {"woke_for": {"wake_at:2026-10-01T02:55:00Z": "2026-10-01T02:00:00Z"}}
        self.assertEqual(self.decide(beat=beat, request_keys=keys, previous=previous)[1]["reason"], "request")
        previous["woke_for"]["request:requests/a.json"] = "2026-10-01T02:30:00Z"
        action, record = self.decide(beat=beat, request_keys=keys, previous=previous)
        self.assertEqual(record["reason"], "set")
        self.assertEqual(len(record["woke_for"]), 3)
        previous["woke_for"][f"set:{KEY_HASH}"] = "2026-10-01T02:50:00Z"
        self.assertEqual(self.decide(beat=beat, request_keys=keys, previous=previous), ("asleep, nothing to do", None))

    def test_a_token_counts_for_six_hours(self):
        def previous(at):
            return {"woke_for": {"wake_at:2026-10-01T02:55:00Z": at}}
        self.assertEqual(self.decide(previous=previous("2026-09-30T20:55:04Z"))[0], "asleep, nothing to do")
        action, record = self.decide(previous=previous("2026-09-30T20:55:03Z"))
        self.assertEqual(action, "start")
        self.assertEqual(record["woke_for"], {"wake_at:2026-10-01T02:55:00Z": "2026-10-01T02:55:03Z"})

    def test_woke_for_keeps_the_newest_twenty(self):
        old = {f"set:{n:064x}": f"2026-09-{n:02d}T00:00:00Z" for n in range(1, 26)}
        record = self.decide(previous={"woke_for": old})[1]
        self.assertEqual(len(record["woke_for"]), 20)
        self.assertIn("wake_at:2026-10-01T02:55:00Z", record["woke_for"])
        self.assertNotIn(f"set:{6:064x}", record["woke_for"])
        self.assertIn(f"set:{7:064x}", record["woke_for"])

    def test_unusable_previous_record(self):
        for previous in ([], "x", {"woke_for": []}, {"woke_for": {"wake_at:2026-10-01T02:55:00Z": "junk", "a": 1}}):
            action, record = self.decide(previous=previous)
            self.assertEqual(action, "start")
            self.assertEqual(record["woke_for"], {"wake_at:2026-10-01T02:55:00Z": "2026-10-01T02:55:03Z"})

    def test_failed_start(self):
        previous = {"result": "started", "first_failed_at": None, "woke_for": {"set:a": "2026-10-01T01:00:00Z"}}
        started = self.decide(previous=previous)[1]
        record = waker.failed(started, previous, "InsufficientInstanceCapacity")
        self.assertEqual(record, dict(started, result="failed", error="InsufficientInstanceCapacity",
                                      first_failed_at="2026-10-01T02:55:03Z",
                                      woke_for={"set:a": "2026-10-01T01:00:00Z"}))
        later = NOW + datetime.timedelta(minutes=5)
        again = waker.failed(self.decide(previous=record, now=later)[1], record, "InsufficientInstanceCapacity")
        self.assertEqual((again["requested_at"], again["first_failed_at"]),
                         ("2026-10-01T03:00:03Z", "2026-10-01T02:55:03Z"))
        self.assertIsNone(self.decide(previous=again, now=later)[1]["first_failed_at"])

    def test_a_failure_before_the_box_last_slept_does_not_start_the_run(self):
        previous = {"result": "failed", "requested_at": "2026-09-20T02:55:03Z",
                    "first_failed_at": "2026-09-20T02:55:03Z", "woke_for": {}}
        started = self.decide(previous=previous)[1]
        # The heartbeat is ten days newer than that attempt: the box ran in between.
        record = waker.failed(started, previous, "InsufficientInstanceCapacity", heartbeat())
        self.assertEqual(record["first_failed_at"], "2026-10-01T02:55:03Z")
        # Same second, or times that cannot be compared: the run is unbroken.
        for beat in (heartbeat(at="2026-09-20T02:55:03Z"), heartbeat(at="junk"), None):
            record = waker.failed(started, previous, "InsufficientInstanceCapacity", beat)
            self.assertEqual(record["first_failed_at"], "2026-09-20T02:55:03Z")
        record = waker.failed(started, dict(previous, requested_at=None), "X", heartbeat())
        self.assertEqual(record["first_failed_at"], "2026-09-20T02:55:03Z")

    def test_new_request_keys(self):
        at = datetime.datetime(2026, 9, 30, 20, 0, 0, tzinfo=datetime.timezone.utc)  # the heartbeat's
        margin = datetime.timedelta(seconds=300)
        listed = [("requests/seen.json", at - margin), ("requests/edge.json", at - margin + datetime.timedelta(seconds=1)),
                  ("requests/new.json", at + datetime.timedelta(hours=1)), ("requests/undated.json", None)]
        self.assertEqual(waker.new_request_keys(listed, heartbeat()),
                         ["requests/edge.json", "requests/new.json", "requests/undated.json"])
        # A heartbeat without a usable time has seen nothing.
        for beat in (heartbeat(at="junk"), heartbeat(at=None)):
            self.assertEqual(len(waker.new_request_keys(listed, beat)), 4)
        naive = [("requests/seen.json", (at - margin).replace(tzinfo=None))]
        self.assertEqual(waker.new_request_keys(naive, heartbeat()), [])

    def test_error_code(self):
        self.assertEqual(waker.error_code(AwsError("InsufficientInstanceCapacity")), "InsufficientInstanceCapacity")
        self.assertEqual(waker.error_code(TimeoutError("a message")), "TimeoutError")
        self.assertEqual(waker.error_code(AwsError("not a code, some text")), "Unknown")


class RunTests(unittest.TestCase):
    def run_waker(self, ec2, s3, web=None, now=NOW):
        self.web = FakeWeb() if web is None else web
        return waker.run(ENV, now, ec2, s3, self.web)

    def test_no_instance_or_several(self):
        s3 = s3_with(heartbeat())
        self.assertEqual(self.run_waker(FakeEc2(()), s3), "no instance")
        ec2 = FakeEc2((("i-1", "stopped"), ("i-2", "running")))
        self.assertEqual(self.run_waker(ec2, s3), "several instances")
        self.assertEqual((ec2.started, s3.puts), ([], []))
        self.assertEqual(ec2.filters, {"tag:Project": ["forge-perf"], "tag:Box": ["main"],
                                       "instance-state-name": ["pending", "running", "stopping", "stopped"]})

    def test_awake_reads_nothing(self):
        s3 = s3_with(heartbeat(), request_keys=["requests/a.json"])
        self.assertEqual(self.run_waker(FakeEc2((("i-1", "running"),)), s3), "awake")
        self.assertEqual((s3.listed, self.web.calls), ([], []))

    def test_stopped_by_someone_else(self):
        for s3 in (FakeS3(), s3_with(heartbeat(state="idle")),
                   FakeS3({("results", "published/main/heartbeat.json"): b"{not json"})):
            ec2 = FakeEc2()
            self.assertEqual(self.run_waker(ec2, s3), "stopped, not asleep")
            self.assertEqual((ec2.started, s3.puts, s3.listed, self.web.calls), ([], [], [], []))

    def test_nothing_to_do_writes_nothing(self):
        ec2, s3 = FakeEc2(), s3_with(heartbeat(wake_at="2026-10-02T02:55:00Z"))
        self.assertEqual(self.run_waker(ec2, s3), "asleep, nothing to do")
        self.assertEqual((ec2.started, s3.puts), ([], []))
        self.assertEqual(s3.listed, [{"Bucket": "requests", "Prefix": "requests/", "MaxKeys": 20}])
        self.assertEqual(len(self.web.calls), 21)

    def test_wake_at_starts_and_records(self):
        ec2, s3 = FakeEc2(), s3_with(heartbeat())
        self.assertEqual(self.run_waker(ec2, s3), "started")
        self.assertEqual(ec2.started, [["i-0abc"]])
        self.assertEqual(s3.puts, [("results", "published/main/waker.json", "application/json")])
        self.assertEqual(written(s3)["woke_for"], {"wake_at:2026-10-01T02:55:00Z": "2026-10-01T02:55:03Z"})
        # The set is resolved only when no earlier reason starts the box.
        self.assertEqual(self.web.calls, [])

    def test_request_starts(self):
        s3 = s3_with(heartbeat(wake_at="2026-10-02T02:55:00Z"),
                     request_keys=["requests/", "requests/Bad.json", "requests/a-1.json", "requests/b.json"])
        self.assertEqual(self.run_waker(FakeEc2(), s3), "started")
        self.assertEqual((written(s3)["reason"], written(s3)["detail"]), ("request", "requests/a-1.json"))

    def test_a_request_the_box_slept_on_does_not_start_it(self):
        # The daily cap: the box listed this request, left it queued and slept
        # until 00:01. Only a request newer than its heartbeat is a reason.
        beat = heartbeat(at="2026-09-30T10:15:00Z", wake_at="2026-10-01T00:01:00Z")
        queued = ("requests/a-queued.json", datetime.datetime(2026, 9, 30, 9, 0, 0, tzinfo=datetime.timezone.utc))
        ec2, s3 = FakeEc2(), s3_with(beat, request_keys=[queued])
        for hour in (10, 16, 22):
            now = datetime.datetime(2026, 9, 30, hour, 20, 3, tzinfo=datetime.timezone.utc)
            self.assertEqual(self.run_waker(ec2, s3, now=now), "asleep, nothing to do")
        self.assertEqual((ec2.started, s3.puts), ([], []))
        # A request that arrives while it sleeps starts it, under its own key.
        arrived = datetime.datetime(2026, 9, 30, 22, 30, 0, tzinfo=datetime.timezone.utc)
        s3.request_keys.append(("requests/b-new.json", arrived))
        self.assertEqual(self.run_waker(ec2, s3, now=arrived + datetime.timedelta(minutes=5)), "started")
        self.assertEqual((written(s3)["reason"], written(s3)["detail"]), ("request", "requests/b-new.json"))
        # The wake time still starts it for the queued one.
        ec2, s3 = FakeEc2(), s3_with(beat, request_keys=[queued])
        now = datetime.datetime(2026, 10, 1, 0, 1, 3, tzinfo=datetime.timezone.utc)
        self.assertEqual(self.run_waker(ec2, s3, now=now), "started")
        self.assertEqual(written(s3)["reason"], "wake_at")

    def test_new_set_starts(self):
        ec2, s3 = FakeEc2(), s3_with(heartbeat(wake_at="2026-10-02T02:55:00Z", seen_keys=[OTHER_HASH]))
        self.assertEqual(self.run_waker(ec2, s3), "started")
        self.assertEqual((written(s3)["reason"], written(s3)["detail"]), ("set", KEY_HASH))
        # The next tick after the box slept again without seeing that set.
        ec2 = FakeEc2()
        self.assertEqual(self.run_waker(ec2, s3, now=NOW + datetime.timedelta(hours=1)), "asleep, nothing to do")
        self.assertEqual(ec2.started, [])

    def test_failed_resolution_leaves_the_other_reasons(self):
        s3 = s3_with(heartbeat(wake_at="2026-10-02T02:55:00Z", seen_keys=[]))
        self.assertEqual(self.run_waker(FakeEc2(), s3, FakeWeb(down=("ghcr.io",))), "asleep, nothing to do")
        s3.request_keys = ["requests/a.json"]
        self.assertEqual(self.run_waker(FakeEc2(), s3, FakeWeb(down=("ghcr.io",))), "started")

    def test_failed_start_is_retried(self):
        s3 = s3_with(heartbeat())
        self.assertEqual(self.run_waker(FakeEc2(start_error=AwsError("InsufficientInstanceCapacity")), s3), "failed")
        first = written(s3)
        self.assertEqual((first["result"], first["error"], first["first_failed_at"], first["woke_for"]),
                         ("failed", "InsufficientInstanceCapacity", "2026-10-01T02:55:03Z", {}))
        later = NOW + datetime.timedelta(minutes=5)
        self.assertEqual(self.run_waker(FakeEc2(start_error=AwsError("InsufficientInstanceCapacity")), s3, now=later),
                         "failed")
        self.assertEqual((written(s3)["requested_at"], written(s3)["first_failed_at"]),
                         ("2026-10-01T03:00:03Z", "2026-10-01T02:55:03Z"))
        ec2 = FakeEc2()
        self.assertEqual(self.run_waker(ec2, s3, now=later), "started")
        self.assertEqual((written(s3)["result"], written(s3)["error"], written(s3)["first_failed_at"]),
                         ("started", None, None))

    def test_an_unreadable_bucket_starts_nothing(self):
        class Denied(FakeS3):
            def get_object(self, Bucket, Key):
                raise AwsError("AccessDenied")
        ec2 = FakeEc2()
        with self.assertRaises(AwsError):
            self.run_waker(ec2, Denied())
        self.assertEqual(ec2.started, [])

    def test_a_denied_record_starts_nothing(self):
        # Without s3:ListBucket a missing waker.json reads as AccessDenied. It
        # is not taken for "no record", which would forget woke_for.
        ec2, s3 = FakeEc2(), s3_with(heartbeat())
        s3.denied = ("published/main/waker.json",)
        with self.assertRaises(AwsError):
            self.run_waker(ec2, s3)
        self.assertEqual((ec2.started, s3.puts), ([], []))

    def test_a_failure_after_the_box_ran_starts_a_new_run(self):
        stale = {"schema": "forge-perf.waker/v1", "box": "main", "requested_at": "2026-09-20T02:55:03Z",
                 "reason": "wake_at", "detail": "2026-09-20T02:55:00Z", "result": "failed",
                 "error": "InsufficientInstanceCapacity", "first_failed_at": "2026-09-20T02:55:03Z", "woke_for": {}}
        s3 = s3_with(heartbeat(), stale)
        self.assertEqual(self.run_waker(FakeEc2(start_error=AwsError("InsufficientInstanceCapacity")), s3), "failed")
        self.assertEqual(written(s3)["first_failed_at"], "2026-10-01T02:55:03Z")

    def test_a_failed_request_listing_leaves_the_other_reasons(self):
        class NoList(FakeS3):
            def list_objects_v2(self, **kwargs):
                raise AwsError("AccessDenied")
        s3 = NoList(s3_with(heartbeat()).objects)
        self.assertEqual(self.run_waker(FakeEc2(), s3), "started")


if __name__ == "__main__":
    unittest.main()
