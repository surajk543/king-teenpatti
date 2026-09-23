/**
 * Turns a ramp run into one self-contained HTML report.
 *
 *   node ramp-report.mjs --ramp ramp.json --host ramp-host.json [--samples host-samples.jsonl]
 *                        [--title "…"] [--out report.html]
 *
 * Three inputs, two of them optional:
 *   --ramp     ramptest.mjs's report: one result per stage (latency percentiles, actions/s,
 *              hands/min, /health samples) plus the run's facts and verdict.
 *   --host     host-metrics.mjs's output: what the host's Prometheus (node_exporter, the game
 *              server's own metrics, postgres_exporter, redis_exporter, nginx) recorded during
 *              each stage's exact hold window, with loadtest/host-sampler.py's lines folded in.
 *   --samples  loadtest/host-sampler.py's JSONL for the WHOLE run, one line per interval — the
 *              time-series section, with every stage's hold window shaded over it.
 *
 * Everything in the page is drawn here: inline CSS, inline SVG, no <script>, no images, no
 * chart library. The only thing fetched is the typeface. Every figure shown is a figure from
 * the JSON — nothing is estimated, and nothing is rounded past what the file holds (ms stay
 * whole, MB keep one decimal, percentages one, and the sampler's sub-millisecond Redis
 * latencies keep their three). A missing input leaves its sections saying "not collected"
 * rather than leaving them out, so a report always has the same shape.
 */
import fs from 'node:fs';
import path from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).reduce((p, t, i, a) => {
  if (t.startsWith('--')) p.push([t.slice(2), a[i + 1]]);
  return p;
}, []));
if (!args.ramp) { console.error('usage: node ramp-report.mjs --ramp <ramp.json> [--host <host.json>] [--samples <samples.jsonl>] [--title "…"] [--out report.html]'); process.exit(2); }

// ------------------------------------------------------------------ loading
const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const ramp = readJson(args.ramp);
const host = args.host ? readJson(args.host) : null;
const samples = args.samples
  ? fs.readFileSync(args.samples, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
  : null;
const OUT = args.out ?? path.basename(args.ramp).replace(/\.json$/, '') + '-report.html';
const TITLE = args.title ?? `Ramp report — ${ramp.url ?? 'unknown server'}`;

const stages = ramp.results ?? [];
const hostByTarget = new Map((host?.stages ?? []).map((s) => [s.target, s]));
const hostOf = (stage) => hostByTarget.get(stage.target) ?? null;

// ------------------------------------------------------------ formatting
// Every formatter answers "—" for a value that is not there, and none of them
// invents precision: an integer stays an integer, a decimal keeps what it has.
const has = (v) => v !== null && v !== undefined && !(typeof v === 'number' && !Number.isFinite(v));
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const fmtInt = (v) => (has(v) ? Math.round(v).toLocaleString('en-US') : '—');
const fmtDec = (v, d) => (has(v) ? Number(v).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }) : '—');
const fmt1 = (v) => fmtDec(v, 1);
const fmt2 = (v) => fmtDec(v, 2);
/** A number as the file holds it: whole when whole, otherwise its own decimals (up to three). */
const fmtAsIs = (v) => (has(v) ? (Number.isInteger(v) ? fmtInt(v) : Number(v).toLocaleString('en-US', { maximumFractionDigits: 3 })) : '—');
const fmtPct = (v) => (has(v) ? `${fmt1(v)}%` : '—');
const fmtMs = (v) => (has(v) ? `${fmtInt(v)} ms` : '—');
const fmtMb = (v) => (has(v) ? `${fmt1(v)} MB` : '—');
const fmtRatio = (v) => (has(v) ? `${fmt1(v * 100)}%` : '—');
const iso = (s) => (s ? new Date(s).toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC') : '—');
const clock = (epochS) => new Date(epochS * 1000).toISOString().slice(11, 19);
const durationOf = (a, b) => {
  if (!a || !b) return '—';
  const s = Math.round((new Date(b) - new Date(a)) / 1000);
  return s >= 3600 ? `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min` : s >= 60 ? `${Math.floor(s / 60)} min ${s % 60} s` : `${s} s`;
};
const kStage = (n) => (n >= 1000 && n % 1000 === 0 ? `${n / 1000}k` : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));

// Latency bands for the coloured cells: what the reference report called "flat",
// "the knee" and "saturated". The run's own stop threshold is always critical.
const bandClass = (ms, stopMs) => (!has(ms) ? '' : ms > stopMs || ms > 1000 ? 'crit' : ms > 100 ? 'warn' : 'ok');

// ----------------------------------------------------------- derived facts
const stopMs = ramp.thresholds?.maxP95Ms ?? 3000;
const stopErr = ramp.thresholds?.maxErrorRate ?? 0.1;
const totalActions = stages.reduce((n, s) => n + (s.action?.count ?? 0), 0);
const totalErrors = stages.reduce((n, s) => n + (s.action?.errors ?? 0), 0);
const firstAbove = (ms) => stages.find((s) => has(s.action?.p95) && s.action.p95 > ms) ?? null;
const knee100 = firstAbove(100);
const knee1000 = firstAbove(1000);
const heldAt99 = stages.filter((s) => s.target > 0 && s.connected / s.target >= 0.99).map((s) => s.target);
const maxHeld99 = heldAt99.length ? Math.max(...heldAt99) : null;
const worstP95 = stages.reduce((w, s) => (has(s.action?.p95) && (!w || s.action.p95 > w.action.p95) ? s : w), null);
const comfortable = stages.filter((s) => has(s.action?.p95) && s.action.p95 <= 100 && s.target > 0 && s.connected / s.target >= 0.99).map((s) => s.target);
const maxComfortable = comfortable.length ? Math.max(...comfortable) : null;
const lastStage = stages.at(-1) ?? null;
const lastHost = lastStage ? hostOf(lastStage) : null;
const numCpu = ramp.serverBefore?.process?.numCpu ?? lastHost?.host?.cores ?? null;
// The ceiling stage may have no result row at all (the ramp aborted while adding
// players), or be the last row (a stop rule tripped after its hold).
const ceiling = ramp.ceiling ?? null;
const ceilingHasRow = ceiling ? stages.some((s) => s.target === ceiling.target) : false;

/** The plain-English paragraph the header carries, every clause from a figure above. */
function summaryParagraph() {
  if (!stages.length) return 'The run recorded no completed stage.';
  const parts = [];
  const first = stages[0]; const last = stages.at(-1);
  parts.push(`${stages.length} stage${stages.length === 1 ? '' : 's'} completed, from ${fmtInt(first.target)} to ${fmtInt(last.target)} players, each held ${fmtInt(ramp.holdSeconds)} s against ${esc(ramp.url ?? 'the server')}.`);
  if (knee100) parts.push(`Action-ack p95 first crossed 100 ms at ${fmtInt(knee100.target)} players (${fmtMs(knee100.action.p95)})`);
  else if (worstP95) parts.push(`Action-ack p95 never crossed 100 ms: the highest was ${fmtMs(worstP95.action.p95)} at ${fmtInt(worstP95.target)} players`);
  if (knee1000) parts.push(`and crossed 1 s at ${fmtInt(knee1000.target)} (${fmtMs(knee1000.action.p95)}).`);
  else if (knee100) parts.push('and never crossed 1 s.'); else parts[parts.length - 1] += '.';
  if (has(maxHeld99)) parts.push(`The most players held with at least 99% connected was ${fmtInt(maxHeld99)}.`);
  parts.push(`${fmtInt(totalErrors)} refused action${totalErrors === 1 ? '' : 's'} in ${fmtInt(totalActions)}.`);
  if (lastHost?.host) {
    parts.push(`At the last stage the host's ${fmtInt(lastHost.host.cores)} cores averaged ${fmtPct(lastHost.host.cpuTotalPercentMean)} busy (I/O wait ${fmtPct(lastHost.host.iowaitPercentMean)}), the game process ${fmt2(lastHost.gameServer?.cpuCoresMean)} cores on average and ${fmt2(lastHost.gameServer?.cpuCoresMax)} at peak, so ${fmt1(100 - lastHost.host.cpuTotalPercentMean)}% of the machine was idle.`);
  } else if (lastStage?.host && has(numCpu)) {
    parts.push(`At the last stage the game process averaged ${fmtPct(lastStage.host.cpuPercentMean)} of one core (peak ${fmtPct(lastStage.host.cpuPercentMax)}) on a ${fmtInt(numCpu)}-core server, as /health reported it; host-wide CPU was not collected.`);
  }
  if (ceiling) parts.push(`The run stopped at ${fmtInt(ceiling.target)} players: ${ceiling.reasons?.map(esc).join('; ') ?? 'no reason recorded'}.`);
  else parts.push('No stop rule tripped: every stage listed was held to the end.');
  return parts.join(' ');
}

