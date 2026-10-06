#!/bin/sh
# Runs the screenshot tour and exports attachments into app-tests/screenshots/<date>/.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATE="${SCREENSHOT_DATE:-2026-10-05}"
OUT="$ROOT/app-tests/screenshots/$DATE"
DERIVED="${DERIVED_DATA_PATH:-/tmp/pp-uitest-derived}"
RESULT_DIR="$DERIVED/Logs/Test"
RESULT=""

cd "$ROOT"
mkdir -p "$OUT"

if [ -z "${DESTINATION:-}" ]; then
  echo "Set DESTINATION to an unused simulator, for example: platform=iOS Simulator,id=<UDID>" >&2
  exit 1
fi

case "$DESTINATION" in
  *800D1649-1CE4-4706-A6E1-FDFF5CFB2891*|*8628478B-072F-425F-A539-2ABE345A917D*)
    echo "Refusing a live simulator." >&2
    exit 1
    ;;
esac

xcodebuild test \
  -project "$ROOT/Project Planner.xcodeproj" \
  -scheme "Project Planner" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -testPlan ProjectPlanner-Full \
  -only-testing:ProjectPlannerUITests/ScreenshotTourTests \
  -resultBundlePath "$DERIVED/ScreenshotTour.xcresult" \
  || true

RESULT="$DERIVED/ScreenshotTour.xcresult"
if [ ! -d "$RESULT" ]; then
  RESULT="$(find "$RESULT_DIR" -name '*.xcresult' -print | head -1 || true)"
fi
if [ -z "$RESULT" ] || [ ! -d "$RESULT" ]; then
  echo "No xcresult bundle found under $DERIVED" >&2
  exit 1
fi

EXPORT="$OUT/raw"
rm -rf "$EXPORT"
mkdir -p "$EXPORT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$EXPORT"

python3 - "$EXPORT" "$OUT" <<'PY'
import json, os, shutil, sys
export_root, out = sys.argv[1], sys.argv[2]
moved = []
for dirpath, _, filenames in os.walk(export_root):
    manifest = os.path.join(dirpath, "manifest.json")
    names = {}
    if os.path.isfile(manifest):
        try:
            data = json.load(open(manifest))
        except Exception:
            data = []
        if isinstance(data, dict):
            data = data.get("attachments") or data.get("files") or []
        if isinstance(data, list):
            for item in data:
                if not isinstance(item, dict):
                    continue
                suggested = item.get("suggestedFilename") or item.get("name") or ""
                exported = item.get("exportedFileName") or item.get("filename") or ""
                if suggested and exported:
                    names[exported] = suggested
    for filename in filenames:
        if filename == "manifest.json":
            continue
        src = os.path.join(dirpath, filename)
        suggested = names.get(filename, "")
        if not suggested:
            stem = os.path.splitext(filename)[0]
            if "__" in stem:
                suggested = filename
        if "__" not in suggested:
            continue
        base = os.path.splitext(suggested)[0]
        ext = os.path.splitext(filename)[1] or ".png"
        parts = base.split("__")
        if len(parts) < 5:
            dest_dir = os.path.join(out, "unsorted")
            dest_name = base + ext
        else:
            role, appearance, module = parts[0], parts[1], parts[2]
            dest_dir = os.path.join(out, role, appearance, module)
            dest_name = base + ext
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, dest_name)
        shutil.copy2(src, dest)
        moved.append(os.path.relpath(dest, out))

index = os.path.join(out, "INDEX.md")
by_module = {}
counts = {}
for rel in sorted(moved):
    parts = rel.split(os.sep)
    if len(parts) < 4 or parts[0] in ("unsorted", "raw"):
        module = "unsorted"
    else:
        role, appearance, module = parts[0], parts[1], parts[2]
        counts[(role, appearance)] = counts.get((role, appearance), 0) + 1
    by_module.setdefault(module, []).append(rel)

lines = ["# Screenshot tour", "", f"Date: {os.path.basename(out)}", "", "## Counts", ""]
if not counts:
    lines.append("No renamed screenshots. Attachments may still be in `raw/`.")
else:
    lines.append("| Role | Appearance | Screenshots |")
    lines.append("|---|---|---|")
    for (role, appearance), count in sorted(counts.items()):
        lines.append(f"| {role} | {appearance} | {count} |")
lines += ["", "## By module", ""]
for module in sorted(by_module):
    lines.append(f"### {module}")
    lines.append("")
    for rel in by_module[module]:
        lines.append(f"- `{rel}`")
    lines.append("")
lines += [
    "## Not reached",
    "",
    "QS and subcontractor are not signed-in roles in this app. Subcontractors are records. There is no QS role.",
    "",
    "Screens the tour did not open are listed in the `meta/missed` text attachments when those exported.",
    "Loading and error states, swipe actions, date pickers, and confirm dialogs are only captured when a control with that label is on screen.",
    "Help does not show info@projectplanner.us. Camera, photo library, location permission, and push prompts need a system alert the tour does not force.",
    "",
]
open(index, "w").write("\n".join(lines) + "\n")
print(f"Exported {len(moved)} screenshots to {out}")
PY
