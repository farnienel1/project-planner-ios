# Password reset Cloud Functions

These functions send the password reset email via Resend so the link actually arrives when users click **“Send password reset email instead”** on the setup-password page.

- **sendPasswordResetHttp** – HTTP endpoint (called with `fetch()` from the web).
- **sendProjectPlannerPasswordReset** – Callable (Firebase SDK).

---

## Setup instructions

**Use the full step-by-step guide:**  
**[../PASSWORD_RESET_SETUP.md](../PASSWORD_RESET_SETUP.md)**

That document includes:

- What you need before starting (Node, Firebase CLI, Resend key, Blaze plan).
- Numbered steps with exact commands.
- How to open Terminal and navigate to the `website` folder.
- What success looks like at each step.
- A checklist and troubleshooting table.

---

## Short version (if you’ve done this before)

From the **website** folder:

1. `firebase functions:secrets:set RESEND_API_KEY` (paste your Resend key when prompted).
2. `npm install --prefix functions`
3. `firebase deploy --only functions`

Wait for “Deploy complete”, then test on the setup-password page.
