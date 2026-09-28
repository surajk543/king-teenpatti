#!/usr/bin/env bash
# deploy.sh — deploy a Go server release on the game host with one command: the latest pull, the
# release tag built, every database migration applied, the service restarted onto it.
#
#   bash go-server/ops/deploy.sh                       the newest go-server/v* tag
#   bash go-server/ops/deploy.sh go-server/v1.11.0     that tag (v1.11.0 and 1.11.0 read the same)
#   bash go-server/ops/deploy.sh --dry-run             what it would do, changing nothing
#   bash go-server/ops/deploy.sh v1.11.0 --force       restart even when /health already reports the tag
#   bash go-server/ops/deploy.sh v1.10.2 --allow-downgrade   go BACK to an older tag (DEPLOY.md §5 first)
#
# Run it as the operator who owns the checkout (write, on game-server-01), from any directory, and
# INSIDE tmux or screen: it finds the repository from its own path, as build.sh does. It asks sudo for
# three things only — the migration, run as the service's user; the restart; the journal when a
# restart goes wrong — up front, before the build, and again (a refresh; it may ask for the password
# once more after a long first build) right before the migration and before the restart.
#
# In order (DEPLOY.md "One-command deploy (deploy.sh)" has the why of each):
#   1. the log (.git/deploy-logs/, the last $LOG_KEEP runs) and a lock (flock on .git/deploy.lock):
#      everything it prints is kept, and two deploys never overlap;
#   2. refuses tracked files with local changes (untracked and ignored ones — .env, bin/,
#      play-key.json — are fine): a deploy checks another commit out over them;
#   3. reads the INSTALLED unit (systemctl show): its user, working directory, environment file and
#      Environment= lines. It must run this checkout's go-server/bin/gameplay from go-server/, and its
#      environment file must be go-server/.env, the file -migrate reads — else it refuses;
#   4. git fetch origin (branches and tags, --prune --force), then fast-forwards the local master to
#      origin/master without touching the working tree — the "latest pull";
#   5. chooses the tag (the argument, or the newest go-server/v* by version) and says what /health
#      reports is running now. It refuses a tag older than $OLDEST_TAG outright (this database cannot
#      run one), and a tag older than what runs without --allow-downgrade. It warns when the installed
#      unit lacks what the tag's unit template asks for, and refuses a checkout it cannot write;
#   6. remembers HEAD and keeps the RUNNING build as bin/gameplay.prev (one: the last) — bin/gameplay,
#      when /health says that is what runs; otherwise the .prev already there, when that is; else it
#      refuses without --force — checks the tag out DETACHED, checks git wrote every file, builds it
#      (the tag's own build.sh) and checks the binary names the tag;
#   7. MIGRATES: the NEW binary's `gameplay -migrate` as the service's user, in its working directory,
#      with its Environment= — every embedded script, through the code a boot runs. BEFORE the
#      restart: the previous build keeps serving while it runs, and a script that fails stops the
#      deploy with nothing restarted. A tag from before -migrate existed migrates at its own boot;
#   8. restarts gameplay — unless /health already reports the tag and the build just made is byte for
#      byte the running one (--force restarts anyway) — waits up to HEALTH_WAIT_SECONDS for /health to
#      answer ok with the tag's version, then watches it HEALTH_WATCH_SECONDS more (the same MainPID,
#      no automatic restart, a rising uptime). From the restart on, Ctrl-C and a dropped session do not
#      stop it: it runs until the new build is judged, and rolls it back if it must;
#   9. reports: the version before and after, the table catalogue /health reports, the tag, the
#      scripts applied, every warning, the time taken, the log.
#
# A failure at 6 or 7 puts bin/gameplay.prev and the remembered HEAD back and restarts nothing. A new
# build that never answers /health, or falls over while it is watched, is rolled back: the journal is
# printed, the previous binary put back, the service restarted onto it and /health waited for again,
# then the remembered HEAD checked out (a checkout that fails then is reported, never fatal).
#
# Exit codes: 0 deployed, already running the tag, or a dry run; 1 refused, or failed before anything
# was restarted — including a command failing unexpectedly or a signal (their own codes are reported
# and mapped to 1); 2 a migration failed (nothing restarted); 3 the new build was rolled back and the
# previous build serves again; 4 the rollback did not come back either, or the run was stopped during
# the restart and cannot say what serves — production may be DOWN.
#
# The checkout is left DETACHED at the tag, on purpose: what runs is the tag, not a branch. master is
# kept at origin/master. So on the host this replaces `git pull origin master`, which fails on a
# detached HEAD — and the next deploy fetches anyway.
#
# Env overrides: REMOTE (origin), BRANCH (master), UNIT (gameplay), HEALTH_URL
# (http://127.0.0.1:<PORT>/health — PORT from the .env when readable, else the unit's Environment=,
# else 3000), HEALTH_WAIT_SECONDS (60), HEALTH_WATCH_SECONDS (30).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" \
  || { printf 'deploy.sh: cannot find the checkout %s belongs to (git says why above)\n' "$SCRIPT_DIR" >&2; exit 1; }

REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-master}"
UNIT="${UNIT:-gameplay}"
TAG_PREFIX="go-server/v"
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-60}"
HEALTH_WATCH_SECONDS="${HEALTH_WATCH_SECONDS:-30}"
LOG_KEEP=20

# The oldest tag this database can run, whatever the flags say (DEPLOY.md §5). Player stats v2
# (go-server/v1.7.0, 27 Sep 2026) keeps player_stats per game; a tag before it writes the table with
# ON CONFLICT (user_id), which this database's table cannot satisfy, so every pack, leave and hand end
# would fail to be written while /health said ok — and go-server/v1.5.0 and older read users columns
# this database does not have. Such a tag goes onto a fresh database only, by hand (DEPLOY.md §8).
# Raise it whenever a release makes the one before it unable to run on the database it leaves.
OLDEST_TAG="go-server/v1.7.0"

# lib.sh: log / note / die, env_value (reads $ENV_FILE), json_get. Its paths follow REPO_DIR, so it
# is pointed at the checkout this script lives in, not at the default /var/www path. It is read
# whole, now, before anything is checked out — as is this script (main runs from memory).
REPO_DIR="$REPO_ROOT"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"
GO_DIR="$REPO_ROOT/go-server"
GO_BIN="$GO_DIR/bin/gameplay"
PREV_BIN="$GO_BIN.prev"

usage() {
  cat <<EOF
usage: bash go-server/ops/deploy.sh [go-server/vX.Y.Z] [--dry-run] [--force] [--allow-downgrade]

  (no tag)           deploy the newest ${TAG_PREFIX}* tag after fetching $REMOTE
  --dry-run          lock, check, fetch and choose the tag; say what would happen; change nothing
  --force            restart even when /health already reports the tag and the build is the same;
                     and go ahead when neither bin/gameplay nor bin/gameplay.prev is the build that
                     runs (the rollback copy is then a build that never ran)
  --allow-downgrade  deploy a tag OLDER than the one running — read DEPLOY.md §5 first. Never one
                     older than $OLDEST_TAG: this database cannot run it

Run as the operator who owns the checkout, inside tmux or screen; sudo is asked for up front (and may
ask again before the migration and the restart). DEPLOY.md "One-command deploy".
EOF
}

