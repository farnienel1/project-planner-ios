#!/usr/bin/env bash
# Mirrors the published rulebook pack from project-planner-web into this repo, byte for byte.
#
#   scripts/sync-rulebook-from-web.sh            # from ../project-planner-web, else raw GitHub `main`
#   scripts/sync-rulebook-from-web.sh <branch>   # from raw GitHub <branch> when ../project-planner-web is missing
#   WEB_REPO=/path/to/web scripts/sync-rulebook-from-web.sh
#
# Never edit the mirrored files by hand. A rule change starts in web `lib/canonical`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_REPO="${WEB_REPO:-$ROOT/../project-planner-web}"
BRANCH="${1:-main}"
RAW_BASE="https://raw.githubusercontent.com/farnienel1/project-planner-web/$BRANCH"

# web path -> iOS path
FILES=(
  "lib/canonical/dist/canonical-business.js|Project Planner/Canonical/canonical-business.js"
  "lib/canonical/dist/canonical-business.sha256|Project Planner/Canonical/canonical-business.js.sha256"
  "lib/canonical/dist/canonical-manifest.json|Project Planner/Canonical/canonical-manifest.json"
  "docs/RULEBOOK.md|docs/RULEBOOK.md"
  "lib/canonical/parity-fixture.json|ProjectPlannerTests/CanonicalParityFixture.json"
)

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

json_string() { # json_string <file> <key>: first "key": "value" in a flat JSON file
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ -d "$WEB_REPO/lib/canonical" ]; then
  SOURCE="local checkout $(cd "$WEB_REPO" && pwd)"
  if git -C "$WEB_REPO" rev-parse --short HEAD >/dev/null 2>&1; then
    SOURCE="$SOURCE @ $(git -C "$WEB_REPO" rev-parse --abbrev-ref HEAD) $(git -C "$WEB_REPO" rev-parse --short HEAD)"
  fi
  for pair in "${FILES[@]}"; do
    src="${pair%%|*}"
    [ -f "$WEB_REPO/$src" ] || { echo "Missing $WEB_REPO/$src — run npm run build:canonical in the web repo." >&2; exit 1; }
    mkdir -p "$STAGE/$(dirname "$src")"
    cp "$WEB_REPO/$src" "$STAGE/$src"
  done
else
  SOURCE="$RAW_BASE"
  for pair in "${FILES[@]}"; do
    src="${pair%%|*}"
    mkdir -p "$STAGE/$(dirname "$src")"
    curl -fsSL "$RAW_BASE/$src" -o "$STAGE/$src" || { echo "Could not download $RAW_BASE/$src" >&2; exit 1; }
  done
fi

MANIFEST="$STAGE/lib/canonical/dist/canonical-manifest.json"
want_bundle="$(json_string "$MANIFEST" bundleSha256)"
want_rulebook="$(json_string "$MANIFEST" rulebookSha256)"
version="$(json_string "$MANIFEST" rulebookVersion)"
got_bundle="$(sha256_of "$STAGE/lib/canonical/dist/canonical-business.js")"
got_rulebook="$(sha256_of "$STAGE/docs/RULEBOOK.md")"
sha_file="$(tr -d '[:space:]' < "$STAGE/lib/canonical/dist/canonical-business.sha256")"
rulebook_version="$(sed -n 's/^Version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$STAGE/docs/RULEBOOK.md" | head -n 1)"

fail=0
[ "$got_bundle" = "$want_bundle" ] || { echo "canonical-business.js sha256 $got_bundle ≠ manifest bundleSha256 $want_bundle" >&2; fail=1; }
[ "$sha_file" = "$want_bundle" ] || { echo "canonical-business.sha256 ($sha_file) ≠ manifest bundleSha256 $want_bundle" >&2; fail=1; }
[ "$got_rulebook" = "$want_rulebook" ] || { echo "RULEBOOK.md sha256 $got_rulebook ≠ manifest rulebookSha256 $want_rulebook" >&2; fail=1; }
[ "$rulebook_version" = "$version" ] || { echo "RULEBOOK.md Version: $rulebook_version ≠ manifest rulebookVersion $version" >&2; fail=1; }
[ "$fail" = 0 ] || { echo "Web pack is inconsistent; nothing copied. Rebuild it in the web repo (npm run build:canonical)." >&2; exit 1; }

for pair in "${FILES[@]}"; do
  src="${pair%%|*}"; dst="${pair#*|}"
  mkdir -p "$ROOT/$(dirname "$dst")"
  cp "$STAGE/$src" "$ROOT/$dst"
done

echo "Rulebook $version mirrored from $SOURCE"
echo "  packed script sha256 $got_bundle"
echo "  rulebook sha256      $got_rulebook"
echo "Next: run RulebookParityTests and CanonicalParityFixtureTests (xcodebuild test -scheme ProjectPlannerTests), then follow web docs/ios-handoff/LATEST.md."
