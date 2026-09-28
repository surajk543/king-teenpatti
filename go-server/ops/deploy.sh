#!/usr/bin/env bash
# deploy.sh — deploy a Go server release on the game host with one command: the latest pull, the
# release tag built, every database migration applied, the service restarted onto it.
#
#   bash go-server/ops/deploy.sh                       the newest go-server/v* tag
#   bash go-server/ops/deploy.sh go-server/v1.11.0     that tag (v1.11.0 and 1.11.0 read the same)
#   bash go-server/ops/deploy.sh --dry-run             what it would do, changing nothing
#   bash go-server/ops/deploy.sh v1.11.0 --force       restart even when /health already reports the tag
#
# Run it as the operator who owns the checkout (write, on game-server-01), from any directory: it
# finds the repository from its own path, as build.sh does. It asks sudo for three things only — the
# migration, run as the service's user; the restart; the journal when a restart goes wrong — and asks
# for the password once, up front, before the build.
#
# In order (DEPLOY.md "One-command deploy (deploy.sh)" has the why of each):
#   1. a lock (flock on .git/deploy.lock): two deploys never overlap;
#   2. refuses tracked files with local changes (untracked and ignored ones — .env, bin/,
#      play-key.json — are fine): a deploy checks another commit out over them;
#   3. reads the INSTALLED unit (systemctl show): its user, working directory, environment file and
#      Environment= lines. It must run this checkout's go-server/bin/gameplay from go-server/, and its
#      environment file must be go-server/.env, the file -migrate reads — else it refuses;
#   4. git fetch origin (branches and tags, --prune --force), then fast-forwards the local master to
#      origin/master without touching the working tree — the "latest pull";
#   5. chooses the tag (the argument, or the newest go-server/v* by version) and says what /health
#      reports is running now;
#   6. remembers HEAD, keeps bin/gameplay as bin/gameplay.prev (one: the last), checks the tag out
#      DETACHED, builds it (the tag's own build.sh) and checks the binary names the tag;
#   7. MIGRATES: the NEW binary's `gameplay -migrate` as the service's user, in its working directory,
#      with its Environment= — every embedded script, through the code a boot runs. BEFORE the
#      restart: the previous build keeps serving while it runs, and a script that fails stops the
#      deploy with nothing restarted. A tag from before -migrate existed migrates at its own boot;
#   8. restarts gameplay — only when /health reports another version, or with --force — and waits up
#      to HEALTH_WAIT_SECONDS for /health to answer ok with the tag's version;
#   9. reports: the version before and after, the tag, the scripts applied, the time taken.
#
# A failure at 6 or 7 puts bin/gameplay.prev and the remembered HEAD back and restarts nothing. A new
# build that never answers /health at 8 is rolled back: the journal is printed, the previous binary
# and HEAD put back, the service restarted onto them and /health waited for again.
#
# Exit codes: 0 deployed, already running the tag, or a dry run; 1 refused, or failed before anything
# was restarted; 2 a migration failed (nothing restarted); 3 the new build never became healthy and
# the previous build serves again; 4 the rollback did not come back either — production is DOWN.
#
# The checkout is left DETACHED at the tag, on purpose: what runs is the tag, not a branch. master is
# kept at origin/master. So on the host this replaces `git pull origin master`, which fails on a
# detached HEAD — and the next deploy fetches anyway.
#
# Env overrides: REMOTE (origin), BRANCH (master), UNIT (gameplay), HEALTH_URL
# (http://127.0.0.1:<PORT>/health — PORT from the .env when readable, else the unit's Environment=,
# else 3000), HEALTH_WAIT_SECONDS (60).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" \
  || { printf 'deploy.sh: cannot find the checkout %s belongs to (git says why above)\n' "$SCRIPT_DIR" >&2; exit 1; }

REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-master}"
UNIT="${UNIT:-gameplay}"
TAG_PREFIX="go-server/v"
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-60}"

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
usage: bash go-server/ops/deploy.sh [go-server/vX.Y.Z] [--dry-run] [--force]

  (no tag)    deploy the newest ${TAG_PREFIX}* tag after fetching $REMOTE
  --dry-run   lock, check, fetch and choose the tag; say what would happen; change nothing
  --force     restart even when /health already reports the tag

Run as the operator who owns the checkout; sudo is asked for once. DEPLOY.md "One-command deploy".
EOF
}

