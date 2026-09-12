# Shared helpers for install-go-server.sh. Sourced, not run.
# Everything here is read-only apart from what the caller does with the results.

# --- paths (override with env vars when the checkout lives elsewhere) ---------
REPO_DIR="${REPO_DIR:-/var/www/gameplay/king-teenpatti}"
NODE_DIR="$REPO_DIR/server"          # the removed Node server; only its untracked .env may linger
GO_DIR="$REPO_DIR/go-server"
GO_BIN="$GO_DIR/bin/gameplay"
ENV_FILE="${ENV_FILE:-$GO_DIR/.env}"
LEGACY_ENV_FILE="$NODE_DIR/.env"
UNIT_NAME="gameplay.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
UNIT_BACKUP="$UNIT_PATH.node.bak"
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-45}"

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '%s: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0"
}

# env_value KEY [default] — the last KEY=value line of $ENV_FILE, quotes stripped.
env_value() {
  local key="$1" default="${2:-}" value
  [ -r "$ENV_FILE" ] || { printf '%s' "$default"; return; }
  value="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$key=//p" "$ENV_FILE" | tail -n1)"
  value="${value%%[[:space:]]#*}"          # trailing comment
  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/')"
  printf '%s' "${value:-$default}"
}

# json_get FILE DOTTED.PATH — prints the value or nothing. python3 is on every
# Ubuntu; the grep fallback only handles a flat "key":"string" lookup.
json_get() {
  local file="$1" path="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$path" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'):
        v = v[k]
    print(v if not isinstance(v, bool) else str(v).lower())
except Exception:
    pass
PY
  else
    grep -o "\"${path##*.}\":\"[^\"]*\"" "$file" | head -n1 | sed 's/.*:"//; s/"$//'
  fi
}

# wait_for_health WANT_PREFIX — polls 127.0.0.1:$PORT/health until ok:true and
# process.node starts with WANT_PREFIX ("go" or "v"), or HEALTH_WAIT_SECONDS
# pass. Prints the matching JSON on success; returns 1 on timeout. An older
# Node build without the `process` key counts as Node when WANT_PREFIX is "v".
wait_for_health() {
  local want="$1" port url body node ok i
  port="$(env_value PORT 3000)"
  url="http://127.0.0.1:$port/health"
  body="$(mktemp)"
  note "waiting up to ${HEALTH_WAIT_SECONDS}s for $url …"
  for ((i = 0; i < HEALTH_WAIT_SECONDS; i++)); do
    if curl -sf --max-time 2 -o "$body" "$url"; then
      ok="$(json_get "$body" ok)"
      node="$(json_get "$body" process.node)"
      if [ "$ok" = "true" ]; then
        if [ -z "$node" ] && [ "$want" = "v" ]; then
          note "health ok after ${i}s (old Node build: no process.node field)"
          cat "$body"; echo; rm -f "$body"; return 0
        fi
        case "$node" in
          "$want"*)
            note "health ok after ${i}s: process.node = $node"
            HEALTH_NODE="$node"
            cat "$body"; echo; rm -f "$body"; return 0 ;;
          *) note "health answered by process.node = ${node:-?} — still waiting for '${want}*'" ;;
        esac
      fi
    fi
    sleep 1
  done
  rm -f "$body"
  return 1
}

# metrics_head — prints the HTTP status of a HEAD on /metrics with the token
# from .env (no Authorization header when METRICS_TOKEN is empty).
metrics_head() {
  local port path token
  port="$(env_value PORT 3000)"
  path="$(env_value METRICS_PATH /metrics)"
  token="$(env_value METRICS_TOKEN)"
  if [ -n "$token" ]; then
    curl -s -o /dev/null -w '%{http_code}' -I --max-time 5 -H "Authorization: Bearer $token" "http://127.0.0.1:$port$path"
  else
    curl -s -o /dev/null -w '%{http_code}' -I --max-time 5 "http://127.0.0.1:$port$path"
  fi
}

show_service() {
  log "systemctl status $UNIT_NAME"
  systemctl status "$UNIT_NAME" --no-pager || true
  log "journalctl -u ${UNIT_NAME%.service} -n 20"
  journalctl -u "${UNIT_NAME%.service}" -n 20 --no-pager || true
}
