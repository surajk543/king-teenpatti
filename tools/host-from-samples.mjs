#!/usr/bin/env node
/**
 * host-metrics.mjs for a host with NO Prometheus: builds the same per-stage host report from
 * loadtest/host-sampler.py's JSONL alone (and the ramp report's own /health figures), so
 * ramp-report.mjs can draw it.
 *
 *   node host-from-samples.mjs --ramp ramp.json --samples host-samples.jsonl --out ramp-host.json
 *
 * Every value is aggregated over [holdStartedAt, holdEndedAt] of the stage (mean and max of the
 * sampler's lines, one every few seconds), so a stage's row describes the same seconds the generator
 * measured. What only an exporter records — the game's own histograms of its ledger writes, move
 * processing and live-store operations, nginx's accepted count — is left null, and the report says so.
 * The shape matches host-metrics.mjs's, plus `disk`, `tcp` and `load`, which the sampler adds.
 */
import fs from 'node:fs';

const args = Object.fromEntries(process.argv.slice(2).reduce((p, t, i, a) => {
  if (t.startsWith('--')) p.push([t.slice(2), a[i + 1]]);
  return p;
}, []));
if (!args.ramp || !args.samples) {
  console.error('usage: node host-from-samples.mjs --ramp <ramp.json> --samples <host-samples.jsonl> [--out <host.json>]');
  process.exit(2);
}
const OUT = args.out ?? 'ramp-host.json';
const ramp = JSON.parse(fs.readFileSync(args.ramp, 'utf8'));
const SAMPLES = fs.readFileSync(args.samples, 'utf8').split('\n').filter(Boolean).map((l) => {
  try { return JSON.parse(l); } catch { return null; }
}).filter(Boolean);

const fin = (v) => Number.isFinite(v);
const mean = (v) => (v.length ? v.reduce((a, b) => a + b, 0) / v.length : null);
const max = (v) => (v.length ? v.reduce((a, b) => (b > a ? b : a), -Infinity) : null);
const min = (v) => (v.length ? v.reduce((a, b) => (b < a ? b : a), Infinity) : null);
const round = (v, d = 1) => (v === null || v === undefined || !fin(v) ? null : Number(v.toFixed(d)));

