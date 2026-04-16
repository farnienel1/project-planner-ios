# 🚀 Quick Start - Password Website Setup

## 🎯 Choose Your Method First

**Don't want to use terminal?** Use **Netlify** instead! See `NETLIFY_DRAG_DROP_GUIDE.md`

**Want Firebase Hosting?** Continue below (requires terminal).

---

## Step 1: Get Your Firebase Config (2 minutes)

1. Open **Firebase Console**: https://console.firebase.google.com/
2. Select your **Project Planner** project
3. Click ⚙️ **Settings** → **Project Settings**
4. Scroll to **"Your apps"** section
5. Click on **Web app** (or create one if it doesn't exist)
6. Copy the `firebaseConfig` object

It looks like this:
```javascript
{
  apiKey: "AIzaSyC...",
  authDomain: "your-project.firebaseapp.com",
  projectId: "your-project-id",
  storageBucket: "your-project.appspot.com",
  messagingSenderId: "123456789",
  appId: "1:123456789:web:abc123"
}
```

## Step 2: Update Config in 3 Files (3 minutes)

Open these files in the `website` folder and replace `YOUR_API_KEY`, `YOUR_PROJECT_ID`, etc.:

1. **`setup-password.html`** (around line 246)
2. **`reset-password.html`** (around line 143)
3. **`reset-password-complete.html`** (around line 218)

Find this section in each file:
```javascript
const firebaseConfig = {
    apiKey: "YOUR_API_KEY",  // ← Replace these
    authDomain: "YOUR_PROJECT_ID.firebaseapp.com",
    projectId: "YOUR_PROJECT_ID",
    storageBucket: "YOUR_PROJECT_ID.appspot.com",
    messagingSenderId: "YOUR_SENDER_ID",
    appId: "YOUR_APP_ID"
};
```

## Step 3: Deploy (Choose One - 5 minutes)

### ✅ Option A: Netlify (Easiest - Drag & Drop)

1. Go to [netlify.com](https://netlify.com) and sign up (free)
2. Drag the entire `website` folder onto Netlify
3. Done! Your site is live at `https://your-site.netlify.app`

### ✅ Option B: Firebase Hosting (Recommended)

```bash
npm install -g firebase-tools
firebase login
cd website
firebase init hosting
# Select your project, public directory: ., single-page: No
firebase deploy --only hosting
```

Your site: `https://YOUR_PROJECT_ID.web.app`

### ✅ Option C: Vercel

```bash
npm install -g vercel
cd website
vercel
```

## Step 4: Update Email Links in iOS App (2 minutes)

The email template in `SendGridEmailService.swift` is already configured to use:
```
https://projectplanner.us/setup-password.html?token=CODE
```

**After deploying**, make sure this URL matches your actual website URL!

## Step 5: Update Firestore Rules (2 minutes)

In Firebase Console → Firestore Database → Rules:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Allow public read for invitation verification
    match /invitations/{invitationId} {
      allow read: if true;
      allow write: if request.auth != null;
    }
    
    match /users/{userId} {
      allow read: if request.auth != null;
      allow write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Your existing organization rules...
  }
}
```

## Step 6: Test! (5 minutes)

1. **Test Password Setup:**
   - In your iOS app, invite a test user
   - Copy the invitation code from the email
   - Visit: `https://your-site.com/setup-password.html?token=CODE`
   - Complete password setup

2. **Test Password Reset:**
   - Visit: `https://your-site.com/reset-password.html`
   - Enter your email
   - Check email and click reset link
   - Reset password

## ✅ You're Done!

Your password website is now live and working!

---

## Files Created

- ✅ `setup-password.html` - First-time password setup for invited users
- ✅ `reset-password.html` - Request password reset
- ✅ `reset-password-complete.html` - Complete password reset
- ✅ `index.html` - Main landing page
- ✅ `styles.css` - Styling
- ✅ `DEPLOY.md` - Full deployment guide
- ✅ `FIREBASE_SETUP_INSTRUCTIONS.md` - Detailed Firebase setup

---

## Need Help?

- See `DEPLOY.md` for detailed deployment options
- See `FIREBASE_SETUP_INSTRUCTIONS.md` for Firebase configuration
- Check browser console for errors
- Verify Firestore rules allow invitation reads

