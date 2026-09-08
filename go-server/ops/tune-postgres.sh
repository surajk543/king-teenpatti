#!/usr/bin/env bash
# Tune the production PostgreSQL for the game's write pattern: ~1,000 small
# committed transactions per second (one per move), all waiting on the same
# virtual disk. Measured on 8 Sep 2026: pg_test_fsync gives ~650 fsyncs/s
# (1.5 ms each); at 4,000 players the bet transaction p95 reached 0.8 s while
# the Go process idled at one core. The database, not the server, is the limit.
#
#   sudo bash tune-postgres.sh durable   # group commit + planner/WAL sizing; no durability change; reload only
#   sudo bash tune-postgres.sh fast      # durable + synchronous_commit=off (see the warning below); reload only
#   sudo bash tune-postgres.sh memory    # shared_buffers/wal_buffers for an 8 GB host; RESTARTS postgresql (a few seconds of refused moves)
#   sudo bash tune-postgres.sh revert    # ALTER SYSTEM RESET everything this script ever set; reload
#   sudo bash tune-postgres.sh show      # current values
#
# What each mode does
#   durable: commit_delay=1000 (µs) + commit_siblings=5 → when 5+ transactions are
#            in flight, the committer waits up to 1 ms so ONE fsync covers many
#            commits (group commit). Full durability kept; adds ≤1 ms per commit.
#            Also effective_io_concurrency=200, random_page_cost=1.1 (SSD-class
#            virtual disk), checkpoint_timeout=15min, max_wal_size=4GB (fewer,
#            smoother checkpoints), track_wal_io_timing=on (so pg_stat_wal shows
#            sync time in Grafana).
#   fast:    everything in durable, plus synchronous_commit=off. Commits no longer
#            wait for the WAL fsync; the WAL writer flushes every 200 ms.
#            WARNING: on an OS crash or power loss (NOT on a Postgres or game
#            server crash) up to ~600 ms of the most recent committed
#            transactions can be lost. Each transaction is still atomic, so a
#            wallet never disagrees with its ledger — but the last few moves
#            before the crash may be gone. For virtual chips this is the usual
#            trade; it is the owner's call, hence a separate mode.
#   memory:  shared_buffers=2GB, wal_buffers=64MB, effective_cache_size=6GB.
#            Needs a Postgres restart; the game server's pool reconnects by
#            itself and refuses moves (persist_failed) for the second or two
#            Postgres is down. Run at a quiet time.
set -euo pipefail

MODE="${1:-show}"
PSQL=(sudo -u postgres psql -X -q -v ON_ERROR_STOP=1)

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0 $MODE"; exit 1; }
command -v psql >/dev/null || { echo "psql not found"; exit 1; }

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

set_param() { # name value
  "${PSQL[@]}" -c "ALTER SYSTEM SET $1 = '$2';"
  note "$1 = $2"
}
reset_param() {
  "${PSQL[@]}" -c "ALTER SYSTEM RESET $1;" && note "reset $1"
}
show() {
  "${PSQL[@]}" -P pager=off -c "select name, setting, unit, pending_restart from pg_settings where name in ('synchronous_commit','commit_delay','commit_siblings','effective_io_concurrency','random_page_cost','checkpoint_timeout','max_wal_size','track_wal_io_timing','shared_buffers','wal_buffers','effective_cache_size','max_connections') order by 1;"
}

DURABLE_PARAMS=(commit_delay commit_siblings effective_io_concurrency random_page_cost checkpoint_timeout max_wal_size track_wal_io_timing)
FAST_PARAMS=(synchronous_commit)
MEMORY_PARAMS=(shared_buffers wal_buffers effective_cache_size)

case "$MODE" in
  show)
    show ;;
  durable|fast)
    log "Group commit and I/O settings (reload, no restart)"
    set_param commit_delay 1000
    set_param commit_siblings 5
    set_param effective_io_concurrency 200
    set_param random_page_cost 1.1
    set_param checkpoint_timeout 15min
    set_param max_wal_size 4GB
    set_param track_wal_io_timing on
    if [ "$MODE" = fast ]; then
      log "synchronous_commit = off (see the WARNING in this script's header)"
      set_param synchronous_commit off
    fi
    "${PSQL[@]}" -c "select pg_reload_conf();" >/dev/null
    note "configuration reloaded"
    show ;;
  memory)
    log "Memory sizing for an 8 GB host (restart required)"
    set_param shared_buffers 2GB
    set_param wal_buffers 64MB
    set_param effective_cache_size 6GB
    log "Restarting postgresql (the game server refuses moves for a second or two, then reconnects)"
    systemctl restart postgresql
    sleep 2
    show
    note "check the game server picked the database back up:"
    note "  curl -s http://127.0.0.1:3000/health | python3 -m json.tool | grep -A3 '\"db\"'" ;;
  revert)
    log "Resetting every setting this script manages"
    for p in "${DURABLE_PARAMS[@]}" "${FAST_PARAMS[@]}" "${MEMORY_PARAMS[@]}"; do reset_param "$p"; done
    "${PSQL[@]}" -c "select pg_reload_conf();" >/dev/null
    note "reloaded; shared_buffers/wal_buffers/effective_cache_size revert on the next postgresql restart"
    show ;;
  *)
    echo "usage: sudo bash $0 {show|durable|fast|memory|revert}"; exit 2 ;;
esac
