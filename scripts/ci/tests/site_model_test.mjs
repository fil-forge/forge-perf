// Tests of site/model.js, the page's rules: which runs move the mercury and
// light gates, the ceiling in force, the scale, the heartbeat line and the
// history markers. Run by scripts/ci/check-site.sh: node --test <this file>.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as M from "../../../site/model.js";

const NOW = Date.parse("2026-10-10T12:00:00Z");
let n = 0;
function run(fields = {}) {
  n += 1;
  const at = fields.at || `2026-10-0${Math.min(9, n)}T00:00:00Z`;
  return {
    run_id: `main-20261001t${String(n).padStart(6, "0")}z`, series: "per-trigger", class: "valid", reasons: [], flags: [],
    box: { id: "main", tier: 1, instance_type: "m9gd.2xlarge" }, run_started_at: at, pairing_id: null,
    p5_bytes_per_s: 0.3e9, median_bytes_per_s: 0.35e9, instrument_changes: [], changed: ["ingot"], ...fields,
  };
}
const measured = (gate, ceiling, at, previous) => ({
  gate, instance_type: "m9gd.2xlarge", nic_reference_gbps: 4.25, ceiling_bytes_per_s: ceiling,
  s3_put_bytes_per_s: ceiling, nvme_seq_write_bytes_per_s: ceiling, measured_at: at,
  forge_perf_sha: "a".repeat(40), method: "calibration/README.md", ...(previous ? { previous } : {}),
});
const unmeasured = (gate) => ({ gate, instance_type: "m9gd.16xlarge", nic_reference_gbps: 34, ceiling_bytes_per_s: null,
  s3_put_bytes_per_s: null, nvme_seq_write_bytes_per_s: null, measured_at: null, forge_perf_sha: null, method: null });
const index = (runs, gates = [unmeasured(1)], overrides = []) =>
  M.prepare({ runs, gates: { schema: "forge-perf.gates/v1", gates }, overrides });

test("no runs: no mercury, the fallback scale, unmeasured gates unlit", () => {
  const d = index([]);
  assert.equal(M.mercury(d.runs, NOW), null);
  assert.equal(M.scaleTop(d.gates, null), 1e9);
  assert.deepEqual(M.litGates(d.runs, d.gates).map((l) => l.run), [null]);
});

test("calibration runs never move the mercury or light a gate", () => {
  const d = index([run({ series: "calibration", p5_bytes_per_s: 5e9 })], [measured(1, 0.36e9, "2026-09-01T00:00:00Z")]);
  assert.equal(M.mercury(d.runs, NOW), null);
  assert.equal(M.litGates(d.runs, d.gates)[0].run, null);
});

test("only valid runs count, after overrides", () => {
  const gates = [measured(1, 0.36e9, "2026-09-01T00:00:00Z")];
  const warn = run({ class: "availability_warning", p5_bytes_per_s: 0.5e9 });
  const overridden = run({ p5_bytes_per_s: 0.5e9 });
  const d = index([warn, overridden], gates, [{ run_id: overridden.run_id, class: "invalid", issue: "https://github.com/fil-forge/forge-perf/issues/1" }]);
  assert.equal(M.mercury(d.runs, NOW), null);
  assert.equal(M.litGates(d.runs, d.gates)[0].run, null);
  assert.equal(M.outcomeText(d.runs[1]), "Marked invalid measurement after review");
});

test("nightly and campaign runs light gates; the mercury is the latest per-trigger or nightly run on the persistent box", () => {
  const gates = [measured(1, 0.36e9, "2026-09-01T00:00:00Z")];
  const pt = run({ p5_bytes_per_s: 0.2e9 });
  const nightly = run({ series: "nightly", p5_bytes_per_s: 0.4e9 });
  const campaign = run({ series: "campaign", box: { id: "campaign", tier: 3, instance_type: "m9gd.16xlarge" }, p5_bytes_per_s: 3e9 });
  const d = index([pt, nightly, campaign], gates);
  const merc = M.mercury(d.runs, NOW);
  assert.equal(merc.run.run_id, nightly.run_id);
  assert.equal(merc.runs_since, 0);
  assert.equal(M.litGates(d.runs, d.gates)[0].run.run_id, nightly.run_id);
  assert.ok(Math.abs(M.scaleTop(d.gates, merc) - 1.1 * 0.4e9) < 1);
});

