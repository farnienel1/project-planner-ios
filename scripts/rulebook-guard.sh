#!/usr/bin/env bash
# Claude Code hooks for the rulebook mirror.
#
#   scripts/rulebook-guard.sh stop     Stop hook. Reads the hook JSON on stdin. Exits 2 (blocks finishing,
#                                      reason on stderr) when the mirrored pack no longer matches its
#                                      manifest, or when changed Swift adds logic for a rulebook-owned
#                                      area without calling CanonicalBusinessEngine. Respects stop_hook_active.
#   scripts/rulebook-guard.sh status   SessionStart hook. Prints the mirrored rulebook version and whether
#                                      ../project-planner-web has a newer one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_REPO="${WEB_REPO:-$ROOT/../project-planner-web}"
CANON="$ROOT/Project Planner/Canonical"
MANIFEST="$CANON/canonical-manifest.json"
RULEBOOK="$ROOT/docs/RULEBOOK.md"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
json_string() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -n 1; }
rulebook_version() { sed -n 's/^Version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" 2>/dev/null | head -n 1; }

status() {
  local mine web
  mine="$(rulebook_version "$RULEBOOK")"
  echo "Rulebook mirror: ${mine:-missing} (docs/RULEBOOK.md is a mirror of project-planner-web — never edit it here)."
  if [ -f "$WEB_REPO/docs/RULEBOOK.md" ]; then
    web="$(rulebook_version "$WEB_REPO/docs/RULEBOOK.md")"
    if [ "$web" != "$mine" ]; then
      echo "Web checkout has rulebook $web. Run scripts/sync-rulebook-from-web.sh and follow web docs/ios-handoff/LATEST.md."
    else
      echo "Web checkout is on the same version."
    fi
  fi
  exit 0
}

pack_problems() {
  local want_bundle want_rulebook
  [ -f "$MANIFEST" ] || { echo "Project Planner/Canonical/canonical-manifest.json is missing — run scripts/sync-rulebook-from-web.sh."; return; }
  want_bundle="$(json_string "$MANIFEST" bundleSha256)"
  want_rulebook="$(json_string "$MANIFEST" rulebookSha256)"
  [ "$(sha256_of "$CANON/canonical-business.js")" = "$want_bundle" ] \
    || echo "canonical-business.js differs from the manifest. It is generated in web; restore it with scripts/sync-rulebook-from-web.sh (git checkout to undo a hand edit)."
  [ "$(tr -d '[:space:]' < "$CANON/canonical-business.js.sha256")" = "$want_bundle" ] \
    || echo "canonical-business.js.sha256 differs from the manifest — re-run scripts/sync-rulebook-from-web.sh."
  [ -f "$RULEBOOK" ] && [ "$(sha256_of "$RULEBOOK")" = "$want_rulebook" ] \
    || echo "docs/RULEBOOK.md differs from the rulebook web published. It is a mirror; rule text changes start in project-planner-web."
}

# Rulebook-owned areas (RULEBOOK.md §4–§13). A changed Swift file that adds lines computing one of these
# without a CanonicalBusinessEngine call in the same change is flagged.
AREA='overtime|unbooked|clash|payRate|dayRate|hourlyRate|payBasis|annualLeave|leaveBalance|cutOff|coverageWindow|paymentRun|invoicingPeriod|workedHours|timesheetPeriod|payrollTimePolicy|lineManager|notificationPreference|passwordMin|currencyCode|formatMoney'
CALC='Calendar|dateComponents|\.weekday|startOfDay|[^=!<>]=[^=]|\+=|-=|\*|/ |max\(|min\(|filter|reduce'

swift_problems() {
  local files f added
  cd "$ROOT" || return
  files="$( { git diff --name-only HEAD -- '*.swift' 2>/dev/null; git ls-files --others --exclude-standard -- '*.swift' 2>/dev/null; } | sort -u)"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    case "$f" in ProjectPlannerTests/*|ProjectPlannerUITests/*|"Project Planner/Canonical/"*) continue ;; esac
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      added="$(git diff HEAD -U0 -- "$f" | sed -n 's/^+\([^+].*\)/\1/p')"
    else
      added="$(cat "$f")"
    fi
    if printf '%s\n' "$added" | grep -Eiq "$AREA" \
      && printf '%s\n' "$added" | grep -Ei "$AREA" | grep -Eq "$CALC" \
      && ! printf '%s\n' "$added" | grep -q 'CanonicalBusinessEngine'; then
      echo "$f adds logic for a rulebook-owned area without a CanonicalBusinessEngine call. Call the packed rule, or name the rulebook function in your report (none exists → it goes to web lib/canonical first)."
    fi
  done <<< "$files"
}

stop() {
  local input problems
  input="$(cat 2>/dev/null || true)"
  if printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then exit 0; fi
  problems="$(pack_problems; swift_problems)"
  if [ -n "$problems" ]; then
    printf 'Rulebook guard:\n%s\n' "$problems" >&2
    exit 2
  fi
  exit 0
}

case "${1:-status}" in
  stop) stop ;;
  status) status ;;
  *) echo "usage: $0 stop|status" >&2; exit 1 ;;
esac