// ------------------------------------------------------------ SVG charts
// One line-chart helper draws every chart in the page. It takes numbers and
// hands back markup: axes, solid hairline gridlines, labelled ticks, one
// polyline per series, markers that carry the value as a native <title>
// tooltip, optional reference lines and shaded bands, and — under the SVG —
// a legend and the numbers as a table, so nothing is readable by colour alone.
const notCollected = (what) => `<div class="note muted"><div class="h">Not collected</div><p>${what}</p></div>`;
const SERIES_VARS = ['var(--s1)', 'var(--s2)', 'var(--s3)', 'var(--s4)', 'var(--s5)'];
const W = 560; const H = 296; const ML = 58; const MR = 18; const MT = 26; const MB = 40;

/** 1-2-5 ticks from 0 to just past the maximum. */
function niceTicks(max, want = 5) {
  if (!(max > 0)) return [0, 1];
  const raw = max / want;
  const pow = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * pow).find((s) => s >= raw) ?? 10 * pow;
  const ticks = [];
  for (let v = 0; v <= max + step * 0.999; v += step) ticks.push(Number(v.toFixed(10)));
  if (ticks.at(-1) < max) ticks.push(ticks.at(-1) + step);
  return ticks;
}
const tickLabel = (v) => (Math.abs(v) >= 1e6 ? `${v / 1e6}M` : Math.abs(v) >= 1e4 ? `${v / 1e3}k` : Number.isInteger(v) ? String(v) : String(Number(v.toFixed(3))));

/**
 * @param {object} o
 * @param {string} o.title            what the chart shows
 * @param {string} o.unit             the y unit, written on the axis
 * @param {number[]} o.x              one x per column (player targets, or epoch seconds)
 * @param {(x:number)=>string} o.xLabel   how an x is written on the axis and in the table
 * @param {{name:string, values:(number|null)[], color?:string, dash?:boolean}[]} o.series
 * @param {'linear'|'log'} [o.scale]
 * @param {{value:number, label:string}[]} [o.refLines]   horizontal dashed rules (a threshold, a limit)
 * @param {{from:number, to:number, label:string}[]} [o.bands]   shaded x ranges (a stage's hold)
 * @param {boolean} [o.markers]       point markers (off for dense time series)
 * @param {(v:number)=>string} [o.fmt]   how a value is written in the table and tooltip
 * @param {string} [o.caption]
 * @param {string} [o.xTitle]
 */
function lineChart(o) {
  const scale = o.scale ?? 'linear';
  const fmt = o.fmt ?? fmtAsIs;
  const markers = o.markers ?? true;
  const xs = o.x;
  if (!xs.length) return `<figure><h3>${esc(o.title)}</h3>${notCollected('Nothing to plot: the run recorded no stage.')}</figure>`;
  const allY = o.series.flatMap((s) => s.values).filter((v) => has(v));
  const allRef = (o.refLines ?? []).map((r) => r.value).filter(has);
  const yMaxData = Math.max(0, ...allY, ...allRef);
  const plotW = W - ML - MR; const plotH = H - MT - MB;
  // x: linear in the value, with a little padding so the first and last markers are whole.
  const xMin = Math.min(...xs); const xMax = Math.max(...xs);
  const xSpan = xMax - xMin;
  const px = (x) => (xSpan === 0 ? ML + plotW / 2 : ML + 12 + ((x - xMin) / xSpan) * (plotW - 24));
  let ticks; let py;
  if (scale === 'log') {
    const pos = allY.filter((v) => v > 0);
    const lo = 10 ** Math.floor(Math.log10(Math.min(1, ...pos)));
    const hi = 10 ** Math.ceil(Math.log10(Math.max(10, yMaxData)));
    ticks = []; for (let v = lo; v <= hi; v *= 10) ticks.push(v);
    const l0 = Math.log10(lo); const l1 = Math.log10(hi);
    py = (v) => MT + plotH - ((Math.log10(Math.max(v, lo)) - l0) / (l1 - l0)) * plotH;
  } else {
    ticks = niceTicks(yMaxData);
    const top = ticks.at(-1);
    py = (v) => MT + plotH - (v / top) * plotH;
  }
  const parts = [];
  parts.push(`<svg viewBox="0 0 ${W} ${H}" width="100%" role="img" aria-label="${esc(o.title)}">`);
  // shaded bands (hold windows) go under everything
  for (const b of o.bands ?? []) {
    const x0 = px(b.from); const x1 = px(b.to);
    parts.push(`<rect x="${x0.toFixed(1)}" y="${MT}" width="${Math.max(1, x1 - x0).toFixed(1)}" height="${plotH}" class="band"/>`);
    parts.push(`<text x="${(x0 + 3).toFixed(1)}" y="${MT + 11}" class="bandlbl">${esc(b.label)}</text>`);
  }
  // gridlines + y labels
  for (const t of ticks) {
    const y = py(t).toFixed(1);
    parts.push(`<line x1="${ML}" y1="${y}" x2="${W - MR}" y2="${y}" class="grid"/>`);
    parts.push(`<text x="${ML - 6}" y="${(Number(y) + 3.5).toFixed(1)}" class="tick" text-anchor="end">${tickLabel(t)}</text>`);
  }
  // x ticks: every column while their labels have room (46 px), thinned when they would touch
  const gaps = xs.slice(1).map((x, i) => Math.abs(px(x) - px(xs[i]))).filter((g) => g > 0);
  const every = Math.max(1, Math.ceil(46 / (gaps.length ? Math.min(...gaps) : plotW)));
  xs.forEach((x, i) => {
    if (i % every !== 0 && i !== xs.length - 1) return;
    const X = px(x).toFixed(1);
    parts.push(`<line x1="${X}" y1="${MT + plotH}" x2="${X}" y2="${MT + plotH + 4}" class="axis"/>`);
    parts.push(`<text x="${X}" y="${MT + plotH + 16}" class="tick" text-anchor="middle">${esc(o.xLabel(x))}</text>`);
  });
  parts.push(`<line x1="${ML}" y1="${MT + plotH}" x2="${W - MR}" y2="${MT + plotH}" class="axis"/>`);
  parts.push(`<text x="4" y="${MT - 12}" class="tick">${esc(o.unit)}</text>`);
  if (o.xTitle) parts.push(`<text x="${W - MR}" y="${H - 6}" class="tick" text-anchor="end">${esc(o.xTitle)}</text>`);
  // reference lines
  for (const r of o.refLines ?? []) {
    if (!has(r.value)) continue;
    const y = py(r.value).toFixed(1);
    parts.push(`<line x1="${ML}" y1="${y}" x2="${W - MR}" y2="${y}" class="ref"/>`);
    // labelled at the left end, where the series' own end labels never are
    parts.push(`<text x="${ML + 4}" y="${(Number(y) - 4).toFixed(1)}" class="reflbl">${esc(r.label)}</text>`);
  }
  // series
  const endLabels = [];
  o.series.forEach((s, si) => {
    const color = s.color ?? SERIES_VARS[si % SERIES_VARS.length];
    const pts = xs.map((x, i) => (has(s.values[i]) ? [px(x), py(s.values[i]), s.values[i], x] : null));
    // a null breaks the line: one polyline per run of present values
    let run = [];
    const flush = () => { if (run.length > 1) parts.push(`<polyline fill="none" stroke="${color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"${s.dash ? ' stroke-dasharray="5 4"' : ''} points="${run.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ')}"/>`); run = []; };
    for (const p of pts) { if (p) run.push(p); else flush(); }
    flush();
    if (markers) {
      for (const p of pts) {
        if (!p) continue;
        parts.push(`<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="4" fill="${color}" class="mark"><title>${esc(s.name)} · ${esc(o.xLabel(p[3]))}: ${esc(fmt(p[2]))} ${esc(o.unit)}</title></circle>`);
      }
    } else {
      // dense series: an invisible hit circle still gives a tooltip, one per ~2 px of plot width
      // at most — a 1 s sampler over an hour would otherwise write 3,600 of them per series and
      // push the page past several MB, for tooltips that would sit on top of each other anyway.
      const hitEvery = Math.max(1, Math.ceil(pts.length / Math.floor(plotW / 2)));
      for (const [i, p] of pts.entries()) {
        if (!p || (i % hitEvery !== 0 && i !== pts.length - 1)) continue;
        parts.push(`<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="5" fill="transparent"><title>${esc(s.name)} · ${esc(o.xLabel(p[3]))}: ${esc(fmt(p[2]))} ${esc(o.unit)}</title></circle>`);
      }
    }
    const lastPt = [...pts].reverse().find(Boolean);
    if (lastPt && o.series.length <= 5) endLabels.push({ y: lastPt[1], text: s.name, color });
  });
  // direct labels at the line ends, nudged apart so they never overlap
  endLabels.sort((a, b) => a.y - b.y);
  for (let i = 1; i < endLabels.length; i++) if (endLabels[i].y - endLabels[i - 1].y < 11) endLabels[i].y = endLabels[i - 1].y + 11;
  for (const l of endLabels) parts.push(`<text x="${W - MR - 2}" y="${(l.y - 6).toFixed(1)}" class="endlbl" text-anchor="end" fill="${l.color}">${esc(l.text)}</text>`);
  parts.push('</svg>');
  // legend + numbers
  const legend = `<div class="legend">${o.series.map((s, si) => `<span><i style="background:${s.color ?? SERIES_VARS[si % SERIES_VARS.length]}"></i>${esc(s.name)}</span>`).join('')}</div>`;
  const table = xs.length <= 24 ? `<div class="scroll"><table class="numbers"><thead><tr><th>${esc(o.unit)}</th>${xs.map((x) => `<th>${esc(o.xLabel(x))}</th>`).join('')}</tr></thead><tbody>${o.series.map((s) => `<tr><td>${esc(s.name)}</td>${s.values.map((v) => `<td>${esc(fmt(v))}</td>`).join('')}</tr>`).join('')}</tbody></table></div>` : '';
  return `<figure><h3>${esc(o.title)}</h3><div class="chart">${parts.join('')}${legend}</div>${o.caption ? `<p class="cap">${o.caption}</p>` : ''}${table}</figure>`;
}