test("a lone nightly run fills the mercury", () => {
  const nightly = run({ series: "nightly", p5_bytes_per_s: 0.54e9 });
  const d = index([nightly], [measured(1, 0.52e9, "2026-09-01T00:00:00Z")]);
  assert.equal(M.mercury(d.runs, NOW).run.run_id, nightly.run_id);
  assert.equal(M.litGates(d.runs, d.gates)[0].run.run_id, nightly.run_id);
});

test("the mercury is the latest of per-trigger and nightly, whichever came last", () => {
  const nightly = run({ series: "nightly", p5_bytes_per_s: 0.4e9 });
  const pt = run({ p5_bytes_per_s: 0.2e9 });
  const d = index([nightly, pt], [measured(1, 0.36e9, "2026-09-01T00:00:00Z")]);
  const merc = M.mercury(d.runs, NOW);
  assert.equal(merc.run.run_id, pt.run_id);
  assert.equal(merc.runs_since, 0);
  assert.ok(Math.abs(M.scaleTop(d.gates, merc) - 1.1 * 0.36e9) < 1);
});

test("a nightly marked invalid, or on another box, leaves the mercury on the earlier run", () => {
  const pt = run({ p5_bytes_per_s: 0.3e9 });
  const overridden = run({ series: "nightly", p5_bytes_per_s: 0.4e9 });
  const elsewhere = run({ series: "nightly", box: { id: "spare", tier: 1, instance_type: "m9gd.2xlarge" }, p5_bytes_per_s: 0.5e9 });
  const d = index([pt, overridden, elsewhere], [unmeasured(1)],
    [{ run_id: overridden.run_id, class: "invalid", issue: "https://github.com/fil-forge/forge-perf/issues/1" }]);
  const merc = M.mercury(d.runs, NOW);
  assert.equal(merc.run.run_id, pt.run_id);
  assert.equal(merc.runs_since, 1);
});

test("a campaign run on the persistent box lights a gate but leaves the mercury", () => {
  const gates = [measured(1, 0.36e9, "2026-09-01T00:00:00Z")];
  const pt = run({ p5_bytes_per_s: 0.3e9 });
  const bridge = run({ series: "campaign", pairing_id: "pair-20261001-t1t2", p5_bytes_per_s: 0.4e9 });
  const d = index([pt, bridge], gates);
  const merc = M.mercury(d.runs, NOW);
  assert.equal(merc.run.run_id, pt.run_id);
  assert.equal(merc.runs_since, 1);
  assert.equal(M.litGates(d.runs, d.gates)[0].run.run_id, bridge.run_id);
});

test("a lit gate keeps the ceiling in force when its run happened", () => {
  const gate = measured(1, 0.40e9, "2026-10-05T00:00:00Z", [
    { ceiling_bytes_per_s: 0.30e9, s3_put_bytes_per_s: 0.30e9, nvme_seq_write_bytes_per_s: 0.30e9,
      measured_at: "2026-09-01T00:00:00Z", forge_perf_sha: "b".repeat(40), method: "calibration/README.md" }]);
  const early = run({ at: "2026-10-02T00:00:00Z", p5_bytes_per_s: 0.33e9 });
  const d = index([early, run({ at: "2026-10-06T00:00:00Z", p5_bytes_per_s: 0.35e9 })], [gate]);
  const lit = M.litGates(d.runs, d.gates)[0];
  assert.equal(lit.run.run_id, early.run_id);
  assert.equal(lit.ceiling.ceiling_bytes_per_s, 0.30e9);
  assert.equal(M.ceilingAt(d.gates[0], "2026-08-01T00:00:00Z"), null);
});

