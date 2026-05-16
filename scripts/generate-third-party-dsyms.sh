#!/bin/bash
# Generate UUID-matched dSYMs for Firebase/gRPC binary frameworks (SPM does not ship them).
# Resolves Xcode 16+ TestFlight "Upload Symbols Failed" warnings. See firebase-ios-sdk#13764.

set -euo pipefail

if [[ "${CONFIGURATION:-}" != "Release" ]]; then
  exit 0
fi

FRAMEWORKS_DIR="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
DSYM_DIR="${DWARF_DSYM_FOLDER_PATH:-}"

if [[ ! -d "$FRAMEWORKS_DIR" || -z "$DSYM_DIR" ]]; then
  exit 0
fi

mkdir -p "$DSYM_DIR"

# Firestore + gRPC xcframeworks embedded via Swift Package Manager.
FRAMEWORKS=(
  FirebaseFirestoreInternal
  grpc
  grpcpp
  absl
  openssl_grpc
)

for name in "${FRAMEWORKS[@]}"; do
  binary="${FRAMEWORKS_DIR}/${name}.framework/${name}"
  if [[ ! -f "$binary" ]]; then
    continue
  fi
  out="${DSYM_DIR}/${name}.framework.dSYM"
  if [[ -d "$out" ]]; then
    continue
  fi
  echo "note: Generating dSYM for ${name}.framework (TestFlight symbol upload)"
  dsymutil "$binary" -o "$out"
done