# --------------------------------------------------------------- state
TAG_ARG="" DRY_RUN=0 FORCE=0 ALLOW_DOWNGRADE=0
ORIG_HEAD="" ORIG_BRANCH=""          # what was checked out before the deploy
HAVE_PREV=0 PREV_VERSION=""          # the binary kept as bin/gameplay.prev
PREV_PROVEN=0                        # 1: /health said bin/gameplay.prev's version is what runs
KEEP="" KEEP_WHY=""                  # what step 6 does with the rollback copy (choose_rollback_copy)
STAGE="start"                        # start | changed | restarting | restored | rolledback | done
TMP_DIR="$(mktemp -d)"
LOG_FILE="" TEE_PID=""
HEALTH_URL="${HEALTH_URL:-}"         # set in step 3 unless given
UNIT_USER="" UNIT_GROUP="" UNIT_WD="" UNIT_EXEC="" UNIT_LOAD=""
UNIT_ENV_FILES=() UNIT_ENV=()
HEALTH_OK="" HEALTH_VERSION="" HEALTH_UPTIME="" HEALTH_TC_SOURCE="" HEALTH_TC_FALLBACK=""
WARNINGS=()                          # said where they arise, and again in the report
WATCH_WHY=""
CLEANED=0 FINAL_STATUS=1             # clean_up's, once

# ------------------------------------------------------------- helpers
# Every child that could outlive this script (a git gc that detaches, anything build.sh or sudo
# starts) is started with the lock's descriptor closed: a leftover child holding it would refuse the
# next deploy with the pid of a process long gone.
git_() { git -C "$REPO_ROOT" "$@" 9>&-; }
sudo_() { sudo "$@" 9>&-; }
short() { git_ rev-parse --short "$1"; }
warn() { WARNINGS+=("$*"); printf '    WARNING: %s\n' "$*"; }

# unit_prop NAME — one property of the installed unit, as systemctl show gives it; empty when unknown.
unit_prop() { systemctl show "$UNIT" -p "$1" --value 2>/dev/null || true; }

# bin_version PATH — the version a built binary names (`gameplay v1.11.0 go1.27.1 linux/amd64`).
bin_version() { "$1" -version 2>/dev/null | awk '{print $2}' || true; }

# version_core V — V without its leading "v" and a "-dirty" stamp, when it is a release version
# (1.11.0, or 1.11.0-3-gabc1234 past one); empty for anything else ("dev", a bare commit).
version_core() {
  local v="${1#v}"
  v="${v%-dirty}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && printf '%s' "$v"
  return 0
}

# version_older A B — true when release version A is older than B (both cores; sort -V).
version_older() {
  local a b
  a="$(version_core "$1")" b="$(version_core "$2")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] \
    && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$a" ]
}

# read_health — one GET of $HEALTH_URL into HEALTH_OK / HEALTH_VERSION / HEALTH_UPTIME and the table
# catalogue's source and fallback; all empty when nothing answers.
read_health() {
  local body="$TMP_DIR/health.json"
  HEALTH_OK="" HEALTH_VERSION="" HEALTH_UPTIME="" HEALTH_TC_SOURCE="" HEALTH_TC_FALLBACK=""
  if curl -fsS --max-time 3 -o "$body" "$HEALTH_URL" 2>/dev/null; then
    HEALTH_OK="$(json_get "$body" ok)"
    HEALTH_VERSION="$(json_get "$body" version)"
    HEALTH_UPTIME="$(json_get "$body" uptime)"
    HEALTH_TC_SOURCE="$(json_get "$body" tableConfig.source)"
    HEALTH_TC_FALLBACK="$(json_get "$body" tableConfig.fallback)"
  fi
}

# health_words — what the last read_health saw, in words.
health_words() {
  if [ -z "$HEALTH_OK" ]; then
    printf 'nothing (%s does not answer)' "$HEALTH_URL"
  else
    printf '%s (ok=%s)' "${HEALTH_VERSION:-unknown version}" "$HEALTH_OK"
  fi
}

# catalogue_words — the table catalogue the last read_health saw.
catalogue_words() {
  if [ -z "$HEALTH_TC_SOURCE" ]; then
    printf 'not reported'
  else
    printf 'source=%s fallback=%s' "$HEALTH_TC_SOURCE" "${HEALTH_TC_FALLBACK:-?}"
  fi
}

# wait_for_version WANT — polls /health until it answers ok with version WANT (any version when WANT
# is empty), or HEALTH_WAIT_SECONDS pass. Says what it sees whenever that changes; returns 1 on timeout.
wait_for_version() {
  local want="$1" seen="" now i
  note "waiting up to ${HEALTH_WAIT_SECONDS}s for $HEALTH_URL to report ${want:-any version} …"
  for ((i = 0; i <= HEALTH_WAIT_SECONDS; i++)); do
    read_health
    if [ "$HEALTH_OK" = "true" ] && { [ -z "$want" ] || [ "$HEALTH_VERSION" = "$want" ]; }; then
      note "health ok after ${i}s: version ${HEALTH_VERSION:-?}"
      return 0
    fi
    if [ -z "$HEALTH_OK" ]; then now="not answering"; else now="answering ok=$HEALTH_OK version=${HEALTH_VERSION:-?}"; fi
    if [ "$now" != "$seen" ]; then note "${i}s: $now"; seen="$now"; fi
    if [ "$i" -lt "$HEALTH_WAIT_SECONDS" ]; then sleep 1; fi
  done
  return 1
}

# watch_health WANT — the first ok is not the verdict: /health's ok is true the moment the listener is
# up, and a build can fall over seconds later (a background job's panic), then flap under
# Restart=always while every probe between two crashes still says ok. So, HEALTH_WATCH_SECONDS more:
# the unit's MainPID and NRestarts must not change, and at the end /health must answer ok with WANT
# and an uptime past the one first seen. Sets WATCH_WHY and returns 1 when it does not hold.
watch_health() {
  local want="$1" pid0 nr0 up0 pid nr i
  WATCH_WHY=""
  [ "$HEALTH_WATCH_SECONDS" -gt 0 ] || return 0
  pid0="$(unit_prop MainPID)" nr0="$(unit_prop NRestarts)" up0="${HEALTH_UPTIME:-0}"
  note "watching it ${HEALTH_WATCH_SECONDS}s more (MainPID ${pid0:-?}, NRestarts ${nr0:-?}): a build that boots and then falls over is rolled back too"
  for ((i = 1; i <= HEALTH_WATCH_SECONDS; i++)); do
    sleep 1
    pid="$(unit_prop MainPID)" nr="$(unit_prop NRestarts)"
    if [ "$pid" != "$pid0" ]; then
      WATCH_WHY="$UNIT fell over ${i}s after it first answered /health (MainPID ${pid0:-?} → ${pid:-none})"
      return 1
    fi
    if [ -n "$nr0" ] && [ "$nr" != "$nr0" ]; then
      WATCH_WHY="$UNIT was restarted by systemd ${i}s after it first answered /health (NRestarts $nr0 → ${nr:-?})"
      return 1
    fi
  done
  # One slow answer is not a crash: up to five tries for the last word.
  for ((i = 0; i < 5; i++)); do
    read_health
    if [ "$HEALTH_OK" = "true" ] && [ "$HEALTH_VERSION" = "$want" ] \
      && awk -v a="${HEALTH_UPTIME:-0}" -v b="$up0" 'BEGIN { exit !(a + 0 > b + 0) }'; then
      note "still ok after ${HEALTH_WATCH_SECONDS}s: MainPID $pid0, uptime ${HEALTH_UPTIME}s"
      return 0
    fi
    sleep 1
  done
  WATCH_WHY="after ${HEALTH_WATCH_SECONDS}s $HEALTH_URL reports $(health_words), uptime ${HEALTH_UPTIME:-?}s (it was ${up0}s)"
  return 1
}

