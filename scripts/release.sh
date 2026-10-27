#!/usr/bin/env bash
# release.sh - cut a tagged release of agentdev and open a Homebrew tap PR.
#
# agentdev ships no compiled binary, so there is no GoReleaser step. A release is:
#   1. an annotated git tag vX.Y.Z pushed to origin (GitHub then serves the source
#      tarball at /archive/refs/tags/vX.Y.Z.tar.gz), and
#   2. a pull request to the Homebrew tap (gherlein/homebrew-tap) that updates the
#      formula's version + sha256 to that tarball.
# The tap's main is protected, so the formula lands via PR and a human merges it.
# Nothing here merges, and nothing happens until you run it (make release).
#
# Usage:
#   scripts/release.sh [--dry-run] [--yes] X.Y.Z
#     --dry-run   run every precondition check and render the formula; no tag/push/PR
#     --yes       skip the interactive confirmation (for CI)
#
# Requires: git, gh (authenticated), curl, and sha256sum or shasum.
set -euo pipefail

REPO_SLUG="gherlein/agentdev"
TAP_SLUG="gherlein/homebrew-tap"
FORMULA_IN_TAP="Formula/agentdev.rb"

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TEMPLATE="$ROOT/packaging/agentdev.rb.tmpl"

die()  { echo "release: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

DRY_RUN=no; ASSUME_YES=no; VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=yes ;;
    --yes|-y)  ASSUME_YES=yes ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         [[ -z "$VERSION" ]] || die "version given twice"; VERSION="$1" ;;
  esac
  shift
done

[[ -n "$VERSION" ]] || die "usage: scripts/release.sh [--dry-run] [--yes] X.Y.Z"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (no leading v): got '$VERSION'"
TAG="v$VERSION"

# --- tools ---
for t in git gh curl; do command -v "$t" >/dev/null || die "missing required tool: $t"; done
if   command -v sha256sum >/dev/null; then sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum    >/dev/null; then sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else die "need sha256sum or shasum"; fi

[[ -f "$TEMPLATE" ]] || die "formula template not found: $TEMPLATE"

# --- repo state (clean main, in sync with origin) ---
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo"
branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == main ]] || die "release from main (currently on '$branch')"
git diff --quiet && git diff --cached --quiet || die "working tree is dirty; commit or stash first"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || die "local main is not in sync with origin/main (push or pull first)"

# --- gh auth + PUBLIC repo (a private repo 404s the release tarball) ---
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
vis="$(gh repo view "$REPO_SLUG" --json visibility -q .visibility 2>/dev/null || echo unknown)"
[[ "$vis" == "PUBLIC" ]] || die "repo $REPO_SLUG is '$vis'; Homebrew needs a PUBLIC repo (the tarball 404s otherwise)"

# --- the tag must be new ---
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
   || git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists; bump the version"
fi

TARBALL_URL="https://github.com/$REPO_SLUG/archive/refs/tags/$TAG.tar.gz"

render_formula() {   # $1 = sha256 (or a placeholder) -> stdout
  sed -e "s|__VERSION__|$VERSION|g" -e "s|__SHA256__|$1|g" "$TEMPLATE"
}

if [[ "$DRY_RUN" == yes ]]; then
  note "DRY RUN - no tag, no push, no PR."
  note "version: $VERSION   tag: $TAG"
  note "repo:    $REPO_SLUG ($vis)"
  note "tap:     $TAP_SLUG  (PR updates $FORMULA_IN_TAP)"
  note "tarball: $TARBALL_URL"
  note "sha256:  computable only after the tag is pushed"
  echo "----- rendered formula (sha256 pending) -----"
  render_formula "SHA256_COMPUTED_AT_RELEASE"
  exit 0
fi

note "About to tag $TAG, push it to origin, and open a PR to $TAP_SLUG. Nothing is merged."
if [[ "$ASSUME_YES" != yes ]]; then
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]] || die "aborted."
fi

note "tagging $TAG and pushing"
git tag -a "$TAG" -m "agentdev $TAG"
git push origin "$TAG"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
note "downloading the release tarball to compute sha256"
curl -fsSL "$TARBALL_URL" -o "$tmp/src.tgz" || die "could not download $TARBALL_URL"
sha="$(sha256_of "$tmp/src.tgz")"
note "sha256: $sha"

note "opening the tap PR ($TAP_SLUG)"
gh repo clone "$TAP_SLUG" "$tmp/tap" -- -q || die "could not clone $TAP_SLUG"
cd "$tmp/tap"
pr_branch="agentdev-$TAG"
git checkout -q -b "$pr_branch"
mkdir -p "$(dirname "$FORMULA_IN_TAP")"
render_formula "$sha" > "$FORMULA_IN_TAP"
git add "$FORMULA_IN_TAP"
git commit -q -m "agentdev $TAG"
git push -q -u origin "$pr_branch"
pr_url="$(gh pr create --repo "$TAP_SLUG" --base main --head "$pr_branch" \
  --title "agentdev $TAG" \
  --body "Automated formula update for agentdev $TAG (tarball sha256 \`$sha\`). Merge to publish." \
  2>&1 | tail -n1)"

cat >&2 <<EOF

Release $TAG tagged and pushed; tap PR opened:
  $pr_url

After the PR is merged, verify the install:
  brew tap gherlein/tap
  brew trust gherlein/tap
  brew install agentdev
  agentdev --help
EOF
