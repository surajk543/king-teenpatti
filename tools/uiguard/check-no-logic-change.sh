#!/usr/bin/env bash
# Proves a UI redesign changed nothing it was forbidden to change.
#
# The owner's rule for the premium redesign was absolute: presentation only.
# No server, socket, DTO, game-rule or state-logic change. This script is how
# that claim is checked rather than asserted — run it against the commit the
# redesign started from.
#
#   bash tools/uiguard/check-no-logic-change.sh <base-ref>
set -euo pipefail
BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: $0 <base-ref>"; exit 2; }

# Directories that must be byte-identical: everything that is not the Flutter
# client's presentation layer.
FORBIDDEN_DIRS='^(go-server|bot-play|tools/parity|docs/load-reports)/'
# Files inside the client that carry the server contract rather than its looks.
FORBIDDEN_FILES='^flutter-client/lib/(net/|state/|models/)'

fail=0
changed="$(git diff --name-only "$BASE" -- . || true)"

for pattern in "$FORBIDDEN_DIRS" "$FORBIDDEN_FILES"; do
  hits="$(echo "$changed" | grep -E "$pattern" || true)"
  if [ -n "$hits" ]; then
    echo "FORBIDDEN CHANGES under /$pattern/:"
    echo "$hits" | sed 's/^/    /'
    fail=1
  fi
done

# game_state.dart is the one file a redesign may legitimately need to touch (a
# new UI-only getter), so it is not banned outright — but every changed line is
# printed so a human can see it is presentation, not logic.
if echo "$changed" | grep -q 'flutter-client/lib/state/game_state.dart'; then
  echo
  echo "game_state.dart changed — every line, for review:"
  git diff "$BASE" -- flutter-client/lib/state/game_state.dart | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | sed 's/^/    /'
fi

if [ "$fail" = 0 ]; then
  echo "clean: no server, socket, DTO or state-logic file was modified"
fi
exit "$fail"