# unit_env_value KEY — KEY's value among the unit's Environment= assignments, or nothing.
unit_env_value() {
  local kv
  for kv in ${UNIT_ENV[@]+"${UNIT_ENV[@]}"}; do
    if [ "${kv%%=*}" = "$1" ]; then printf '%s' "${kv#*=}"; fi
  done
}

# split_words — the words of one systemctl show value, one per line, shell quoting honoured (a value
# with a space is shown quoted); nothing at all for an empty value. python3 is on every Ubuntu;
# without it, plain whitespace splitting.
split_words() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import shlex, sys
words = shlex.split(sys.stdin.read())
if words:
    print("\n".join(words))'
  else
    tr -s '[:space:]' '\n' | sed '/^$/d'
  fi
}

# read_unit — the INSTALLED unit, which may differ from ops/gameplay-go.service.
read_unit() {
  local out raw kv
  out="$(systemctl show "$UNIT" -p LoadState -p User -p Group -p WorkingDirectory \
    -p EnvironmentFiles -p Environment -p ExecStart 2>/dev/null)" \
    || die "systemctl show $UNIT failed — is systemd running here?"
  UNIT_LOAD="$(printf '%s\n' "$out" | sed -n 's/^LoadState=//p' | head -n1)"
  UNIT_USER="$(printf '%s\n' "$out" | sed -n 's/^User=//p' | head -n1)"
  UNIT_GROUP="$(printf '%s\n' "$out" | sed -n 's/^Group=//p' | head -n1)"
  UNIT_WD="$(printf '%s\n' "$out" | sed -n 's/^WorkingDirectory=//p' | head -n1)"
  # ExecStart={ path=/…/bin/gameplay ; argv[]=/…/bin/gameplay ; ignore_errors=no ; … }
  UNIT_EXEC="$(printf '%s\n' "$out" | sed -n 's/^ExecStart={ path=\([^ ;]*\).*/\1/p' | head -n1)"
  # One EnvironmentFiles= line per file: "/path (ignore_errors=no)".
  mapfile -t UNIT_ENV_FILES < <(printf '%s\n' "$out" | sed -n 's/^EnvironmentFiles=//p' | sed 's/ (ignore_errors=[a-z]*)$//' | sed '/^$/d')
  raw="$(printf '%s\n' "$out" | sed -n 's/^Environment=//p' | head -n1)"
  UNIT_ENV=()
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue   # a unit with no Environment= at all is fine
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "cannot read the unit's Environment= ('$kv' in: $raw)"
    UNIT_ENV+=("$kv")
  done < <(printf '%s' "$raw" | split_words)
}

# check_unit — refuses a unit this script cannot deploy to faithfully.
check_unit() {
  [ "$UNIT_LOAD" = "loaded" ] || die "unit $UNIT is not installed here (LoadState=${UNIT_LOAD:-?}) — the first install is install-go-server.sh (DEPLOY.md §3)"
  [ -n "$UNIT_WD" ] || die "unit $UNIT sets no WorkingDirectory; this script needs it to be $GO_DIR"
  [ "$(realpath -m "$UNIT_WD")" = "$(realpath -m "$GO_DIR")" ] \
    || die "unit $UNIT runs from $UNIT_WD, not from this checkout's go-server ($GO_DIR): this script deploys only the checkout it lives in"
  [ "$(realpath -m "${UNIT_EXEC:-?}")" = "$(realpath -m "$GO_BIN")" ] \
    || die "unit $UNIT runs ${UNIT_EXEC:-an ExecStart it could not read}, not $GO_BIN — the binary this script builds"
  local f
  case "${#UNIT_ENV_FILES[@]}" in
    0) ;;   # no EnvironmentFile: the server reads ./.env itself (godotenv), as -migrate does
    1) f="${UNIT_ENV_FILES[0]#-}"
       [ "$(realpath -m "$f")" = "$(realpath -m "$UNIT_WD/.env")" ] \
         || die "unit $UNIT reads its environment from $f, but gameplay -migrate reads $UNIT_WD/.env (./.env, as the server's own godotenv does) — so it would migrate with another configuration than the server runs. Point EnvironmentFile= at $UNIT_WD/.env, or deploy by hand (DEPLOY.md §3)" ;;
    *) die "unit $UNIT reads ${#UNIT_ENV_FILES[@]} environment files (${UNIT_ENV_FILES[*]}); gameplay -migrate reads $UNIT_WD/.env alone, so it would migrate with another configuration than the server runs. Merge them into $UNIT_WD/.env, or deploy by hand" ;;
  esac
  id -u "${UNIT_USER:-root}" >/dev/null 2>&1 || die "unit $UNIT runs as '${UNIT_USER}', which is not a user on this host"
}

# check_node_env — -migrate's production guards (the JWT secret, no fake providers) are the
# server's, and hang on NODE_ENV=production: said when neither the unit nor the .env (as far as this
# user can read it) sets it.
check_node_env() {
  local from_unit from_env=""
  from_unit="$(unit_env_value NODE_ENV)"
  if [ -r "$ENV_FILE" ]; then from_env="$(env_value NODE_ENV "")"; fi
  if [ "$from_unit" != "production" ] && [ "$from_env" != "production" ]; then
    if [ -r "$ENV_FILE" ]; then
      warn "NODE_ENV=production is in neither the unit's Environment= nor $ENV_FILE: the server runs without its production guards, and gameplay -migrate checks the .env without them too"
    else
      warn "the unit's Environment= does not set NODE_ENV=production, and $(id -un) cannot read $ENV_FILE to see whether it does: if neither does, the production guards are off"
    fi
  fi
}

# span_ms SPAN — a systemd time span ("30", "30s", "1min 30s", "100ms") in milliseconds; fails on
# anything else ("infinity").
span_ms() {
  local total=0 tok n u
  local -a toks
  read -r -a toks <<<"$1"
  [ "${#toks[@]}" -gt 0 ] || return 1
  for tok in "${toks[@]}"; do
    [[ "$tok" =~ ^([0-9]+)(us|ms|s|sec|m|min|h|hr)?$ ]] || return 1
    n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    case "$u" in
      us)       total=$((total + n / 1000)) ;;
      ms)       total=$((total + n)) ;;
      ""|s|sec) total=$((total + n * 1000)) ;;
      m|min)    total=$((total + n * 60000)) ;;
      h|hr)     total=$((total + n * 3600000)) ;;
    esac
  done
  printf '%s' "$total"
}

