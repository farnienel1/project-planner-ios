#!/bin/sh
# Runs the ProjectPlannerTests unit-test target, including snapshot comparisons.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-/tmp/project-planner-snapshot-derived}"
SIM_ID="${SNAPSHOT_SIMULATOR_ID:-9250FFF9-6782-4AF9-96C3-8E2C04D880A4}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,id=${SIM_ID}}"

case "$DESTINATION" in
  *800D1649-1CE4-4706-A6E1-FDFF5CFB2891*|*8628478B-072F-425F-A539-2ABE345A917D*|*8ECB1E11-056F-4A08-A547-54D26E3B26B2*)
    echo "Refusing the live iPhone 17 / iPhone 18 Pro simulator session." >&2
    exit 1
    ;;
esac

cd "$ROOT"
xcodebuild test \
  -project "$ROOT/Project Planner.xcodeproj" \
  -scheme ProjectPlannerTests \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -only-testing:ProjectPlannerTests \
  "$@"

# Snapshot comparisons are part of ProjectPlannerTests. This also runs them on their own
# so a snapshot failure is visible even if the filter above is narrowed later.
"$ROOT/scripts/test-snapshots.sh"
