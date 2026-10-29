// What the page shows, computed from data/index.json with no DOM access, so
// scripts/ci/tests/site_model_test.mjs can check it under node.

export const PERSISTENT_BOX = "main";
export const LIVE_SERIES = ["per-trigger", "nightly", "campaign"];
export const SERIES = [
  { id: "per-trigger", label: "Per trigger", slot: 1 },
  { id: "nightly", label: "Nightly", slot: 2 },
  { id: "campaign", label: "Campaign", slot: 3 },
];
export const CLASS_LABEL = {
  valid: "Valid",
  availability_warning: "Availability errors",
  invalid: "Invalid measurement",
  failed: "Failed",
  no_data: "No data",
};
const STALE_MS = 30 * 60 * 1000;
const FALLBACK_TOP = 1e9;

// Rows gain `klass` (the class after overrides) and `override`.
export function prepare(index) {
  const overrides = new Map((index.overrides || []).map((o) => [o.run_id, o]));
  const runs = (index.runs || []).map((r) => {
    const override = overrides.get(r.run_id) || null;
    return { ...r, override, klass: override ? override.class : r.class };
  });
  return { ...index, runs, gates: gateList(index.gates) };
}

// Each gate with its measurements oldest first; `current` is null when unmeasured.
export function gateList(doc) {
  return ((doc && doc.gates) || []).map((g) => {
    const current = g.ceiling_bytes_per_s == null ? null : g;
    return { gate: g.gate, instance_type: g.instance_type, current,
             history: current ? [...(g.previous || []), current] : [] };
  });
}

export function ceilingAt(gate, time) {
  let found = null;
  for (const m of gate.history) if (m.measured_at <= time) found = m;
  return found;
}

// A run can move the mercury or light a gate only when it is valid after
// overrides, in a live series, and has a p5. Series calibration and
// experiment are outside LIVE_SERIES.
export function counts(run) {
  return run.klass === "valid" && LIVE_SERIES.includes(run.series) && run.p5_bytes_per_s != null;
}

// The first run that reached each gate, against the ceiling in force when it ran.
export function litGates(runs, gates) {
  return gates.map((gate) => {
    for (const run of runs) {
      if (!counts(run)) continue;
      const m = ceilingAt(gate, run.run_started_at);
      if (m && run.p5_bytes_per_s >= m.ceiling_bytes_per_s) return { gate, run, ceiling: m };
    }
    return { gate, run: null, ceiling: null };
  });
}

// The mercury is the latest counting per-trigger or nightly run on the
// persistent box. Campaign runs, including bridge runs on that box, only light gates.
const MERCURY_SERIES = ["per-trigger", "nightly"];

export function mercury(runs, now) {
  let at = -1;
  runs.forEach((r, i) => {
    if (counts(r) && MERCURY_SERIES.includes(r.series) && r.box.id === PERSISTENT_BOX) at = i;
  });
  if (at < 0) return null;
  const run = runs[at];
  return {
    run,
    age_ms: now - Date.parse(run.run_started_at),
    runs_since: runs.slice(at + 1).filter((r) => r.box.id === PERSISTENT_BOX).length,
  };
}

// The latest counting run in any live series, for the headline when no
// run moves the mercury yet.
export function latestCounting(runs) {
  return runs.filter(counts).pop() || null;
}

// One top for the three thermometers: the gates and the mercury run's p5 and
// median of every stream.
export function scaleTop(gates, merc) {
  const values = gates.filter((g) => g.current).map((g) => g.current.ceiling_bytes_per_s);
  if (merc) values.push(...STREAMS.flatMap((s) => [merc.run[s.p5] ?? 0, merc.run[s.median] ?? 0]));
  return values.length ? 1.1 * Math.max(...values) : FALLBACK_TOP;
}

// The three streams a run measures and the index fields of each one's rates.
export const STREAMS = [
  { id: "ingest", label: "Ingest", p5: "p5_bytes_per_s", median: "median_bytes_per_s" },
  { id: "read_back", label: "Read-back", p5: "read_back_p5_bytes_per_s", median: "read_back_median_bytes_per_s" },
  { id: "restore", label: "Restore", p5: "restore_p5_bytes_per_s", median: "restore_median_bytes_per_s" },
];

