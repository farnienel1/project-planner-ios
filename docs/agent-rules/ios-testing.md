# iOS testing

Test the Project Planner iOS app safely and quickly.

## Safety

- Use only the test organisation, the Firebase Emulator, and test accounts from the project's seed or fixture files.
- Prefix created data with `TEST-` (example: a project named `TEST-Kitchen refit`).
- Never touch production data, billing, signing, TestFlight, or the App Store.

## Leave app behaviour alone

Never change app behaviour to make a test pass. Test-only code belongs in the test targets or inside `#if DEBUG`. If the app has a bug, report it.

```swift
// ❌ App target — skips a real check so the test goes green
if CommandLine.arguments.contains("-uiTest") { return }

// ✅ Test target, or debug-only app code
#if DEBUG
enum UITestSeed { static let projectName = "TEST-Kitchen refit" }
#endif
```

## How to run checks

Prefer unit tests and XCUITest. Live Simulator tapping is only for exploring a new feature or reproducing a bug.

- Unit tests run from the `ProjectPlannerTests` scheme (`xcodebuild test -scheme ProjectPlannerTests`). The `Project Planner` app scheme does not include them.
- Snapshot references in `FixedSampleScreenSnapshotTests` were recorded on iPhone 16e, iOS 26.2. A run on another simulator fails on device differences, not real changes.
- Security-rules tests are `npm run test:rules` and `npm run test:tenant`. They need Node 24.12 or later and Java for the Firestore emulator.
- Local walks launch `Project Planner` with `-uiTesting -autoLoginRole admin -seedDemoData`. That stays on seeded TEST data and skips the live Firebase session.
- Skip clean builds and reinstalls unless a step needs them.
- Use one simulator unless the test needs two users.
- Tap by accessibility identifier first, then by label. Use coordinates only when neither is available.

## Records

- Security-rules results go in `app-tests/REPORT.md`.
- Report what was run, on which simulator and OS, and what was not checked.
