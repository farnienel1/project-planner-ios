# Password reset email – full setup instructions

This guide gets the **“Send password reset email instead”** button working on the setup-password web page. The email is sent via Resend (same as the app) so it actually arrives.

---

## Easiest: run the setup script (no terminal commands to remember)

1. **Get your Resend API key**  
   Go to https://resend.com → sign in → **API Keys** → create or copy a key (starts with `re_`).

2. **Run the setup:**
   - **On Mac:** In Finder, go to your **website** folder and **double‑click**  
     **`Setup Password Reset.command`**  
     A Terminal window will open. When it asks for your Resend API key, paste the key and press **Enter**. Wait until it says “Done.”
   - **Or in Terminal:** Open Terminal, then run:
     ```bash
     cd '/Users/farnienel/Desktop/Project Planner/website'
     node setup-password-reset.js
     ```
     Paste your Resend API key when prompted and press **Enter**.

3. **First time only:** You may need to run `firebase login` once (the script will tell you if login is required).

That’s it. The script sets the secret, installs dependencies, and deploys the functions.

---

## Before you start (if you prefer doing it manually)

You need:

- **Node.js** installed (from https://nodejs.org – use the LTS version).  
  Check: open Terminal and type `node --version`. You should see something like `v18.x.x` or `v20.x.x`.

- **Firebase CLI** installed.  
  Check: type `firebase --version`. If you get “command not found”, install it:
  - Run: `npm install -g firebase-tools`
  - Then run: `firebase login`

- Your **Resend API key** (the same one used in the iOS app).  
  - Go to https://resend.com and sign in.  
  - Click **API Keys** in the sidebar.  
  - Create a key or copy an existing one. It starts with `re_` (e.g. `re_123abc...`).  
  - Keep it somewhere you can paste from (e.g. Notes).

- Your Firebase project on the **Blaze (pay-as-you-go)** plan.  
  - Cloud Functions require Blaze. In Firebase Console → Project settings → Usage and billing, upgrade if needed. You still only pay for what you use; the free tier covers light use.

- Your **project folder** open.  
  - You need to be in the folder that **contains** the `website` folder (e.g. `Project Planner` or `Project Planner/website` depending on how your project is laid out).

---

## Step-by-step instructions

### Step 1: Open Terminal

- **Mac:** Open the **Terminal** app (search “Terminal” in Spotlight).
- **Windows:** Open **Command Prompt** or **PowerShell** (search “cmd” or “PowerShell”).

---

### Step 2: Go to the correct folder

- You must be **inside** the `website` folder of your project.

  **Copy and paste this** (for your Mac path):

  ```bash
  cd '/Users/farnienel/Desktop/Project Planner/website'
  ```

  **If you are already inside** `Project Planner`:

  ```bash
  cd website
  ```

- Check you’re in the right place: run `ls`.  
  You should see files like `setup-password.html`, `index.html`, and a folder called `functions`.

---

### Step 3: Log in to Firebase (if needed)

- Run:

  ```bash
  firebase login
  ```

- A browser window will open. Sign in with the Google account that owns your Firebase project.
- When it says “Success!”, you can close the browser and go back to Terminal.

---

### Step 4: Make sure you’re using the right Firebase project

- Run:

  ```bash
  firebase use
  ```

- You should see your project ID (e.g. `project-planner-f986c`).  
- If it shows the wrong project or “no project”, run:

  ```bash
  firebase use YOUR_PROJECT_ID
  ```

  (Replace `YOUR_PROJECT_ID` with the ID from Firebase Console → Project settings.)

---

### Step 5: Store your Resend API key as a secret

- Run:

  ```bash
  firebase functions:secrets:set RESEND_API_KEY
  ```

- When it says **“Enter a value for RESEND_API_KEY”**, paste your Resend API key (the one that starts with `re_`) and press **Enter**.  
  (Nothing will appear as you paste – that’s normal.)

- You should see a message like: **“Created a new secret version…”** or **“Updated secret…”**

- **If you get “Permission denied” or “not found”:**  
  Make sure you’re in the `website` folder and that this project has the Blaze plan. Run `firebase use` again and try the command once more.

---

### Step 6: Install the function dependencies

- Still in the `website` folder, run:

  ```bash
  npm install --prefix functions
  ```

- Wait until it finishes. You should see something like “added 200 packages” and no red errors.

- **If you get “npm: command not found”:**  
  Install Node.js from https://nodejs.org and try again.

---

### Step 7: Deploy the functions

- Run:

  ```bash
  firebase deploy --only functions
  ```

- The first time can take 1–2 minutes. You should see:
  - “Building…”
  - “Uploading…”
  - “sendPasswordResetHttp” and “sendProjectPlannerPasswordReset” listed.
  - **“Deploy complete!”** at the end.

- **If it says “Billing account not configured” or “upgrade to Blaze”:**  
  In Firebase Console → Project settings → Usage and billing, link a billing account and switch to the Blaze plan.

- **If it says “RESEND_API_KEY” not found or secret error:**  
  Run Step 5 again and make sure you pasted the full key and pressed Enter.

---

### Step 8: Test that it works

1. Open your setup-password page in a browser (e.g. `https://projectplanner.us/setup-password.html` or your staging URL).
2. Enter an invitation code that would trigger “An account with this email already exists” (or use a test account that already has an Auth account).
3. When the page shows **“Send password reset email instead”**, click it.
4. You should see a green/success message like: **“We’ve sent a password reset link to [email] from Project Planner…”**
5. Check that email’s inbox (and spam). You should receive an email from **Project Planner** (info@projectplanner.us) with a “Reset password” button or link.

If the message says **“Password reset isn’t set up yet”** or **“Your email wasn’t found”**, go back to Step 5 (secret) and Step 7 (deploy) and make sure both completed without errors.

---

## Quick checklist

- [ ] Node.js installed (`node --version` works).
- [ ] Firebase CLI installed and logged in (`firebase login`).
- [ ] In the `website` folder (`ls` shows `setup-password.html` and `functions`).
- [ ] Correct Firebase project selected (`firebase use`).
- [ ] Resend API key stored: `firebase functions:secrets:set RESEND_API_KEY`.
- [ ] Dependencies installed: `npm install --prefix functions`.
- [ ] Functions deployed: `firebase deploy --only functions` → “Deploy complete!”.
- [ ] Tested on the setup-password page and received the email.

---

## If something goes wrong

| Problem | What to do |
|--------|------------|
| `firebase: command not found` | Install Firebase CLI: `npm install -g firebase-tools`, then `firebase login`. |
| `npm: command not found` | Install Node.js from https://nodejs.org (LTS). |
| “Billing account not configured” | Firebase Console → Usage and billing → upgrade to Blaze. |
| “Permission denied” on secrets | Confirm you’re in `website` and your Google account owns the Firebase project. |
| “Deploy complete” but email still doesn’t send | Re-run Step 5 (paste the Resend key again), then Step 7 (deploy again). Clear browser cache and test again. |
| Email not in inbox | Check spam/junk. Confirm the Resend domain (e.g. projectplanner.us) is verified in the Resend dashboard. |