// --------------------------------------------------------------- sections
const targets = stages.map((s) => s.target);
const byStage = (f) => stages.map((s) => { const v = f(s); return has(v) ? v : null; });
const byHost = (f) => stages.map((s) => { const h = hostOf(s); if (!h) return null; const v = f(h); return has(v) ? v : null; });
const stageX = { x: targets, xLabel: (x) => fmtInt(x), xTitle: 'players' };

function sectionHeader() {
  const sb = ramp.serverBefore ?? {}; const pr = sb.process ?? {};
  const h0 = host?.stages?.[0]?.host ?? null;
  const facts = [
    ['Target', ramp.url], ['Started', iso(ramp.startedAt)], ['Finished', iso(ramp.finishedAt)], ['Duration', durationOf(ramp.startedAt, ramp.finishedAt)],
    ['Stages', (ramp.stages ?? []).map(fmtInt).join(', ')], ['Hold', has(ramp.holdSeconds) ? `${fmtInt(ramp.holdSeconds)} s per stage` : null],
    ['Workers', ramp.workers], ['Table', ramp.table ? `${ramp.table.category}, boot ${fmtInt(ramp.table.boot)}` : null],
    ['Stop rules', `p95 > ${fmtInt(stopMs)} ms · errors > ${fmtRatio(stopErr)} · connected < 90%`],
    ['Server', [pr.node, sb.version ? `build ${sb.version}` : null, has(pr.numCpu) ? `${fmtInt(pr.numCpu)} CPUs (GOMAXPROCS ${fmtInt(pr.gomaxprocs)})` : null].filter(Boolean).join(' · ') || null],
    ['Server before', sb.ok !== undefined ? `uptime ${fmtInt(sb.uptime)} s · ${fmtInt(sb.players)} players · ${fmtInt(sb.tables)} tables · ${fmtInt(sb.sockets)} sockets · RSS ${fmtMb(pr.rssMb)}` : null],
    ['Table config', sb.tableConfig ? `${sb.tableConfig.source}${sb.tableConfig.fallback ? ' (fallback)' : ''} · ${String(sb.tableConfig.version).slice(0, 12)}…` : null],
    ['Host', h0 ? `${fmtInt(h0.cores)} cores · ${fmtInt(h0.memTotalMb)} MB RAM` : 'not collected'],
    ['Live store', sb.live ? `${sb.live.kind} (${sb.live.ok ? 'ok' : 'NOT ok'})` : null],
  ].filter(([, v]) => has(v) && v !== '');
  const verdictTiles = [
    ['Comfortable', has(maxComfortable) ? fmtInt(maxComfortable) : '—', has(maxComfortable) ? 'players at p95 ≤ 100 ms, ≥ 99% connected' : 'no stage met p95 ≤ 100 ms with 99% connected', 'good'],
    ['Last healthy stage', fmtInt(ramp.lastHealthyStage), lastStage && ramp.lastHealthyStage === lastStage.target ? `p95 ${fmtMs(lastStage.action?.p95)}, still serving` : 'per the stop rules', 'sap'],
    ['Ceiling', ceiling ? fmtInt(ceiling.target) : 'none', ceiling ? (ceiling.reasons?.[0] ?? '') : 'no stop rule tripped', ceiling ? 'crit' : 'good'],
    ['Stopped because', ramp.stoppedBecause ?? 'ran to the end', has(ramp.connectionsAtStop) ? `${fmtInt(ramp.connectionsAtStop)} connections at stop` : '', ramp.stoppedBecause ? 'warn' : 'good'],
    ['Errors, all stages', fmtInt(totalErrors), `in ${fmtInt(totalActions)} actions`, totalErrors ? 'warn' : 'good'],
  ];
  return `
<header class="mast">
  <div class="eyebrow">King Teen Patti · Ramp report</div>
  <h1>${esc(TITLE)}</h1>
  <p class="standfirst">${summaryParagraph()}</p>
  <div class="byline">${facts.map(([k, v]) => `<span><b>${esc(k)}</b> ${esc(v)}</span>`).join('')}</div>
</header>
<div class="verdict">${verdictTiles.map(([k, v, s, cls]) => `<div class="vfig"><div class="k">${esc(k)}</div><div class="v ${cls}">${esc(v)}</div><div class="s">${esc(s)}</div></div>`).join('')}</div>`;
}

function sectionSummaryTable() {
  const rows = stages.map((s) => {
    const a = s.action ?? {};
    const refusals = s.joinRefusals && Object.keys(s.joinRefusals).length ? Object.entries(s.joinRefusals).map(([k, v]) => `${k} ${fmtInt(v)}`).join(', ') : '0';
    const cls = ceiling && s.target === ceiling.target ? ' class="dead"' : knee100 && s.target === knee100.target ? ' class="knee"' : '';
    return `<tr${cls}><td>${fmtInt(s.target)}</td><td>${fmtInt(s.connected)}</td><td>${fmtInt(s.joined)}</td><td>${fmtInt(s.login?.p95)}</td><td>${fmtInt(s.connect?.p95)}</td><td>${fmtAsIs(a.perSec)}</td><td>${fmtAsIs(s.hands?.perMinute)}</td>`
      + `<td>${fmtInt(a.p50)}</td><td>${fmtInt(a.p90)}</td><td class="${bandClass(a.p95, stopMs)}">${fmtInt(a.p95)}</td><td class="${bandClass(a.p99, stopMs)}">${fmtInt(a.p99)}</td><td>${fmtInt(a.max)}</td>`
      + `<td>${has(a.errorRate) ? fmtRatio(a.errorRate) : '—'} (${fmtInt(a.errors)})</td><td>${fmtInt(s.healthRtt?.p95)}</td><td>${fmtInt(s.disconnectsDuringHold)}</td><td>${esc(refusals)}</td></tr>`;
  });
  if (ceiling && !ceilingHasRow) {
    // No hold was completed at this target: the ramp aborted while adding players, or /health went away during the hold.
    // `connectedAtStop` is recorded only when the ramp aborted while adding players; `ramp.connectionsAtStop`
    // is the LAST COMPLETED stage's count, so it must not be shown as this stage's.
    rows.push(`<tr class="dead"><td>${fmtInt(ceiling.target)}</td><td>${fmtInt(ceiling.connectedAtStop)}</td><td>—</td><td colspan="13">Stopped — ${esc(ceiling.reasons?.join('; ') ?? 'no reason recorded')}</td></tr>`);
  }
  return `
<section>
  <h2>The ladder</h2>
  <div class="scroll"><table>
    <thead><tr><th>Players</th><th>Conn.</th><th>Joined</th><th>Login p95</th><th>Connect p95</th><th>Act/s</th><th>Hands/min</th><th>p50</th><th>p90</th><th>p95</th><th>p99</th><th>max</th><th>Errors</th><th>Health p95</th><th>Disconn.</th><th>Join refusals</th></tr></thead>
    <tbody>${rows.join('')}</tbody>
  </table></div>
  <p class="cap">Latencies in milliseconds, measured from the generator: login is the REST round trip, connect the websocket handshake, p50–max the <code>game:action</code> acknowledgement round trip during the hold, Health p95 the <code>/health</code> poll. Cells are green at or under 100 ms, amber to 1,000 ms, red above that or above the run's own stop threshold of ${fmtInt(stopMs)} ms. Errors are refused actions during the hold; Disconn. counts sockets dropped during the hold; join refusals are quick-join acks that were not <code>ok</code>. ${knee100 ? `The amber row is where p95 first passed 100 ms.` : ''}</p>
</section>`;
}

