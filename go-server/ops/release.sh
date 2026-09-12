#!/usr/bin/env bash
# release.sh — cut a release tag for the Go server.
#
#   bash go-server/ops/release.sh patch     go-server/v1.0.0 -> go-server/v1.0.1
#   bash go-server/ops/release.sh minor     go-server/v1.0.1 -> go-server/v1.1.0
#   bash go-server/ops/release.sh major     go-server/v1.1.0 -> go-server/v2.0.0
#   bash go-server/ops/release.sh v1.4.0    that exact version
#   bash go-server/ops/release.sh --current what the tag would be right now
#
# Why the tags are named `go-server/vX.Y.Z` rather than plain `vX.Y.Z`: this
# repository holds three shippable things — the server, the Flutter client and
# the bot fleet — which are released on their own schedules. A component prefix
# lets each carry its own version without the numbers colliding, and lets
# ops/build.sh's `git describe --match 'go-server/v*'` ignore the others.
#
# The tag is what `bin/gameplay -version` and GET /health report, so it is the
# answer to "which build is production on?". That only stays true if a tag
# names a commit someone else can rebuild byte for byte, which is why this
# refuses a dirty tree and refuses to move a tag that already exists.
#
# It does NOT push. Pushing publishes a version number that cannot be taken
# back once anyone has fetched it, so the command is printed for you to run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PREFIX="go-server/v"

die() { printf 'release: %s\n' "$1" >&2; exit 1; }

# The newest existing tag, by version order rather than date: a patch cut
# after a minor must not be read as the latest.
latest_tag() {
  git -C "$REPO_ROOT" tag --list "${PREFIX}*" --sort=-v:refname | head -n 1
}

# Split "go-server/v1.2.3" into the three numbers.
parse() {
  local v="${1#"$PREFIX"}"
  [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "cannot read a version out of '$1'"
  MAJOR="${BASH_REMATCH[1]}"; MINOR="${BASH_REMATCH[2]}"; PATCH="${BASH_REMATCH[3]}"
}

BUMP="${1:-patch}"

CURRENT="$(latest_tag)"
if [ -z "$CURRENT" ]; then
  # No tags yet: the first release is v1.0.0 whatever was asked for, because
  # bumping from nothing has no meaning.
  MAJOR=1; MINOR=0; PATCH=0
  case "$BUMP" in
    v*) parse "$BUMP" ;;
    patch|minor|major) printf 'release: no %s* tag yet — the first release is v1.0.0\n' "$PREFIX" >&2 ;;
    --current) printf 'no release tag yet; next would be %s1.0.0\n' "$PREFIX"; exit 0 ;;
    *) die "unknown argument '$BUMP' (patch | minor | major | vX.Y.Z | --current)" ;;
  esac
else
  parse "$CURRENT"
  case "$BUMP" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    v*)    parse "$BUMP" ;;
    --current)
      printf 'latest: %s\ndescribe: %s\n' "$CURRENT" \
        "$(git -C "$REPO_ROOT" describe --tags --match "${PREFIX}*" --always --dirty)"
      exit 0 ;;
    *) die "unknown argument '$BUMP' (patch | minor | major | vX.Y.Z | --current)" ;;
  esac
fi

NEW="${PREFIX}${MAJOR}.${MINOR}.${PATCH}"

# ------------------------------------------------------------- refusals
# A tag must name a rebuildable commit. With uncommitted work in the tree the
# binary you are about to ship is not the one the tag points at, and the
# `-dirty` suffix in the stamp would be the only clue.
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] \
  || die "the working tree has uncommitted changes; commit or stash them first"

if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$NEW" >/dev/null; then
  die "$NEW already exists; a released version is never moved — cut the next one instead"
fi

ALREADY="$(git -C "$REPO_ROOT" tag --points-at HEAD --list "${PREFIX}*" | head -n 1)"
[ -z "$ALREADY" ] \
  || die "HEAD is already released as $ALREADY; commit something before cutting another"

# ------------------------------------------------------------- the tag
SUBJECT="$(git -C "$REPO_ROOT" log -1 --format=%s)"
SHORT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
git -C "$REPO_ROOT" tag -a "$NEW" -m "$NEW

$SUBJECT

Cut from $SHORT by ops/release.sh."

printf '\n  tagged %s at %s\n    %s\n\n' "$NEW" "$SHORT" "$SUBJECT"
printf 'Next:\n'
printf '  git push origin %s            # publish the tag\n' "$NEW"
printf '  bash go-server/ops/build.sh                 # stamps v%s.%s.%s into the binary\n' "$MAJOR" "$MINOR" "$PATCH"
printf '  bash go-server/ops/prod-version.sh          # what prod is actually running\n\n'