test("the mercury reports its age and the runs since on the box", () => {
  const d = index([run({ at: "2026-10-10T09:00:00Z" }), run({ at: "2026-10-10T10:00:00Z", class: "no_data", p5_bytes_per_s: null })]);
  const merc = M.mercury(d.runs, NOW);
  assert.equal(M.ago(merc.age_ms), "3 h");
  assert.equal(merc.runs_since, 1);
});

test("heartbeat lines", () => {
  assert.equal(M.heartbeatLine(null, NOW), "no heartbeat received");
  assert.equal(M.heartbeatLine({ at: "2026-10-10T11:57:00Z", state: "idle", poll_failures: 0 }, NOW), "idle, last poll 3 min ago");
  assert.equal(M.heartbeatLine({ at: "2026-10-10T11:59:00Z", state: "held", poll_failures: 0 }, NOW), "held, last poll 1 min ago");
  assert.equal(M.heartbeatLine({ at: "2026-10-10T10:10:00Z", state: "idle" }, NOW), "no heartbeat for 110 min");
  assert.equal(M.heartbeatLine({ at: "2026-10-10T08:00:00Z", state: "idle" }, NOW), "no heartbeat for 4 h");
  // An asleep box is not stale, however old its heartbeat.
  assert.equal(M.heartbeatLine({ at: "2026-10-10T08:00:00Z", state: "asleep", wake_at: "2026-10-11T02:55:00Z", poll_failures: 0 }, NOW),
    "asleep for 4 h, next wake 2026-10-11 02:55 UTC");
  assert.equal(M.heartbeatLine({ at: "2026-10-10T08:00:00Z", state: "asleep", wake_at: "2026-10-10T11:00:00Z" }, NOW),
    "asleep for 4 h, due to wake 2026-10-10 11:00 UTC");
});

test("history marks the first run on a new box type once, and rings the incoming paired box", () => {
  const big = { id: "main", tier: 2, instance_type: "m9gd.8xlarge" };
  const rows = M.history([
    run(), run({ pairing_id: "pair-20261003-a" }), run({ pairing_id: "pair-20261003-a", box: big, instrument_changes: ["box"] }),
    run({ pairing_id: "pair-20261003-a", instrument_changes: ["box"] }), run({ box: big, instrument_changes: ["box", "smelt"] }),
  ], "per-trigger");
  assert.deepEqual(rows.map((r) => r.box_change), [null, null, "m9gd.8xlarge", null, null]);
  assert.deepEqual(rows.map((r) => r.incoming), [false, false, true, false, false]);
  assert.deepEqual(rows.map(M.instrumentMarker), [false, false, false, false, true]);
});

test("changes text, compare links and the previous run", () => {
  const a = run(), b = run({ series: "nightly" }), c = run({ instrument_changes: ["smelt", "postgres"] });
  assert.equal(M.changesText(c), "ingot, instrument: smelt, postgres");
  assert.equal(M.previousRun([a, b, c], c).run_id, a.run_id);
  assert.equal(M.previousRun([a, b, c], a), null);
  assert.deepEqual(M.compare("https://github.com/fil-forge/ingot", "b".repeat(40), "a".repeat(40)),
    { text: "compare", href: `https://github.com/fil-forge/ingot/compare/${"a".repeat(40)}...${"b".repeat(40)}` });
  assert.deepEqual(M.compare("https://x", "a", "a"), { text: "same as previous" });
  assert.equal(M.compare("https://x", "a", undefined), null);
  assert.equal(M.gbps(25360000), "0.025");
  assert.equal(M.gbps(2.05e9), "2.05");
  assert.equal(M.perSecond(0.15000000000000002), "0.15");
  assert.equal(M.perSecond(12.3456), "12.3");
  assert.equal(M.perSecond(0), "0");
  assert.equal(M.perSecond(null), "–");
});

const READS = { read_back_p5_bytes_per_s: 0.29e9, read_back_median_bytes_per_s: 0.34e9,
  restore_p5_bytes_per_s: 0.12e9, restore_median_bytes_per_s: 0.18e9, restore_ranged_gets_median_per_s: 43.21 };