# --------------------------------------------------------------- state
TAG_ARG="" DRY_RUN=0 FORCE=0
ORIG_HEAD="" ORIG_BRANCH=""          # what was checked out before the deploy
HAVE_PREV=0 PREV_VERSION=""          # the binary kept as bin/gameplay.prev
STAGE="start"                        # start | changed | restarting | restored | done
TMP_DIR="$(mktemp -d)"
UNIT_USER="" UNIT_GROUP="" UNIT_WD="" UNIT_EXEC="" UNIT_LOAD=""
UNIT_ENV_FILES=() UNIT_ENV=()
HEALTH_OK="" HEALTH_VERSION=""

# ------------------------------------------------------------- helpers
git_() { git -C "$REPO_ROOT" "$@"; }
short() { git_ rev-parse --short "$1"; }

# read_health — one GET of $HEALTH_URL into HEALTH_OK / HEALTH_VERSION; both empty when nothing answers.
read_health() {
  local body="$TMP_DIR/health.json"
  HEALTH_OK="" HEALTH_VERSION=""
  if curl -fsS --max-time 3 -o "$body" "$HEALTH_URL" 2>/dev/null; then
    HEALTH_OK="$(json_get "$body" ok)"
    HEALTH_VERSION="$(json_get "$body" version)"
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
    [ "$i" -lt "$HEALTH_WAIT_SECONDS" ] && sleep 1
  done
  return 1
}

# unit_env_value KEY — KEY's value among the unit's Environment= assignments, or nothing.
unit_env_value() {
  local kv
  for kv in "${UNIT_ENV[@]}"; do
    if [ "${kv%%=*}" = "$1" ]; then printf '%s' "${kv#*=}"; fi
  done
}

# split_words — the words of one systemctl show value, one per line, shell quoting honoured (a value
# with a space is shown quoted). python3 is on every Ubuntu; without it, plain whitespace splitting.
split_words() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import shlex, sys; print("\n".join(shlex.split(sys.stdin.read())))'
  else
    tr -s '[:space:]' '\n' | sed '/^$/d'
  fi
}