function collect(stage) {
  const start = Math.floor(new Date(stage.holdStartedAt).getTime() / 1000);
  const end = Math.ceil(new Date(stage.holdEndedAt).getTime() / 1000);
  const rows = SAMPLES.filter((r) => r.t >= start && r.t <= end && r.cpu);
  const col = (f) => rows.map((r) => { try { return f(r); } catch { return undefined; } }).filter(fin);
  const agg = (f, d = 1) => { const v = col(f); return { mean: round(mean(v), d), max: round(max(v), d), samples: v.length }; };
  const nCores = max(rows.map((r) => r.cores?.length ?? 0)) ?? 0;
  const perCore = Array.from({ length: nCores }, (_, i) => {
    const v = col((r) => r.cores[i]);
    return { core: i, mean: round(mean(v)), max: round(max(v)) };
  });
  const h = stage.host ?? {}; // the ramp's own /health figures for this hold
  const last = rows[rows.length - 1] ?? {};
  const sampled = rows.length ? {
    samples: rows.length,
    postgresCpuPercent: agg((r) => r.cpu.postgres),
    gameplayCpuPercent: agg((r) => r.cpu.gameplay),
    redisCpuPercent: agg((r) => r.cpu['redis-server']),
    nginxCpuPercent: agg((r) => r.cpu.nginx),
    hostCpuPercent: agg((r) => r.hostCpuPercent),
    redisClientLatencyMs: { avg: agg((r) => r.redisLatencyMs.avg, 3), p95: agg((r) => r.redisLatencyMs.p95, 3), max: agg((r) => r.redisLatencyMs.max, 3) },
    redisUsedMemoryMb: agg((r) => r.redis.usedMemoryBytes / 1048576, 2),
    redisOpsPerSec: agg((r) => r.redis.opsPerSec, 0),
    netRxKBps: agg((r) => r.net.rxBytesPerSec / 1024, 1),
    netTxKBps: agg((r) => r.net.txBytesPerSec / 1024, 1),
  } : null;
  const gameCpu = col((r) => r.cpu.gameplay / 100);
  const tps = col((r) => r.pg.tps);
  const rollbacks = col((r) => r.pg.rollbacksPerSec);
  return {
    target: stage.target,
    window: { start: stage.holdStartedAt, end: stage.holdEndedAt, seconds: end - start },
    host: {
      cores: nCores,
      cpuPerCorePercent: perCore,
      cpuTotalPercentMean: round(mean(col((r) => r.hostCpuPercent))),
      cpuTotalPercentMax: round(max(col((r) => r.hostCpuPercent))),
      iowaitPercentMean: round(mean(col((r) => r.iowaitPercent))),
      memTotalMb: last.mem?.totalMb ?? null,
      memUsedMbMean: round(mean(col((r) => r.mem.usedMb)), 0),
      memUsedMbMax: round(max(col((r) => r.mem.usedMb)), 0),
      memAvailableMbMin: round(min(col((r) => r.mem.availableMb)), 0),
      swapUsedMbMax: round(max(col((r) => r.mem.swapUsedMb)), 0),
      load1Max: round(max(col((r) => r.load[0])), 2),
      load1Mean: round(mean(col((r) => r.load[0])), 2),
    },
    gameServer: {
      rssMbMean: round(mean(col((r) => r.rssMb.gameplay)), 0), rssMbMax: round(max(col((r) => r.rssMb.gameplay)), 0),
      cpuCoresMean: round(mean(gameCpu), 2), cpuCoresMax: round(max(gameCpu), 2),
      goroutinesMax: h.goroutinesMax ?? null, goroutinesMean: null, threadsMax: null,
      socketsMean: round(mean(col((r) => r.tcp['3000'])), 0), socketsMax: h.socketsMax ?? round(max(col((r) => r.tcp['3000'])), 0),
      socketsPeakSinceStart: null, connectionsAccepted: null, disconnections: null,
      playersSeatedMean: null, playersSeatedMax: h.playersMax ?? null,
      tablesMean: h.tablesMax ?? null, tablesInHandMean: round(h.activeHandsMean ?? null, 0), tablesInHandMax: h.activeHandsMax ?? null, tablesWaitingMean: null,
      moveProcessingP95Ms: null, moveProcessingP99Ms: null,
      fdsMax: round(max(col((r) => r.gameplayFds)), 0),
    },
    database: {
      poolConnectionsMax: h.dbTotalMax ?? null,
      txP95Ms: {}, txP99Ms: {}, txMeanMs: null,
      commitsPerSecMean: tps.length ? round(mean(tps) - (mean(rollbacks) ?? 0), 0) : null,
      transactionsPerSecMean: round(mean(tps), 0), transactionsPerSecMax: round(max(tps), 0),
      rollbacksPerSecMean: round(mean(rollbacks), 2),
      backendsMean: round(mean(col((r) => r.pg.backends)), 0), backendsMax: round(max(col((r) => r.pg.backends)), 0),
      maxConnections: last.pg?.maxConnections ?? null,
      activeBackendsMean: round(mean(col((r) => r.pg.active)), 1), activeBackendsMax: round(max(col((r) => r.pg.active)), 0),
      idleInTxMax: round(max(col((r) => r.pg.idleInTx)), 0),
      cpuPercentMean: sampled?.postgresCpuPercent.mean ?? null, cpuPercentMax: sampled?.postgresCpuPercent.max ?? null,
      rssMbMax: round(max(col((r) => r.rssMb.postgres)), 0),
    },
    redis: {
      usedMemoryMbMean: round(mean(col((r) => r.redis.usedMemoryBytes / 1048576)), 2), usedMemoryMbMax: round(max(col((r) => r.redis.usedMemoryBytes / 1048576)), 2),
      clientsMax: round(max(col((r) => r.redis.connectedClients)), 0),
      commandsPerSecMean: round(mean(col((r) => r.redis.opsPerSec)), 0), commandsPerSecMax: round(max(col((r) => r.redis.opsPerSec)), 0),
      serverLatencyMeanMs: null, gameOpP95Ms: null, gameOpP99Ms: null, gameOpMeanMs: null, gameOpsPerSecMean: null,
      clientLatencyMs: sampled?.redisClientLatencyMs ?? null,
      cpuPercentMean: sampled?.redisCpuPercent.mean ?? null, cpuPercentMax: sampled?.redisCpuPercent.max ?? null,
    },
    network: {
      iface: args.iface ?? 'ens3',
      rxKBpsMean: sampled?.netRxKBps.mean ?? null, rxKBpsMax: sampled?.netRxKBps.max ?? null,
      txKBpsMean: sampled?.netTxKBps.mean ?? null, txKBpsMax: sampled?.netTxKBps.max ?? null,
    },
    nginx: {
      activeConnectionsMax: round(max(col((r) => r.tcp['443'])), 0), accepted: null,
      cpuPercentMean: sampled?.nginxCpuPercent.mean ?? null, cpuPercentMax: sampled?.nginxCpuPercent.max ?? null,
      rssMbMax: round(max(col((r) => r.rssMb.nginx)), 0),
    },
    disk: {
      rootTotalGb: last.disk?.rootTotalGb ?? null, rootUsedGb: last.disk?.rootUsedGb ?? null, rootUsedPercent: last.disk?.rootUsedPercent ?? null,
      readMBpsMean: round(mean(col((r) => r.disk.readMBps)), 3), readMBpsMax: round(max(col((r) => r.disk.readMBps)), 3),
      writeMBpsMean: round(mean(col((r) => r.disk.writeMBps)), 3), writeMBpsMax: round(max(col((r) => r.disk.writeMBps)), 3),
      writeIopsMean: round(mean(col((r) => r.disk.writeIops)), 1), writeIopsMax: round(max(col((r) => r.disk.writeIops)), 1),
      utilPercentMean: round(mean(col((r) => r.disk.utilPercent))), utilPercentMax: round(max(col((r) => r.disk.utilPercent))),
    },
    sampled,
  };
}