const readLineCases = [
  { name: "read-back with a p5", run: READS, id: "read_back",
    want: "Read-back 0.29 GB/s held by 95% of windows · median 0.34 GB/s" },
  { name: "restore with a p5 and ranged GETs", run: READS, id: "restore",
    want: "Restore 0.12 GB/s held by 95% of windows · median 0.18 GB/s · 43.2 ranged GETs/s" },
  { name: "read-back from before the harness recorded p5", run: { ...READS, read_back_p5_bytes_per_s: null },
    id: "read_back", want: "Read-back median 0.34 GB/s" },
  { name: "restore from before the harness recorded p5 and ranged GETs",
    run: { ...READS, restore_p5_bytes_per_s: null, restore_ranged_gets_median_per_s: null },
    id: "restore", want: "Restore median 0.18 GB/s" },
  { name: "a run without read results", run: {}, id: "restore", want: null },
];
for (const c of readLineCases) {
  test(`the headline line for ${c.name}`, () => {
    assert.equal(M.readLine(run(c.run), c.id), c.want);
  });
}

test("with every gate unmeasured, the scale covers the mercury's median", () => {
  const d = index([run({ p5_bytes_per_s: 0.04e9, median_bytes_per_s: 0.10e9 })]);
  const merc = M.mercury(d.runs, NOW);
  assert.ok(Math.abs(M.scaleTop(d.gates, merc) - 1.1 * 0.10e9) < 1);
});

test("the history of a read stream joins runs without read p5 on its median line only", () => {
  const before = run({ klass: "valid", restore_median_bytes_per_s: 0.2e9 });
  const after = run({ klass: "valid", restore_p5_bytes_per_s: 0.15e9, restore_median_bytes_per_s: 0.2e9 });
  const invalid = run({ klass: "invalid", restore_p5_bytes_per_s: 0.1e9, restore_median_bytes_per_s: 0.2e9 });
  const failed = run({ klass: "failed", restore_p5_bytes_per_s: 0.1e9, restore_median_bytes_per_s: 0.2e9 });
  const got = M.streamRows([before, after, invalid, failed], "restore");
  assert.deepEqual(Object.fromEntries(Object.entries(got).map(([k, rows]) => [k, rows.map((r) => r.run_id)])),
    { p5Line: [after.run_id], medianLine: [before.run_id, after.run_id], dots: [after.run_id, invalid.run_id] });
});

test("the history of ingest reads the ingest fields", () => {
  const r = run({ klass: "valid", read_back_p5_bytes_per_s: null });
  assert.deepEqual(Object.values(M.streamRows([r], "ingest")).map((rows) => rows.length), [1, 1, 1]);
});

const readScaleCases = [
  { name: "read-back p5", fields: { read_back_p5_bytes_per_s: 0.5e9 }, top: 0.5e9 },
  { name: "read-back median", fields: { read_back_median_bytes_per_s: 0.6e9 }, top: 0.6e9 },
  { name: "restore p5", fields: { restore_p5_bytes_per_s: 0.7e9 }, top: 0.7e9 },
  { name: "restore median", fields: { restore_median_bytes_per_s: 0.8e9 }, top: 0.8e9 },
  { name: "nothing above ingest, read p5 null", fields: { read_back_p5_bytes_per_s: null, restore_median_bytes_per_s: 0.1e9 }, top: 0.35e9 },
];
for (const c of readScaleCases) {
  test(`the shared scale covers the mercury run's ${c.name}`, () => {
    const d = index([run(c.fields)]);
    assert.ok(Math.abs(M.scaleTop(d.gates, M.mercury(d.runs, NOW)) - 1.1 * c.top) < 1);
  });
}

test("flags that leave the class alone are named beside the outcome", () => {
  const r = run({ flags: ["cap_not_reached", "raw_missing"] });
  assert.equal(M.flagText(r), "stopped at its time limit before its size");
  const d = index([r]);
  assert.equal(M.mercury(d.runs, NOW).run.run_id, r.run_id);
});

