#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/farnienel1/project-planner-ios.git"
TARGET="${HOME}/Developer/project-planner-ios"

echo "==> Project Planner — get latest main and open Xcode"
echo "    Target folder: ${TARGET}"
echo

if [[ -d "${TARGET}/.git" ]]; then
  cd "${TARGET}"
  git fetch origin
  git checkout main
  git pull origin main
else
  mkdir -p "${HOME}/Developer"
  git clone "${REPO_URL}" "${TARGET}"
  cd "${TARGET}"
fi

echo
echo "==> Current commit:"
git log -1 --oneline
echo

if [[ ! -d "Project Planner.xcodeproj" ]]; then
  echo "ERROR: Project Planner.xcodeproj not found in ${TARGET}" >&2
  exit 1
fi

echo "==> Opening Xcode..."
open "Project Planner.xcodeproj"
echo "Done. In Xcode: Product > Clean Build Folder, then Run."
