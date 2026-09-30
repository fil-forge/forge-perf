// Renders data/index.json: thermometer, headline, history chart, runs table
// and the details view at #run=<run_id>. Plot and d3 come from vendor/.
import * as M from "./model.js";

const REPO = "https://github.com/fil-forge/forge-perf";
const SMELT = "https://github.com/fil-forge/smelt";
const $ = (sel) => document.querySelector(sel);
const state = { data: null, series: "per-trigger", shown: 50, now: Date.now() };

function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k.startsWith("aria-") && typeof v === "boolean") { el.setAttribute(k, String(v)); continue; }
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid);
  return el;
}

function svg(tag, attrs = {}, text) {
  const el = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  if (text != null) el.textContent = text;
  return el;
}

const utc = (iso) => new Date(iso).toLocaleString("en-GB", {
  day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "UTC",
}) + " UTC";
const day = (iso) => new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const rate = (bytes) => (bytes == null ? "–" : `${M.gbps(bytes)} GB/s`);
const gb = (bytes) => (bytes == null ? "–" : `${Math.round(bytes / 1e9)} GB`);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const ICON = { valid: "●", availability_warning: "▲", invalid: "○", failed: "✕", no_data: "✕" };
const outcome = (run) => h("span", { class: `outcome ${run.klass}` },
  h("span", { class: "icon", "aria-hidden": "true" }, ICON[run.klass]), " ", M.outcomeText(run),
  M.flagText(run) ? h("span", { class: "secondary" }, ` · ${M.flagText(run)}`) : null);
// A traced run's link to its spans, or null.
const traces = (run) => {
  const href = M.traceLink(run);
  return href && h("span", {}, h("a", { href }, "Traces in Grafana"),
    h("span", { class: "secondary" }, " (needs a Grafana login)"));
};

