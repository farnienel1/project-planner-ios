#!/bin/bash
# Auto-pull the current (or specified) git branch so Xcode stays in sync with
# Cloud Agent pushes. Cursor cannot push into your Mac checkout automatically —
# run this once in Terminal while you iterate with the agent.
#
# Usage:
#   ./scripts/watch-agent-branch.sh
#   ./scripts/watch-agent-branch.sh cursor/warnings-build-stamp-visible-ec6c
#   BRANCH=cursor/warnings-build-stamp-visible-ec6c INTERVAL=10 ./scripts/watch-agent-branch.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BRANCH="${1:-${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}}"
INTERVAL="${INTERVAL:-15}"

if [[ "$BRANCH" == "HEAD" ]]; then
  echo "Detached HEAD — pass a branch name: $0 cursor/<agent-branch>-ec6c" >&2
  exit 1
fi

echo "==> Watching origin/$BRANCH every ${INTERVAL}s"
echo "    Repo: $ROOT"
echo "    Leave this running; Xcode will see file changes after each pull."
echo "    Ctrl+C to stop."
echo

git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH" || true
git log -1 --oneline
echo

notify() {
  local msg="$1"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"Project Planner pull\"" >/dev/null 2>&1 || true
  fi
  echo "$(date '+%H:%M:%S') $msg"
}

while true; do
  if ! git fetch origin "$BRANCH" >/dev/null 2>&1; then
    echo "$(date '+%H:%M:%S') fetch failed — retrying"
    sleep "$INTERVAL"
    continue
  fi

  LOCAL="$(git rev-parse HEAD)"
  REMOTE="$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)"
  if [[ -z "$REMOTE" ]]; then
    echo "$(date '+%H:%M:%S') origin/$BRANCH missing"
    sleep "$INTERVAL"
    continue
  fi

  if [[ "$LOCAL" != "$REMOTE" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
      notify "Remote updated but local has uncommitted changes — pull skipped"
    elif git pull --ff-only origin "$BRANCH"; then
      notify "Pulled $(git rev-parse --short HEAD) — Clean Build in Xcode"
      git log -1 --oneline
    else
      notify "Pull failed (diverged?) — check Terminal"
    fi
  fi
  sleep "$INTERVAL"
done
