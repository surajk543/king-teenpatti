#!/usr/bin/env python3
"""Host-side sampler for a load test — what the host's Prometheus does NOT record,
and, on a host with no Prometheus at all, everything the report needs.

    nohup python3 host-sampler.py 5 ~/loadtest/host-samples.jsonl ens3 sda /path/to/go-server/.env \
        > /dev/null 2>&1 &

Arguments, all positional and optional: INTERVAL seconds (5), OUT file, IFACE (eth0), DISK device (sda),
and ENV_FILE — the game server's .env, read ONLY for its DATABASE_URL, so the sampler can count
PostgreSQL's connections as the game's own role sees them. The URL is never written anywhere: it is split
into PG* environment variables for psql, and every query sets its own statement_timeout.

Every INTERVAL seconds, one JSON line:
- `cpu` / `rssMb` / `procs`: every `postgres`, `gameplay`, `redis-server` and `nginx` process summed per
  name from /proc/<pid>/stat and /proc/<pid>/status (CPU as percent of ONE core, so a many-process
  PostgreSQL can exceed 100);
- `hostCpuPercent`, `iowaitPercent` and `cores` (each core's busy percent) from /proc/stat;
- `mem` (total, available, used = total − available, swap used; MB) from /proc/meminfo;
- `load` (1, 5 and 15 minute averages) from /proc/loadavg;
- `disk`: the root filesystem's use (statvfs) and the DISK device's read/write MB/s, IOPS and busy
  percent from /proc/diskstats;
- `net`: IFACE bytes in and out per second;
- `tcp`: ESTABLISHED sockets per local port (443 nginx, 3000 the game, 5432 PostgreSQL, 6379 Redis)
  from /proc/net/tcp and tcp6, and `gameplayFds`, the game server's open file descriptors;
- `pg`: client backends (total, active, idle, idle in transaction), max_connections, and transactions
  and rollbacks per second (pg_stat_database deltas);
- `redis`: its own INFO figures, and `redisLatencyMs`, Redis latency as a CLIENT sees it — twenty PINGs
  on a fresh loopback socket, min/avg/p95/max in ms — the way redis-cli --latency measures it.

Python 3 standard library only, because that is all the host has. host-metrics.mjs (--samples) folds each
ramp stage's window of these lines into that stage's row; host-from-samples.mjs builds a whole host
report from them where there is no Prometheus.
"""
import json
import os
import socket
import subprocess
import sys
import time
from urllib.parse import unquote, urlparse

INTERVAL = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
OUT = sys.argv[2] if len(sys.argv) > 2 else 'host-samples.jsonl'
IFACE = sys.argv[3] if len(sys.argv) > 3 else 'eth0'
DISK = sys.argv[4] if len(sys.argv) > 4 else 'sda'
ENV_FILE = sys.argv[5] if len(sys.argv) > 5 else None
CLK = os.sysconf('SC_CLK_TCK')
PAGE_KB = os.sysconf('SC_PAGE_SIZE') // 1024
NAMES = ('postgres', 'gameplay', 'redis-server', 'nginx')
PORTS = (443, 3000, 5432, 6379)


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


def rss_kb(pid):
    try:
        with open(f'/proc/{pid}/statm') as f:
            return int(f.read().split()[1]) * PAGE_KB
    except (OSError, IndexError, ValueError):
        return 0


def cpu_times():
    """{'cpu': (total, idle, iowait), 'cpu0': …} from /proc/stat."""
    out = {}
    with open('/proc/stat') as f:
        for line in f:
            if not line.startswith('cpu'):
                break
            p = line.split()
            vals = list(map(int, p[1:]))
            out[p[0]] = (sum(vals), vals[3] + vals[4], vals[4])
    return out


def meminfo():
    kv = {}
    with open('/proc/meminfo') as f:
        for line in f:
            k, v = line.split(':', 1)
            kv[k] = int(v.split()[0])  # kB
    total, avail = kv.get('MemTotal', 0), kv.get('MemAvailable', 0)
    return {'totalMb': round(total / 1024), 'availableMb': round(avail / 1024),
            'usedMb': round((total - avail) / 1024),
            'swapUsedMb': round((kv.get('SwapTotal', 0) - kv.get('SwapFree', 0)) / 1024)}


def loadavg():
    with open('/proc/loadavg') as f:
        a = f.read().split()
    return [float(a[0]), float(a[1]), float(a[2])]


def diskstats():
    with open('/proc/diskstats') as f:
        for line in f:
            p = line.split()
            if len(p) > 13 and p[2] == DISK:
                # reads completed, sectors read, writes completed, sectors written, io_ticks (ms)
                return int(p[3]), int(p[5]), int(p[7]), int(p[9]), int(p[12])
    return None


def root_usage():
    s = os.statvfs('/')
    total = s.f_blocks * s.f_frsize
    free = s.f_bavail * s.f_frsize
    used = total - s.f_bfree * s.f_frsize
    return {'rootTotalGb': round(total / 1e9, 1), 'rootUsedGb': round(used / 1e9, 2),
            'rootUsedPercent': round(100.0 * used / max(1, used + free), 1)}


def net():
    with open('/proc/net/dev') as f:
        for line in f:
            if line.strip().startswith(IFACE + ':'):
                p = line.split(':', 1)[1].split()
                return int(p[0]), int(p[8])
    return 0, 0