# read_unit — the INSTALLED unit, which may differ from ops/gameplay-go.service.
read_unit() {
  local out raw
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
  mapfile -t UNIT_ENV_FILES < <(printf '%s\n' "$out" | sed -n 's/^EnvironmentFiles=//p' | sed 's/ (ignore_errors=[a-z]*)$//')
  raw="$(printf '%s\n' "$out" | sed -n 's/^Environment=//p' | head -n1)"
  mapfile -t UNIT_ENV < <(printf '%s' "$raw" | split_words)
  local kv
  for kv in "${UNIT_ENV[@]}"; do
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "cannot read the unit's Environment= ('$kv' in: $raw)"
  done
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

# migrate_env — the assignments the migration runs with: the unit's Environment=, less any key the
# .env also sets. systemd lets the EnvironmentFile win over Environment=, and godotenv never
# overrides a variable the process already has — so a key in both is left to godotenv to read from
# the .env, as the service does. (When this user cannot read the .env, every Environment= line is
# passed; the template's NODE_ENV and PUBLIC_DIR are not .env keys.)
migrate_env() {
  local kv key
  for kv in "${UNIT_ENV[@]}"; do
    key="${kv%%=*}"
    if [ -r "$ENV_FILE" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE"; then continue; fi
    printf '%s\n' "$kv"
  done
}

# restore_previous — the binary kept as bin/gameplay.prev and the remembered HEAD, back in place.
restore_previous() {
  if [ "$HAVE_PREV" = 1 ] && [ -f "$PREV_BIN" ]; then
    cp --preserve=mode,timestamps "$PREV_BIN" "$GO_BIN.restore.tmp"
    mv -f "$GO_BIN.restore.tmp" "$GO_BIN"
    note "put bin/gameplay back from bin/gameplay.prev (${PREV_VERSION:-its version unknown})"
  else
    note "there was no previous bin/gameplay to put back"
  fi
  if [ -n "$ORIG_BRANCH" ] && [ "$(git_ rev-parse -q --verify "refs/heads/$ORIG_BRANCH^{commit}" || true)" = "$ORIG_HEAD" ]; then
    git_ checkout -q "$ORIG_BRANCH"
  else
    git_ -c advice.detachedHead=false checkout -q --detach "$ORIG_HEAD"
  fi
  note "checkout back at $(short "$ORIG_HEAD")${ORIG_BRANCH:+ ($ORIG_BRANCH)}"
  STAGE="restored"
}

# on_exit — the EXIT trap: the scratch directory goes, and a run that stops between the checkout and
# the restart (set -e, Ctrl-C) puts the previous build back rather than leave the tag half-deployed.
# shellcheck disable=SC2317  # called by the trap, which shellcheck does not follow
on_exit() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$STAGE" = "changed" ]; then
    printf '\n%s: stopped unexpectedly (exit %s) after checking the tag out; putting the previous build back\n' "$(basename "$0")" "$status" >&2
    restore_previous || printf '%s: could not put the previous build back: check %s and git status by hand\n' "$(basename "$0")" "$GO_BIN" >&2
    printf '%s: nothing was restarted; gameplay still runs the build it ran before\n' "$(basename "$0")" >&2
  elif [ "$status" -ne 0 ] && [ "$STAGE" = "restarting" ]; then
    printf '\n%s: stopped during the restart (exit %s): check %s and sudo journalctl -u %s -n 60 --no-pager NOW\n' \
      "$(basename "$0")" "$status" "$HEALTH_URL" "$UNIT" >&2
  fi
  rm -rf "$TMP_DIR"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- main
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --force)   FORCE=1 ;;
      -h|--help) usage; return 0 ;;
      -*)        usage >&2; die "unknown option '$arg'" ;;
      *)         [ -z "$TAG_ARG" ] || die "one tag at a time ('$TAG_ARG' and '$arg')"; TAG_ARG="$arg" ;;
    esac
  done
  [ "$(id -u)" -ne 0 ] || die "run this as the operator who owns the checkout, not as root: a root build leaves root-owned files in go-server/bin and uses ~root's Go. It calls sudo itself where it must."
  local tool
  for tool in git curl flock systemctl realpath; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
  local began=$SECONDS

  # ------------------------------------------------------- 1. the lock
  local lock_file mode=""
  lock_file="$(git_ rev-parse --absolute-git-dir)/deploy.lock"
  exec 9<>"$lock_file"
  flock -n 9 || die "another deploy is running (lock $lock_file: $(tr -d '\n' < "$lock_file" 2>/dev/null || echo '?'))"
  printf 'pid %s, %s, since %s\n' "$$" "$(id -un)" "$(date -u +%FT%TZ)" > "$lock_file"
  if [ "$DRY_RUN" = 1 ]; then mode=" — DRY RUN, nothing will change"; fi
  log "Deploying from $REPO_ROOT as $(id -un)$mode"
  note "lock $lock_file"

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
  local -a sudo_as=(-u "$run_as")
  if [ -n "$UNIT_GROUP" ] && [ "$UNIT_GROUP" != "$(id -gn "$run_as")" ]; then sudo_as+=(-g "$UNIT_GROUP"); fi
  local -a mig_env
  mapfile -t mig_env < <(migrate_env)

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
  local before_version="$HEALTH_VERSION" before_ok="$HEALTH_OK"
  log "Target $tag ($(short "$tag_sha"))"
  note "running now: $before"
  if [ -n "$before_version" ] && [ "$before_version" != "$want" ] \
    && [ "$(printf '%s\n%s\n' "${before_version#v}" "${want#v}" | sort -V | head -n1)" = "${want#v}" ]; then
    note "that goes BACK from $before_version to $want — a rollback: read DEPLOY.md §5 for what an older tag needs"
  fi
  local scripts changed has_migrate=0
  scripts="$(git_ ls-tree --name-only "$tag_sha" go-server/internal/db/migration/ | sed 's#.*/##' | paste -sd ' ' -)"
  changed="$(git_ diff --name-status "$ORIG_HEAD" "$tag_sha" -- go-server/internal/db/migration \
    | sed 's#go-server/internal/db/migration/##' | tr '\t' ' ' | paste -sd ';' - | sed 's/;/; /g')"
  note "the tag's migrations: ${scripts:-none}"
  note "changed since the checkout's HEAD: ${changed:-none}"
  if git_ cat-file -e "$tag_sha:go-server/cmd/gameplay/migrate.go" 2>/dev/null; then has_migrate=1; fi

  if [ "$DRY_RUN" = 1 ]; then
    local current="no binary yet"
    if [ -x "$GO_BIN" ]; then current="$("$GO_BIN" -version 2>/dev/null || echo 'its version unknown')"; fi
    log "Dry run — what a real run would do"
    note "would keep bin/gameplay as bin/gameplay.prev ($current)"
    note "would check out $tag detached ($(short "$tag_sha")) and build it with its ops/build.sh"
    if [ "$has_migrate" = 1 ]; then
      note "would migrate: (cd $UNIT_WD && sudo ${sudo_as[*]} env ${mig_env[*]} ./bin/gameplay -migrate)"
    else
      note "would not migrate beforehand: $tag predates gameplay -migrate, so its migrations run at its own boot"
    fi
    if [ "$before_ok" = "true" ] && [ "$before_version" = "$want" ] && [ "$FORCE" = 0 ]; then
      note "would not restart: /health already reports $want (--force would)"
    else
      note "would restart $UNIT and wait up to ${HEALTH_WAIT_SECONDS}s for /health to report $want"
    fi
    log "Dry run: nothing changed (the fetch only updated $REMOTE's refs and the tags)"
    STAGE="done"
    return 0
  fi

  # Asked now, before a build that can take minutes, so the password prompt is not left waiting.
  log "sudo (for the migration as $run_as, the restart and the journal)"
  sudo -v || die "sudo refused — this deploy needs it for the migration, the restart and the journal"

  # ---------------------------------------- 6. keep, check out, build
  log "Checking out $tag and building"
  if [ -x "$GO_BIN" ]; then
    PREV_VERSION="$("$GO_BIN" -version 2>/dev/null | awk '{print $2}' || true)"
    cp --preserve=mode,timestamps "$GO_BIN" "$PREV_BIN.tmp"
    mv -f "$PREV_BIN.tmp" "$PREV_BIN"
    HAVE_PREV=1
    note "kept bin/gameplay as bin/gameplay.prev (${PREV_VERSION:-its version unknown})"
  else
    note "no bin/gameplay yet: nothing to keep, nothing to roll back to"
  fi
  STAGE="changed"
  git_ -c advice.detachedHead=false checkout -q --detach "$tag_sha"
  note "HEAD is now $tag ($(short "$tag_sha")), detached"
  # build.sh ends with a hint for the manual routine ("Next: sudo bash …install-go-server.sh …");
  # this script is that routine, so the hint is dropped.
  if ! bash "$GO_DIR/ops/build.sh" 2>&1 | sed '/^Next: /d'; then
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
       die "bin/gameplay says '${built:-nothing}', not $want: another ${TAG_PREFIX}* tag names the same commit, or the tree changed during the build" ;;
  esac

  # ------------------------------------------------------- 7. migrate
  local migrate_log="$TMP_DIR/migrate.log" migrated="" usage_text
  usage_text="$("$GO_BIN" -help 2>&1 || true)"
  case "$usage_text" in
    *"-migrate"*)
      log "Migrating with the new binary (gameplay -migrate) — the running server is untouched"
      note "as $run_as in $UNIT_WD with ${mig_env[*]:-no extra environment} (and $ENV_FILE, read by the binary)"
      if ! (cd "$UNIT_WD" && sudo "${sudo_as[@]}" env "${mig_env[@]}" "$GO_BIN" -migrate) 2>&1 \
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
  local restarted="no" after
  read_health
  if [ "$HEALTH_OK" = "true" ] && [ "$HEALTH_VERSION" = "$want" ] && [ "$FORCE" = 0 ]; then
    log "already running $want; migrations applied; not restarted"
    STAGE="done"
  else
    log "Restarting $UNIT (running: ${HEALTH_VERSION:-nothing answers}; target: $want)"
    STAGE="restarting"
    local ok=1
    sudo systemctl restart "$UNIT" || ok=0
    if [ "$ok" = 1 ] && wait_for_version "$want"; then
      restarted="yes"
      STAGE="done"
    else
      log "ROLLING BACK: $want did not answer /health within ${HEALTH_WAIT_SECONDS}s — its journal:"
      sudo journalctl -u "$UNIT" -n 60 --no-pager || true
      restore_previous
      sudo systemctl restart "$UNIT" || true
      if [ "$HAVE_PREV" = 1 ] && wait_for_version "$PREV_VERSION"; then
        printf '\n==> ROLLED BACK. %s was NOT deployed: it never became healthy. Production runs %s again.\n' "$tag" "$PREV_VERSION" >&2
        printf '    Its migrations %s stay applied (additive; the previous build runs on them). Fix the release, then deploy again.\n' "${migrated:+($migrated)}" >&2
        exit 3
      fi
      printf '\n==> PRODUCTION IS DOWN. %s never became healthy, and the previous build did not come back either.\n' "$tag" >&2
      sudo journalctl -u "$UNIT" -n 60 --no-pager >&2 || true
      printf '    Look at the journal above NOW: sudo journalctl -u %s -f\n' "$UNIT" >&2
      exit 4
    fi
  fi

  # -------------------------------------------------------- 9. report
  read_health
  after="$(health_words)"
  log "Deployed $tag"
  note "before      $before"
  note "after       $after"
  note "tag         $tag ($(short "$tag_sha")), checked out detached; $BRANCH at $(short "$new_master") = $REMOTE/$BRANCH"
  note "migrations  ${migrated:-?}"
  note "restarted   $restarted"
  note "kept        bin/gameplay.prev (${PREV_VERSION:-none})"
  note "elapsed     $((SECONDS - began)) s"
  printf '\nNext, from anywhere: bash go-server/ops/prod-version.sh   (IN SYNC is the proof)\n'
}

main "$@"
exit $?
