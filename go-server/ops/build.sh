#!/usr/bin/env bash
# Build the Go game server for production — run as the deploy user, no sudo.
#
#   cd /var/www/gameplay/king-teenpatti/go-server && bash ops/build.sh
#
# What it does, every time it is run (safe to repeat):
#   1. finds a Go toolchain >= GO_VERSION ($HOME/.local/go first, then PATH);
#      when none is good enough it downloads go<GO_VERSION>.linux-<arch>.tar.gz
#      from go.dev, verifies the sha256 that go.dev publishes for that file
#      (fetched at run time from https://go.dev/dl/?mode=json&include=all) and
#      unpacks it into $HOME/.local/go — no root, nothing outside $HOME;
#   2. builds a static, stripped binary at bin/gameplay with the release tag
#      (`git describe --match 'go-server/v*'`) stamped into `main.version` —
#      shown by `bin/gameplay -version`, in the first journal line of the
#      service, and in GET /health as `version`;
#   3. prints the binary's size and `file` output.
#
# Env overrides: GO_VERSION (default 1.27.1), GO_INSTALL_DIR (default
# $HOME/.local/go), GOPROXY/GOFLAGS pass straight through to `go build`.
set -euo pipefail

GO_VERSION="${GO_VERSION:-1.27.1}"
GO_INSTALL_DIR="${GO_INSTALL_DIR:-$HOME/.local/go}"
GO_DL_BASE="https://go.dev/dl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # …/go-server
OUT="$MODULE_DIR/bin/gameplay"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

# One scratch directory for the whole run, removed on any exit.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ------------------------------------------------------------- helpers
# "go1.27.1" -> "1.27.1" ; prints nothing when the binary does not run.
go_version_of() {
  "$1" version 2>/dev/null | sed -n 's/^go version go\([0-9][0-9.]*\).*/\1/p'
}

# true when $1 >= $2 as dotted versions (1.27.1 >= 1.27 is true).
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

arch_of() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported architecture $(uname -m) — set GO_VERSION/GO_INSTALL_DIR and install Go by hand" ;;
  esac
}

# Prints the sha256 go.dev publishes for a release tarball. Uses python3 when
# present (Ubuntu always has it), otherwise a grep/sed pass over the JSON.
published_sha256() {
  local filename="$1" json
  json="$(curl -fsSL "$GO_DL_BASE/?mode=json&include=all")" || die "could not fetch $GO_DL_BASE/?mode=json"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
name = sys.argv[1]
for release in json.load(sys.stdin):
    for f in release.get("files", []):
        if f.get("filename") == name:
            print(f["sha256"]); sys.exit(0)
sys.exit(1)' "$filename"
  else
    printf '%s' "$json" | tr -d '\n' | tr '{' '\n' \
      | grep -F "\"filename\": \"$filename\"" \
      | sed -n 's/.*"sha256": *"\([0-9a-f]\{64\}\)".*/\1/p' | head -n1
  fi
}

install_go() {
  local arch tarball url want got
  arch="$(arch_of)"
  tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  url="$GO_DL_BASE/$tarball"

  log "Installing Go $GO_VERSION into $GO_INSTALL_DIR"
  want="$(published_sha256 "$tarball" || true)"
  [ -n "$want" ] || die "go.dev did not publish a sha256 for $tarball — is GO_VERSION=$GO_VERSION a real release?"
  echo "    expected sha256 $want"

  echo "    downloading $url"
  curl -fSL --progress-bar -o "$TMP_DIR/$tarball" "$url"
  got="$(sha256sum "$TMP_DIR/$tarball" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "sha256 mismatch for $tarball: got $got, expected $want — refusing to install"
  echo "    sha256 verified"

  # Unpack next to the target and swap atomically so a half-extracted tree is
  # never what `go` resolves to.
  mkdir -p "$(dirname "$GO_INSTALL_DIR")"
  rm -rf "$GO_INSTALL_DIR.new"
  mkdir -p "$GO_INSTALL_DIR.new"
  tar -C "$GO_INSTALL_DIR.new" --strip-components=1 -xzf "$TMP_DIR/$tarball"
  rm -rf "$GO_INSTALL_DIR.old"
  [ -d "$GO_INSTALL_DIR" ] && mv "$GO_INSTALL_DIR" "$GO_INSTALL_DIR.old"
  mv "$GO_INSTALL_DIR.new" "$GO_INSTALL_DIR"
  rm -rf "$GO_INSTALL_DIR.old"
  echo "    installed $("$GO_INSTALL_DIR/bin/go" version)"
  echo "    (add to ~/.profile for interactive use:  export PATH=\"$GO_INSTALL_DIR/bin:\$PATH\")"
}

# ----------------------------------------------------- 1. toolchain
log "Looking for Go >= $GO_VERSION"
GO_BIN=""
for candidate in "$GO_INSTALL_DIR/bin/go" "$(command -v go 2>/dev/null || true)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  v="$(go_version_of "$candidate")"
  if [ -n "$v" ] && version_ge "$v" "$GO_VERSION"; then
    GO_BIN="$candidate"
    echo "    using $candidate (go$v)"
    break
  fi
  [ -n "$v" ] && echo "    $candidate is go$v — too old"
done
if [ -z "$GO_BIN" ]; then
  install_go
  GO_BIN="$GO_INSTALL_DIR/bin/go"
fi
export PATH="$(dirname "$GO_BIN"):$PATH"
# Never let `go` silently download a different toolchain because of the go.mod
# `go` line; the one we just verified is the one that builds.
export GOTOOLCHAIN=local

# ----------------------------------------------------------- 2. build
cd "$MODULE_DIR"
# The stamp is the go-server release tag as `git describe` renders it:
# "v1.0.1" exactly on a tag, "v1.0.1-3-gabc1234" three commits past one, plus
# "-dirty" when the tree has uncommitted changes. --match keeps the client's
# and the bot fleet's tags out of it, so each component versions on its own;
# with no tag yet it falls back to the bare commit. ops/release.sh cuts them.
VERSION="$(git -C "$MODULE_DIR" describe --tags --match 'go-server/v*' --always --dirty 2>/dev/null || echo unknown)"
VERSION="${VERSION#go-server/}"
log "Building $OUT (version $VERSION, $("$GO_BIN" version | cut -d' ' -f3))"
mkdir -p "$MODULE_DIR/bin"
CGO_ENABLED=0 "$GO_BIN" build -trimpath \
  -ldflags "-s -w -X main.version=$VERSION" \
  -o "$OUT" ./cmd/gameplay

# ---------------------------------------------------------- 3. report
log "Built"
ls -lh "$OUT" | awk '{print "    size  " $5 "  " $9}'
if command -v file >/dev/null 2>&1; then
  echo "    $(file "$OUT")"
fi
echo "    $("$OUT" -version)"
echo
echo "Next: sudo bash $SCRIPT_DIR/install-go-server.sh   (first time)  or  sudo systemctl restart gameplay   (already on Go)"