function sectionStageCharts() {
  const hostNote = host ? '' : notCollected('No host JSON was given (<code>--host</code>), so the host, PostgreSQL, Redis, network and nginx charts are empty. The game-server charts fall back to what the generator read from <code>/health</code> during each hold.');
  const charts = [];
  // 1. action latency percentiles, log scale — p50 sits at tens of ms while max sits at hundreds or thousands
  charts.push(lineChart({ ...stageX, title: 'Action acknowledgement latency', unit: 'ms', scale: 'log', fmt: fmtInt,
    series: [{ name: 'p50', values: byStage((s) => s.action?.p50) }, { name: 'p95', values: byStage((s) => s.action?.p95) }, { name: 'p99', values: byStage((s) => s.action?.p99) }, { name: 'max', values: byStage((s) => s.action?.max), dash: true }],
    refLines: [{ value: stopMs, label: `stop rule ${fmtInt(stopMs)} ms` }],
    caption: 'Logarithmic axis: each gridline is ten times the one below. Client-observed round trips from the generator machine, over TLS where the target is HTTPS, so they include the network and nginx.' }));
  charts.push(lineChart({ ...stageX, title: 'Login and connect p95', unit: 'ms', fmt: fmtInt,
    series: [{ name: 'login p95', values: byStage((s) => s.login?.p95) }, { name: 'connect p95', values: byStage((s) => s.connect?.p95) }],
    caption: 'Measured while the stage was being filled, not during the hold: the REST login and the websocket handshake of the players added for that stage.' }));
  charts.push(lineChart({ ...stageX, title: 'Actions per second', unit: 'actions/s', series: [{ name: 'actions/s', values: byStage((s) => s.action?.perSec) }], caption: 'Moves acknowledged during the hold, divided by the hold length.' }));
  charts.push(lineChart({ ...stageX, title: 'Hands per minute', unit: 'hands/min', series: [{ name: 'hands/min', values: byStage((s) => s.hands?.perMinute) }], caption: 'Distinct hands that ended during the hold, scaled to a minute.' }));
  if (host) {
    const cores = host.stages[0]?.host?.cpuPerCorePercent?.map((c) => c.core) ?? [];
    charts.push(lineChart({ ...stageX, title: 'Host CPU, total and per core', unit: '% busy', fmt: fmt1,
      series: [{ name: 'all cores (mean)', values: byHost((h) => h.host?.cpuTotalPercentMean), color: 'var(--ink)' },
        ...cores.map((c) => ({ name: `core ${c}`, values: byHost((h) => h.host?.cpuPerCorePercent?.find((p) => p.core === c)?.mean) })),
        { name: 'I/O wait', values: byHost((h) => h.host?.iowaitPercentMean), color: 'var(--ink-3)', dash: true }],
      refLines: [{ value: 100, label: '100%' }],
      caption: 'Mean busy share of each core over the hold window, from node_exporter; the black line is the mean across cores and the dotted grey one the I/O wait share.' }));
    charts.push(lineChart({ ...stageX, title: 'Game server CPU', unit: 'cores', fmt: fmt2,
      series: [{ name: 'mean', values: byHost((h) => h.gameServer?.cpuCoresMean) }, { name: 'max', values: byHost((h) => h.gameServer?.cpuCoresMax) }],
      refLines: has(numCpu) ? [{ value: numCpu, label: `${fmtInt(numCpu)} cores on the host` }] : [],
      caption: 'The gameplay process, in cores of CPU time per second of wall time, from its own process metrics.' }));
    charts.push(lineChart({ ...stageX, title: 'Game server RSS', unit: 'MB', fmt: fmt1,
      series: [{ name: 'mean', values: byHost((h) => h.gameServer?.rssMbMean) }, { name: 'max', values: byHost((h) => h.gameServer?.rssMbMax) }], caption: 'Resident memory of the gameplay process.' }));
    charts.push(lineChart({ ...stageX, title: 'Goroutines', unit: 'goroutines', fmt: fmtInt,
      series: [{ name: 'mean', values: byHost((h) => h.gameServer?.goroutinesMean) }, { name: 'max', values: byHost((h) => h.gameServer?.goroutinesMax) }], caption: 'Every table is one goroutine and every socket a few; the count is the shape of the load.' }));
    charts.push(lineChart({ ...stageX, title: 'WebSocket connections', unit: 'sockets', fmt: fmtInt,
      series: [{ name: 'mean', values: byHost((h) => h.gameServer?.socketsMean) }, { name: 'max', values: byHost((h) => h.gameServer?.socketsMax) }, { name: 'target', values: targets, color: 'var(--ink-3)', dash: true }],
      caption: 'Sockets the game server held open, against the stage target. The count includes anybody else on the server at the time (the resident bots, real players).' }));
    charts.push(lineChart({ ...stageX, title: 'PostgreSQL CPU', unit: '% of one core', fmt: fmt1,
      series: [{ name: 'mean', values: byHost((h) => h.database?.cpuPercentMean) }, { name: 'max', values: byHost((h) => h.database?.cpuPercentMax) }],
      caption: 'Every postgres process summed, as a share of one core (so it can exceed 100), from the host sampler.' }));
    charts.push(lineChart({ ...stageX, title: 'PostgreSQL backends', unit: 'backends', fmt: fmtAsIs,
      series: [{ name: 'backends (mean)', values: byHost((h) => h.database?.backendsMean) }, { name: 'backends (max)', values: byHost((h) => h.database?.backendsMax) }, { name: 'active (max)', values: byHost((h) => h.database?.activeBackendsMax) }, { name: 'game pool (max)', values: byHost((h) => h.database?.poolConnectionsMax), dash: true }],
      refLines: [{ value: host.stages.find((s) => has(s.database?.maxConnections))?.database?.maxConnections ?? null, label: 'max_connections' }],
      caption: 'Connected backends from postgres_exporter, those in state active, and the game\'s pgx pool size; the dashed rule is the server\'s max_connections.' }));
    charts.push(lineChart({ ...stageX, title: 'PostgreSQL transactions per second', unit: 'tx/s', fmt: fmtAsIs,
      series: [{ name: 'mean', values: byHost((h) => h.database?.transactionsPerSecMean) }, { name: 'max', values: byHost((h) => h.database?.transactionsPerSecMax) }, { name: 'rollbacks/s', values: byHost((h) => h.database?.rollbacksPerSecMean), dash: true }],
      caption: 'Commits plus rollbacks per second across every database, from pg_stat_database.' }));
    const ops = [...new Set(host.stages.flatMap((s) => Object.keys(s.database?.txP95Ms ?? {})))].sort();
    charts.push(lineChart({ ...stageX, title: 'PostgreSQL transaction latency, per operation', unit: 'ms', fmt: fmtAsIs,
      series: [...ops.map((op, i) => ({ name: `${op} p95`, values: byHost((h) => h.database?.txP95Ms?.[op]), color: SERIES_VARS[i % SERIES_VARS.length] })), ...ops.map((op, i) => ({ name: `${op} p99`, values: byHost((h) => h.database?.txP99Ms?.[op]), color: SERIES_VARS[i % SERIES_VARS.length], dash: true })), { name: 'mean, all ops', values: byHost((h) => h.database?.txMeanMs), color: 'var(--ink-3)' }],
      caption: 'The game\'s own histogram of its ledger transactions (checkpoint = a pack or a leave, settle = the hand end); the worst 15-second p95 and p99 in the window, solid for p95 and dashed for p99, and the mean over the window in grey.' }));
    charts.push(lineChart({ ...stageX, title: 'Redis memory', unit: 'MB', fmt: fmt2,
      series: [{ name: 'mean', values: byHost((h) => h.redis?.usedMemoryMbMean) }, { name: 'max', values: byHost((h) => h.redis?.usedMemoryMbMax) }], caption: 'used_memory from redis_exporter: every live table\'s snapshot and the presence keys.' }));
    charts.push(lineChart({ ...stageX, title: 'Redis commands per second', unit: 'commands/s', fmt: fmtAsIs,
      series: [{ name: 'mean', values: byHost((h) => h.redis?.commandsPerSecMean) }, { name: 'max', values: byHost((h) => h.redis?.commandsPerSecMax) }, { name: 'game ops/s (mean)', values: byHost((h) => h.redis?.gameOpsPerSecMean), dash: true }],
      caption: 'Commands Redis processed against the game\'s own count of live-store operations (a snapshot save is several commands).' }));
    charts.push(lineChart({ ...stageX, title: 'Redis latency', unit: 'ms', scale: 'log', fmt: fmtAsIs,
      series: [{ name: 'game op p95', values: byHost((h) => h.redis?.gameOpP95Ms) }, { name: 'game op p99', values: byHost((h) => h.redis?.gameOpP99Ms) }, { name: 'client avg', values: byHost((h) => h.redis?.clientLatencyMs?.avg?.mean) }, { name: 'client p95', values: byHost((h) => h.redis?.clientLatencyMs?.p95?.mean) }, { name: 'server mean', values: byHost((h) => h.redis?.serverLatencyMeanMs) }],
      caption: 'Three views, logarithmic. Game op: a live-store operation as the game server times it, queueing and serialisation included. Client: twenty PINGs on a fresh loopback socket, as redis-cli --latency measures. Server mean: Redis\'s own per-command time. A gap between them is time outside Redis.' }));
    charts.push(lineChart({ ...stageX, title: 'Network traffic', unit: 'KB/s', fmt: fmt1,
      series: [{ name: 'rx mean', values: byHost((h) => h.network?.rxKBpsMean) }, { name: 'rx max', values: byHost((h) => h.network?.rxKBpsMax), dash: true }, { name: 'tx mean', values: byHost((h) => h.network?.txKBpsMean) }, { name: 'tx max', values: byHost((h) => h.network?.txKBpsMax), dash: true }],
      caption: `${esc(host.stages[0]?.network?.iface ?? 'the interface')} bytes in (rx) and out (tx) per second, from node_exporter. Out is the larger: every move fans a redacted snapshot out to every seat.` }));
    charts.push(lineChart({ ...stageX, title: 'nginx active connections', unit: 'connections', fmt: fmtInt,
      series: [{ name: 'active (max)', values: byHost((h) => h.nginx?.activeConnectionsMax) }, { name: 'target', values: targets, color: 'var(--ink-3)', dash: true }],
      caption: 'Connections nginx held open, from its stub_status; each player is one TLS session.' }));
  } else {
    // What the generator read from /health each 5 s of the hold — the fallback when nothing else was collected.
    charts.push(lineChart({ ...stageX, title: 'Game server CPU (from /health)', unit: '% of one core', fmt: fmt1,
      series: [{ name: 'mean', values: byStage((s) => s.host?.cpuPercentMean) }, { name: 'max', values: byStage((s) => s.host?.cpuPercentMax) }],
      refLines: has(numCpu) ? [{ value: numCpu * 100, label: `${fmtInt(numCpu)} cores = ${fmtInt(numCpu * 100)}%` }] : [],
      caption: 'The gameplay process as a share of one core, as its /health reported it to the generator during the hold.' }));
    charts.push(lineChart({ ...stageX, title: 'Game server RSS (from /health)', unit: 'MB', fmt: fmt1, series: [{ name: 'max', values: byStage((s) => s.host?.rssMbMax) }], caption: 'The largest resident size /health reported during the hold.' }));
    charts.push(lineChart({ ...stageX, title: 'Goroutines (from /health)', unit: 'goroutines', fmt: fmtInt, series: [{ name: 'max', values: byStage((s) => s.host?.goroutinesMax) }], caption: 'The largest goroutine count /health reported during the hold.' }));
    charts.push(lineChart({ ...stageX, title: 'WebSocket connections (from /health)', unit: 'sockets', fmt: fmtInt,
      series: [{ name: 'min', values: byStage((s) => s.host?.socketsMin) }, { name: 'max', values: byStage((s) => s.host?.socketsMax) }, { name: 'target', values: targets, color: 'var(--ink-3)', dash: true }],
      caption: 'Sockets the game server held open during the hold, from /health, against the stage target.' }));
  }
  charts.push(lineChart({ ...stageX, title: 'Generator lag (validity check)', unit: 'ms', fmt: fmtInt,
    series: [{ name: 'p50', values: byStage((s) => s.generatorLag?.p50) }, { name: 'p95', values: byStage((s) => s.generatorLag?.p95) }, { name: 'max', values: byStage((s) => s.generatorLag?.max), dash: true }],
    caption: 'How late the generator\'s own 100 ms timer fired. If this climbs with the player count the generator machine, not the server, is the bottleneck, and every latency above it is suspect.' }));
  return `
<section>
  <h2>Against the player count</h2>
  <p class="lede">Every chart below has the stage target on its x axis and the numbers it draws in a table under it.</p>
  ${hostNote}
  <div class="two">${charts.join('')}</div>
</section>`;
}

