# Project Planner - Password Setup Website

This is a simple static website for handling password setup for invited users.

## Setup Instructions

### 1. Update Firebase Configuration

Open `setup-password.html` and replace the Firebase configuration with your actual values:

```javascript
const firebaseConfig = {
    apiKey: "YOUR_API_KEY",
    authDomain: "YOUR_PROJECT_ID.firebaseapp.com",
    projectId: "YOUR_PROJECT_ID",
    storageBucket: "YOUR_PROJECT_ID.appspot.com",
    messagingSenderId: "YOUR_SENDER_ID",
    appId: "YOUR_APP_ID"
};
```

You can find these values in:
- Firebase Console → Project Settings → General → Your apps
- Or in your `GoogleService-Info.plist` file

### 2. Hosting Options

#### Option A: Firebase Hosting (Recommended - Free)
```bash
# Install Firebase CLI
npm install -g firebase-tools

# Login
firebase login

# Initialize hosting
firebase init hosting

# Deploy
firebase deploy --only hosting
```

Your URL will be: `https://YOUR_PROJECT_ID.web.app/setup-password.html`

#### Option B: Netlify (Free & Easy)
1. Go to [netlify.com](https://netlify.com)
2. Drag and drop the `website` folder
3. Your URL will be: `https://your-site.netlify.app/setup-password.html`

#### Option C: Vercel (Free & Easy)
```bash
# Install Vercel CLI
npm install -g vercel

# Deploy
vercel
```

#### Option D: GitHub Pages
1. Create a GitHub repository
2. Push the `website` folder
3. Enable GitHub Pages in repository settings
4. Your URL will be: `https://yourusername.github.io/repo-name/setup-password.html`

### 3. Update Email Links

After deploying, update the email template in your iOS app:

In `SendGridEmailService.swift`, update the password setup email link:
```swift
<a href="https://YOUR_DEPLOYED_URL/setup-password.html?token=\(invitationCode)"
```

### 4. Firebase Security Rules

Make sure your Firestore rules allow reading invitations:

```javascript
match /invitations/{invitationId} {
  allow read: if request.auth == null; // Allow public read for invitation verification
  allow write: if request.auth != null;
}
```

And allow updating user documents:
```javascript
match /users/{userId} {
  allow read: if request.auth != null;
  allow write: if request.auth != null && request.auth.uid == userId;
}
```

## How It Works

1. User receives invitation email with link: `https://your-site.com/setup-password.html?token=INVITATION_CODE`
2. User enters invitation code (or it's auto-filled from URL)
3. System verifies invitation code against Firestore
4. User creates password
5. System creates Firebase Auth account
6. System updates Firestore user document with `passwordSet: true`
7. System marks invitation as used

## Password Reset

For password reset, you can use Firebase Auth's built-in functionality:

1. User clicks "Forgot Password" in app
2. App calls `auth.sendPasswordReset(withEmail: email)`
3. Firebase sends password reset email (you can customize the email template in Firebase Console)
4. User clicks link and resets password

Firebase handles the reset flow automatically - no custom website needed!

## Testing

1. Create an invitation in your app
2. Copy the invitation code from the email
3. Visit: `https://your-site.com/setup-password.html?token=INVITATION_CODE`
4. Test the password setup flow







