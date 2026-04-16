# 🚀 START HERE - Choose Your Hosting Method

**Ready to deploy? Choose the method that works best for you:**

---

## Option 1: Netlify (No Terminal Required)

Easiest method - just drag and drop files.

- No terminal or command line needed
- About 5 minutes total
- Free hosting included
- Automatic HTTPS

Read: NETLIFY_SIMPLE.md

**Quick steps:**
1. Sign up at https://netlify.com
2. Drag and drop your website ZIP file
3. Done! Your site is live

---

## Option 2: Firebase Hosting (Terminal Required)

Uses Firebase directly but requires terminal commands.

- Official Firebase hosting
- Requires terminal/command line
- About 35 minutes setup time

Read: FIREBASE_HOSTING_STEP_BY_STEP.md

**Quick steps:**
1. Install Firebase CLI (terminal)
2. Login to Firebase (terminal)
3. Initialize and deploy (terminal)

---

## What You Need to Do (All Methods)

### 1. Get Firebase Config (5 minutes)

1. Go to: https://console.firebase.google.com/
2. Select your project
3. ⚙️ Settings → Project Settings
4. Scroll to "Your apps" → Web app
5. Copy the `firebaseConfig` values

### 2. Update 3 HTML Files (10 minutes)

Update these files with your Firebase config:
- `setup-password.html` (search for `firebaseConfig`)
- `reset-password.html` (search for `firebaseConfig`)
- `reset-password-complete.html` (search for `firebaseConfig`)

Replace:
```javascript
apiKey: "YOUR_API_KEY",  // ← Replace with your actual values
```

### 3. Update Firestore Rules (5 minutes)

Firebase Console → Firestore → Rules:

Add this rule:
```javascript
match /invitations/{invitationId} {
  allow read: if true;
  allow write: if request.auth != null;
}
```

---

## Which Should You Choose?

Method: Netlify
- Terminal needed: No
- Time: 5 minutes
- Difficulty: Easiest

Method: Firebase
- Terminal needed: Yes
- Time: 35 minutes
- Difficulty: Medium

Recommendation: Use Netlify if you want the easiest, fastest method without terminal.

---

## Documentation

- No Terminal? Read: NETLIFY_SIMPLE.md or HOSTING_WITHOUT_TERMINAL.md
- Want Firebase? Read: FIREBASE_HOSTING_STEP_BY_STEP.md
- Quick overview: QUICK_START.md

---

## Test Your Website

After deploying (any method):
1. Password Setup: Visit your URL + /setup-password.html?token=TEST_CODE
2. Password Reset: Visit your URL + /reset-password.html

## That's It

Your password website will be live and ready to use.

Next: Update your iOS app email templates to use the new website URL.