test("a CPU-capped check run is named beside the outcome and never moves the mercury", () => {
  const capped = run({ series: "calibration", flags: ["few_windows", "cpu_capped"], p5_bytes_per_s: 9e9 });
  assert.equal(M.flagText(capped), "under 20 steady windows, CPU capped (check run)");
  const d = index([capped]);
  assert.equal(M.mercury(d.runs, NOW), null);
});

test("a traced run is named beside the outcome and still moves the mercury", () => {
  const traced = run({ flags: ["traced"] });
  assert.equal(M.flagText(traced), "traced");
  assert.equal(M.flagText(run({ flags: ["few_windows", "traced", "trace_missing"] })),
    "under 20 steady windows, traced, trace file missing");
  const d = index([traced]);
  assert.equal(M.mercury(d.runs, NOW).run.run_id, traced.run_id);
});

test("the paired offset is the ratio of each type's median run median", () => {
  const big = { id: "main", tier: 2, instance_type: "m9gd.8xlarge" };
  const pair = "pair-20261010-tier2";
  const d = index([
    run({ pairing_id: pair, median_bytes_per_s: 0.33e9 }), run({ pairing_id: pair, median_bytes_per_s: 0.35e9 }),
    run({ pairing_id: pair, median_bytes_per_s: 0.34e9 }), run({ pairing_id: pair, box: big, median_bytes_per_s: 1.02e9 }),
    run({ pairing_id: pair, box: big, median_bytes_per_s: 1.2e9, class: "invalid" }),
    run({ pairing_id: pair, box: big, median_bytes_per_s: 1.04e9 }),
    run({ pairing_id: "pair-one-side", median_bytes_per_s: 0.3e9 }),
  ]);
  const [o, ...rest] = M.pairedOffsets(d.runs);
  assert.equal(rest.length, 0);
  assert.deepEqual([o.pairing_id, o.from, o.to, o.from_runs, o.to_runs], [pair, "m9gd.2xlarge", "m9gd.8xlarge", 3, 2]);
  assert.equal(o.from_median, 0.34e9);
  assert.equal(o.to_median, 1.03e9);
  assert.ok(Math.abs(o.ratio - 1.03 / 0.34) < 1e-9);
});

test("the paired offset compares the largest run size both types ran", () => {
  const big = { id: "main", tier: 2, instance_type: "m9gd.8xlarge" };
  const pair = "pair-20261011-t1t2";
  const at = (size_bytes, median_bytes_per_s, box) => run({ pairing_id: pair, size_bytes, median_bytes_per_s, ...(box ? { box } : {}) });
  const d = index([
    at(100e9, 0.58e9), at(100e9, 0.59e9), at(100e9, 0.57e9),
    at(350e9, 0.58e9), at(350e9, 0.58e9), at(350e9, 0.576e9),
    at(100e9, 2.03e9, big), at(100e9, 2.0e9, big), at(100e9, 1.87e9, big),
    at(350e9, 1.016e9, big), at(350e9, 1.024e9, big), at(350e9, 0.985e9, big),
    at(500e9, 1.0e9, big),
  ]);
  const [o, ...rest] = M.pairedOffsets(d.runs);
  assert.equal(rest.length, 0);
  assert.deepEqual([o.size_bytes, o.from_runs, o.to_runs], [350e9, 3, 3]);
  assert.equal(o.from_median, 0.58e9);
  assert.equal(o.to_median, 1.016e9);
  assert.ok(Math.abs(o.ratio - 1.016 / 0.58) < 1e-9);
});

test("a pairing with no run size in common gets no offset", () => {
  const big = { id: "main", tier: 2, instance_type: "m9gd.8xlarge" };
  const d = index([run({ pairing_id: "pair-apart", size_bytes: 100e9 }),
    run({ pairing_id: "pair-apart", size_bytes: 350e9, box: big })]);
  assert.deepEqual(M.pairedOffsets(d.runs), []);
});