/** One resource table: stages down, the given columns across. */
function resourceTable(title, columns, caption) {
  const rows = stages.map((s) => {
    const h = hostOf(s);
    return `<tr><td>${fmtInt(s.target)}</td>${columns.map(([, f]) => `<td>${h ? f(h, s) : '—'}</td>`).join('')}</tr>`;
  });
  return `<h3>${esc(title)}</h3><div class="scroll"><table><thead><tr><th>Players</th>${columns.map(([k]) => `<th>${k}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>${caption ? `<p class="cap">${caption}</p>` : ''}`;
}

function sectionResourceTables() {
  if (!host) return `<section><h2>Resources per stage</h2>${notCollected('No host JSON was given (<code>--host</code>). Run <code>host-metrics.mjs</code> against the host\'s Prometheus with this ramp report and pass its output to see CPU, RAM, goroutines, sockets, PostgreSQL, Redis, network and nginx per stage.')}</section>`;
  const cores = host.stages[0]?.host?.cpuPerCorePercent?.map((c) => c.core) ?? [];
  const ops = [...new Set(host.stages.flatMap((s) => Object.keys(s.database?.txP95Ms ?? {})))].sort();
  const tables = [
    resourceTable('CPU', [
      ['Host mean', (h) => fmtPct(h.host?.cpuTotalPercentMean)],
      ...cores.map((c) => [`Core ${c} mean / max`, (h) => { const p = h.host?.cpuPerCorePercent?.find((q) => q.core === c); return p ? `${fmtPct(p.mean)} / ${fmtPct(p.max)}` : '—'; }]),
      ['I/O wait', (h) => fmtPct(h.host?.iowaitPercentMean)],
      ['Game cores mean / max', (h) => `${fmt2(h.gameServer?.cpuCoresMean)} / ${fmt2(h.gameServer?.cpuCoresMax)}`],
      ['Game % (sampler) mean / max', (h) => `${fmtPct(h.sampled?.gameplayCpuPercent?.mean)} / ${fmtPct(h.sampled?.gameplayCpuPercent?.max)}`],
      ['PostgreSQL % mean / max', (h) => `${fmtPct(h.database?.cpuPercentMean)} / ${fmtPct(h.database?.cpuPercentMax)}`],
      ['Redis % mean / max', (h) => `${fmtPct(h.redis?.cpuPercentMean)} / ${fmtPct(h.redis?.cpuPercentMax)}`],
    ], 'Host and per-core figures are the busy share of a core from node_exporter. Game cores is CPU seconds per wall second from the process\'s own metrics; the sampler columns are the process CPU as a share of one core from /proc, so PostgreSQL (many processes) can exceed 100%.'),
    resourceTable('RAM', [
      ['Host total', (h) => fmtMb(h.host?.memTotalMb)], ['Host used mean / max', (h) => `${fmtMb(h.host?.memUsedMbMean)} / ${fmtMb(h.host?.memUsedMbMax)}`], ['Host available min', (h) => fmtMb(h.host?.memAvailableMbMin)],
      ['Game RSS mean / max', (h) => `${fmtMb(h.gameServer?.rssMbMean)} / ${fmtMb(h.gameServer?.rssMbMax)}`], ['Game RSS max (/health)', (h, s) => fmtMb(s.host?.rssMbMax)], ['Game heap max (/health)', (h, s) => fmtMb(s.host?.heapUsedMbMax)],
    ], 'Host memory from node_exporter (used = total − available). The two /health columns are what the generator read from the server itself, for a cross-check against the exporter.'),
    resourceTable('Go runtime', [
      ['Goroutines mean / max', (h) => `${fmtInt(h.gameServer?.goroutinesMean)} / ${fmtInt(h.gameServer?.goroutinesMax)}`], ['Goroutines max (/health)', (h, s) => fmtInt(s.host?.goroutinesMax)], ['OS threads max', (h) => fmtInt(h.gameServer?.threadsMax)],
      ['Sched latency p99 max (/health)', (h, s) => has(s.host?.loopLagP99MsMax) ? `${fmtAsIs(s.host.loopLagP99MsMax)} ms` : '—'], ['Sched latency max (/health)', (h, s) => has(s.host?.loopLagMaxMs) ? `${fmtAsIs(s.host.loopLagMaxMs)} ms` : '—'],
      ['Move processing p95 / p99', (h) => `${fmtMs(h.gameServer?.moveProcessingP95Ms)} / ${fmtMs(h.gameServer?.moveProcessingP99Ms)}`],
    ], 'Scheduler latency is Go\'s event-loop-lag analogue, as /health reports it. Move processing is server-side only — the time inside the table actor — which is why it sits far below the client-observed acknowledgements.'),
    resourceTable('Sockets', [
      ['Mean / max', (h) => `${fmtInt(h.gameServer?.socketsMean)} / ${fmtInt(h.gameServer?.socketsMax)}`], ['Peak since server start', (h) => fmtInt(h.gameServer?.socketsPeakSinceStart)],
      ['Accepted in window', (h) => fmtInt(h.gameServer?.connectionsAccepted)], ['Disconnections in window', (h) => fmtInt(h.gameServer?.disconnections)],
      ['Players seated mean / max', (h) => `${fmtInt(h.gameServer?.playersSeatedMean)} / ${fmtInt(h.gameServer?.playersSeatedMax)}`], ['Tables mean (in hand / waiting)', (h) => `${fmtInt(h.gameServer?.tablesMean)} (${fmtInt(h.gameServer?.tablesInHandMean)} / ${fmtInt(h.gameServer?.tablesWaitingMean)})`],
    ], 'From the game server\'s own metrics over the hold window. Accepted and disconnections are the increase of the counters across the window — the stage\'s players connected before it, so accepted is small.'),
    resourceTable('PostgreSQL', [
      ['Backends mean / max', (h) => `${fmtInt(h.database?.backendsMean)} / ${fmtInt(h.database?.backendsMax)}`], ['max_connections', (h) => fmtInt(h.database?.maxConnections)], ['Active mean / max', (h) => `${fmtAsIs(h.database?.activeBackendsMean)} / ${fmtInt(h.database?.activeBackendsMax)}`], ['Game pool max', (h) => fmtInt(h.database?.poolConnectionsMax)], ['Pool waiting max (/health)', (h, s) => fmtInt(s.host?.dbWaitingMax)],
      ['TPS mean / max', (h) => `${fmtInt(h.database?.transactionsPerSecMean)} / ${fmtInt(h.database?.transactionsPerSecMax)}`], ['Commits/s', (h) => fmtInt(h.database?.commitsPerSecMean)], ['Rollbacks/s', (h) => fmtAsIs(h.database?.rollbacksPerSecMean)],
      ['Tx mean', (h) => has(h.database?.txMeanMs) ? `${fmtAsIs(h.database.txMeanMs)} ms` : '—'],
      ...ops.map((op) => [`${op} p95 / p99`, (h) => `${fmtMs(h.database?.txP95Ms?.[op])} / ${fmtMs(h.database?.txP99Ms?.[op])}`]),
      ['CPU mean / max', (h) => `${fmtPct(h.database?.cpuPercentMean)} / ${fmtPct(h.database?.cpuPercentMax)}`],
    ], 'Backends, TPS and rollbacks from postgres_exporter; the transaction latencies are the game\'s own histogram of its ledger writes (the worst 15 s quantile in the window, and the mean over it); CPU from the host sampler, every postgres process summed. Pool waiting is the largest acquire-wait /health reported.'),
    resourceTable('Redis', [
      ['Memory mean / max', (h) => `${fmt2(h.redis?.usedMemoryMbMean)} / ${fmt2(h.redis?.usedMemoryMbMax)} MB`], ['Clients max', (h) => fmtInt(h.redis?.clientsMax)],
      ['Commands/s mean / max', (h) => `${fmtInt(h.redis?.commandsPerSecMean)} / ${fmtInt(h.redis?.commandsPerSecMax)}`], ['Game ops/s', (h) => fmtInt(h.redis?.gameOpsPerSecMean)],
      ['Server mean latency', (h) => has(h.redis?.serverLatencyMeanMs) ? `${fmtAsIs(h.redis.serverLatencyMeanMs)} ms` : '—'],
      ['Game op mean / p95 / p99', (h) => `${fmtAsIs(h.redis?.gameOpMeanMs)} / ${fmtAsIs(h.redis?.gameOpP95Ms)} / ${fmtAsIs(h.redis?.gameOpP99Ms)} ms`],
      ['Client avg / p95 / max', (h) => h.redis?.clientLatencyMs ? `${fmtAsIs(h.redis.clientLatencyMs.avg?.mean)} / ${fmtAsIs(h.redis.clientLatencyMs.p95?.mean)} / ${fmtAsIs(h.redis.clientLatencyMs.max?.max)} ms` : '—'],
      ['CPU mean / max', (h) => `${fmtPct(h.redis?.cpuPercentMean)} / ${fmtPct(h.redis?.cpuPercentMax)}`],
    ], 'Memory, clients, commands and the server\'s own per-command time from redis_exporter; game op from the game server\'s live-store histogram; client latency and CPU from the host sampler (client avg and p95 are the window means of each sample\'s twenty-PING figure, client max is the largest single PING).'),
    resourceTable('Network and nginx', [
      ['rx KB/s mean / max', (h) => `${fmt1(h.network?.rxKBpsMean)} / ${fmt1(h.network?.rxKBpsMax)}`], ['tx KB/s mean / max', (h) => `${fmt1(h.network?.txKBpsMean)} / ${fmt1(h.network?.txKBpsMax)}`],
      ['rx KB/s (sampler) mean / max', (h) => `${fmt1(h.sampled?.netRxKBps?.mean)} / ${fmt1(h.sampled?.netRxKBps?.max)}`], ['tx KB/s (sampler) mean / max', (h) => `${fmt1(h.sampled?.netTxKBps?.mean)} / ${fmt1(h.sampled?.netTxKBps?.max)}`],
      ['nginx active max', (h) => fmtInt(h.nginx?.activeConnectionsMax)], ['nginx accepted in window', (h) => fmtInt(h.nginx?.accepted)],
    ], `Interface ${esc(host.stages[0]?.network?.iface ?? '?')} from node_exporter (15 s rate) and from the host sampler (5 s deltas), which is why the two pairs differ; nginx from its stub_status exporter.`),
  ];
  return `<section><h2>Resources per stage</h2><p class="lede">Every figure is an aggregate over that stage's hold window, ${host.stages[0]?.window ? `${fmtInt(host.stages[0].window.seconds)} s` : ''} of Prometheus samples and sampler lines; a dash is a figure the host did not record.</p>${tables.join('')}</section>`;
}

