/**
 * Host-side companion to ramptest.mjs: for every stage in a ramp report, pull
 * what the server host recorded during that stage's hold window from its
 * Prometheus (node_exporter, the game server's own metrics, postgres_exporter,
 * nginx exporter) and write them next to the generator's numbers.
 *
 *   ssh -N -L 9090:127.0.0.1:9090 deploy@148.113.24.201 &   # Prometheus lives on the host's loopback
 *   node host-metrics.mjs --prom http://127.0.0.1:9090 --ramp ramp.json --out ramp-host.json
 *
 * Every value is aggregated over [holdStartedAt, holdEndedAt] of the stage
 * (mean and max of 15 s samples), so a stage's row describes the same seconds
 * the generator measured.
 */
import fs from 'node:fs';

const args = Object.fromEntries(process.argv.slice(2).reduce((p, t, i, a) => {
  if (t.startsWith('--')) p.push([t.slice(2), a[i + 1]]);
  return p;
}, []));
const PROM = args.prom ?? 'http://127.0.0.1:9090';
const RAMP = args.ramp;
const OUT = args.out ?? RAMP.replace(/\.json$/, '') + '-host.json';
const STEP = Number(args.step ?? 15);
if (!RAMP) { console.error('--ramp <ramp-report.json> is required'); process.exit(2); }

const ramp = JSON.parse(fs.readFileSync(RAMP, 'utf8'));

