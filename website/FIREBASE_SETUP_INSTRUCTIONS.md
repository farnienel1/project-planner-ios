# Firebase Setup Instructions for Password Setup Website

## Step 1: Get Your Firebase Configuration

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project
3. Click the gear icon ⚙️ → **Project Settings**
4. Scroll down to **Your apps** section
5. Click on the **Web** app (or create one if it doesn't exist)
6. Copy the `firebaseConfig` object

Or you can extract it from your iOS app's `GoogleService-Info.plist`:

```swift
// From GoogleService-Info.plist:
API_KEY = "AIza..."
AUTH_DOMAIN = "your-project-id.firebaseapp.com"
PROJECT_ID = "your-project-id"
STORAGE_BUCKET = "your-project-id.appspot.com"
MESSAGING_SENDER_ID = "123456789"
APP_ID = "1:123456789:web:abc123"
```

## Step 2: Update setup-password.html

Open `website/setup-password.html` and find this section (around line 246):

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

Replace with your actual values:

```javascript
const firebaseConfig = {
    apiKey: "AIzaSyC...", // From GoogleService-Info.plist -> API_KEY
    authDomain: "your-project-id.firebaseapp.com", // PROJECT_ID + ".firebaseapp.com"
    projectId: "your-project-id", // PROJECT_ID
    storageBucket: "your-project-id.appspot.com", // PROJECT_ID + ".appspot.com"
    messagingSenderId: "123456789", // GCM_SENDER_ID
    appId: "1:123456789:web:abc123" // CLIENT_ID (web)
};
```

## Step 3: Update Firestore Security Rules

Make sure your Firestore rules allow:
1. Reading invitations (for verification)
2. Updating user documents (to set passwordSet: true)

Go to Firebase Console → Firestore Database → Rules:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Allow public read for invitation verification (before user is authenticated)
    match /invitations/{invitationId} {
      allow read: if true; // Allow public read for verification
      allow write: if request.auth != null;
    }
    
    // Allow authenticated users to read/write their own user document
    match /users/{userId} {
      allow read: if request.auth != null;
      // Allow write if user is authenticated OR if creating new user during setup
      allow write: if request.auth != null && request.auth.uid == userId;
      // Also allow public write for new user creation during password setup
      allow create: if true; // Only for creating new user documents
    }
    
    // Your existing rules...
  }
}
```

**Note**: The above rules are very permissive for invitations. For production, you might want to add expiration checks or rate limiting.

## Step 4: Enable Firebase Authentication

1. Go to Firebase Console → Authentication
2. Click **Get Started** if you haven't enabled it
3. Enable **Email/Password** provider
4. Make sure **Email link (passwordless sign-in)** is enabled (optional, but recommended)

## Step 5: Test Locally

Before deploying, test locally:

1. Open `setup-password.html` in a browser
2. Use an invitation code from your app
3. Test the password setup flow

## Step 6: Deploy

Choose one of these options:

### Option A: Firebase Hosting (Recommended)

```bash
# Install Firebase CLI
npm install -g firebase-tools

# Login
firebase login

# Initialize hosting (if not already done)
cd website
firebase init hosting

# When prompted:
# - Select existing project
# - Public directory: . (current directory)
# - Single-page app: No
# - Set up automatic builds: No

# Deploy
firebase deploy --only hosting
```

Your URL will be: `https://YOUR_PROJECT_ID.web.app/setup-password.html`

### Option B: Deploy to Custom Domain

If you have `projectplanner.us`:

1. In Firebase Console → Hosting → Add custom domain
2. Enter `projectplanner.us`
3. Follow DNS setup instructions
4. Deploy: `firebase deploy --only hosting`

Your URL will be: `https://projectplanner.us/setup-password.html`

### Option C: Netlify (Free & Easy)

1. Go to [netlify.com](https://netlify.com) and sign up
2. Drag and drop the `website` folder
3. Your URL will be: `https://your-site.netlify.app/setup-password.html`
4. Optionally add custom domain in Netlify settings

### Option D: GitHub Pages

1. Create a GitHub repository
2. Push the `website` folder
3. Go to repository Settings → Pages
4. Select source branch (usually `main`)
5. Your URL will be: `https://yourusername.github.io/repo-name/setup-password.html`

## Step 7: Update Email Template

After deploying, update the URL in your iOS app:

The email template in `SendGridEmailService.swift` is already updated to use:
```
https://projectplanner.us/setup-password.html?token=INVITATION_CODE
```

Make sure this matches your actual deployed URL!

## Troubleshooting

### "Invalid invitation code"
- Check that the invitation document exists in Firestore
- Verify the invitation code matches exactly
- Check Firestore rules allow reading invitations

### "Failed to set up password"
- Check Firebase Authentication is enabled
- Verify Email/Password provider is enabled
- Check browser console for specific error messages
- Ensure user document exists in Firestore (should be created when invitation is sent)

### "Permission denied" errors
- Check Firestore security rules
- Ensure rules allow writing to user documents
- Check that authentication state is correct







