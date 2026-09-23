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
 *
 * Since 24 Sep 2026 (the 1K–9K preprod ladder) it also pulls what the owner
 * asked a full report to carry: p99s beside the p95s, the database's
 * connections and transactions per second (postgres_exporter), its latency as
 * the game measures it (game_db_transaction_duration_seconds), Redis memory,
 * clients, commands/s (redis_exporter) and latency as the game measures it
 * (game_live_store_duration_seconds), and eth0 bytes in and out
 * (node_exporter). What no exporter records — PostgreSQL's own CPU, and Redis
 * latency as a CLIENT on the host sees it — comes from
 * loadtest/host-sampler.py, run on the host during the ramp, whose JSON lines
 * are folded in with --samples <host-samples.jsonl>.
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
const SAMPLES = args.samples ? fs.readFileSync(args.samples, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
const IFACE = args.iface ?? 'eth0';
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
    dbP99, dbMean, movesP99, pgBackends, pgMaxConns, pgActive, pgTps, pgRollbacks,
    redisMem, redisClients, redisCmds, redisExpLatency, liveP95, liveP99, liveMean, liveOps,
    netRx, netTx, goroutinesMean,
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
    byLabel(`histogram_quantile(0.99, sum by (le, op) (rate(game_db_transaction_duration_seconds_bucket[${W}])))`, 'op', start, end),
    scalar(`sum(rate(game_db_transaction_duration_seconds_sum[${W}])) / sum(rate(game_db_transaction_duration_seconds_count[${W}]))`, start, end),
    scalar(`histogram_quantile(0.99, sum by (le) (rate(game_move_processing_duration_seconds_bucket[${W}])))`, start, end),
    scalar('sum(pg_stat_database_numbackends)', start, end),
    scalar('pg_settings_max_connections', start, end),
    scalar('sum(pg_stat_activity_count{state="active"})', start, end),
    scalar(`sum(rate(pg_stat_database_xact_commit[${W}])) + sum(rate(pg_stat_database_xact_rollback[${W}]))`, start, end),
    scalar(`sum(rate(pg_stat_database_xact_rollback[${W}]))`, start, end),
    scalar('redis_memory_used_bytes', start, end),
    scalar('redis_connected_clients', start, end),
    scalar(`rate(redis_commands_processed_total[${W}])`, start, end),
    scalar(`sum(rate(redis_commands_duration_seconds_total[${W}])) / sum(rate(redis_commands_total[${W}]))`, start, end),
    scalar(`histogram_quantile(0.95, sum by (le) (rate(game_live_store_duration_seconds_bucket[${W}])))`, start, end),
    scalar(`histogram_quantile(0.99, sum by (le) (rate(game_live_store_duration_seconds_bucket[${W}])))`, start, end),
    scalar(`sum(rate(game_live_store_duration_seconds_sum[${W}])) / sum(rate(game_live_store_duration_seconds_count[${W}]))`, start, end),
    scalar(`sum(rate(game_live_store_operations_total[${W}]))`, start, end),
    scalar(`rate(node_network_receive_bytes_total{device="${IFACE}"}[${W}])`, start, end),
    scalar(`rate(node_network_transmit_bytes_total{device="${IFACE}"}[${W}])`, start, end),
    scalar('game_server_go_goroutines', start, end),
  ]);
  // The host sampler's lines inside this window (loadtest/host-sampler.py).
  const inWindow = SAMPLES.filter((r) => r.t >= start && r.t <= end && r.cpu);
  const col = (f) => inWindow.map(f).filter((v) => Number.isFinite(v));
  const agg = (f, d = 1) => { const v = col(f); return { mean: round(mean(v), d), max: round(max(v), d), samples: v.length }; };
  const sampled = inWindow.length ? {
    samples: inWindow.length,
    postgresCpuPercent: agg((r) => r.cpu.postgres),
    gameplayCpuPercent: agg((r) => r.cpu.gameplay),
    redisCpuPercent: agg((r) => r.cpu['redis-server']),
    hostCpuPercent: agg((r) => r.hostCpuPercent),
    redisClientLatencyMs: { avg: agg((r) => r.redisLatencyMs?.avg, 3), p95: agg((r) => r.redisLatencyMs?.p95, 3), max: agg((r) => r.redisLatencyMs?.max, 3) },
    redisUsedMemoryMb: agg((r) => r.redis?.usedMemoryBytes / 1048576, 2),
    redisOpsPerSec: agg((r) => r.redis?.opsPerSec, 0),
    netRxKBps: agg((r) => r.net?.rxBytesPerSec / 1024, 1),
    netTxKBps: agg((r) => r.net?.txBytesPerSec / 1024, 1),
  } : null;
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
      moveProcessingP99Ms: round((movesP99.max ?? 0) * 1000, 0),
      goroutinesMean: round(goroutinesMean.mean ?? 0, 0),
    },
    database: {
      poolConnectionsMax: round(poolConns.max ?? 0, 0),
      txP95Ms: Object.fromEntries(Object.entries(dbP95).map(([op, v]) => [op, round((v.max ?? 0) * 1000, 0)])),
      txP99Ms: Object.fromEntries(Object.entries(dbP99).map(([op, v]) => [op, round((v.max ?? 0) * 1000, 0)])),
      txMeanMs: round((dbMean.mean ?? 0) * 1000, 2),
      commitsPerSecMean: round(commits.mean ?? 0, 0),
      transactionsPerSecMean: round(pgTps.mean ?? 0, 0), transactionsPerSecMax: round(pgTps.max ?? 0, 0),
      rollbacksPerSecMean: round(pgRollbacks.mean ?? 0, 2),
      backendsMean: round(pgBackends.mean ?? 0, 0), backendsMax: round(pgBackends.max ?? 0, 0), maxConnections: round(pgMaxConns.last ?? 0, 0),
      activeBackendsMean: round(pgActive.mean ?? 0, 1), activeBackendsMax: round(pgActive.max ?? 0, 0),
      cpuPercentMean: sampled?.postgresCpuPercent.mean ?? null, cpuPercentMax: sampled?.postgresCpuPercent.max ?? null,
    },
    redis: {
      usedMemoryMbMean: round((redisMem.mean ?? 0) / 1048576, 2), usedMemoryMbMax: round((redisMem.max ?? 0) / 1048576, 2),
      clientsMax: round(redisClients.max ?? 0, 0),
      commandsPerSecMean: round(redisCmds.mean ?? 0, 0), commandsPerSecMax: round(redisCmds.max ?? 0, 0),
      serverLatencyMeanMs: round((redisExpLatency.mean ?? 0) * 1000, 3),
      gameOpP95Ms: round((liveP95.max ?? 0) * 1000, 2), gameOpP99Ms: round((liveP99.max ?? 0) * 1000, 2), gameOpMeanMs: round((liveMean.mean ?? 0) * 1000, 3),
      gameOpsPerSecMean: round(liveOps.mean ?? 0, 0),
      clientLatencyMs: sampled?.redisClientLatencyMs ?? null,
      cpuPercentMean: sampled?.redisCpuPercent.mean ?? null, cpuPercentMax: sampled?.redisCpuPercent.max ?? null,
    },
    network: {
      iface: IFACE,
      rxKBpsMean: round((netRx.mean ?? 0) / 1024, 1), rxKBpsMax: round((netRx.max ?? 0) / 1024, 1),
      txKBpsMean: round((netTx.mean ?? 0) / 1024, 1), txKBpsMax: round((netTx.max ?? 0) / 1024, 1),
    },
    nginx: { activeConnectionsMax: round(nginxActive.max ?? 0, 0), accepted: round(nginxAccepted.last ?? 0, 0) },
    sampled,
  };
}