const out = {
  source: 'loadtest/host-sampler.py (no Prometheus on this host)', sampledOnly: true,
  ramp: args.ramp, collectedAt: new Date().toISOString(), stages: [],
};
for (const stage of ramp.results ?? []) {
  if (!stage.holdStartedAt) continue;
  const row = collect(stage);
  out.stages.push(row);
  console.log(`[${row.target}] host cpu ${row.host.cpuTotalPercentMean}% (max ${row.host.cpuTotalPercentMax}%) cores ${row.host.cpuPerCorePercent.map((c) => c.mean).join('/')} | mem used ${row.host.memUsedMbMax} MB | game ${row.gameServer.cpuCoresMax} cores ${row.gameServer.rssMbMax} MB fds ${row.gameServer.fdsMax} | pg backends ${row.database.backendsMax}/${row.database.maxConnections} active ${row.database.activeBackendsMax} tps ${row.database.transactionsPerSecMean} cpu ${row.database.cpuPercentMax}% | nginx conns ${row.nginx.activeConnectionsMax} cpu ${row.nginx.cpuPercentMax}% | disk w ${row.disk.writeMBpsMax} MB/s util ${row.disk.utilPercentMax}% | net rx ${row.network.rxKBpsMean} tx ${row.network.txKBpsMean} KB/s`);
}
fs.writeFileSync(OUT, JSON.stringify(out, null, 2));
console.log(`host metrics written to ${OUT} (${out.stages.length} stages from ${SAMPLES.length} samples)`);