// Theme: light, dark or system, remembered when storage allows.
function setTheme(choice) {
  if (choice === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", choice);
  for (const b of document.querySelectorAll("#theme button")) b.setAttribute("aria-pressed", String(b.value === choice));
  try { localStorage.setItem("theme", choice); } catch { /* storage unavailable */ }
  if (state.data) drawHistory();
}

function thermometer({ gates, lit, merc, top }) {
  const Y0 = 404;
  const unmeasured = gates.filter((g) => !g.current);
  const Y1 = 24 + 44 * unmeasured.length;
  const y = (v) => Y0 - (Math.min(v, top) / top) * (Y0 - Y1);
  const desc = [merc ? `p5 ${M.gbps(merc.run.p5_bytes_per_s)} GB/s, median ${M.gbps(merc.run.median_bytes_per_s)} GB/s.` : "No valid per-trigger or nightly run yet."];
  const root = svg("svg", { viewBox: "0 0 240 480", role: "img", class: "thermo" });
  root.append(svg("title", {}, "Ingest rate against three hardware gates"));
  const d = svg("desc");
  root.append(d);
  root.append(svg("rect", { x: 50, y: 14, width: 28, height: 410, rx: 14, class: "tube" }));
  root.append(svg("circle", { cx: 64, cy: 440, r: 24, class: "bulb" }));
  if (merc) {
    const top = y(merc.run.p5_bytes_per_s);
    root.append(svg("rect", { x: 56, y: top, width: 16, height: 432 - top, rx: 4, class: "mercury" }));
    const my = y(merc.run.median_bytes_per_s);
    root.append(svg("path", { d: `M50 ${my} l-8 -5 v10 z`, class: "median" }));
    root.append(svg("text", { x: 39, y: my - 2, "text-anchor": "end", class: "label secondary" }, "median"));
    root.append(svg("text", { x: 39, y: my + 11, "text-anchor": "end", class: "label secondary" }, M.gbps(merc.run.median_bytes_per_s)));
  }
  // Labels keep 34 px apart, pushed down from the top.
  const marks = gates.map((g, i) => ({ g, l: lit[i], y: g.current ? y(g.current.ceiling_bytes_per_s) : 24 + 44 * unmeasured.indexOf(g) + 22 }));
  let floor = -Infinity;
  for (const m of [...marks].sort((a, b) => a.y - b.y)) { m.ly = Math.max(m.y, floor + 34); floor = m.ly; }
  for (const m of marks) {
    const value = m.g.current ? `${M.gbps(m.g.current.ceiling_bytes_per_s)} GB/s` : "not measured yet";
    root.append(svg("line", { x1: 46, x2: 82, y1: m.y, y2: m.y, class: m.g.current ? "gate" : "gate unmeasured" }));
    if (m.ly !== m.y) root.append(svg("line", { x1: 82, x2: 90, y1: m.y, y2: m.ly - 4, class: "leader" }));
    root.append(svg("circle", { cx: 97, cy: m.ly - 4, r: 6, class: m.l.run ? "lit" : "unlit" }));
    if (m.l.run) root.append(svg("path", { d: `M94 ${m.ly - 4} l2 2.5 l4 -5`, class: "check" }));
    const [first, second] = m.g.current ? [`Gate ${m.g.gate} · ${value}`, m.l.run ? `${m.g.instance_type} · reached` : m.g.instance_type]
      : [`Gate ${m.g.gate} · ${m.g.instance_type}`, value];
    root.append(svg("text", { x: 107, y: m.ly, class: "label" }, first));
    root.append(svg("text", { x: 107, y: m.ly + 14, class: "label secondary" }, second));
    desc.push(`Gate ${m.g.gate}, ${m.g.instance_type}, ${value}, ${m.l.run ? "reached" : "not reached"}.`);
  }
  d.textContent = desc.join(" ");
  return root;
}

function headline({ runs, merc, gates, lit, heartbeats, published_at }) {
  const box = h("div", { class: "headline" });
  if (merc) {
    const r = merc.run, tl = traces(r);
    box.append(
      h("p", { class: "big" }, `${M.gbps(r.p5_bytes_per_s)} GB/s held by 95% of windows`),
      h("p", {}, `Median ${M.gbps(r.median_bytes_per_s)} GB/s · ${M.perSecond(r.writes_median_per_s)} writes/s`
        + (r.flags.includes("few_windows") ? ` · p5 over ${r.sustained_windows} windows` : "")),
      h("p", { class: "secondary" }, "Run ", h("a", { href: `#run=${r.run_id}` }, r.run_id),
        ` on ${r.box.instance_type}, ${utc(r.run_started_at)}, ${gb(r.size_bytes)}`),
      ...(tl ? [h("p", { class: "secondary" }, tl)] : []),
      h("p", { class: "secondary" }, `${M.ago(merc.age_ms)} ago · ${merc.runs_since} run${merc.runs_since === 1 ? "" : "s"} on the box since`));
  } else {
    box.append(h("p", { class: "big" }, "No valid per-trigger or nightly run yet"));
    const other = M.latestCounting(runs);
    if (other) {
      box.append(h("p", {}, "Latest valid run ", h("a", { href: `#run=${other.run_id}` }, other.run_id),
        ` (${other.series}, ${other.box.instance_type}): p5 ${M.gbps(other.p5_bytes_per_s)} GB/s. `
        + `The thermometer moves on per-trigger and nightly runs on box ${M.PERSISTENT_BOX}.`));
    }
    const last = runs[runs.length - 1];
    box.append(last
      ? h("p", {}, "Latest run ", h("a", { href: `#run=${last.run_id}` }, last.run_id), ` (${last.series}): `,
        outcome(last), last.reasons.length ? `, ${last.reasons.join(", ")}` : "",
        last.series === "calibration" ? ". Calibration runs do not move the thermometer." : "",
        last.series === "experiment" ? ". Experiment runs do not move the thermometer." : "")
      : h("p", {}, "No runs have been published."));
  }
  box.append(h("ul", { class: "gates" }, gates.map((g, i) => {
    const l = lit[i];
    if (!g.current) return h("li", {}, `Gate ${g.gate}, ${g.instance_type} ceiling: not measured yet`);
    const head = `Gate ${g.gate}, ${g.instance_type} ceiling, ${M.gbps(g.current.ceiling_bytes_per_s)} GB/s: `;
    const method = [" (", h("a", { href: `${REPO}/blob/main/${g.current.method}` }, "method"), ")"];
    if (!l.run) return h("li", {}, head + "not yet reached", method);
    return h("li", {}, head + `reached ${day(l.run.run_started_at)} (run `, h("a", { href: `#run=${l.run.run_id}` }, l.run.run_id),
      `) against ${M.gbps(l.ceiling.ceiling_bytes_per_s)} GB/s measured ${day(l.ceiling.measured_at)}`, method);
  })));
  const hb = heartbeats ? heartbeats[M.PERSISTENT_BOX] : undefined;
  box.append(h("p", { class: "status" },
    published_at ? `Last published ${utc(published_at)}` : "Not published yet",
    ` · Box ${M.PERSISTENT_BOX}: ${M.heartbeatLine(hb, state.now)}`));
  return box;
}

function drawHistory() {
  const host = $("#chart");
  host.replaceChildren();
  const series = M.SERIES.find((s) => s.id === state.series);
  const rows = M.history(state.data.runs, series.id).map((r) => ({ ...r, x: new Date(r.run_started_at) }));
  if (!rows.length) { host.append(h("p", { class: "empty" }, `No ${series.label.toLowerCase()} runs yet.`)); return; }
  const color = css(`--series-${series.slot}`), muted = css("--text-muted"), second = css("--text-secondary");
  const surface = css("--surface-1"), grid = css("--chart-grid");
  const joined = rows.filter((r) => ["valid", "availability_warning"].includes(r.klass) && r.p5_bytes_per_s != null);
  const plotted = rows.filter((r) => r.p5_bytes_per_s != null && !["failed", "no_data"].includes(r.klass));
  const strip = rows.filter((r) => ["failed", "no_data"].includes(r.klass));
  const measured = state.data.gates.filter((g) => g.current).map((g) => g.current.ceiling_bytes_per_s / 1e9);
  // With nothing plotted, a readable range: up to the lowest measured gate, or 1 GB/s.
  const max = plotted.length ? Math.max(...plotted.map((r) => r.p5_bytes_per_s / 1e9), ...plotted.map((r) => (r.median_bytes_per_s ?? 0) / 1e9), 1e-3)
    : (measured.length ? Math.min(...measured) : 1) / 1.15;
  const shown = [], above = [];
  for (const g of state.data.gates.filter((g) => g.current)) {
    (g.current.ceiling_bytes_per_s / 1e9 <= 1.3 * max ? shown : above).push(g);
  }
  const width = host.clientWidth || 640;
  const tip = (r) => [r.run_id, utc(r.run_started_at), `p5 ${M.gbps(r.p5_bytes_per_s)} GB/s`,
    `median ${M.gbps(r.median_bytes_per_s)} GB/s`, `${r.sustained_windows ?? 0} windows`, M.outcomeText(r), "Click to open details"].join("\n");
  const changes = rows.filter((r) => M.instrumentMarker(r));
  const boxes = rows.filter((r) => r.box_change);
  const x = { type: "utc", domain: [rows[0].x, rows[rows.length - 1].x], nice: rows.length > 1, label: null };
  if (rows.length === 1) x.domain = [new Date(+rows[0].x - 43200e3), new Date(+rows[0].x + 43200e3)];
  const last = joined[joined.length - 1];
  const chart = Plot.plot({
    width, height: width < 480 ? 240 : 320, marginRight: 70, marginTop: 24, marginBottom: strip.length ? 52 : 30, x,
    y: { domain: [0, max * 1.15], grid: true, label: "GB/s", ticks: 5 },
    style: { background: "transparent", color: second, fontSize: "12px" },
    marks: [
      Plot.gridY({ stroke: grid, strokeOpacity: 1, ticks: 5 }),
      Plot.ruleY(shown, { y: (g) => g.current.ceiling_bytes_per_s / 1e9, stroke: muted, strokeDasharray: "4,3" }),
      Plot.text(shown, { y: (g) => g.current.ceiling_bytes_per_s / 1e9, frameAnchor: "left", dx: 4, dy: -7, textAnchor: "start",
        text: (g) => `Gate ${g.gate} · ${g.instance_type}`, fill: muted }),
      Plot.ruleX(changes, { x: "x", stroke: muted, strokeDasharray: "1,3", title: (r) => `Instrument changed: ${r.instrument_changes.join(", ")}` }),
      Plot.text(spaced(changes, x.domain, width), { x: "x", frameAnchor: "top", dy: -12, text: () => "instrument", fill: muted }),
      Plot.ruleX(boxes, { x: "x", stroke: second, strokeWidth: 2 }),
      Plot.text(boxes, { x: "x", frameAnchor: "top", dy: -12, dx: 4, textAnchor: "start", text: "box_change", fill: second }),
      Plot.line(joined, { x: "x", z: (r) => r.box.instance_type, y: (r) => r.median_bytes_per_s / 1e9, stroke: color, strokeWidth: 2, strokeDasharray: "5,4" }),
      Plot.line(joined, { x: "x", z: (r) => r.box.instance_type, y: (r) => r.p5_bytes_per_s / 1e9, stroke: color, strokeWidth: 2 }),
      Plot.dot(plotted, {
        x: "x", y: (r) => r.p5_bytes_per_s / 1e9, r: 4.5,
        symbol: (r) => (r.klass === "availability_warning" ? "triangle" : "circle"),
        fill: (r) => (r.klass === "invalid" ? "none" : color), stroke: (r) => (r.klass === "invalid" ? muted : r.incoming ? surface : color),
        strokeWidth: (r) => (r.incoming ? 2 : 1.5),
      }),
      Plot.dot(strip, { x: "x", frameAnchor: "bottom", dy: 42, symbol: "times", r: 4,
        stroke: (r) => (r.klass === "failed" ? css("--status-critical") : muted), strokeWidth: 2 }),
      last && Plot.text([last], { x: "x", y: (r) => r.p5_bytes_per_s / 1e9, text: () => "p5", dx: 8, textAnchor: "start", fill: css("--text-primary") }),
      last && Plot.text([last], { x: "x", y: (r) => r.median_bytes_per_s / 1e9, text: () => "Median", dx: 8, textAnchor: "start", fill: css("--text-primary") }),
      Plot.tip(rows.filter((r) => r.p5_bytes_per_s != null || strip.includes(r)), Plot.pointerX({
        x: "x", y: (r) => (strip.includes(r) ? 0 : r.p5_bytes_per_s / 1e9), title: tip, fill: surface, stroke: grid })),
    ].filter(Boolean),
  });
  chart.setAttribute("aria-label", `${series.label} history: p5 and median ingest rate per run. The runs table below lists the same runs.`);
  chart.addEventListener("click", () => { if (chart.value) location.hash = `run=${chart.value.run_id}`; });
  host.append(chart);
  if (strip.length) host.append(h("p", { class: "note" }, "✕ below the time axis: failed and no-data runs, whose rates are absent or untrustworthy."));
  for (const o of M.pairedOffsets(rows)) {
    host.append(h("p", { class: "note" }, `Paired runs ${o.pairing_id}${o.size_bytes != null ? ` at ${gb(o.size_bytes)}` : ""}: median ${M.gbps(o.to_median)} GB/s on ${o.to} `
      + `(${o.to_runs} run${o.to_runs === 1 ? "" : "s"}) against ${M.gbps(o.from_median)} GB/s on ${o.from} `
      + `(${o.from_runs} run${o.from_runs === 1 ? "" : "s"}), ${o.ratio.toFixed(2)}×.`));
  }
  if (above.length) host.append(h("p", { class: "note" }, above.map((g) => `Gate ${g.gate} (${M.gbps(g.current.ceiling_bytes_per_s)} GB/s) above range`).join(" · ")));
}

// Marker labels at least 80 px apart, so neighbouring changes keep their rules
// without their labels running together; the tooltip still lists each one.
function spaced(rows, [t0, t1], width) {
  let last = -Infinity;
  return rows.filter((r) => {
    const px = ((r.x - t0) / (t1 - t0 || 1)) * width;
    if (px - last < 80) return false;
    last = px;
    return true;
  });
}

// An experiment's pull request, the set the run ran, and links to the other
// runs of its pairing.
function experimentCell(note) {
  return h("span", {}, h("a", { href: note.pr_url }, note.label), ` · ${note.role} at `,
    h("a", { href: note.commit_url }, h("code", {}, note.commit)),
    note.paired.length ? [" · paired with ", ...note.paired.flatMap((p, i) =>
      [i ? ", " : "", h("a", { href: `#run=${p.run_id}` }, p.role || p.run_id)])] : "");
}

function table() {
  const runs = [...state.data.runs].reverse();
  const head = ["Started (UTC)", "Series", "Box", "Outcome", "p5 GB/s", "Median GB/s", "Writes/s", "Windows", "RTT ms", "Changes"];
  const body = h("tbody");
  for (const r of runs.slice(0, state.shown)) {
    const cells = [
      h("a", { href: `#run=${r.run_id}` }, utc(r.run_started_at).replace(" UTC", "")), r.series,
      `${r.box.id} · ${r.box.instance_type}`, outcome(r), M.gbps(r.p5_bytes_per_s), M.gbps(r.median_bytes_per_s),
      M.perSecond(r.writes_median_per_s), r.sustained_windows ?? "–", r.rtt_median_ms ?? "–",
      r.experiment ? experimentCell(M.experimentNote(state.data.runs, r)) : M.changesText(r) || "–",
    ];
    body.append(h("tr", { onclick: (e) => { if (e.target.tagName !== "A") location.hash = `run=${r.run_id}`; } },
      cells.map((c, i) => h("td", { "data-label": head[i] }, c))));
  }
  const el = h("div", {}, h("table", {}, h("thead", {}, h("tr", {}, head.map((c) => h("th", { scope: "col" }, c)))), body));
  if (!runs.length) el.replaceChildren(h("p", { class: "empty" }, "No runs have been published."));
  if (runs.length > state.shown) {
    el.append(h("button", { type: "button", onclick: () => {
      const next = state.shown;
      state.shown += 50;
      $("#runs").replaceChildren(table());
      $(`#runs tbody tr:nth-child(${next + 1}) a`)?.focus();
    } }, "Show 50 more"));
  }
  return el;
}

function kv(title, obj, missing) {
  if (obj == null) return h("section", {}, h("h3", {}, title), h("p", {}, missing || "Not recorded."));
  const rows = Object.entries(obj).map(([k, v]) => h("tr", {}, h("th", { scope: "row" }, k.replaceAll("_", " ")),
    h("td", {}, v == null ? "–" : typeof v === "boolean" ? String(v) : typeof v === "object" && !(v instanceof Node) ? JSON.stringify(v) : v)));
  return h("section", {}, h("h3", {}, title), h("table", { class: "kv" }, h("tbody", {}, rows)));
}

async function details(id) {
  const panel = $("#details");
  const run = state.data.runs.find((r) => r.run_id === id);
  if (!run) { panel.hidden = true; return; }
  const prevRow = M.previousRun(state.data.runs, run);
  const get = (rid) => fetch(`data/runs/${rid}.json`).then((res) => (res.ok ? res.json() : null)).catch(() => null);
  const [rec, prev] = await Promise.all([get(id), prevRow ? get(prevRow.run_id) : null]);
  // Closed, or another run opened, while the records loaded.
  if (location.hash !== `#run=${id}`) return;
  panel.replaceChildren(h("div", { class: "details-head" },
    h("h2", { tabindex: "-1" }, `Run ${id}`), h("a", { href: "#", class: "close" }, "Close")));
  panel.hidden = false;
  if (!rec) { panel.append(h("p", {}, "The record could not be loaded.")); panel.querySelector("h2").focus(); return; }
  const t = rec.time, res = rec.drill.results || {}, o = rec.outcome;
  const dur = Math.round((Date.parse(t.run_finished_at) - Date.parse(t.run_started_at)) / 60000);
  const tl = traces(run);
  panel.append(
    kv("Summary", { class: outcome(run), override: run.override ? h("a", { href: run.override.issue }, run.override.issue) : null,
      reasons: o.reasons.join(", ") || "none", restarted_services: (o.restarted_services || []).join(", ") || "none",
      flags: o.flags.join(", ") || "none", series: rec.series, pairing: rec.pairing_id,
      trigger: `${rec.trigger.reason}${rec.trigger.changed?.length ? `: ${rec.trigger.changed.join(", ")}` : ""}`,
      started: utc(t.run_started_at), stack_up: t.stack_up_at && utc(t.stack_up_at),
      drill_started: t.drill_started_at && utc(t.drill_started_at), drill_finished: t.drill_finished_at && utc(t.drill_finished_at),
      finished: utc(t.run_finished_at), duration: `${dur} min`, ...(tl ? { traces: tl } : {}),
      previous_run: prevRow ? h("a", { href: `#run=${prevRow.run_id}` }, prevRow.run_id) : "none" }),
    ...experimentSection(run),
    kv("Rates", { p5: rate(res.ingest_p5_bytes_per_s), median: rate(res.ingest_median_bytes_per_s),
      writes_per_s: res.writes_median_per_s == null ? null : M.perSecond(res.writes_median_per_s), steady_windows: res.sustained_windows, total_windows: res.total_windows,
      cap_reached: res.cap_reached, ingest_cutoff_s: res.ingest_cutoff_s, bytes_ingested: res.bytes_ingested, ingest_sent_bytes: res.ingest_sent_bytes,
      bytes_read_back: res.bytes_read_back, bytes_restored: res.bytes_restored, blobs_written: res.blobs_written,
      window_rates: res.window_ingest_bytes_per_s && h("details", {}, h("summary", {}, `${res.window_ingest_bytes_per_s.length} windows, GB/s`),
        res.window_ingest_bytes_per_s.map(M.gbps).join(" ")) }),
    h("section", {}, h("h3", {}, "Cache-served rates"),
      h("p", {}, "Read-back runs 30 to 60 seconds after each write, so these rates mostly measure the spool and page cache."),
      kv("", { read_back_median: rate(res.cache_served?.read_back_median_bytes_per_s),
        restore_median: rate(res.cache_served?.restore_median_bytes_per_s) }).querySelector("table")),
    kv("Requests", { ...(rec.drill.requests || {}), drill_exit: o.drill_exit, failure_codes: o.failure_codes.join(", ") || "none" }),
    kv("Drill settings", rec.drill.settings, "Not recorded: the settings file was missing or unreadable."),
    kv("Latency", Object.fromEntries(Object.entries(rec.latency).filter(([k]) => !["before", "after"].includes(k)))),
    kv("Latency before", rec.latency.before || {}), kv("Latency after", rec.latency.after || {}),
    kv("NIC allowance counters", { ...rec.network.allowance_exceeded, egress_median: rate(rec.network.egress_bytes_per_s_median),
      seconds_above_baseline: rec.network.seconds_above_baseline }),
    kv("Box", { ...rec.box, cpu: `${rec.box.cpu.implementer ?? "–"} / ${rec.box.cpu.part ?? "–"}, ${rec.box.cpu.cores} cores`,
      cpu_features: h("details", {}, h("summary", {}, `${rec.box.cpu.features.length} features`), rec.box.cpu.features.join(" ")),
      nvme: `${rec.box.nvme.model ?? "–"}, ${gb(rec.box.nvme.size_bytes)}, ${rec.box.nvme.filesystem ?? "–"}` }),
    components(rec, prev),
    kv("Fingerprints", {
      instrument: fingerprint(rec.instrument.fingerprint, prev?.instrument.fingerprint),
      box: fingerprint(rec.instrument.box_fingerprint, prev?.instrument.box_fingerprint),
      instrument_tree: mono(rec.provenance.forge_perf.instrument_tree ?? "–"),
      raw_record: h("a", { href: `data/runs/${id}.json` }, `${id}.json`) }));
  panel.querySelector("h2").focus();
}

// The pull request an experiment's run tested, and the set it ran; nothing
// for any other run.
function experimentSection(run) {
  const note = M.experimentNote(state.data.runs, run);
  if (!note) return [];
  return [kv("Experiment", {
    pull_request: h("a", { href: note.pr_url }, `${run.experiment.repository}#${run.experiment.pr}`),
    commit: h("a", { href: note.commit_url }, mono(run.experiment.commit)),
    set: note.role === "branch" ? `main's, with the pull request's ${run.experiment.service} image` : "main's",
    request: mono(run.experiment.request_id), pairing: run.pairing_id,
    paired_runs: note.paired.length ? h("span", {}, note.paired.flatMap((p, i) =>
      [i ? ", " : "", h("a", { href: `#run=${p.run_id}` }, p.run_id), p.role ? ` (${p.role})` : ""])) : "none yet",
  })];
}

const mono = (s) => h("code", {}, s);
function fingerprint(cur, prev) {
  return h("span", {}, mono(cur), prev && prev !== cur ? h("span", { class: "badge" }, "changed") : null);
}

function link(c) { return c ? (c.href ? h("a", { href: c.href }, c.text) : c.text) : ""; }

function components(rec, prev) {
  const p = rec.provenance, pp = prev?.provenance;
  const rows = [
    ["forge-perf", "instrument", p.forge_perf.sha, "", M.compare(REPO, p.forge_perf.sha, pp?.forge_perf.sha)],
    ["smelt", "instrument", p.smelt.sha, "", M.compare(SMELT, p.smelt.sha, pp?.smelt.sha)],
    ["harness", "instrument", p.harness.sha, p.harness.binary_sha256 ? `sha256:${p.harness.binary_sha256}` : "",
      `private repository · ${p.harness.go_version ?? "go unknown"}${p.harness.modified ? " · modified checkout" : ""}`],
    ...p.images.map((i) => {
      const old = pp?.images.find((j) => j.repo === i.repo);
      const c = i.role === "under_test" ? M.compare(i.source, i.revision, old?.revision)
        : old && old.digest !== i.digest ? { text: `previous ${old.digest}` } : M.compare(null, i.digest, old?.digest);
      return [h("span", {}, i.repo, h("br"), h("span", { class: "secondary" }, `${i.ref} · ${(i.services || []).join(", ")}`)),
        i.role.replace("_", " "), i.revision || "–", i.digest, c];
    }),
  ];
  return h("section", {}, h("h3", {}, "Components"), h("table", { class: "components" },
    h("thead", {}, h("tr", {}, ["Name", "Role", "Revision", "Digest", ""].map((c) => h("th", { scope: "col" }, c)))),
    h("tbody", {}, rows.map(([name, role, rev, digest, c]) => h("tr", {},
      h("td", {}, name), h("td", {}, role), h("td", {}, mono(rev)), h("td", {}, digest ? mono(digest) : "–"),
      h("td", {}, typeof c === "string" ? c : link(c)))))));
}

function route() {
  const m = location.hash.match(/^#run=([a-z0-9-]+)$/);
  if (m) details(m[1]);
  else $("#details").hidden = true;
}

async function main() {
  let stored = "system";
  try { stored = localStorage.getItem("theme") || "system"; } catch { /* storage unavailable */ }
  for (const b of document.querySelectorAll("#theme button")) b.addEventListener("click", () => setTheme(b.value));
  setTheme(stored);
  // "System" follows the OS; the chart reads its colors when drawn.
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (state.data && !document.documentElement.hasAttribute("data-theme")) drawHistory();
  });
  const tabs = $("#series");
  for (const s of M.SERIES) {
    tabs.append(h("button", { type: "button", value: s.id, "aria-pressed": s.id === state.series,
      onclick: () => { state.series = s.id; for (const b of tabs.children) b.setAttribute("aria-pressed", String(b.value === s.id)); drawHistory(); } }, s.label));
  }
  try {
    const res = await fetch("data/index.json", { cache: "no-cache" });
    if (!res.ok) throw new Error(res.status);
    state.data = M.prepare(await res.json());
  } catch {
    $("#summary").replaceChildren(h("p", { class: "big" }, "The run data could not be loaded."));
    return;
  }
  const d = state.data;
  const merc = M.mercury(d.runs, state.now);
  const lit = M.litGates(d.runs, d.gates);
  const view = { ...d, merc, lit, top: M.scaleTop(d.gates, merc) };
  $("#summary").replaceChildren(h("div", { class: "thermo-wrap" }, thermometer(view)), headline(view));
  // The history opens on the series of the run the mercury shows.
  if (merc) {
    state.series = merc.run.series;
    for (const b of tabs.children) b.setAttribute("aria-pressed", String(b.value === state.series));
  }
  drawHistory();
  $("#runs").replaceChildren(table());
  let width = 0;
  new ResizeObserver(([e]) => {
    if (Math.round(e.contentRect.width) !== width) { width = Math.round(e.contentRect.width); drawHistory(); }
  }).observe($("#chart"));
  window.addEventListener("hashchange", route);
  route();
}

main();
