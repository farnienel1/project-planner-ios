#!/bin/bash
# Archive Project Planner for iOS (device). Run from repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="Project Planner.xcodeproj"
SCHEME="Project Planner"
ARCHIVE_PATH="${HOME}/Desktop/Project Planner $(date +%Y-%m-%d\ %H-%M-%S).xcarchive"

echo "→ Resolving Swift packages…"
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME"

echo "→ Archiving (Release, generic iOS device)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo ""
echo "✓ Archive succeeded:"
echo "  $ARCHIVE_PATH"
echo ""
echo "Open in Organizer: open -a Xcode \"$ARCHIVE_PATH\""