def tcp_established():
    counts = {str(p): 0 for p in PORTS}
    want = {f'{p:04X}': str(p) for p in PORTS}
    for path in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            with open(path) as f:
                next(f)
                for line in f:
                    p = line.split(None, 4)
                    if len(p) > 3 and p[3] == '01':  # ESTABLISHED
                        port = want.get(p[1].rsplit(':', 1)[1])
                        if port:
                            counts[port] += 1
        except OSError:
            pass
    return counts


def fd_count(pid):
    try:
        return len(os.listdir(f'/proc/{pid}/fd'))
    except OSError:
        return None


def pg_env():
    """PG* variables for psql from the .env's DATABASE_URL; None when there is none."""
    url = os.environ.get('DATABASE_URL')
    if not url and ENV_FILE:
        try:
            with open(ENV_FILE) as f:
                for line in f:
                    if line.startswith('DATABASE_URL='):
                        url = line.split('=', 1)[1].strip().strip('"').strip("'")
        except OSError:
            return None
    if not url:
        return None
    u = urlparse(url)
    env = dict(os.environ)
    env.update({'PGHOST': u.hostname or 'localhost', 'PGPORT': str(u.port or 5432),
                'PGUSER': unquote(u.username or ''), 'PGPASSWORD': unquote(u.password or ''),
                'PGDATABASE': (u.path or '/').lstrip('/') or 'postgres', 'PGCONNECT_TIMEOUT': '2'})
    return env


PG_ENV = pg_env()
PG_SQL = ("set statement_timeout = 2000;"
          "select count(*), count(*) filter (where state = 'active'), count(*) filter (where state = 'idle'),"
          " count(*) filter (where state like 'idle in transaction%') from pg_stat_activity"
          " where backend_type = 'client backend';"
          "select setting from pg_settings where name = 'max_connections';"
          "select coalesce(sum(xact_commit + xact_rollback), 0), coalesce(sum(xact_rollback), 0) from pg_stat_database;")


def pg_stats():
    if not PG_ENV:
        return None
    try:
        out = subprocess.run(['psql', '-X', '-q', '-A', '-t', '-F', ',', '-c', PG_SQL], env=PG_ENV,
                             capture_output=True, text=True, timeout=4).stdout.split()
        a, b, c = out[0].split(','), out[1], out[2].split(',')
        return {'backends': int(a[0]), 'active': int(a[1]), 'idle': int(a[2]), 'idleInTx': int(a[3]),
                'maxConnections': int(b), 'xacts': int(c[0]), 'rollbacks': int(c[1])}
    except (OSError, subprocess.SubprocessError, IndexError, ValueError):
        return None


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
        times = cpu_times()
        rx, tx = net()
        disk = diskstats()
        pg = pg_stats()
        game_pid = pids['gameplay'][0] if pids['gameplay'] else None
        row = {'t': round(now, 3), 'procs': {n: len(ps) for n, ps in pids.items()},
               'rssMb': {n: round(sum(rss_kb(p) for p in ps) / 1024, 1) for n, ps in pids.items()},
               'mem': meminfo(), 'load': loadavg(), 'tcp': tcp_established(),
               'gameplayFds': fd_count(game_pid) if game_pid else None,
               'redisLatencyMs': redis_latency(), 'redis': redis_info()}
        root = root_usage()
        if prev:
            dt = max(1e-3, now - prev['now'])
            row['cpu'] = {n: round(100.0 * (ticks[n] - prev['ticks'].get(n, 0)) / CLK / dt, 1) for n in NAMES}
            tot, idle, iowait = times['cpu']
            ptot, pidle, piowait = prev['times']['cpu']
            dtot = max(1, tot - ptot)
            row['hostCpuPercent'] = round(100.0 * (1 - (idle - pidle) / dtot), 1)
            row['iowaitPercent'] = round(100.0 * (iowait - piowait) / dtot, 1)
            row['cores'] = []
            for name in sorted((k for k in times if k != 'cpu'), key=lambda k: int(k[3:])):
                if name in prev['times']:
                    t1, i1, _ = times[name]
                    t0, i0, _ = prev['times'][name]
                    row['cores'].append(round(100.0 * (1 - (i1 - i0) / max(1, t1 - t0)), 1))
            row['net'] = {'rxBytesPerSec': round((rx - prev['rx']) / dt), 'txBytesPerSec': round((tx - prev['tx']) / dt)}
            d = dict(root)
            if disk and prev['disk']:
                r, rs, w, ws, busy = (a - b for a, b in zip(disk, prev['disk']))
                d.update({'readMBps': round(rs * 512 / 1e6 / dt, 3), 'writeMBps': round(ws * 512 / 1e6 / dt, 3),
                          'readIops': round(r / dt, 1), 'writeIops': round(w / dt, 1),
                          'utilPercent': round(min(100.0, busy / 10.0 / dt), 1)})
            row['disk'] = d
            if pg:
                row['pg'] = {k: pg[k] for k in ('backends', 'active', 'idle', 'idleInTx', 'maxConnections')}
                if prev['pg']:
                    row['pg']['tps'] = round((pg['xacts'] - prev['pg']['xacts']) / dt, 1)
                    row['pg']['rollbacksPerSec'] = round((pg['rollbacks'] - prev['pg']['rollbacks']) / dt, 2)
        else:
            row['disk'] = root
        prev = {'now': now, 'ticks': ticks, 'times': times, 'rx': rx, 'tx': tx, 'disk': disk, 'pg': pg}
        out.write(json.dumps(row) + '\n')
        out.flush()
        time.sleep(max(0.0, INTERVAL - (time.time() - now)))
