# Visual issues

Reviewed: 5 Oct 2026.

## Result

No screenshots were available to review. No visual issues are listed, because none were seen.

`app-tests/screenshots/` was missing for the whole check. The expected folder `app-tests/screenshots/2026-10-05/` was never created, and no images were written under `app-tests/`.

Checks:

| Time (BST) | What was on disk |
|---|---|
| 17:57 | `app-tests/` did not exist |
| 18:00 | `app-tests/` still missing |
| 18:03 | `app-tests/` still missing |
| 18:08 | `app-tests/README.md` only; no `screenshots/` directory |
| 18:16 | Still no screenshot images under `app-tests/` |
| ~18:35 | `app-tests/screenshots/` still did not exist. Files present were `README.md`, `firebase.json`, and `rules/` tests only |

`scripts/screenshot-tour.sh` is set up to export into `app-tests/screenshots/2026-10-05/`, but that export had not started. No Screenshot Tour process was running during these checks.

Screenshots reviewed: **0**.

| Severity | Count |
|---|---|
| MAJOR | 0 |
| MINOR | 0 |
| COSMETIC | 0 |

`app-tests/VISUAL_ISSUES.html` was not built. There are no marked screenshots under `app-tests/visual-issues/`.