# check_unit_drift TAG_SHA — the tag's unit template against the INSTALLED unit, for the directives a
# release can need changed: the unit is a copy (install-go-server.sh), so a release that raises
# TimeoutStopSec or LimitNOFILE, or adds an Environment= line, reaches the host only when someone
# copies it again — and a stop timeout under the server's shutdown budget SIGKILLs it mid-settle.
# Warnings, not refusals: what serves today already runs on this unit.
check_unit_drift() {
  local template want have want_ms have_ms kv key drift=0
  template="$(git_ show "$1:go-server/ops/gameplay-go.service" 2>/dev/null)" || {
    note "$2 carries no gameplay-go.service to compare the installed unit with"
    return 0
  }
  tpl() { printf '%s\n' "$template" | sed -n "s/^$1=//p" | tail -n1; }

  want="$(tpl TimeoutStopSec)" have="$(unit_prop TimeoutStopUSec)"
  if [ -n "$want" ]; then
    if want_ms="$(span_ms "$want")" && have_ms="$(span_ms "$have")"; then
      if [ "$have_ms" -lt "$want_ms" ]; then
        warn "the installed unit stops with TimeoutStopSec=$have, the release's template with ${want}s: systemd would SIGKILL the server inside its own shutdown budget, mid-settle"
        drift=1
      fi
    elif [ "$have" != "infinity" ]; then
      note "could not compare the unit's TimeoutStopSec ('$have') with the template's ('$want')"
    fi
  fi
  want="$(tpl LimitNOFILE)" have="$(unit_prop LimitNOFILESoft)"
  if [[ "$want" =~ ^[0-9]+$ ]] && [[ "$have" =~ ^[0-9]+$ ]] && [ "$have" -lt "$want" ]; then
    warn "the installed unit allows LimitNOFILE=$have, the release's template $want: the server dies of EMFILE near that many players"
    drift=1
  fi
  want="$(tpl Restart)" have="$(unit_prop Restart)"
  if [ -n "$want" ] && [ -n "$have" ] && [ "$want" != "$have" ]; then
    warn "the installed unit has Restart=$have, the release's template Restart=$want"
    drift=1
  fi
  want="$(tpl RestartSec)" have="$(unit_prop RestartUSec)"
  if [ -n "$want" ] && want_ms="$(span_ms "$want")" && have_ms="$(span_ms "$have")" && [ "$want_ms" != "$have_ms" ]; then
    warn "the installed unit has RestartSec=$have, the release's template RestartSec=${want}s"
    drift=1
  fi
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    key="${kv%%=*}"
    if [ -z "$(unit_env_value "$key")" ] && ! { [ -r "$ENV_FILE" ] && [ -n "$(env_value "$key" "")" ]; }; then
      warn "the release's template sets Environment=$kv, which the installed unit does not (nor, as far as $(id -un) can read, the .env)"
      drift=1
    fi
  done < <(printf '%s\n' "$template" | sed -n 's/^Environment=//p' | split_words)
  if [ "$drift" = 1 ]; then
    note "compare: systemctl cat $UNIT   with   git -C $REPO_ROOT show $2:go-server/ops/gameplay-go.service"
    note "to install the release's unit (it replaces the installed one whole — check its User= and paths first):"
    note "  git -C $REPO_ROOT show $2:go-server/ops/gameplay-go.service | sudo tee /etc/systemd/system/$UNIT.service >/dev/null && sudo systemctl daemon-reload"
    note "installed before the deploy's restart, that restart already stops and starts the server under it"
  else
    note "the installed unit has what the release's template asks for (TimeoutStopSec, LimitNOFILE, Restart, RestartSec, Environment=)"
  fi
}

