#!/usr/bin/env bash
# prod-version.sh — what build is production actually running?
#
#   bash go-server/ops/prod-version.sh
#   bash go-server/ops/prod-version.sh http://127.0.0.1:3000     # any server
#
# Reads GET /health, which reports the release tag stamped in by ops/build.sh,
# and compares it with the newest tag in this checkout. That comparison is the
# point: a deploy is only finished when the version answering on the public
# URL is the version you tagged, and until this prints IN SYNC the safe
# assumption is that prod is still serving the previous build — a restart that
# silently failed looks exactly like a successful one from the outside.
#
# No ssh and no credentials: /health is public, so this works from anywhere,
# including a phone.
set -euo pipefail

URL="${1:-https://api.sungamestudio.com}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
PREFIX="go-server/v"

BODY="$(curl -fsS -m 15 "$URL/health" 2>/dev/null)" \
  || { printf 'prod-version: %s/health did not answer\n' "$URL" >&2; exit 1; }

# Tab-separated, not space: the "not reported" fallback below has spaces in it
# and a space split would scatter it across both variables.
IFS=$'\t' read -r LIVE UPTIME <<EOF
$(printf '%s' "$BODY" | python3 -c '
import sys, json
d = json.load(sys.stdin)
# A server built before /health carried the version reports nothing here;
# say so plainly rather than printing an empty string that reads as "no build".
print("%s\t%s" % (d.get("version") or "(not reported - build predates /health.version)", d.get("uptime", 0)))
')
EOF

printf '  %-12s %s\n' "server:" "$URL"
printf '  %-12s %s\n' "running:" "$LIVE"
printf '  %-12s %s\n' "uptime:" "$(printf '%.0f' "$UPTIME") s"

if [ -n "$REPO_ROOT" ]; then
  TAG="$(git -C "$REPO_ROOT" tag --list "${PREFIX}*" --sort=-v:refname | head -n 1)"
  if [ -n "$TAG" ]; then
    WANT="${TAG#"$PREFIX"}"
    printf '  %-12s v%s\n' "newest tag:" "$WANT"
    if [ "$LIVE" = "v$WANT" ]; then
      printf '\n  IN SYNC — prod is running the newest tag.\n\n'
    else
      printf '\n  BEHIND — prod is on %s, newest tag is v%s.\n\n' "$LIVE" "$WANT"
      exit 2
    fi
  else
    printf '  %-12s (none yet — cut one with ops/release.sh)\n\n' "newest tag:"
  fi
fi