function sectionTimeSeries() {
  if (!samples) return `<section><h2>Over the whole run</h2>${notCollected('No samples JSONL was given (<code>--samples</code>). Run <code>loadtest/host-sampler.py</code> on the host during the ramp and pass its file to see the host, process CPU, network and Redis figures every few seconds across the whole run, with each stage\'s hold shaded.')}</section>`;
  const rows = samples.filter((r) => has(r.t));
  if (!rows.length) return `<section><h2>Over the whole run</h2>${notCollected('The samples file holds no timestamped lines.')}</section>`;
  const x = rows.map((r) => r.t);
  const bands = stages.filter((s) => s.holdStartedAt && s.holdEndedAt).map((s) => ({ from: new Date(s.holdStartedAt).getTime() / 1000, to: new Date(s.holdEndedAt).getTime() / 1000, label: `${kStage(s.target)} hold` }));
  const ts = { x, xLabel: clock, xTitle: 'UTC', bands, markers: false };
  const pick = (f) => rows.map((r) => { const v = f(r); return has(v) ? v : null; });
  const charts = [
    lineChart({ ...ts, title: 'Host CPU', unit: '% busy', fmt: fmt1, series: [{ name: 'host CPU', values: pick((r) => r.hostCpuPercent) }], caption: 'The whole machine, from /proc/stat, every sample.' }),
    lineChart({ ...ts, title: 'Process CPU', unit: '% of one core', fmt: fmt1, series: [{ name: 'postgres', values: pick((r) => r.cpu?.postgres) }, { name: 'gameplay', values: pick((r) => r.cpu?.gameplay) }, { name: 'redis-server', values: pick((r) => r.cpu?.['redis-server']) }], caption: 'Each name is every process of that name summed, so PostgreSQL can exceed 100%. The first line of the file has no CPU figure (it needs a previous sample) and is left blank.' }),
    lineChart({ ...ts, title: 'Network', unit: 'KB/s', fmt: fmt1, series: [{ name: 'rx', values: pick((r) => (has(r.net?.rxBytesPerSec) ? r.net.rxBytesPerSec / 1024 : null)) }, { name: 'tx', values: pick((r) => (has(r.net?.txBytesPerSec) ? r.net.txBytesPerSec / 1024 : null)) }], caption: 'Bytes per second on the sampled interface, converted to KB/s (÷ 1,024).' }),
    lineChart({ ...ts, title: 'Redis client latency', unit: 'ms', scale: 'log', fmt: fmtAsIs, series: [{ name: 'avg', values: pick((r) => r.redisLatencyMs?.avg) }, { name: 'p95', values: pick((r) => r.redisLatencyMs?.p95) }, { name: 'max', values: pick((r) => r.redisLatencyMs?.max), dash: true }], caption: 'Twenty PINGs on a fresh loopback socket per sample, logarithmic axis.' }),
    lineChart({ ...ts, title: 'Redis memory', unit: 'MB', fmt: fmt2, series: [{ name: 'used', values: pick((r) => (has(r.redis?.usedMemoryBytes) ? r.redis.usedMemoryBytes / 1048576 : null)) }], caption: 'used_memory from INFO, in MB (÷ 1,048,576).' }),
    lineChart({ ...ts, title: 'Redis clients and ops', unit: 'count', fmt: fmtInt, series: [{ name: 'connected clients', values: pick((r) => r.redis?.connectedClients) }, { name: 'ops/s', values: pick((r) => r.redis?.opsPerSec) }], caption: 'instantaneous_ops_per_sec and connected_clients from INFO.' }),
  ];
  const first = rows[0].t; const last = rows.at(-1).t;
  return `<section><h2>Over the whole run</h2><p class="lede">${fmtInt(rows.length)} samples from ${clock(first)} to ${clock(last)} UTC (${fmtInt(last - first)} s), one every ${rows.length > 1 ? fmtAsIs(Number(((last - first) / (rows.length - 1)).toFixed(1))) : '?'} s. The shaded bands are each stage's hold window; what lies between them is the ramp — players being added — and the idle before and after.</p><div class="two">${charts.join('')}</div></section>`;
}