# check_writable TAG_SHA — every directory a checkout writes in must be writable by this user: git
# replaces a file by unlinking it and writing a new one, and when it cannot it says so, moves HEAD
# anyway and exits 0 — leaving the old file under the new commit.
check_writable() {
  local dir git_dir
  local -a bad=()
  git_dir="$(git_ rev-parse --absolute-git-dir)"
  while IFS= read -r dir; do
    [ -d "$REPO_ROOT/$dir" ] || continue
    [ -w "$REPO_ROOT/$dir" ] || bad+=("$REPO_ROOT/$dir")
  done < <({ printf '.\n'; git_ ls-tree -r -d --name-only HEAD; git_ ls-tree -r -d --name-only "$1"; } | sort -u)
  [ -w "$git_dir" ] || bad+=("$git_dir")
  if [ -d "$GO_DIR/bin" ] && [ ! -w "$GO_DIR/bin" ]; then bad+=("$GO_DIR/bin"); fi
  if [ "${#bad[@]}" -gt 0 ]; then
    for dir in "${bad[@]}"; do note "not writable: $(stat -c '%U:%G %a' "$dir" 2>/dev/null || echo '?') $dir"; done
    die "$(id -un) cannot write ${#bad[@]} director$([ "${#bad[@]}" = 1 ] && printf y || printf ies) of the checkout (above): a checkout would leave files of the old commit in them — fix their owner or mode so $(id -un) can write them, as their owner or through a group it is in, then run it again"
  fi
  note "every directory of the checkout, .git and go-server/bin are writable by $(id -un)"
}

# unwritten_files — after a checkout: tracked files that do not match HEAD, one per line with their
# and their directory's owner and mode; nothing when git wrote every one.
unwritten_files() {
  local line path
  while IFS= read -r line; do
    path="${line:3}"
    printf '%s  (file %s, directory %s)\n' "$path" \
      "$(stat -c '%U:%G %a' "$REPO_ROOT/$path" 2>/dev/null || echo 'missing')" \
      "$(stat -c '%U:%G %a' "$(dirname "$REPO_ROOT/$path")" 2>/dev/null || echo '?')"
  done < <(git_ status --porcelain --untracked-files=no)
}

# choose_rollback_copy — which build step 6 keeps as bin/gameplay.prev. It must be the build that
# RUNS: an interrupted deploy, or a build.sh with no restart, leaves in bin/gameplay a build that never
# ran, and copying that over .prev would lose the only copy of the running one. Sets KEEP (copy: keep
# bin/gameplay; keep: leave .prev as it is; none: nothing to keep; refuse), KEEP_WHY, PREV_VERSION and
# PREV_PROVEN from what /health reported last and the versions the two binaries name.
choose_rollback_copy() {
  local running="" disk="" prev=""
  if [ -n "$HEALTH_OK" ]; then running="$HEALTH_VERSION"; fi
  if [ -x "$GO_BIN" ]; then disk="$(bin_version "$GO_BIN")"; fi
  if [ -x "$PREV_BIN" ]; then prev="$(bin_version "$PREV_BIN")"; fi
  PREV_PROVEN=0 PREV_VERSION=""
  if [ ! -x "$GO_BIN" ]; then
    KEEP="none" KEEP_WHY="no bin/gameplay yet: nothing to keep, nothing to roll back to"
  elif [ -z "$running" ]; then
    KEEP="copy" PREV_VERSION="$disk"
    KEEP_WHY="bin/gameplay (${disk:-its version unknown}) as bin/gameplay.prev — UNVERIFIED: nothing answers /health, so which build runs cannot be checked"
  elif [ -n "$disk" ] && [ "$disk" = "$running" ]; then
    KEEP="copy" PREV_VERSION="$disk" PREV_PROVEN=1
    KEEP_WHY="bin/gameplay ($disk, the running build) as bin/gameplay.prev"
  elif [ -n "$prev" ] && [ "$prev" = "$running" ]; then
    KEEP="keep" PREV_VERSION="$prev" PREV_PROVEN=1
    KEEP_WHY="bin/gameplay.prev ($prev, the running build) as it is: bin/gameplay (${disk:-its version unknown}) never ran — a deploy stopped before its restart, or a build.sh with no restart — and is not kept"
  elif [ "$FORCE" = 1 ]; then
    KEEP="copy" PREV_VERSION="$disk"
    KEEP_WHY="bin/gameplay (${disk:-its version unknown}) as bin/gameplay.prev although $running runs (--force): the rollback copy is a build that is not running"
  else
    KEEP="refuse"
    KEEP_WHY="neither bin/gameplay (${disk:-its version unknown}) nor bin/gameplay.prev (${prev:-none}) is the build /health reports running ($running), so a rollback could only restart a build that never ran. Put the running build back on disk first — bash go-server/ops/deploy.sh ${TAG_PREFIX}${running#v} --force rebuilds and restarts onto it — or pass --force to accept bin/gameplay as the rollback copy"
  fi
}

# restore_binary — the binary kept as bin/gameplay.prev, back in place. Never fails the caller.
restore_binary() {
  if [ "$HAVE_PREV" = 1 ] && [ -f "$PREV_BIN" ]; then
    if cp --preserve=mode,timestamps "$PREV_BIN" "$GO_BIN.restore.tmp" && mv -f "$GO_BIN.restore.tmp" "$GO_BIN"; then
      note "put bin/gameplay back from bin/gameplay.prev (${PREV_VERSION:-its version unknown})"
    else
      note "COULD NOT put bin/gameplay back from bin/gameplay.prev: copy it by hand: cp $PREV_BIN $GO_BIN"
    fi
  else
    note "there was no previous bin/gameplay to put back"
  fi
}

# restore_checkout — the remembered HEAD checked out again. Returns 1 (and says what to do) when git
# cannot: what serves is the binary, never the checkout, so a caller carries on.
restore_checkout() {
  local ok=1
  if [ -n "$ORIG_BRANCH" ] && [ "$(git_ rev-parse -q --verify "refs/heads/$ORIG_BRANCH^{commit}" || true)" = "$ORIG_HEAD" ]; then
    git_ checkout -q "$ORIG_BRANCH" || ok=0
  else
    git_ -c advice.detachedHead=false checkout -q --detach "$ORIG_HEAD" || ok=0
  fi
  if [ "$ok" = 1 ] && [ -z "$(git_ status --porcelain --untracked-files=no)" ]; then
    note "checkout back at $(short "$ORIG_HEAD")${ORIG_BRANCH:+ ($ORIG_BRANCH)}"
    return 0
  fi
  note "COULD NOT check $(short "$ORIG_HEAD") out again cleanly — these files are not as that commit has them:"
  unwritten_files | sed 's/^/      /'
  note "fix their owner or mode, then: git -C $REPO_ROOT checkout -f --detach $ORIG_HEAD   (the next deploy refuses until then)"
  return 1
}

# restore_previous — both, the binary first.
restore_previous() {
  restore_binary
  restore_checkout || true
  STAGE="restored"
}

# clean_up STATUS — what every way out of a run does, once: a run that stops between the checkout and
# the restart (set -e, Ctrl-C, a dropped session) puts the previous build back rather than leave the tag
# half-deployed; one stopped DURING the restart says so (exit 4); every exit code outside 0–4 is
# reported and mapped to 1 (FINAL_STATUS). Called by the signal traps themselves, not only by the EXIT
# trap: bash can end an EXIT trap that an `exit` in a SIGINT trap started after its first command
# (rehearsed: Ctrl-C during the build left the tag checked out), while a trap's own commands run.
# shellcheck disable=SC2317  # called by the traps, which shellcheck does not follow
clean_up() {
  local status=$1 me="${0##*/}"
  if [ "$CLEANED" = 1 ]; then return 0; fi
  CLEANED=1
  if [ "$status" -ne 0 ] && [ "$STAGE" = "changed" ]; then
    printf '\n%s: stopped unexpectedly (exit %s) after checking the tag out; putting the previous build back\n' "$me" "$status" >&2
    restore_previous
    printf '%s: nothing was restarted; gameplay still runs the build it ran before\n' "$me" >&2
  elif [ "$status" -ne 0 ] && [ "$STAGE" = "restarting" ]; then
    printf '\n%s: STOPPED DURING THE RESTART (exit %s): what serves is unknown — check %s and sudo journalctl -u %s -n 60 --no-pager NOW\n' \
      "$me" "$status" "$HEALTH_URL" "$UNIT" >&2
    status=4
  fi
  case "$status" in
    0|1|2|3|4) ;;
    *) printf '%s: exit %s (a command failed, or a signal stopped the run) — reported as 1\n' "$me" "$status" >&2
       status=1 ;;
  esac
  FINAL_STATUS=$status
}

# on_signal STATUS — the INT, TERM, HUP and PIPE traps until the restart begins: the clean-up, then out.
# shellcheck disable=SC2317
on_signal() {
  set +e
  trap '' INT HUP TERM PIPE
  clean_up "$1"
  exit "$FINAL_STATUS"
}

# on_exit — the EXIT trap: the clean-up (when no signal trap did it), the scratch directory, the log let
# finish, the status.
# shellcheck disable=SC2317
on_exit() {
  local status=$?
  set +e
  trap '' INT HUP TERM PIPE
  clean_up "$status"
  if [ -n "$LOG_FILE" ]; then printf '%s: this run is logged in %s\n' "${0##*/}" "$LOG_FILE" >&2; fi
  rm -rf "$TMP_DIR"
  if [ -n "$TEE_PID" ]; then
    # Let the log's last lines reach the terminal before the prompt does — for two seconds at most:
    # a process that kept the pipe open would otherwise hold the run open with it.
    exec 1>&- 2>&-
    local i
    for ((i = 0; i < 20; i++)); do kill -0 "$TEE_PID" 2>/dev/null || break; sleep 0.1; done
  fi
  exit "$FINAL_STATUS"
}
trap on_exit EXIT
# Until the restart begins, a signal stops the run (and the previous build is put back).
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap 'on_signal 141' PIPE

# start_log — from here everything printed goes to the terminal AND the log. The log's tee ignores
# every signal a terminal or a dropped session sends, and carries on writing the file when the
# terminal is gone, so no printf of this script ever fails for a dead terminal (under set -e that
# would stop it anywhere) and the end of a run nobody watched can still be read. -i as well as the
# trap: bash does not hand an ignored SIGINT on to a process substitution's command (rehearsed — a
# Ctrl-C killed the tee and with it every line after), so tee ignores it itself.
start_log() {
  local log_dir
  log_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)/deploy-logs"
  mkdir -p "$log_dir" || die "cannot create $log_dir for the deploy log"
  LOG_FILE="$log_dir/deploy-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  : >"$LOG_FILE" || die "cannot write the deploy log $LOG_FILE"
  find "$log_dir" -maxdepth 1 -name 'deploy-*.log' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +"$((LOG_KEEP + 1))" | cut -d' ' -f2- | xargs -r -d '\n' rm -f -- || true
  exec > >(trap '' INT HUP TERM QUIT PIPE; exec tee -i -a --output-error=warn-nopipe "$LOG_FILE") 2>&1
  TEE_PID=$!
}