// A read stream's headline line, or null when the run has no median for it.
// A run from before the harness recorded read p5 shows the median alone.
export function readLine(run, id) {
  const s = STREAMS.find((x) => x.id === id);
  const p5 = run[s.p5], median = run[s.median];
  if (median == null) return null;
  const parts = p5 == null ? [`${s.label} median ${gbps(median)} GB/s`]
    : [`${s.label} ${gbps(p5)} GB/s held by 95% of windows`, `median ${gbps(median)} GB/s`];
  if (id === "restore" && run.restore_ranged_gets_median_per_s != null) {
    parts.push(`${perSecond(run.restore_ranged_gets_median_per_s)} ranged GETs/s`);
  }
  return parts.join(" · ");
}

export function gbps(bytes) {
  if (bytes == null) return "–";
  const v = bytes / 1e9;
  return v >= 0.1 || v === 0 ? v.toFixed(2) : v.toPrecision(2);
}

// A per-second count such as writes/s, to three significant figures, so a
// float sum such as 0.15000000000000002 shows as 0.15.
export function perSecond(v) {
  return v == null ? "–" : String(Number(v.toPrecision(3)));
}

export function ago(ms) {
  const min = Math.floor(ms / 60000);
  if (min < 1) return "under a minute";
  if (min < 120) return `${min} min`;
  const h = Math.floor(min / 60);
  return h < 48 ? `${h} h` : `${Math.floor(h / 24)} days`;
}

export function heartbeatLine(hb, now) {
  if (!hb) return "no heartbeat received";
  const age = now - Date.parse(hb.at);
  // A box that put itself to sleep sends no heartbeat until the waker starts it.
  if (hb.state === "asleep") {
    if (!hb.wake_at) return `asleep for ${ago(age)}`;
    const wake = `${hb.wake_at.slice(0, 16).replace("T", " ")} UTC`;
    return `asleep for ${ago(age)}, ${Date.parse(hb.wake_at) > now ? "next wake" : "due to wake"} ${wake}`;
  }
  if (age > STALE_MS) return `no heartbeat for ${ago(age)}`;
  const parts = [];
  if (hb.state === "held") parts.push("held");
  else if (hb.state === "running" && hb.run_started_at) {
    parts.push(`running, started ${ago(now - Date.parse(hb.run_started_at))} ago`);
  } else parts.push(hb.state || "state unknown");
  parts.push(`last poll ${ago(age)} ago`);
  if (hb.poll_failures) parts.push(`${hb.poll_failures} failed poll${hb.poll_failures > 1 ? "s" : ""} in a row`);
  return parts.join(", ");
}

// The runs of one series with what the chart marks on them.
export function history(runs, series) {
  const rows = runs.filter((r) => r.series === series);
  const firstType = new Map();
  const seen = new Set();
  return rows.map((r) => {
    const type = r.box.instance_type;
    const isNew = seen.size > 0 && !seen.has(type);
    seen.add(type);
    if (r.pairing_id && !firstType.has(r.pairing_id)) firstType.set(r.pairing_id, type);
    return {
      ...r,
      box_change: isNew ? type : null,
      incoming: Boolean(r.pairing_id) && firstType.get(r.pairing_id) !== r.box.instance_type,
    };
  });
}

// For each pairing with counting runs on two instance types, the median of
// each type's run medians and their ratio, the incoming type over the first.
// A pairing compares its two instance types at the largest run size both ran,
// so a short run that ends inside the faster box's start-up burst does not
// skew the offset. A pairing with no size in common gets no offset.
export function pairedOffsets(runs) {
  const pairs = new Map();
  for (const r of runs) {
    if (!r.pairing_id || !counts(r) || r.median_bytes_per_s == null) continue;
    if (!pairs.has(r.pairing_id)) pairs.set(r.pairing_id, new Map());
    const types = pairs.get(r.pairing_id);
    if (!types.has(r.box.instance_type)) types.set(r.box.instance_type, []);
    types.get(r.box.instance_type).push(r);
  }
  const sizeOf = (r) => r.size_bytes ?? null;
  const out = [];
  for (const [pairing_id, types] of pairs) {
    if (types.size !== 2) continue;
    const [[from, a], [to, b]] = [...types];
    const fromSizes = new Set(a.map(sizeOf));
    const shared = [...new Set(b.map(sizeOf))].filter((s) => fromSizes.has(s));
    if (!shared.length) continue;
    const known = shared.filter((s) => s != null);
    const size = known.length ? Math.max(...known) : null;
    const at = (rs) => rs.filter((r) => sizeOf(r) === size).map((r) => r.median_bytes_per_s);
    const fromMedians = at(a), toMedians = at(b);
    const fromMedian = median(fromMedians), toMedian = median(toMedians);
    out.push({ pairing_id, from, to, size_bytes: size, from_median: fromMedian, to_median: toMedian,
               from_runs: fromMedians.length, to_runs: toMedians.length, ratio: toMedian / fromMedian });
  }
  return out;
}