function sectionMethodology() {
  return `
<section>
  <h2>Methodology and how to read this</h2>
  <div class="prose">
  <h3>Where each figure comes from</h3>
  <ul class="tight">
    <li><b>The generator</b> (<code>tools/ramptest.mjs</code>${has(ramp.workers) && ramp.workers > 1 ? `, ${fmtInt(ramp.workers)} worker processes` : ''}): players, connected, joined, login and connect times, the action-acknowledgement percentiles, actions/s, hands/min, errors, disconnects, join refusals, health RTT and its own lag. Every latency is a <b>client-side round trip from the generator machine</b>: it includes the network path, TLS and nginx, not just the server's work.</li>
    <li><b><code>/health</code></b>, polled by the generator every 5 s of each hold: the game process's RSS, heap, CPU share of one core, scheduler latency, goroutines, sockets, players, tables and pool waits. These are what the ramp JSON's <code>host</code> block holds and what this report falls back to when no host JSON is given.</li>
    <li><b>Prometheus on the host</b> (<code>tools/host-metrics.mjs</code>): node_exporter for per-core CPU, I/O wait, memory and the interface counters; the game server's own <code>/metrics</code> for its CPU seconds, RSS, goroutines, threads, sockets, tables, move-processing and ledger-transaction histograms and live-store timings; postgres_exporter for backends, max_connections, active queries, commits and rollbacks; redis_exporter for memory, clients, commands and per-command time; the nginx exporter for connections. Each is aggregated over the stage's exact hold window (mean and max of 15 s samples), so a row describes the same seconds the generator measured.</li>
    <li><b>The host sampler</b> (<code>tools/loadtest/host-sampler.py</code>), what no exporter records: per-process CPU for postgres, gameplay and redis-server from <code>/proc</code>, host CPU, interface bytes, Redis INFO, and Redis latency as a client on the host sees it (twenty PINGs on a fresh loopback socket). Its lines are folded into each stage's row and, when the whole file is given, drawn across the run.</li>
  </ul>
  <h3>The stop rules</h3>
  <p>A stage ends the run when its action p95 is above ${fmtInt(stopMs)} ms, its refused-action rate above ${fmtRatio(stopErr)}, fewer than 90% of its players are connected, or <code>/health</code> stops answering; the ramp also gives up while adding players when more than 5% of the newest fail to connect. The last stage before that is the ceiling; a run with no ceiling was held to its last listed stage.</p>
  <h3>Validity</h3>
  <p>The generator's own lag chart is the check on everything else: it is how late a 100 ms timer fired in the generator process, and if it climbs with the player count the laptop is the bottleneck and the latencies above it are suspect. Below a few milliseconds the figures are the server's.</p>
  <h3>Caveats</h3>
  <ul class="tight">
    <li>Everything ran at one table kind, ${ramp.table ? `<b>${esc(ramp.table.category)}, boot ${fmtInt(ramp.table.boot)}</b>` : 'the ramp\'s table'}; other stakes and the poker rooms write the same checkpoints but deal and settle at their own pace.</li>
    <li>The resident bot fleet and any real players share the server: socket, player and table counts include them, and the "before" line in the header says how many were there.</li>
    <li>The generator's guests are reused between runs (<code>ramp-bot-&lt;n&gt;</code>), so login is an upsert of an existing account, not a first sign-in with a welcome bonus.</li>
    <li>Exporters scrape every 15 s and the sampler every few seconds, so a peak shorter than that is averaged away; the maxima are the largest sample, not the largest instant.</li>
    <li>Bots act within 120–520 ms of their turn and see, show, raise and pack at fixed odds; real players are slower, so a stage's actions/s is a ceiling on what that many people would generate.</li>
  </ul>
  </div>
</section>`;
}

function footer() {
  const files = [['ramp', args.ramp], ['host', args.host], ['samples', args.samples]].filter(([, p]) => p).map(([k, p]) => `${k}: ${esc(path.resolve(p))}`);
  return `<div class="foot">Generated ${iso(new Date().toISOString())} by <code>tools/ramp-report.mjs</code> from ${files.join(' · ')}${host?.collectedAt ? ` · host metrics collected ${iso(host.collectedAt)} from ${esc(host.source ?? '?')}` : ''}. Every figure is from those files; nothing is estimated.</div>`;
}