async function rangeQuery(query, start, end) {
  const url = new URL('/api/v1/query_range', PROM);
  url.searchParams.set('query', query);
  url.searchParams.set('start', String(start));
  url.searchParams.set('end', String(end));
  url.searchParams.set('step', String(STEP));
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${r.status} for ${query}`);
  const body = await r.json();
  if (body.status !== 'success') throw new Error(`${body.error} for ${query}`);
  return body.data.result; // [{metric:{}, values:[[ts,"v"],...]}]
}

const nums = (series) => series.values.map(([, v]) => Number(v)).filter((v) => Number.isFinite(v));
const mean = (v) => (v.length ? v.reduce((a, b) => a + b, 0) / v.length : null);
const max = (v) => (v.length ? Math.max(...v) : null);
const last = (v) => (v.length ? v[v.length - 1] : null);
const round = (x, d = 1) => (x === null || x === undefined ? null : Number(x.toFixed(d)));

/** One scalar series → {mean, max}. */
async function scalar(query, start, end) {
  const res = await rangeQuery(query, start, end);
  if (!res.length) return { mean: null, max: null, last: null };
  const v = nums(res[0]);
  return { mean: mean(v), max: max(v), last: last(v) };
}

/** Series keyed by one label → { label: {mean, max} }. */
async function byLabel(query, label, start, end) {
  const res = await rangeQuery(query, start, end);
  const out = {};
  for (const s of res) { const v = nums(s); out[s.metric[label] ?? '?'] = { mean: mean(v), max: max(v) }; }
  return out;
}

const W = `${STEP * 2}s`; // rate() window: two scrapes, so a stage's first sample is real

async function collect(stage) {
  const start = Math.floor(new Date(stage.holdStartedAt).getTime() / 1000);
  const end = Math.ceil(new Date(stage.holdEndedAt).getTime() / 1000);
  const span = `${Math.max(STEP, end - start)}s`;
  const [
    cpuByCore, iowait, memTotal, memUsed, memAvail,
    goRss, goCpu, goroutines, goThreads,
    sockets, socketsPeak, connections, disconnections, players, activeGames, waitingGames, tables,
    poolConns, dbP95, movesP95, commits, nginxActive, nginxAccepted,
  ] = await Promise.all([
    byLabel(`1 - avg by (cpu) (rate(node_cpu_seconds_total{mode="idle"}[${W}]))`, 'cpu', start, end),
    scalar(`avg(rate(node_cpu_seconds_total{mode="iowait"}[${W}]))`, start, end),
    scalar('node_memory_MemTotal_bytes', start, end),
    scalar('node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes', start, end),
    scalar('node_memory_MemAvailable_bytes', start, end),
    scalar('game_server_process_resident_memory_bytes', start, end),
    scalar(`rate(game_server_process_cpu_seconds_total[${W}])`, start, end),
    scalar('game_server_go_goroutines', start, end),
    scalar('game_server_go_threads', start, end),
    scalar('game_connected_sockets', start, end),
    scalar('game_connected_sockets_peak', start, end),
    scalar(`increase(game_connections_total[${span}])`, end, end),
    scalar(`sum(increase(game_disconnections_total[${span}]))`, end, end),
    scalar('game_players_online', start, end),
    scalar('game_active_games', start, end),
    scalar('game_waiting_games', start, end),
    scalar('sum(game_tables)', start, end),
    scalar('game_db_pool_connections', start, end),
    byLabel(`histogram_quantile(0.95, sum by (le, op) (rate(game_db_transaction_duration_seconds_bucket[${W}])))`, 'op', start, end),
    scalar(`histogram_quantile(0.95, sum by (le) (rate(game_move_processing_duration_seconds_bucket[${W}])))`, start, end),
    scalar(`sum(rate(pg_stat_database_xact_commit[${W}]))`, start, end),
    scalar('nginx_connections_active', start, end),
    scalar(`increase(nginx_connections_accepted[${span}])`, end, end),
  ]);
  const cores = Object.keys(cpuByCore).sort((a, b) => Number(a) - Number(b));
  return {
    target: stage.target,
    window: { start: stage.holdStartedAt, end: stage.holdEndedAt, seconds: end - start },
    host: {
      cores: cores.length,
      cpuPerCorePercent: cores.map((c) => ({ core: Number(c), mean: round(cpuByCore[c].mean * 100), max: round(cpuByCore[c].max * 100) })),
      cpuTotalPercentMean: round(mean(cores.map((c) => cpuByCore[c].mean)) * 100),
      iowaitPercentMean: round((iowait.mean ?? 0) * 100),
      memTotalMb: round((memTotal.last ?? 0) / 1048576, 0),
      memUsedMbMean: round((memUsed.mean ?? 0) / 1048576, 0),
      memUsedMbMax: round((memUsed.max ?? 0) / 1048576, 0),
      memAvailableMbMin: memAvail.mean === null ? null : round(Math.min(...(await rangeQuery('node_memory_MemAvailable_bytes', start, end)).flatMap(nums)) / 1048576, 0),
    },
    gameServer: {
      rssMbMean: round((goRss.mean ?? 0) / 1048576, 0), rssMbMax: round((goRss.max ?? 0) / 1048576, 0),
      cpuCoresMean: round(goCpu.mean ?? 0, 2), cpuCoresMax: round(goCpu.max ?? 0, 2),
      goroutinesMax: round(goroutines.max ?? 0, 0), threadsMax: round(goThreads.max ?? 0, 0),
      socketsMean: round(sockets.mean ?? 0, 0), socketsMax: round(sockets.max ?? 0, 0), socketsPeakSinceStart: round(socketsPeak.max ?? 0, 0),
      connectionsAccepted: round(connections.last ?? 0, 0), disconnections: round(disconnections.last ?? 0, 0),
      playersSeatedMean: round(players.mean ?? 0, 0), playersSeatedMax: round(players.max ?? 0, 0),
      tablesMean: round(tables.mean ?? 0, 0), tablesInHandMean: round(activeGames.mean ?? 0, 0), tablesInHandMax: round(activeGames.max ?? 0, 0), tablesWaitingMean: round(waitingGames.mean ?? 0, 0),
      moveProcessingP95Ms: round((movesP95.max ?? 0) * 1000, 0),
    },
    database: {
      poolConnectionsMax: round(poolConns.max ?? 0, 0),
      txP95Ms: Object.fromEntries(Object.entries(dbP95).map(([op, v]) => [op, round((v.max ?? 0) * 1000, 0)])),
      commitsPerSecMean: round(commits.mean ?? 0, 0),
    },
    nginx: { activeConnectionsMax: round(nginxActive.max ?? 0, 0), accepted: round(nginxAccepted.last ?? 0, 0) },
  };
}

const out = { source: PROM, ramp: RAMP, collectedAt: new Date().toISOString(), stages: [] };
for (const stage of ramp.results ?? []) {
  if (!stage.holdStartedAt) { console.error(`stage ${stage.target} has no hold timestamps (old report format); skipping`); continue; }
  const row = await collect(stage);
  out.stages.push(row);
  const cores = row.host.cpuPerCorePercent.map((c) => `${c.mean}%`).join(' ');
  console.log(`[${row.target}] cores ${cores} | iowait ${row.host.iowaitPercentMean}% | mem used ${row.host.memUsedMbMax} MB | go ${row.gameServer.cpuCoresMax} cores ${row.gameServer.rssMbMax} MB ${row.gameServer.goroutinesMax} goroutines | sockets ${row.gameServer.socketsMax} seated ${row.gameServer.playersSeatedMean} in-hand tables ${row.gameServer.tablesInHandMean}/${row.gameServer.tablesMean} | db p95 ${JSON.stringify(row.database.txP95Ms)} pool ${row.database.poolConnectionsMax} commits/s ${row.database.commitsPerSecMean}`);
}
fs.writeFileSync(OUT, JSON.stringify(out, null, 2));
console.log(`host metrics written to ${OUT}`);
