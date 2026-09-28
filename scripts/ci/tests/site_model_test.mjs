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

test("with every gate unmeasured, the scale covers the mercury's median", () => {
  const d = index([run({ p5_bytes_per_s: 0.04e9, median_bytes_per_s: 0.10e9 })]);
  const merc = M.mercury(d.runs, NOW);
  assert.ok(Math.abs(M.scaleTop(d.gates, merc) - 1.1 * 0.10e9) < 1);
});

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

test("the latest counting run can come from a series other than per-trigger", () => {
  const d = index([run(), run({ series: "nightly" }), run({ series: "calibration" }), run({ class: "failed" })]);
  assert.equal(M.latestCounting(d.runs).series, "nightly");
  assert.equal(M.latestCounting(index([run({ series: "calibration" })]).runs), null);
});