test("the latest counting run can come from a series other than per-trigger", () => {
  const d = index([run(), run({ series: "nightly" }), run({ series: "calibration" }), run({ class: "failed" })]);
  assert.equal(M.latestCounting(d.runs).series, "nightly");
  assert.equal(M.latestCounting(index([run({ series: "calibration" })]).runs), null);
});

test("a traced run links to a Tempo search for its run ID over its run, five minutes either side", () => {
  const r = run({ run_id: "main-20260929t210142z", flags: ["few_windows", "traced"],
    run_started_at: "2026-09-29T21:01:42Z", run_finished_at: "2026-09-29T21:40:00Z" });
  const url = M.traceLink(r);
  const [base, query] = url.split("?");
  assert.equal(base, `${M.GRAFANA}/explore`);
  const params = new URLSearchParams(query);
  assert.deepEqual([params.get("schemaVersion"), params.get("orgId")], ["1", "1"]);
  assert.deepEqual(JSON.parse(params.get("panes")), { a: {
    datasource: M.TEMPO_UID,
    queries: [{ refId: "A", datasource: { type: "tempo", uid: M.TEMPO_UID }, queryType: "traceql",
      query: '{ resource.forge_perf.run_id = "main-20260929t210142z" }', limit: 20 }],
    range: { from: String(Date.parse("2026-09-29T20:56:42Z")), to: String(Date.parse("2026-09-29T21:45:00Z")) },
  } });
  assert.equal(M.GRAFANA, "https://filecoinfoundation.grafana.net");
  assert.equal(M.TEMPO_UID, "grafanacloud-traces");
});

test("only a traced run with its trace file and both times gets a trace link", () => {
  const times = { run_started_at: "2026-09-29T21:01:42Z", run_finished_at: "2026-09-29T21:40:00Z" };
  assert.equal(M.traceLink(run({ ...times })), null);
  assert.equal(M.traceLink(run({ ...times, flags: undefined })), null);
  assert.ok(M.traceLink(run({ ...times, flags: ["traced"] })).startsWith(`${M.GRAFANA}/explore?`));
  assert.equal(M.traceLink(run({ ...times, flags: ["traced", "trace_missing"] })), null);
  assert.equal(M.traceLink(run({ run_started_at: times.run_started_at, flags: ["traced"] })), null);
});

test("experiment runs never move the mercury or light a gate, and name their pull request and pairing", () => {
  const e = { request_id: "ingot-pr123-0123456789ab-17000000001", service: "ingot", repository: "fil-forge/ingot",
    pr: 123, commit: "0123456789abcdef0123456789abcdef01234567" };
  const pairing = `exp-${e.request_id}`;
  const live = run({ p5_bytes_per_s: 0.2e9 });
  const main = run({ series: "experiment", pairing_id: pairing, experiment: { ...e, role: "main" }, p5_bytes_per_s: 5e9 });
  const branch = run({ series: "experiment", pairing_id: pairing, experiment: { ...e, role: "branch" }, p5_bytes_per_s: 5e9 });
  const d = index([live, main, branch], [measured(1, 0.36e9, "2026-09-01T00:00:00Z")]);
  assert.equal(M.mercury(d.runs, NOW).run.run_id, live.run_id);
  assert.equal(M.litGates(d.runs, d.gates)[0].run, null);
  assert.equal(M.latestCounting(d.runs).run_id, live.run_id);
  assert.deepEqual(M.pairedOffsets(d.runs), []);
  assert.deepEqual(M.experimentNote(d.runs, d.runs[2]), {
    label: "ingot #123", pr_url: "https://github.com/fil-forge/ingot/pull/123", commit: "0123456",
    commit_url: `https://github.com/fil-forge/ingot/commit/${e.commit}`, role: "branch",
    paired: [{ run_id: main.run_id, role: "main" }],
  });
  assert.equal(M.experimentNote(d.runs, d.runs[0]), null);
});
