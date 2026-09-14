#!/bin/bash
# One-shot: check out the Cloud Agent Warnings fix branch and open Xcode.
# For continuous sync after every agent push, use: ./scripts/watch-agent-branch.sh

set -euo pipefail

REPO_URL="https://github.com/farnienel1/project-planner-ios.git"
# Prefer the folder you already have open; fall back to ~/Developer clone.
if [[ -d "$(pwd)/.git" ]] && [[ -d "$(pwd)/Project Planner.xcodeproj" || -d "$(pwd)/Project Planner" ]]; then
  TARGET="$(pwd)"
else
  TARGET="${HOME}/Developer/project-planner-ios"
fi

BRANCH="${1:-cursor/warnings-build-stamp-visible-ec6c}"

echo "==> Project Planner — get agent branch and open Xcode"
echo "    Target: ${TARGET}"
echo "    Branch: ${BRANCH}"
echo

if [[ -d "${TARGET}/.git" ]]; then
  cd "${TARGET}"
  git fetch origin
  git checkout "${BRANCH}"
  git pull --ff-only origin "${BRANCH}"
else
  mkdir -p "$(dirname "${TARGET}")"
  git clone "${REPO_URL}" "${TARGET}"
  cd "${TARGET}"
  git checkout "${BRANCH}"
fi

echo
echo "==> Current commit:"
git log -1 --oneline
echo

if [[ -d "Project Planner.xcodeproj" ]]; then
  open "Project Planner.xcodeproj"
elif [[ -d "ProjectPlanner.xcodeproj" ]]; then
  open "ProjectPlanner.xcodeproj"
else
  echo "WARNING: xcodeproj not found — open the project manually from ${TARGET}"
fi

echo "Done. Stamp to verify: Warnings SAFE / wfix-noscan-9"
echo "Keep in sync: ./scripts/watch-agent-branch.sh ${BRANCH}"
