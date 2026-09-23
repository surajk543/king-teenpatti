#!/usr/bin/env python3
"""Host-side sampler for a load test — what the host's Prometheus does NOT record.

    nohup python3 host-sampler.py 5 ~/loadtest/host-samples.jsonl > /dev/null 2>&1 &

Every INTERVAL seconds, one JSON line: the CPU (percent of ONE core, so the
PostgreSQL figure can exceed 100) of every `postgres`, `gameplay` and
`redis-server` process summed per name from /proc/<pid>/stat; the host's
whole-machine CPU from /proc/stat; eth0 bytes in and out per second; Redis's
own INFO figures (used memory, clients, ops/s); and Redis latency as a CLIENT
sees it — twenty PINGs on a fresh loopback socket, min/avg/p95/max in ms — the
way redis-cli --latency measures it. Python 3 standard library only, because
that is all the host has. host-metrics.mjs (--samples) folds each ramp stage's
window of these lines into that stage's row.
"""
import json
import os
import socket
import subprocess
import sys
import time

INTERVAL = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
OUT = sys.argv[2] if len(sys.argv) > 2 else 'host-samples.jsonl'
IFACE = sys.argv[3] if len(sys.argv) > 3 else 'eth0'
CLK = os.sysconf('SC_CLK_TCK')
NAMES = ('postgres', 'gameplay', 'redis-server')


def pids_named():
    out = {n: [] for n in NAMES}
    for pid in os.listdir('/proc'):
        if not pid.isdigit():
            continue
        try:
            with open(f'/proc/{pid}/comm') as f:
                comm = f.read().strip()
        except OSError:
            continue
        for n in NAMES:
            if comm == n:
                out[n].append(int(pid))
    return out


def cpu_ticks(pid):
    try:
        with open(f'/proc/{pid}/stat') as f:
            parts = f.read().rsplit(')', 1)[1].split()
        return int(parts[11]) + int(parts[12])  # utime + stime
    except (OSError, IndexError, ValueError):
        return 0


def cpu_total():
    with open('/proc/stat') as f:
        vals = list(map(int, f.readline().split()[1:]))
    return sum(vals), vals[3] + vals[4]  # total, idle+iowait


def net():
    with open('/proc/net/dev') as f:
        for line in f:
            if line.strip().startswith(IFACE + ':'):
                p = line.split(':', 1)[1].split()
                return int(p[0]), int(p[8])
    return 0, 0


def redis_latency(n=20):
    ts = []
    try:
        s = socket.create_connection(('127.0.0.1', 6379), timeout=1)
        for _ in range(n):
            t0 = time.perf_counter()
            s.sendall(b'PING\r\n')
            s.recv(64)
            ts.append((time.perf_counter() - t0) * 1000)
        s.close()
    except OSError:
        return None
    ts.sort()
    return {'min': round(ts[0], 3), 'avg': round(sum(ts) / len(ts), 3),
            'p95': round(ts[max(0, int(len(ts) * 0.95) - 1)], 3), 'max': round(ts[-1], 3)}


def redis_info():
    try:
        out = subprocess.run(['redis-cli', 'INFO'], capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    kv = dict(l.strip().split(':', 1) for l in out.splitlines() if ':' in l and not l.startswith('#'))
    g = lambda k: int(kv.get(k, 0) or 0)
    return {'usedMemoryBytes': g('used_memory'), 'connectedClients': g('connected_clients'),
            'opsPerSec': g('instantaneous_ops_per_sec'), 'commandsTotal': g('total_commands_processed')}


prev = None
with open(OUT, 'a') as out:
    while True:
        now = time.time()
        pids = pids_named()
        ticks = {n: sum(cpu_ticks(p) for p in ps) for n, ps in pids.items()}
        tot, idle = cpu_total()
        rx, tx = net()
        row = {'t': round(now, 3), 'procs': {n: len(ps) for n, ps in pids.items()},
               'redisLatencyMs': redis_latency(), 'redis': redis_info()}
        if prev:
            dt = max(1e-3, now - prev['now'])
            dtot = max(1, tot - prev['tot'])
            row['cpu'] = {n: round(100.0 * (ticks[n] - prev['ticks'].get(n, 0)) / CLK / dt, 1) for n in NAMES}
            row['hostCpuPercent'] = round(100.0 * (1 - (idle - prev['idle']) / dtot), 1)
            row['net'] = {'rxBytesPerSec': round((rx - prev['rx']) / dt), 'txBytesPerSec': round((tx - prev['tx']) / dt)}
        prev = {'now': now, 'ticks': ticks, 'tot': tot, 'idle': idle, 'rx': rx, 'tx': tx}
        out.write(json.dumps(row) + '\n')
        out.flush()
        time.sleep(max(0.0, INTERVAL - (time.time() - now)))
