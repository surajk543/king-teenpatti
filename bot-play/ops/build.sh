#!/usr/bin/env bash
# Builds bot-play into bin/bot-play: static, stripped, version-stamped.
#
#   bash ops/build.sh
#
# Uses the Go toolchain go-server/ops/build.sh installs (Go 1.27.1 in
# ~/.local/go, sha256-checked against go.dev); when it is not there yet this
# runs that script first, which installs Go (and builds the game server,
# harmlessly). The version is `git describe` of the newest bot-play/v* tag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"        # …/bot-play
REPO_DIR="$(cd "$MODULE_DIR/.." && pwd)"
GO="${GO:-$HOME/.local/go/bin/go}"
OUT="$MODULE_DIR/bin/bot-play"

if ! [ -x "$GO" ]; then
  if command -v go >/dev/null 2>&1; then
    GO="$(command -v go)"
  else
    echo "==> no Go toolchain: installing it with go-server/ops/build.sh"
    bash "$REPO_DIR/go-server/ops/build.sh"
  fi
fi

VERSION="$(git -C "$REPO_DIR" describe --tags --match 'bot-play/v*' --always --dirty 2>/dev/null || echo dev)"
VERSION="${VERSION#bot-play/}"

echo "==> building bot-play $VERSION with $("$GO" version)"
cd "$MODULE_DIR"
mkdir -p bin
CGO_ENABLED=0 "$GO" build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$OUT.new" ./cmd/bot-play
mv "$OUT.new" "$OUT"
"$OUT" -version
echo
echo "Next: sudo bash ops/install.sh   (first time)   or   restart bot-play (see README)"
