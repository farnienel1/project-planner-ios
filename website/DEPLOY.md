# Deployment Guide - Project Planner Password Website

## Quick Start (Choose One)

### Option 1: Firebase Hosting (Recommended - Free & Easy)

1. **Install Firebase CLI:**
  ```bash
   npm install -g firebase-tools
  ```
2. **Login to Firebase:**
  ```bash
   firebase login
  ```
3. **Initialize Hosting:**
  ```bash
   cd website
   firebase init hosting
  ```
   When prompted:
  - ✅ Use an existing project (select your Project Planner project)
  - 📁 Public directory: `.` (current directory)
  - ❌ Single-page app: No
  - ❌ Set up automatic builds: No
4. **Update Firebase Config:**
  - Open `setup-password.html`, `reset-password.html`, and `reset-password-complete.html`
  - Replace `YOUR_API_KEY`, `YOUR_PROJECT_ID`, etc. with your actual Firebase config
  - See `FIREBASE_SETUP_INSTRUCTIONS.md` for details
5. **Deploy:**
  ```bash
   firebase deploy --only hosting
  ```
6. **Your website will be live at:**
  - `https://YOUR_PROJECT_ID.web.app`
  - Or configure custom domain: `https://projectplanner.us`

---

### Option 2: Netlify (Free & Super Easy - Drag & Drop)

1. **Go to [netlify.com](https://netlify.com)** and sign up/login
2. **Drag & Drop:**
  - Simply drag the `website` folder onto Netlify
  - That's it! Your site is live
3. **Update Firebase Config:**
  - Open the files in Netlify's editor
  - Update Firebase config (same as above)
4. **Your website will be live at:**
  - `https://random-name-123.netlify.app`
  - Add custom domain in Netlify settings: `projectplanner.us`

---

### Option 3: Vercel (Free & Easy)

1. **Install Vercel CLI:**
  ```bash
   npm install -g vercel
  ```
2. **Deploy:**
  ```bash
   cd website
   vercel
  ```
  - Follow the prompts
  - Choose your project name
3. **Update Firebase Config** (same as above)
4. **Your website will be live at:**
  - `https://your-project.vercel.app`
  - Add custom domain: `projectplanner.us`

---

### Option 4: GitHub Pages (Free)

1. **Create GitHub Repository:**
  - Create a new repo (e.g., `project-planner-website`)
  - Don't initialize with README
2. **Push Files:**
  ```bash
   cd website
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/YOUR_USERNAME/project-planner-website.git
   git push -u origin main
  ```
3. **Enable GitHub Pages:**
  - Go to repository Settings → Pages
  - Source: `main` branch → `/` (root)
  - Save
4. **Update Firebase Config** (same as above)
5. **Your website will be live at:**
  - `https://YOUR_USERNAME.github.io/project-planner-website`
  - Add custom domain in Pages settings

---

## Getting Your Firebase Configuration

You need these values for all password pages:

1. **From Firebase Console:**
  - Go to [Firebase Console](https://console.firebase.google.com/)
  - Select your project
  - ⚙️ Settings → Project Settings
  - Scroll to "Your apps" → Web app
  - Copy the `firebaseConfig` object
2. **Or from GoogleService-Info.plist:**
  ```swift
   API_KEY → apiKey
   PROJECT_ID → projectId, authDomain, storageBucket
   GCM_SENDER_ID → messagingSenderId
   CLIENT_ID (web) → appId
  ```
3. **Update these files:**
  - `setup-password.html` (line ~246)
  - `reset-password.html` (line ~143)
  - `reset-password-complete.html` (line ~218)

---

## Custom Domain Setup (Optional)

### For Firebase Hosting:

1. Firebase Console → Hosting → Add custom domain
2. Enter: `projectplanner.us`
3. Follow DNS instructions
4. Wait for SSL certificate (can take up to 24 hours)

### For Netlify:

1. Netlify Dashboard → Domain settings
2. Add custom domain: `projectplanner.us`
3. Follow DNS instructions
4. SSL is automatic

### For Vercel:

1. Vercel Dashboard → Project → Settings → Domains
2. Add: `projectplanner.us`
3. Follow DNS instructions
4. SSL is automatic

---

## Firestore Security Rules

Update your Firestore rules to allow invitation verification:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Allow public read for invitation verification
    match /invitations/{invitationId} {
      allow read: if true;
      allow write: if request.auth != null;
    }
    
    // Allow updating user documents during password setup
    match /users/{userId} {
      allow read: if request.auth != null;
      allow write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Your existing rules...
  }
}
```

---

## Testing

1. **Test Password Setup:**
  - Create an invitation in your iOS app
  - Copy the invitation code from the email
  - Visit: `https://your-site.com/setup-password.html?token=CODE`
  - Complete the password setup
2. **Test Password Reset:**
  - Visit: `https://your-site.com/reset-password.html`
  - Enter your email
  - Check email for reset link
  - Click link and reset password

---

## Troubleshooting

### "Invalid invitation code"

- Check Firestore rules allow reading invitations
- Verify invitation code matches exactly
- Check invitation hasn't expired (7 days)

### "Failed to set up password"

- Check Firebase Authentication is enabled
- Verify Email/Password provider is enabled
- Check browser console for errors

### "Permission denied"

- Update Firestore security rules (see above)
- Ensure rules allow writing to user documents

---

## Support

Need help? Check:

- `FIREBASE_SETUP_INSTRUCTIONS.md` - Detailed Firebase setup
- `README.md` - General website info
- Firebase Console → Support