# rollback WHY — the new build is not serving: the journal, the previous binary back, the service
# restarted onto it, /health waited for, then the checkout put back. Exits 3 when the previous build
# serves again, 4 when it does not.
rollback() {
  local why="$1" tag="$2" migrated="$3"
  log "ROLLING BACK: $why — its journal:"
  sudo_ -n journalctl -u "$UNIT" -n 60 --no-pager || note "(the journal could not be read: sudo would not run without a password)"
  restore_binary
  if ! sudo_ -n systemctl restart "$UNIT"; then
    note "sudo systemctl restart $UNIT failed (a dropped session takes sudo's credentials with it). The binary on disk is the"
    note "previous build again, so a new build that keeps crashing comes back on it at systemd's next automatic restart"
  fi
  if [ "$HAVE_PREV" = 1 ] && wait_for_version "$PREV_VERSION"; then
    restore_checkout || true
    STAGE="rolledback"
    printf '\n==> ROLLED BACK. %s was NOT deployed: %s. Production runs %s again.\n' "$tag" "$why" "${PREV_VERSION:-the previous build}" >&2
    printf '    Its migrations %s stay applied (additive; the previous build runs on them). Fix the release, then deploy again.\n' "${migrated:+($migrated)}" >&2
    exit 3
  fi
  restore_checkout || true
  STAGE="rolledback"
  printf '\n==> PRODUCTION IS DOWN. %s: %s, and the previous build did not come back either.\n' "$tag" "$why" >&2
  sudo_ -n journalctl -u "$UNIT" -n 60 --no-pager >&2 || true
  printf '    Look at the journal NOW: sudo journalctl -u %s -f   (the previous binary is bin/gameplay again: sudo systemctl restart %s)\n' "$UNIT" "$UNIT" >&2
  exit 4
}