const out = { source: PROM, ramp: RAMP, collectedAt: new Date().toISOString(), stages: [] };
for (const stage of ramp.results ?? []) {
  if (!stage.holdStartedAt) { console.error(`stage ${stage.target} has no hold timestamps (old report format); skipping`); continue; }
  const row = await collect(stage);
  out.stages.push(row);
  const cores = row.host.cpuPerCorePercent.map((c) => `${c.mean}%`).join(' ');
  console.log(`[${row.target}] cores ${cores} | iowait ${row.host.iowaitPercentMean}% | mem used ${row.host.memUsedMbMax} MB | go ${row.gameServer.cpuCoresMax} cores ${row.gameServer.rssMbMax} MB ${row.gameServer.goroutinesMax} goroutines | sockets ${row.gameServer.socketsMax} seated ${row.gameServer.playersSeatedMean} in-hand tables ${row.gameServer.tablesInHandMean}/${row.gameServer.tablesMean} | db p95 ${JSON.stringify(row.database.txP95Ms)} p99 ${JSON.stringify(row.database.txP99Ms)} pool ${row.database.poolConnectionsMax} tps ${row.database.transactionsPerSecMean} backends ${row.database.backendsMax} pg-cpu ${row.database.cpuPercentMax ?? '?'}% | redis ${row.redis.usedMemoryMbMax} MB ${row.redis.commandsPerSecMean} cmd/s op p99 ${row.redis.gameOpP99Ms} ms | net rx ${row.network.rxKBpsMean} tx ${row.network.txKBpsMean} KB/s`);
}
fs.writeFileSync(OUT, JSON.stringify(out, null, 2));
console.log(`host metrics written to ${OUT}`);