function median(values) {
  const v = [...values].sort((x, y) => x - y), m = v.length >> 1;
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
}

// An instrument marker goes on a run whose instrument changed, except where
// the only change is the box fingerprint alternating between paired boxes or
// at a box change, which has its own marker.
export function instrumentMarker(run) {
  const c = run.instrument_changes || [];
  if (c.some((x) => x !== "box")) return true;
  return c.includes("box") && !run.pairing_id && !run.box_change;
}

// The latest earlier run in the same series on the same box, any class.
export function previousRun(runs, run) {
  let found = null;
  for (const r of runs) {
    if (r.run_id === run.run_id) break;
    if (r.series === run.series && r.box.id === run.box.id) found = r;
  }
  return found;
}

// An experiment's run: the pull request it tested, which of its two sets it
// ran (main's, or main's with the pull request's image), and the other runs
// of its pairing. Null for any other run.
export function experimentNote(runs, run) {
  const e = run.experiment;
  if (!e) return null;
  const source = `https://github.com/${e.repository}`;
  return {
    label: `${e.service} #${e.pr}`, pr_url: `${source}/pull/${e.pr}`,
    commit: e.commit.slice(0, 7), commit_url: `${source}/commit/${e.commit}`, role: e.role,
    paired: runs.filter((r) => r.pairing_id === run.pairing_id && r.run_id !== run.run_id)
      .map((r) => ({ run_id: r.run_id, role: r.experiment ? r.experiment.role : null })),
  };
}

export function changesText(run) {
  const parts = [...(run.changed || [])];
  if (run.instrument_changes && run.instrument_changes.length) {
    parts.push(`instrument: ${run.instrument_changes.join(", ")}`);
  }
  return parts.join(", ");
}

// Flags the runs table and details view name beside the outcome; they leave
// the class alone.
const FLAG_TEXT = {
  cap_not_reached: "stopped at its time limit before its size",
  few_windows: "under 20 steady windows",
  cpu_capped: "CPU capped (check run)",
  traced: "traced",
  trace_missing: "trace file missing",
};
export function flagText(run) {
  return (run.flags || []).filter((f) => FLAG_TEXT[f]).map((f) => FLAG_TEXT[f]).join(", ");
}

// The Grafana stack a traced run's spans go to, and its Tempo data source.
// docs/grafana/forge-perf.json names the same data source.
export const GRAFANA = "https://filecoinfoundation.grafana.net";
export const TEMPO_UID = "grafanacloud-traces";
const TRACE_MARGIN_MS = 5 * 60 * 1000;

// A traced run's spans in Grafana Explore: a TraceQL search for its run ID
// from five minutes before its start to five minutes after its finish.
// Null for an untraced run, and for a traced run whose trace file was
// missing, since none of its spans reached Tempo.
export function traceLink(run) {
  const flags = run.flags || [];
  if (!flags.includes("traced") || flags.includes("trace_missing")) return null;
  if (!run.run_started_at || !run.run_finished_at) return null;
  const pane = {
    datasource: TEMPO_UID,
    queries: [{ refId: "A", datasource: { type: "tempo", uid: TEMPO_UID }, queryType: "traceql",
      query: `{ resource.forge_perf.run_id = "${run.run_id}" }`, limit: 20 }],
    range: { from: String(Date.parse(run.run_started_at) - TRACE_MARGIN_MS),
      to: String(Date.parse(run.run_finished_at) + TRACE_MARGIN_MS) },
  };
  return `${GRAFANA}/explore?schemaVersion=1&orgId=1&panes=${encodeURIComponent(JSON.stringify({ a: pane }))}`;
}

export function outcomeText(run) {
  if (run.override) return `Marked ${CLASS_LABEL[run.klass].toLowerCase()} after review`;
  return CLASS_LABEL[run.klass] || run.klass;
}

// Compare link or note for one component against the previous run's.
export function compare(source, cur, prev) {
  if (!prev || !cur) return null;
  if (cur === prev) return { text: "same as previous" };
  return source ? { text: "compare", href: `${source}/compare/${prev}...${cur}` } : { text: `previous ${prev}` };
}
