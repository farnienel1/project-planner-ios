# iOS testing

Test the Project Planner iOS app safely and quickly.

## Safety

- Use only the test organisation, the Firebase Emulator, and the accounts in `.cursor/test-accounts.local.md`.
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

Prefer XCUITest and unit tests (`test_sim` or `xcodebuild test`). Live Simulator tapping is only for exploring a new feature or reproducing a bug.

When driving the Simulator with XcodeBuildMCP:

- Read the screen with `snapshot_ui` and tap by `elementRef`. Screenshots are evidence only.
- UI taps need the `ui-automation` workflow in `.xcodebuildmcp/config.yaml` and `XCODEBUILDMCP_ENABLED_WORKFLOWS`. Reload the MCP server after that config changes.
- Local walks launch `Project Planner` with `-uiTesting -autoLoginRole admin -seedDemoData`. That stays on seeded TEST data and skips the live Firebase session.
- Set session defaults (project, scheme, simulator) once per session.
- Skip clean builds and reinstalls unless a step needs them.
- Use one simulator unless the test needs two users.
- Tap by accessibility identifier first, then by label. Use coordinates only when neither is available.

## Records

- Keep `app-tests/PROGRESS.md` updated.
- Start a fresh chat after each module.
- Write `app-tests/REPORT.md` in the format from `CURSOR_FULL_APP_TEST_GUIDE.md`.
