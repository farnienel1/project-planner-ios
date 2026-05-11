# Secrets Setup (Do Not Commit Keys)

This app now reads email API keys from runtime configuration only.

## Required keys

- `SENDGRID_API_KEY`
- `RESEND_API_KEY`

## Xcode setup (no terminal)

1. Open the project in Xcode.
2. Click the scheme selector next to the Run button.
3. Select **Edit Scheme...**
4. Select **Run** -> **Arguments**.
5. Under **Environment Variables**, add:
   - `SENDGRID_API_KEY` with your real SendGrid key value
   - `RESEND_API_KEY` with your real Resend key value
6. Ensure both are checked/enabled.
7. Run the app again.

## Optional Info.plist fallback

If needed for non-debug builds, define `SENDGRID_API_KEY` and `RESEND_API_KEY` in the app's `Info.plist` using build settings. Do not store real keys directly in tracked files.

## Security notes

- Never paste real API keys into Swift, Markdown, or JSON files.
- Rotate any key that was ever committed, even if removed later.
- Treat push-protection warnings as real incidents and rotate immediately.