// -------------------------------------------------------------------- page
const CSS = `
  :root{
    --paper:#F5F7FA; --card:#FFFFFF; --ink:#0E1420; --ink-2:#3B4657; --ink-3:#68748A;
    --rule:#DFE4EC; --rule-2:#EDF0F5;
    --sapphire:#1D5FA8; --sapphire-soft:#E7EFF9; --sapphire-deep:#134680;
    --good:#17795E; --good-soft:#E4F2ED;
    --warn:#B45309; --warn-soft:#FBEEE0;
    --crit:#B4232C; --crit-soft:#FBE9EA;
    --s1:#1D5FA8; --s2:#eb6834; --s3:#1baf7a; --s4:#4a3aa7; --s5:#e87ba4;
    --serif:"IBM Plex Serif",Georgia,"Times New Roman",serif;
    --sans:"IBM Plex Sans",system-ui,-apple-system,"Segoe UI",sans-serif;
    --mono:"IBM Plex Mono",ui-monospace,"SF Mono",Menlo,monospace;
    color-scheme:light;
  }
  @media (prefers-color-scheme:dark){
    :root:not([data-theme="light"]){
      --paper:#0B0F16; --card:#131A25; --ink:#EAEEF5; --ink-2:#B4BECD; --ink-3:#7E8B9E;
      --rule:#242E3D; --rule-2:#1B2431;
      --sapphire:#6BA6E8; --sapphire-soft:#16283D; --sapphire-deep:#9CC6F2;
      --good:#5FCBA5; --good-soft:#122A24; --warn:#E2A155; --warn-soft:#2C2114; --crit:#EE7B83; --crit-soft:#2E1618;
      --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#9085e9; --s5:#d55181;
      color-scheme:dark;
    }
  }
  :root[data-theme="dark"]{
    --paper:#0B0F16; --card:#131A25; --ink:#EAEEF5; --ink-2:#B4BECD; --ink-3:#7E8B9E;
    --rule:#242E3D; --rule-2:#1B2431;
    --sapphire:#6BA6E8; --sapphire-soft:#16283D; --sapphire-deep:#9CC6F2;
    --good:#5FCBA5; --good-soft:#122A24; --warn:#E2A155; --warn-soft:#2C2114; --crit:#EE7B83; --crit-soft:#2E1618;
    --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#9085e9; --s5:#d55181;
    color-scheme:dark;
  }
  *{box-sizing:border-box}
  html{background:var(--paper)}
  body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--sans);font-size:16px;line-height:1.6;-webkit-font-smoothing:antialiased}
  .wrap{max-width:1140px;margin:0 auto;padding:0 16px 96px}
  @media(min-width:700px){.wrap{padding:0 28px 96px}}
  .prose{max-width:72ch}
  h1,h2,h3{text-wrap:balance;margin:0}
  a{color:var(--sapphire)}
  code,.num{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:.92em}
  header.mast{padding:56px 0 30px;border-bottom:2px solid var(--ink)}
  .eyebrow{font-family:var(--mono);font-size:11.5px;letter-spacing:.16em;text-transform:uppercase;color:var(--ink-3);margin-bottom:18px}
  h1{font-family:var(--serif);font-size:clamp(30px,5vw,50px);line-height:1.08;font-weight:600;letter-spacing:-.015em}
  .standfirst{font-family:var(--serif);font-style:italic;font-size:clamp(16px,2vw,19px);color:var(--ink-2);margin-top:18px;max-width:70ch;line-height:1.5}
  .byline{display:flex;flex-wrap:wrap;gap:8px 26px;margin-top:26px;font-family:var(--mono);font-size:12px;color:var(--ink-3)}
  .byline b{color:var(--ink-2);font-weight:500}
  .verdict{display:grid;grid-template-columns:repeat(auto-fit,minmax(178px,1fr));gap:0;border-bottom:1px solid var(--rule);margin-bottom:52px}
  .vfig{padding:24px 22px 22px;border-right:1px solid var(--rule)}
  .vfig:last-child{border-right:0}
  .vfig .k{font-family:var(--mono);font-size:11px;letter-spacing:.11em;text-transform:uppercase;color:var(--ink-3)}
  .vfig .v{font-family:var(--sans);font-size:30px;font-weight:600;line-height:1.15;margin-top:10px;letter-spacing:-.02em;overflow-wrap:anywhere}
  .vfig .s{font-size:13px;color:var(--ink-2);margin-top:6px;line-height:1.4}
  .v.good{color:var(--good)} .v.warn{color:var(--warn)} .v.crit{color:var(--crit)} .v.sap{color:var(--sapphire)}
  section{margin:0 0 60px}
  h2{font-family:var(--serif);font-size:26px;font-weight:600;letter-spacing:-.01em;padding-bottom:11px;border-bottom:1px solid var(--rule);margin-bottom:22px}
  h3{font-family:var(--sans);font-size:15px;font-weight:600;margin:26px 0 10px;letter-spacing:.005em}
  figure h3{margin:0 0 10px}
  p{margin:0 0 15px}
  .lede{font-size:17px;color:var(--ink-2)}
  .scroll{overflow-x:auto;border:1px solid var(--rule);border-radius:3px;background:var(--card)}
  table{border-collapse:collapse;width:100%;font-size:13.5px}
  th,td{padding:8px 12px;text-align:right;white-space:nowrap;border-bottom:1px solid var(--rule-2)}
  th{font-family:var(--mono);font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3);font-weight:500;background:var(--rule-2);position:sticky;top:0;border-bottom:1px solid var(--rule)}
  td:first-child,th:first-child{text-align:left}
  tbody td{font-family:var(--mono);font-variant-numeric:tabular-nums}
  tbody tr:last-child td{border-bottom:0}
  tr.knee td{background:var(--warn-soft)}
  tr.dead td{background:var(--crit-soft);color:var(--ink-2)}
  td.ok{color:var(--good)} td.warn{color:var(--warn);background:var(--warn-soft)} td.crit{color:var(--crit);background:var(--crit-soft);font-weight:600}
  figure{margin:0 0 8px;min-width:0}
  .chart{background:var(--card);border:1px solid var(--rule);border-radius:3px;padding:14px 14px 10px}
  .chart svg{display:block;font-family:var(--mono)}
  .chart .grid{stroke:var(--rule);stroke-width:1}
  .chart .axis{stroke:var(--ink-3);stroke-width:1}
  .chart .tick{font-size:10px;fill:var(--ink-3)}
  .chart .endlbl{font-size:10px;font-weight:500;paint-order:stroke;stroke:var(--card);stroke-width:3px}
  .chart .ref{stroke:var(--crit);stroke-width:1.2;stroke-dasharray:4 3}
  .chart .reflbl{font-size:10px;fill:var(--crit)}
  .chart .mark{stroke:var(--card);stroke-width:2}
  .chart .band{fill:var(--sapphire-soft)}
  .chart .bandlbl{font-size:9.5px;fill:var(--sapphire)}
  .legend{display:flex;flex-wrap:wrap;gap:4px 16px;margin-top:8px;font-family:var(--mono);font-size:11px;color:var(--ink-2)}
  .legend i{display:inline-block;width:12px;height:3px;border-radius:2px;vertical-align:middle;margin-right:6px}
  .cap{font-size:12.5px;color:var(--ink-3);margin:10px 0;line-height:1.5}
  table.numbers{font-size:12.5px}
  table.numbers th,table.numbers td{padding:5px 10px}
  .two{display:grid;grid-template-columns:1fr 1fr;gap:22px 22px;margin-top:8px}
  @media(max-width:820px){.two{grid-template-columns:1fr}}
  .note{border-left:3px solid var(--sapphire);background:var(--sapphire-soft);padding:16px 20px;border-radius:0 3px 3px 0;margin:22px 0}
  .note.muted{border-left-color:var(--ink-3);background:var(--rule-2)}
  .note p:last-child{margin-bottom:0}
  .note .h{font-family:var(--mono);font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3);margin-bottom:7px}
  ul.tight{margin:0 0 15px;padding-left:20px}
  ul.tight li{margin-bottom:8px}
  .foot{border-top:1px solid var(--rule);margin-top:66px;padding-top:20px;font-family:var(--mono);font-size:11.5px;color:var(--ink-3);line-height:1.75;overflow-wrap:anywhere}
`;

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(TITLE)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Serif:ital,wght@0,400;0,600;1,400&amp;family=IBM+Plex+Sans:wght@400;500;600&amp;family=IBM+Plex+Mono:wght@400;500;600&amp;display=swap">
<style>${CSS}</style>
</head>
<body>
<div class="wrap">
${sectionHeader()}
${sectionSummaryTable()}
${sectionStageCharts()}
${sectionResourceTables()}
${sectionTimeSeries()}
${sectionMethodology()}
${footer()}
</div>
</body>
</html>
`;

fs.writeFileSync(OUT, html);
console.log(`report written to ${path.resolve(OUT)} (${(html.length / 1024).toFixed(0)} KB, ${stages.length} stage${stages.length === 1 ? '' : 's'}${host ? ', host metrics' : ''}${samples ? `, ${samples.length} samples` : ''})`);
