#!/usr/bin/env python3
"""Renders bench/history/log.json (+ the per-round results files next to it)
into docs/optimization-log.html: the research log of the Rust-vs-Mojo hill
climb, with charts. Run after every round:

    python3 bench/build_log.py
"""

import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
HISTORY = HERE / "history"
OUT = HERE.parent / "docs" / "optimization-log.html"

MAPS = ["SlotMap", "HopSlotMap", "DenseSlotMap", "SecondaryMap", "SparseSecondaryMap"]
OPS = ["insert", "get", "remove", "iter_half", "iter", "reinsert"]


def load():
    log = json.loads((HISTORY / "log.json").read_text())
    for r in log["rounds"]:
        rows = []
        if r.get("results"):
            data = json.loads((HISTORY / r["results"]).read_text())
            r["env"] = data.get("env", {})
            for row in data["results"]:
                if row["rust_ns_per_elem"] and row["mojo_ns_per_elem"]:
                    rows.append([row["map"], row["op"], row["n"],
                                 round(row["rust_ns_per_elem"], 3),
                                 round(row["mojo_ns_per_elem"], 3)])
        rows.sort(key=lambda x: (MAPS.index(x[0]), OPS.index(x[1]), x[2]))
        r["rows"] = rows
    return log


TEMPLATE = r"""<title>__TITLE__</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root {
  --plane: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --rule: #e1e0d9;
  --accent: #2a78d6; --accent-ink: #1c5cab;
  --good: #0ca30c; --serious: #ec835a; --critical: #d03b3b; --warn: #fab219;
  --chip-kept: #e3f3e3; --chip-reverted: #fbe4e4; --chip-none: #ecebe6; --chip-todo: #fdf1d6;
  --sans: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
  --mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --plane: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --rule: #2c2c2a;
    --accent: #3987e5; --accent-ink: #86b6ef;
    --chip-kept: #163a16; --chip-reverted: #4a1c1c; --chip-none: #2c2c2a; --chip-todo: #4a3a10;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --plane: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
  --grid: #2c2c2a; --axis: #383835; --rule: #2c2c2a;
  --accent: #3987e5; --accent-ink: #86b6ef;
  --chip-kept: #163a16; --chip-reverted: #4a1c1c; --chip-none: #2c2c2a; --chip-todo: #4a3a10;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--plane); color: var(--ink); font-family: var(--sans); font-size: 15px; line-height: 1.55; }
.wrap { max-width: 980px; margin: 0 auto; padding-block: 32px 64px; padding-inline: 20px; }
h1, h2, h3 { text-wrap: balance; line-height: 1.15; margin: 0; }
h1 { font-size: clamp(30px, 5vw, 44px); font-weight: 700; letter-spacing: -0.02em; }
h2 { font-size: 22px; font-weight: 600; margin-top: 56px; padding-top: 16px; border-top: 1px solid var(--rule); }
h3 { font-size: 16px; font-weight: 600; }
p { margin: 0; max-width: 68ch; }
a { color: var(--accent-ink); }
.eyebrow { font-family: var(--mono); font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
.lede { color: var(--ink-2); margin-top: 12px; }
.meta { display: flex; flex-wrap: wrap; gap: 8px 20px; margin-top: 14px; font-family: var(--mono); font-size: 12.5px; color: var(--ink-2); }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-top: 28px; }
.tile { background: var(--surface); border: 1px solid var(--rule); border-radius: 6px; padding: 14px 16px; }
.tile .k { font-family: var(--mono); font-size: 11.5px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
.tile .v { font-family: var(--mono); font-size: 28px; font-weight: 500; margin-top: 4px; font-variant-numeric: tabular-nums; }
.tile .s { font-size: 12.5px; color: var(--ink-2); margin-top: 2px; }
.controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 18px 0 10px; }
.controls .lbl { font-family: var(--mono); font-size: 12px; color: var(--muted); margin-right: 4px; }
button.pill { font: inherit; font-size: 13px; font-family: var(--mono); padding: 5px 11px; border-radius: 999px; border: 1px solid var(--axis); background: var(--surface); color: var(--ink); cursor: pointer; }
button.pill[aria-pressed="true"] { background: var(--accent); border-color: var(--accent); color: #fff; }
button.pill:focus-visible, a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 16px; font-size: 12.5px; color: var(--ink-2); margin: 6px 0 10px; }
.legend span::before { content: ""; display: inline-block; width: 12px; height: 12px; border-radius: 3px; margin-right: 6px; vertical-align: -1px; background: var(--c); }
.chart { background: var(--surface); border: 1px solid var(--rule); border-radius: 6px; padding: 10px 6px 4px; overflow-x: auto; }
.chart svg { display: block; width: 100%; height: auto; font-family: var(--mono); font-size: 12px; }
.chart .bar { transition: opacity .12s; }
.chart .row:hover .bar { opacity: .82; }
.tip { position: fixed; z-index: 5; pointer-events: none; background: var(--ink); color: var(--plane); font-family: var(--mono); font-size: 12px; padding: 6px 9px; border-radius: 4px; white-space: nowrap; display: none; }
.note { font-size: 13px; color: var(--ink-2); margin-top: 8px; max-width: 78ch; }
table { border-collapse: collapse; width: 100%; font-size: 13.5px; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { font-family: var(--mono); font-size: 11.5px; letter-spacing: 0.05em; text-transform: uppercase; color: var(--muted); font-weight: 500; }
td.num, th.num { text-align: right; font-family: var(--mono); }
.tablewrap { overflow-x: auto; margin-top: 10px; }
details > summary { cursor: pointer; color: var(--accent-ink); font-size: 13.5px; margin-top: 8px; }
.rounds { display: grid; gap: 14px; margin-top: 16px; }
.round { display: grid; grid-template-columns: 56px 1fr; gap: 14px; background: var(--surface); border: 1px solid var(--rule); border-radius: 6px; padding: 14px 16px; }
.round .no { font-family: var(--mono); font-size: 24px; color: var(--muted); line-height: 1; padding-top: 3px; }
.round h3 { display: flex; flex-wrap: wrap; gap: 6px 12px; align-items: baseline; }
.round h3 small { font-family: var(--mono); font-weight: 400; font-size: 12px; color: var(--muted); }
.round p { margin-top: 6px; color: var(--ink-2); font-size: 14px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
.chip { font-family: var(--mono); font-size: 11.5px; padding: 2px 8px; border-radius: 999px; background: var(--chip-none); color: var(--ink); text-decoration: none; border: 1px solid transparent; }
.chip.kept { background: var(--chip-kept); } .chip.reverted { background: var(--chip-reverted); }
.chip.todo { background: var(--chip-todo); }
.tech { display: grid; gap: 10px; margin-top: 14px; }
.t { background: var(--surface); border: 1px solid var(--rule); border-radius: 6px; padding: 12px 16px; }
.t .h { display: flex; flex-wrap: wrap; gap: 6px 12px; align-items: center; }
.t .h .st { font-family: var(--mono); font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; padding: 2px 8px; border-radius: 999px; }
.st.kept { background: var(--chip-kept); } .st.reverted { background: var(--chip-reverted); } .st.none { background: var(--chip-none); } .st.todo { background: var(--chip-todo); }
.t .tg { font-size: 12.5px; color: var(--muted); font-family: var(--mono); margin-top: 2px; }
.t p { margin-top: 6px; font-size: 14px; color: var(--ink-2); max-width: 80ch; }
.issues { display: grid; gap: 10px; margin-top: 14px; }
.issue { border-left: 3px solid var(--serious); padding: 4px 0 4px 14px; }
.issue.f { border-left-color: var(--accent); }
.issue p { font-size: 14px; color: var(--ink-2); margin-top: 3px; max-width: 80ch; }
@media (max-width: 520px) { .round { grid-template-columns: 1fr; } .round .no { padding-top: 0; } }
@media (prefers-reduced-motion: reduce) { .chart .bar { transition: none; } }
</style>

<div class="wrap">
  <div class="eyebrow">Research log · Mojo port of Rust's slotmap</div>
  <h1 style="margin-top:8px">__TITLE__</h1>
  <p class="lede">__GOAL__</p>
  <div class="meta">
    <span>repo: <a href="https://github.com/ozzyozbourne/slotmap-mojo">ozzyozbourne/slotmap-mojo</a></span>
    <span>bench: <a href="https://github.com/ozzyozbourne/slotmap-mojo/actions/workflows/bench.yml">Benchmark workflow</a></span>
    <span id="updated"></span>
  </div>
  <div class="tiles" id="tiles"></div>

  <h2>Results by round</h2>
  <p class="note">Each bar is the CI-measured Mojo/Rust ratio of mean time per element. The axis is logarithmic so 0.5× and 2× sit at equal distance from parity. A grey tick shows the same case in the previous round that has results. Hover a bar for the raw numbers.</p>
  <div class="controls"><span class="lbl">round</span><span id="roundbtns"></span></div>
  <div class="controls"><span class="lbl">map</span><span id="mapbtns"></span></div>
  <div class="legend">
    <span style="--c:var(--good)">Mojo faster by >20%</span>
    <span style="--c:var(--accent)">within ±20% (parity)</span>
    <span style="--c:var(--serious)">Mojo slower, up to 2×</span>
    <span style="--c:var(--critical)">Mojo slower by more than 2×</span>
    <span style="--c:var(--muted)">previous round</span>
  </div>
  <div class="chart" id="chart"></div>
  <p class="note" id="roundnote"></p>
  <details><summary>Show the numbers as a table</summary><div class="tablewrap" id="table"></div></details>

  <h2>Parity over rounds</h2>
  <p class="note">Share of the 69 benchmark cases within ±20% of Rust, and the median Mojo/Rust ratio, for every round that has CI results.</p>
  <div class="chart" id="trend"></div>

  <h2>Rounds</h2>
  <div class="rounds" id="rounds"></div>

  <h2>Techniques tried</h2>
  <p class="note">Everything attempted, whether it stayed in. "Kept" means it shipped and measured better; "reverted" means it was built and measured worse; "no effect" means it measured the same and was left out.</p>
  <div class="tech" id="tech"></div>

  <h2>Issues along the way</h2>
  <div class="issues" id="issues"></div>

  <h2>What was learned</h2>
  <div class="issues" id="findings"></div>

  <h2>Method</h2>
  <p class="note">__HARNESS__</p>
  <p class="note" style="margin-top:10px">Local micro-benchmarks (best of 20 runs on an M2 laptop) were used to pick directions; every claim of a change in the tables above comes from the CI run linked in its round. The raw results of each CI run are kept under <code>bench/history/</code>, and this page is generated from them by <code>bench/build_log.py</code>.</p>
</div>
<div class="tip" id="tip"></div>

<script>
const LOG = __DATA__;
const MAPS = __MAPS__;
const OPS = __OPS__;
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const withResults = LOG.rounds.filter(r => r.rows && r.rows.length);
let curRound = withResults.length ? withResults[withResults.length - 1].id : LOG.rounds[0].id;
let curMap = MAPS[0];
try { const m = localStorage.getItem("hc-map"); if (m && MAPS.includes(m)) curMap = m; } catch (e) {}

function ratioColor(r) {
  if (r <= 0.8) return "var(--good)";
  if (r < 1.2) return "var(--accent)";
  if (r < 2) return "var(--serious)";
  return "var(--critical)";
}
function stats(round) {
  const rs = round.rows.map(x => x[4] / x[3]).sort((a, b) => a - b);
  if (!rs.length) return null;
  const median = rs[Math.floor(rs.length / 2)];
  const within = rs.filter(r => r >= 0.8 && r <= 1.2).length;
  const worst = round.rows.reduce((a, b) => (b[4] / b[3] > a[4] / a[3] ? b : a));
  return { median, within, n: rs.length, worst, slower2x: rs.filter(r => r > 2).length };
}
function fmt(x) { return x < 100 ? x.toFixed(2) : Math.round(x).toString(); }

function renderTiles() {
  const last = withResults[withResults.length - 1];
  const st = last ? stats(last) : null;
  const tiles = [
    { k: "rounds run", v: LOG.rounds.length, s: withResults.length + " with CI results" },
    st ? { k: "cases at parity", v: Math.round(100 * st.within / st.n) + "%", s: st.within + " of " + st.n + " within ±20% (round " + last.id + ")" } : null,
    st ? { k: "median Mojo/Rust", v: st.median.toFixed(2) + "×", s: "below 1.00 is faster than Rust" } : null,
    st ? { k: "worst case", v: (st.worst[4] / st.worst[3]).toFixed(1) + "×", s: st.worst[0] + " " + st.worst[1] + " at " + st.worst[2].toLocaleString() } : null,
    { k: "techniques kept", v: LOG.techniques.filter(t => t.status === "kept").length, s: LOG.techniques.filter(t => t.status !== "kept").length + " tried and left out" },
  ].filter(Boolean);
  $("#tiles").innerHTML = tiles.map(t => `<div class="tile"><div class="k">${esc(t.k)}</div><div class="v">${esc(t.v)}</div><div class="s">${esc(t.s)}</div></div>`).join("");
}

function renderButtons() {
  $("#roundbtns").innerHTML = LOG.rounds.map(r => `<button class="pill" data-round="${r.id}" aria-pressed="${r.id === curRound}" ${r.rows.length ? "" : "disabled title='no CI results yet'"}>${r.id} · ${esc(r.name)}</button>`).join(" ");
  $("#mapbtns").innerHTML = MAPS.map(m => `<button class="pill" data-map="${m}" aria-pressed="${m === curMap}">${m}</button>`).join(" ");
  document.querySelectorAll("[data-round]").forEach(b => b.onclick = () => { curRound = +b.dataset.round; renderButtons(); renderChart(); });
  document.querySelectorAll("[data-map]").forEach(b => b.onclick = () => { curMap = b.dataset.map; try { localStorage.setItem("hc-map", curMap); } catch (e) {} renderButtons(); renderChart(); });
}

function prevRoundWithResults(id) {
  const idx = LOG.rounds.findIndex(r => r.id === id);
  for (let i = idx - 1; i >= 0; i--) if (LOG.rounds[i].rows.length) return LOG.rounds[i];
  return null;
}

const LOGMIN = Math.log2(0.1), LOGMAX = Math.log2(10);
function renderChart() {
  const round = LOG.rounds.find(r => r.id === curRound);
  const prev = prevRoundWithResults(curRound);
  const rows = round.rows.filter(r => r[0] === curMap);
  const prevMap = {};
  if (prev) prev.rows.forEach(r => prevMap[r[0] + "|" + r[1] + "|" + r[2]] = r);
  const W = 940, left = 150, right = 30, top = 24, rowH = 22, gap = 6;
  const H = top + rows.length * (rowH + gap) + 30;
  const x = (ratio) => left + (Math.log2(Math.max(0.1, Math.min(10, ratio))) - LOGMIN) / (LOGMAX - LOGMIN) * (W - left - right);
  const ticks = [0.125, 0.25, 0.5, 1, 2, 4, 8];
  let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Mojo over Rust ratio per operation for ${esc(curMap)} in round ${curRound}">`;
  ticks.forEach(t => {
    svg += `<line x1="${x(t)}" y1="${top - 6}" x2="${x(t)}" y2="${H - 26}" stroke="${t === 1 ? "var(--axis)" : "var(--grid)"}" stroke-width="${t === 1 ? 1.5 : 1}"/>`;
    svg += `<text x="${x(t)}" y="${H - 10}" text-anchor="middle" fill="var(--muted)">${t}×</text>`;
  });
  svg += `<text x="${x(1)}" y="${top - 10}" text-anchor="middle" fill="var(--ink-2)" font-size="11">parity</text>`;
  rows.forEach((r, i) => {
    const y = top + i * (rowH + gap);
    const ratio = r[4] / r[3];
    const x0 = x(1), x1 = x(ratio);
    const bx = Math.min(x0, x1), bw = Math.max(2, Math.abs(x1 - x0));
    const label = `${r[1]} · ${r[2] >= 1e6 ? "1M" : r[2] >= 1e3 ? (r[2] / 1e3) + "K" : r[2]}`;
    const p = prevMap[r[0] + "|" + r[1] + "|" + r[2]];
    svg += `<g class="row" data-i="${i}">`;
    svg += `<text x="${left - 10}" y="${y + rowH / 2 + 4}" text-anchor="end" fill="var(--ink)">${esc(label)}</text>`;
    svg += `<rect class="bar" x="${bx}" y="${y + 3}" width="${bw}" height="${rowH - 6}" rx="3" fill="${ratioColor(ratio)}"/>`;
    if (p) { const px = x(p[4] / p[3]); svg += `<line x1="${px}" y1="${y + 1}" x2="${px}" y2="${y + rowH - 1}" stroke="var(--muted)" stroke-width="2"/>`; }
    svg += `<text x="${x1 + (ratio >= 1 ? 6 : -6)}" y="${y + rowH / 2 + 4}" text-anchor="${ratio >= 1 ? "start" : "end"}" fill="var(--ink-2)" font-size="11.5">${ratio.toFixed(2)}×</text>`;
    svg += `<rect x="${left}" y="${y}" width="${W - left - right}" height="${rowH}" fill="transparent" data-tip="${esc(`${r[0]} ${r[1]} n=${r[2].toLocaleString()} · Rust ${fmt(r[3])} ns · Mojo ${fmt(r[4])} ns · ${ratio.toFixed(2)}×` + (p ? ` · was ${(p[4] / p[3]).toFixed(2)}× in round ${prev.id}` : ""))}"/>`;
    svg += `</g>`;
  });
  svg += `</svg>`;
  $("#chart").innerHTML = rows.length ? svg : `<p class="note" style="padding:12px">No CI results for this round yet.</p>`;
  $("#roundnote").innerHTML = `<strong>Round ${round.id}, ${esc(round.name)}</strong> (commit <code>${esc(round.commit)}</code>${round.run ? `, <a href="${esc(round.run)}">CI run</a>` : ""}). ${esc(round.summary)}` + (round.env ? ` <span style="color:var(--muted)">${esc(round.env.machine || "")} · ${esc(round.env.mojo || "")}</span>` : "");
  const all = round.rows;
  $("#table").innerHTML = `<table><thead><tr><th>map</th><th>operation</th><th class="num">n</th><th class="num">Rust ns</th><th class="num">Mojo ns</th><th class="num">Mojo/Rust</th>${prev ? `<th class="num">round ${prev.id}</th>` : ""}</tr></thead><tbody>` +
    all.map(r => { const p = prevMap[r[0] + "|" + r[1] + "|" + r[2]]; return `<tr><td>${r[0]}</td><td>${r[1]}</td><td class="num">${r[2].toLocaleString()}</td><td class="num">${fmt(r[3])}</td><td class="num">${fmt(r[4])}</td><td class="num">${(r[4] / r[3]).toFixed(2)}</td>${prev ? `<td class="num">${p ? (p[4] / p[3]).toFixed(2) : "—"}</td>` : ""}</tr>`; }).join("") + `</tbody></table>`;
  const tip = $("#tip");
  document.querySelectorAll("#chart [data-tip]").forEach(el => {
    el.addEventListener("mousemove", (e) => { tip.textContent = el.dataset.tip; tip.style.display = "block"; tip.style.left = Math.min(e.clientX + 14, window.innerWidth - tip.offsetWidth - 8) + "px"; tip.style.top = (e.clientY + 14) + "px"; });
    el.addEventListener("mouseleave", () => tip.style.display = "none");
  });
}

function renderTrend() {
  const pts = withResults.map(r => ({ id: r.id, name: r.name, ...stats(r) }));
  if (!pts.length) { $("#trend").innerHTML = `<p class="note" style="padding:12px">No CI results yet.</p>`; return; }
  const W = 940, H = 220, left = 60, right = 30, top = 20, bottom = 36;
  const xs = (i) => left + (pts.length === 1 ? (W - left - right) / 2 : i / (pts.length - 1) * (W - left - right));
  const yPct = (v) => top + (1 - v / 100) * (H - top - bottom);
  let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Share of cases at parity per round">`;
  [0, 25, 50, 75, 100].forEach(v => { svg += `<line x1="${left}" x2="${W - right}" y1="${yPct(v)}" y2="${yPct(v)}" stroke="var(--grid)"/><text x="${left - 8}" y="${yPct(v) + 4}" text-anchor="end" fill="var(--muted)">${v}%</text>`; });
  const path = pts.map((p, i) => `${i ? "L" : "M"}${xs(i)},${yPct(100 * p.within / p.n)}`).join(" ");
  svg += `<path d="${path}" fill="none" stroke="var(--accent)" stroke-width="2"/>`;
  pts.forEach((p, i) => {
    const y = yPct(100 * p.within / p.n);
    svg += `<circle cx="${xs(i)}" cy="${y}" r="5" fill="var(--accent)" stroke="var(--surface)" stroke-width="2"/>`;
    svg += `<text x="${xs(i)}" y="${y - 12}" text-anchor="middle" fill="var(--ink)">${Math.round(100 * p.within / p.n)}% at parity · median ${p.median.toFixed(2)}×</text>`;
    svg += `<text x="${xs(i)}" y="${H - 12}" text-anchor="middle" fill="var(--ink-2)">round ${p.id} · ${esc(p.name)}</text>`;
  });
  svg += `</svg>`;
  $("#trend").innerHTML = svg;
}

function renderRounds() {
  const tmap = Object.fromEntries(LOG.techniques.map(t => [t.id, t]));
  $("#rounds").innerHTML = LOG.rounds.map(r => {
    const st = r.rows.length ? stats(r) : null;
    return `<div class="round" id="round-${r.id}"><div class="no">${r.id}</div><div>
      <h3>${esc(r.name)} <small>${esc(r.commit)}${r.run ? ` · <a href="${esc(r.run)}">CI run</a>` : " · CI pending"}${st ? ` · ${Math.round(100 * st.within / st.n)}% at parity, median ${st.median.toFixed(2)}×` : ""}</small></h3>
      <p>${esc(r.summary)}</p>
      ${r.changes.length ? `<div class="chips">${r.changes.map(c => tmap[c] ? `<a class="chip ${tmap[c].status === "kept" ? "kept" : tmap[c].status === "reverted" ? "reverted" : ""}" href="#t-${c}">${esc(tmap[c].name)}</a>` : "").join("")}</div>` : ""}
    </div></div>`;
  }).join("");
}

function renderTech() {
  const order = { kept: 0, reverted: 1, "no effect": 2, "not attempted": 3 };
  const cls = (s) => s === "kept" ? "kept" : s === "reverted" ? "reverted" : s === "no effect" ? "none" : "todo";
  $("#tech").innerHTML = [...LOG.techniques].sort((a, b) => order[a.status] - order[b.status]).map(t =>
    `<div class="t" id="t-${t.id}"><div class="h"><span class="st ${cls(t.status)}">${esc(t.status)}</span><h3>${esc(t.name)}</h3></div><div class="tg">${esc(t.target)}</div><p>${esc(t.detail)}</p></div>`).join("");
}

function renderIssues() {
  $("#issues").innerHTML = LOG.issues.map(i => `<div class="issue"><h3>${esc(i.title)}</h3><p>${esc(i.detail)}</p></div>`).join("");
  $("#findings").innerHTML = LOG.findings.map(i => `<div class="issue f"><h3>${esc(i.title)}</h3><p>${esc(i.detail)}</p></div>`).join("");
}

$("#updated").textContent = "generated " + LOG.generated;
renderTiles(); renderButtons(); renderChart(); renderTrend(); renderRounds(); renderTech(); renderIssues();
</script>
"""


def main():
    import datetime
    log = load()
    log["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    html = (TEMPLATE
            .replace("__TITLE__", log["title"])
            .replace("__GOAL__", log["goal"])
            .replace("__HARNESS__", log["harness"])
            .replace("__MAPS__", json.dumps(MAPS))
            .replace("__OPS__", json.dumps(OPS))
            .replace("__DATA__", json.dumps(log)))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html)
    print(f"wrote {OUT} ({len(html)//1024} KB)")


if __name__ == "__main__":
    main()