# ---------------------------------------------------------------- main
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)         DRY_RUN=1 ;;
      --force)           FORCE=1 ;;
      --allow-downgrade) ALLOW_DOWNGRADE=1 ;;
      -h|--help)         usage; return 0 ;;
      -*)                usage >&2; die "unknown option '$arg'" ;;
      *)                 [ -z "$TAG_ARG" ] || die "one tag at a time ('$TAG_ARG' and '$arg')"; TAG_ARG="$arg" ;;
    esac
  done
  [ "$(id -u)" -ne 0 ] || die "run this as the operator who owns the checkout, not as root: a root build leaves root-owned files in go-server/bin and uses ~root's Go. It calls sudo itself where it must."
  local tool
  for tool in git curl flock systemctl realpath tee stat cmp awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
  [[ "$HEALTH_WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "HEALTH_WAIT_SECONDS must be a whole number of seconds, not '$HEALTH_WAIT_SECONDS'"
  [[ "$HEALTH_WATCH_SECONDS" =~ ^[0-9]+$ ]] || die "HEALTH_WATCH_SECONDS must be a whole number of seconds, not '$HEALTH_WATCH_SECONDS'"
  local began=$SECONDS

  # ------------------------------------------------- 1. the log, the lock
  start_log
  local lock_file mode="" holder
  lock_file="$(git_ rev-parse --absolute-git-dir)/deploy.lock"
  exec 9<>"$lock_file"
  if ! flock -n 9; then
    holder="$(tr -d '\n' <"$lock_file" 2>/dev/null || echo '?')"
    die "another deploy holds the lock $lock_file (${holder:-?}). If that pid is gone, a process it started still holds the lock (a git gc it left running, say): \`fuser -v $lock_file\` names it — wait for it to end; never delete the file"
  fi
  printf 'pid %s, %s, since %s\n' "$$" "$(id -un)" "$(date -u +%FT%TZ)" >"$lock_file"
  if [ "$DRY_RUN" = 1 ]; then mode=" — DRY RUN, nothing will change"; fi
  log "Deploying from $REPO_ROOT as $(id -un)$mode"
  note "lock $lock_file"
  note "log  $LOG_FILE"
  if [ "$DRY_RUN" = 0 ] && [ -z "${TMUX:-}${STY:-}" ]; then
    note "not inside tmux or screen: if this session drops before the restart the run stops and puts the previous build back;"
    note "once the restart has begun it runs to its end regardless (read the log above). tmux or screen avoids both"
  fi

  # -------------------------------------------- 2. tracked local changes
  local dirty
  dirty="$(git_ status --porcelain --untracked-files=no)"
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
    die "tracked files have local changes (above) — commit, stash or revert them: a deploy checks another commit out over them"
  fi
  ORIG_HEAD="$(git_ rev-parse HEAD)"
  ORIG_BRANCH="$(git_ symbolic-ref -q --short HEAD || true)"
  note "no tracked changes; HEAD is $(short "$ORIG_HEAD") (${ORIG_BRANCH:-detached})"

  # ------------------------------------------------ 3. the installed unit
  log "Reading the installed unit $UNIT"
  read_unit
  check_unit
  ENV_FILE="${UNIT_ENV_FILES[0]:-$UNIT_WD/.env}"
  ENV_FILE="${ENV_FILE#-}"
  local run_as="${UNIT_USER:-root}" port
  note "User=$run_as${UNIT_GROUP:+ Group=$UNIT_GROUP}  WorkingDirectory=$UNIT_WD  ExecStart=$UNIT_EXEC"
  note "EnvironmentFile=${UNIT_ENV_FILES[0]:-(none: ./.env read by the server itself)}  Environment=${UNIT_ENV[*]:-(none)}"
  port="$(env_value PORT "")"
  [ -n "$port" ] || port="$(unit_env_value PORT)"
  HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${port:-3000}/health}"
  if [ ! -r "$ENV_FILE" ]; then
    note "$ENV_FILE is not readable by $(id -un): the health port comes from the unit or the default (${port:-3000}) — set HEALTH_URL if the server listens elsewhere"
  fi
  check_node_env
  local -a sudo_as=(-u "$run_as")
  if [ -n "$UNIT_GROUP" ] && [ "$UNIT_GROUP" != "$(id -gn "$run_as")" ]; then sudo_as+=(-g "$UNIT_GROUP"); fi
  local -a mig_env=()
  local kv key
  for kv in ${UNIT_ENV[@]+"${UNIT_ENV[@]}"}; do
    # The unit's Environment=, less any key the .env also sets: systemd lets the EnvironmentFile win
    # over Environment=, and godotenv never overrides a variable the process already has — so a key in
    # both is left to godotenv to read from the .env, as the service does. (When this user cannot read
    # the .env, every Environment= line is passed; the template's NODE_ENV and PUBLIC_DIR are not .env keys.)
    key="${kv%%=*}"
    if [ -r "$ENV_FILE" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE"; then continue; fi
    mig_env+=("$kv")
  done

  # --------------------------------------------- 4. fetch; master forward
  log "Fetching $REMOTE (branches and tags)"
  git_ fetch "$REMOTE" --prune --tags --force
  local new_master old_master
  new_master="$(git_ rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH^{commit}")" \
    || die "$REMOTE/$BRANCH does not exist after the fetch"
  old_master="$(git_ rev-parse -q --verify "refs/heads/$BRANCH^{commit}" || true)"
  local master_move=""
  if [ -z "$old_master" ]; then
    master_move="$BRANCH created at $(short "$new_master")"
  elif [ "$old_master" = "$new_master" ]; then
    note "$BRANCH is already at $REMOTE/$BRANCH ($(short "$new_master"))"
  elif git_ merge-base --is-ancestor "$old_master" "$new_master"; then
    local ahead
    ahead="$(git_ rev-list --count "$old_master..$new_master")"
    master_move="$BRANCH fast-forwarded $(short "$old_master")..$(short "$new_master") ($ahead new commit$([ "$ahead" = 1 ] || printf s))"
  else
    die "local $BRANCH ($(short "$old_master")) has commits $REMOTE/$BRANCH lacks — this host should never hold history of its own; look at \`git log $REMOTE/$BRANCH..$BRANCH\` and reset it by hand"
  fi
  if [ -n "$master_move" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      note "would be: $master_move (as a ref, the working tree untouched)"
    else
      # Moved as a ref, never checked out: the working tree changes once, to the tag, right before
      # the build — go-server/public/ is served from disk by the running binary. On master itself,
      # HEAD is detached where it stands first (git will not move the branch it is on by ref).
      if [ "$ORIG_BRANCH" = "$BRANCH" ]; then
        git_ -c advice.detachedHead=false checkout -q --detach
      fi
      git_ update-ref "refs/heads/$BRANCH" "$new_master" ${old_master:+"$old_master"}
      note "$master_move"
    fi
  fi

  # --------------------------------------------------------- 5. the tag
  local tag tag_sha want before
  if [ -n "$TAG_ARG" ]; then
    tag="${TAG_ARG#go-server/}"
    tag="$TAG_PREFIX${tag#v}"
  else
    tag="$(git_ tag --list "${TAG_PREFIX}*" --sort=-v:refname | head -n1)"
    [ -n "$tag" ] || die "no ${TAG_PREFIX}* tag in this checkout or on $REMOTE — cut one with ops/release.sh and push it"
  fi
  tag_sha="$(git_ rev-parse -q --verify "refs/tags/$tag^{commit}")" \
    || die "no tag $tag, even after fetching $REMOTE (the newest: $(git_ tag --list "${TAG_PREFIX}*" --sort=-v:refname | head -n3 | tr '\n' ' '))"
  want="${tag#go-server/}"
  read_health
  before="$(health_words)"
  local before_version="$HEALTH_VERSION" before_catalogue before_source="$HEALTH_TC_SOURCE"
  before_catalogue="$(catalogue_words)"
  log "Target $tag ($(short "$tag_sha"))"
  note "running now: $before; table catalogue $before_catalogue"

  if version_older "$want" "${OLDEST_TAG#go-server/}"; then
    die "$tag cannot run on this database: tags before $OLDEST_TAG (Player stats v2) write player_stats with ON CONFLICT (user_id), which its table cannot satisfy — every pack, leave and hand end would fail to be written while /health said ok — and go-server/v1.5.0 and older do not even boot on it. DEPLOY.md §5: such a tag goes onto a fresh database only, by hand (§8). Not with this script, whatever the flags"
  fi
  local running_version="$before_version" running_from="/health"
  if [ -z "$running_version" ] && [ -x "$GO_BIN" ]; then
    running_version="$(bin_version "$GO_BIN")" running_from="bin/gameplay -version (nothing answers /health)"
  fi
  if [ -n "$running_version" ] && version_older "$want" "$running_version"; then
    if [ "$ALLOW_DOWNGRADE" = 0 ]; then
      die "$tag is OLDER than what runs ($running_version, from $running_from): that is a rollback. Read DEPLOY.md §5 for what $want needs on this database, then run it again with --allow-downgrade"
    fi
    warn "going BACK from $running_version to $want (--allow-downgrade): DEPLOY.md §5 says what an older tag needs"
  elif [ -n "$running_version" ] && [ -z "$(version_core "$running_version")" ]; then
    note "what runs names no release version ($running_version), so whether $want is older cannot be told"
  fi

  local scripts changed has_migrate=0 base="$ORIG_HEAD" base_label="the checkout's HEAD" running_sha=""
  # Compare with what RUNS wherever its tag is known: on a first run the
  # checkout has already been moved to the new commit by hand, so its HEAD
  # would say nothing changed however much the scripts did.
  if [ -n "$running_version" ]; then
    running_sha="$(git_ rev-parse -q --verify "refs/tags/go-server/$running_version^{commit}" || true)"
  fi
  if [ -n "$running_sha" ]; then
    base="$running_sha" base_label="what runs ($running_version)"
  fi
  scripts="$(git_ ls-tree --name-only "$tag_sha" go-server/internal/db/migration/ | sed 's#.*/##' | paste -sd ' ' -)"
  changed="$(git_ diff --name-status "$base" "$tag_sha" -- go-server/internal/db/migration \
    | sed 's#go-server/internal/db/migration/##' | tr '\t' ' ' | paste -sd ';' - | sed 's/;/; /g')"
  note "the tag's migrations: ${scripts:-none}"
  note "changed since $base_label: ${changed:-none}"
  if git_ cat-file -e "$tag_sha:go-server/cmd/gameplay/migrate.go" 2>/dev/null; then has_migrate=1; fi
  check_unit_drift "$tag_sha" "$tag"
  check_writable "$tag_sha"
  choose_rollback_copy

  if [ "$DRY_RUN" = 1 ]; then
    log "Dry run — what a real run would do"
    case "$KEEP" in
      copy) note "would keep $KEEP_WHY" ;;
      keep) note "would keep $KEEP_WHY" ;;
      none) note "$KEEP_WHY" ;;
      refuse) warn "a real run would STOP here: $KEEP_WHY" ;;
    esac
    note "would check out $tag detached ($(short "$tag_sha")) and build it with its ops/build.sh"
    if [ "$has_migrate" = 1 ]; then
      note "would migrate: (cd $UNIT_WD && sudo -n ${sudo_as[*]} env ${mig_env[*]} ./bin/gameplay -migrate)"
    else
      note "would not migrate beforehand: $tag predates gameplay -migrate, so its migrations run at its own boot"
    fi
    if [ "$HEALTH_OK" = "true" ] && [ "$before_version" = "$want" ] && [ "$FORCE" = 0 ]; then
      note "would not restart if the build is byte for byte the running one (it is when $tag has not moved); would restart otherwise"
    else
      note "would restart $UNIT, wait up to ${HEALTH_WAIT_SECONDS}s for /health to report $want and watch it ${HEALTH_WATCH_SECONDS}s more"
    fi
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
      log "Warnings"
      for arg in "${WARNINGS[@]}"; do note "$arg"; done
    fi
    log "Dry run: nothing changed (the fetch only updated $REMOTE's refs and the tags)"
    STAGE="done"
    return 0
  fi
  [ "$KEEP" != "refuse" ] || die "$KEEP_WHY"

  # Asked now, before a build that can take minutes, so the password prompt is not left waiting.
  log "sudo (for the migration as $run_as, the restart and the journal)"
  sudo_ -v || die "sudo refused — this deploy needs it for the migration, the restart and the journal"

  # ---------------------------------------- 6. keep, check out, build
  log "Checking out $tag and building"
  case "$KEEP" in
    copy)
      cp --preserve=mode,timestamps "$GO_BIN" "$PREV_BIN.tmp"
      mv -f "$PREV_BIN.tmp" "$PREV_BIN"
      HAVE_PREV=1
      note "kept $KEEP_WHY" ;;
    keep)
      HAVE_PREV=1
      note "kept $KEEP_WHY" ;;
    none)
      note "$KEEP_WHY" ;;
  esac
  if [ "$KEEP" = "copy" ] && [ "$PREV_PROVEN" = 0 ]; then
    warn "the rollback copy bin/gameplay.prev (${PREV_VERSION:-its version unknown}) is not proven to be a build that ran"
  fi
  STAGE="changed"
  git_ -c advice.detachedHead=false checkout -q --detach "$tag_sha"
  local unwritten
  unwritten="$(unwritten_files)"
  if [ -n "$unwritten" ]; then
    printf '%s\n' "$unwritten" | sed 's/^/    /' >&2
    log "git could not write every file of $tag (above) — putting the previous build back"
    restore_binary
    STAGE="restored"
    if restore_checkout; then
      die "the checkout of $tag left these files as they were (git says so, and exits 0): fix their owner or mode, then deploy again. Nothing was built or restarted"
    fi
    die "the checkout of $tag left these files as they were (git says so, and exits 0), and could not be undone: fix their owner or mode, run the git checkout -f above, then deploy again. Nothing was built or restarted; gameplay runs what it ran"
  fi
  note "HEAD is now $tag ($(short "$tag_sha")), detached; every tracked file as the tag has it"
  # build.sh ends with a hint for the manual routine ("Next: sudo bash …install-go-server.sh …");
  # this script is that routine, so the hint is dropped.
  if ! bash "$GO_DIR/ops/build.sh" 9>&- 2>&1 | sed '/^Next: /d'; then
    log "The build failed — putting the previous build back"
    restore_previous
    die "the build of $tag failed (above); nothing was restarted"
  fi
  local built
  built="$("$GO_BIN" -version 2>/dev/null || true)"
  case "$built" in
    "gameplay $want "*) note "built: $built" ;;
    *) log "The binary does not name the tag — putting the previous build back"
       restore_previous
       die "bin/gameplay says '${built:-nothing}', not $want: another ${TAG_PREFIX}* tag names the same commit, or a file changed during the build" ;;
  esac

  # ------------------------------------------------------- 7. migrate
  local migrate_log="$TMP_DIR/migrate.log" migrated="" usage_text
  usage_text="$("$GO_BIN" -help 2>&1 || true)"
  case "$usage_text" in
    *"-migrate"*)
      log "Migrating with the new binary (gameplay -migrate) — the running server is untouched"
      if ! sudo_ -v; then
        log "sudo refused before the migration — putting the previous build back"
        restore_previous
        die "sudo refused (no password, or no terminal left to ask on): nothing was migrated or restarted"
      fi
      note "as $run_as in $UNIT_WD with ${mig_env[*]:-no extra environment} (and $ENV_FILE, read by the binary)"
      if ! (cd "$UNIT_WD" && sudo_ -n "${sudo_as[@]}" env ${mig_env[@]+"${mig_env[@]}"} "$GO_BIN" -migrate) 2>&1 \
          | tee "$migrate_log" | sed 's/^/    | /'; then
        log "MIGRATION FAILED — putting the previous build back; NOTHING was restarted"
        restore_previous
        read_health
        note "gameplay still runs $(health_words)"
        note "the database is as the failing script left it: that script ran as one transaction and rolled back whole;"
        note "the scripts before it are applied. Every script is idempotent and additive, so the running build is"
        note "unaffected, and the next deploy (or boot) runs them all again. The failing script is named above."
        exit 2
      fi
      migrated="$(sed -n 's/^migrated //p' "$migrate_log" | tail -n1)"
      ;;
    *)
      log "Not migrating beforehand: $tag predates gameplay -migrate"
      note "its migrations run at its own boot, as every release before deploy.sh did"
      migrated="at the boot ($tag predates -migrate)"
      ;;
  esac

  # ------------------------------------------------------- 8. restart
  local restarted="no" after why=""
  read_health
  if [ "$HEALTH_OK" = "true" ] && [ "$HEALTH_VERSION" = "$want" ] && [ "$FORCE" = 0 ]; then
    if [ "$PREV_PROVEN" = 1 ] && [ "$HAVE_PREV" = 1 ] && cmp -s "$GO_BIN" "$PREV_BIN"; then
      trap '' INT HUP   # done: nothing left to stop but the report
      log "already running $want; migrations applied; not restarted"
      note "the build just made is byte for byte the running one (bin/gameplay.prev)"
      STAGE="done"
    else
      warn "/health reports $want, but the build just made is not byte for byte the running one — $tag was moved on $REMOTE, or the running build was made from other sources: restarting onto the tag's build"
    fi
  fi
  if [ "$STAGE" != "done" ]; then
    if ! sudo_ -v; then
      log "sudo refused before the restart — putting the previous build back"
      restore_previous
      die "sudo refused (no password, or no terminal left to ask on): nothing was restarted; the migrations stay applied (additive, and the running build runs on them)"
    fi
    log "Restarting $UNIT (running: ${HEALTH_VERSION:-nothing answers}; target: $want)"
    STAGE="restarting"
    # From here the previous build is stopped: a signal, a dropped session or a dead terminal must not
    # stop the run before the new build is judged — the log carries on without the terminal.
    trap '' INT HUP
    note "from here Ctrl-C and a dropped session do not stop it: it runs until $want is judged (about $((HEALTH_WAIT_SECONDS + HEALTH_WATCH_SECONDS))s at most), logging to the file above"
    if ! sudo_ -n systemctl restart "$UNIT"; then
      why="sudo systemctl restart $UNIT failed"
    elif ! wait_for_version "$want"; then
      why="$want never answered /health ok within ${HEALTH_WAIT_SECONDS}s"
    elif ! watch_health "$want"; then
      why="$WATCH_WHY"
    fi
    if [ -n "$why" ]; then
      rollback "$why" "$tag" "$migrated"
    fi
    restarted="yes"
    STAGE="done"   # INT and HUP stay ignored: the deploy is done, and the report is its record
  fi

  # -------------------------------------------------------- 9. report
  read_health
  after="$(health_words)"
  log "Deployed $tag"
  note "before      $before"
  note "after       $after"
  note "catalogue   $(catalogue_words)   (before: $before_catalogue)"
  note "tag         $tag ($(short "$tag_sha")), checked out detached; $BRANCH at $(short "$new_master") = $REMOTE/$BRANCH"
  note "migrations  ${migrated:-?}"
  note "restarted   $restarted"
  note "kept        bin/gameplay.prev (${PREV_VERSION:-none})"
  note "elapsed     $((SECONDS - began)) s"
  note "log         $LOG_FILE"
  if [ "$HEALTH_TC_FALLBACK" = "true" ]; then
    warn "/health says tableConfig.fallback=true: this build could NOT use the database's table catalogue and plays the env menu instead — the lobby changed. Find the ERROR 'table config' in the journal, fix the rows (-check-table-config), restart"
  elif [ "$before_source" = "db" ] && [ -n "$HEALTH_TC_SOURCE" ] && [ "$HEALTH_TC_SOURCE" != "db" ]; then
    warn "the table catalogue came from the database before and from $HEALTH_TC_SOURCE now: check TABLE_CONFIG_SOURCE in the .env"
  fi
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    log "WARNINGS (${#WARNINGS[@]})"
    for arg in "${WARNINGS[@]}"; do note "$arg"; done
  fi
  printf '\nNext, from anywhere: bash go-server/ops/prod-version.sh   (IN SYNC is the proof)\n'
}

main "$@"
exit $?
