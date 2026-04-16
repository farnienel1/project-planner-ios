# 🔥 Firebase Hosting - Step-by-Step Guide

Complete guide to build and host your Project Planner password website on Firebase.

---

## Prerequisites

Before starting, you need:
- ✅ A Firebase project (you already have this!)
- ✅ Node.js installed on your computer ([download here](https://nodejs.org/))
- ✅ The website files in the `website` folder

---

## Step 1: Install Firebase CLI (5 minutes)

### On macOS/Linux:

1. **Open Terminal** (Applications → Utilities → Terminal)

2. **Install Firebase CLI globally:**
   ```bash
   npm install -g firebase-tools
   ```
   
   If you get a permission error, use:
   ```bash
   sudo npm install -g firebase-tools
   ```

3. **Verify installation:**
   ```bash
   firebase --version
   ```
   
   You should see something like: `13.0.0` or similar.

---

## Step 2: Login to Firebase (2 minutes)

1. **In Terminal, run:**
   ```bash
   firebase login
   ```

2. **A browser window will open:**
   - Click "Allow" to authorize Firebase CLI
   - Or choose "Use another account" if needed
   - Select your Google account that has access to your Firebase project

3. **You should see:** ✅ Logged in as: your-email@gmail.com

---

## Step 3: Navigate to Website Folder (1 minute)

1. **Open Terminal**

2. **Navigate to your project folder:**
   ```bash
   cd "/Users/farnienel/Desktop/Project Planner"
   cd website
   ```

3. **Verify you're in the right place:**
   ```bash
   ls
   ```
   
   You should see files like:
   - `setup-password.html`
   - `reset-password.html`
   - `index.html`
   - etc.

---

## Step 4: Initialize Firebase Hosting (5 minutes)

1. **In Terminal (still in the `website` folder), run:**
   ```bash
   firebase init hosting
   ```

2. **You'll be asked several questions - answer them like this:**
   ```
   ? Which Firebase CLI features do you want to set up for this directory?
   → Use arrow keys to select "Hosting: Configure files for Firebase Hosting"
   → Press Space to select, then Enter to confirm
   
   ? Please select an option: (Use arrow keys)
   → Select "Use an existing project"
   
   ? Select a default Firebase project for this directory:
   → Use arrow keys to find and select your "Project Planner" project
   → Press Enter
   
   ? What do you want to use as your public directory? (public)
   → Type: . (just a dot, meaning current directory)
   → Press Enter
   
   ? Configure as a single-page app (rewrite all urls to /index.html)? (y/N)
   → Type: N
   → Press Enter
   
   ? Set up automatic builds and deploys with GitHub? (y/N)
   → Type: N
   → Press Enter
   
   ? File public/index.html already exists. Overwrite? (y/N)
   → Type: N (we want to keep our files)
   → Press Enter
   ```

3. **Firebase will create:**
   - `.firebaserc` - Project configuration
   - `firebase.json` - Hosting configuration

---

## Step 5: Get Your Firebase Configuration (5 minutes)

You need to update the Firebase config in your HTML files.

### Option A: From Firebase Console (Easiest)

1. **Go to:** https://console.firebase.google.com/
2. **Select your project:** "Project Planner"
3. **Click:** ⚙️ Settings → **Project Settings**
4. **Scroll down** to **"Your apps"** section
5. **Click:** Web app (or the `</>` icon) - **Create one if it doesn't exist**
6. **You'll see a config like this:**
   ```javascript
   const firebaseConfig = {
     apiKey: "AIzaSyC...",
     authDomain: "your-project-id.firebaseapp.com",
     projectId: "your-project-id",
     storageBucket: "your-project-id.appspot.com",
     messagingSenderId: "123456789",
     appId: "1:123456789:web:abc123"
   };
   ```
7. **Copy these values** - you'll need them in the next step

### Option B: From GoogleService-Info.plist

1. **Open:** `Project Planner/GoogleService-Info.plist`
2. **Find these values:**
   - `API_KEY` → `apiKey`
   - `PROJECT_ID` → `projectId`, `authDomain`, `storageBucket`
   - `GCM_SENDER_ID` → `messagingSenderId`
   - `CLIENT_ID` (look for the one with `web` in it) → `appId`

---

## Step 6: Update Firebase Config in HTML Files (10 minutes)

You need to update **3 files** with your Firebase configuration:

### File 1: `setup-password.html`

1. **Open:** `website/setup-password.html` in a text editor
2. **Find line ~246** (search for `firebaseConfig`)
3. **Replace:**
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
   
   **With your actual values:**
   ```javascript
   const firebaseConfig = {
       apiKey: "AIzaSyC...",  // Your actual API key
       authDomain: "your-project-id.firebaseapp.com",
       projectId: "your-project-id",
       storageBucket: "your-project-id.appspot.com",
       messagingSenderId: "123456789",
       appId: "1:123456789:web:abc123"
   };
   ```
4. **Save the file**

### File 2: `reset-password.html`

1. **Open:** `website/reset-password.html`
2. **Find line ~143** (search for `firebaseConfig`)
3. **Replace with the same values as above**
4. **Save the file**

### File 3: `reset-password-complete.html`

1. **Open:** `website/reset-password-complete.html`
2. **Find line ~218** (search for `firebaseConfig`)
3. **Replace with the same values as above**
4. **Save the file**

---

## Step 7: Update Firestore Security Rules (5 minutes)

Your website needs to read invitations from Firestore.

1. **Go to:** Firebase Console → **Firestore Database** → **Rules** tab

2. **Update your rules to include:**
   ```javascript
   rules_version = '2';
   service cloud.firestore {
     match /databases/{database}/documents {
       // Allow public read for invitation verification (before user is authenticated)
       match /invitations/{invitationId} {
         allow read: if true; // Allow anyone to read for verification
         allow write: if request.auth != null; // Only authenticated users can write
       }
       
       // Allow users to read/write their own user document
       match /users/{userId} {
         allow read: if request.auth != null;
         allow write: if request.auth != null && request.auth.uid == userId;
       }
       
       // Your existing organization rules...
       match /organizations/{organizationId} {
         allow read: if request.auth != null;
         allow write: if request.auth != null;
         
         match /{collection}/{document=**} {
           allow read, write: if request.auth != null;
         }
       }
     }
   }
   ```

3. **Click:** "Publish" button

---

## Step 8: Deploy to Firebase Hosting (2 minutes)

1. **In Terminal** (still in the `website` folder), run:
   ```bash
   firebase deploy --only hosting
   ```

2. **You'll see output like:**
   ```
   ✔ Deploy complete!
   
   Project Console: https://console.firebase.google.com/project/your-project/overview
   Hosting URL: https://your-project-id.web.app
   ```

3. **Your website is now live!** 🎉
   - Main URL: `https://your-project-id.web.app`
   - Setup password: `https://your-project-id.web.app/setup-password.html`
   - Reset password: `https://your-project-id.web.app/reset-password.html`

---

## Step 9: Test Your Website (5 minutes)

### Test Password Setup:

1. **In your iOS app**, invite a test user (or use an existing invitation)
2. **Copy the invitation code** from the email
3. **Visit:** `https://your-project-id.web.app/setup-password.html?token=INVITATION_CODE`
4. **Verify the code works** - you should see the password form
5. **Set a password** - should work!

### Test Password Reset:

1. **Visit:** `https://your-project-id.web.app/reset-password.html`
2. **Enter your email**
3. **Check your email** for reset link
4. **Click the link** - should take you to reset page
5. **Reset password** - should work!

---

## Step 10: Set Up Custom Domain (Optional - 15 minutes)

If you want to use `projectplanner.us` instead of `your-project-id.web.app`:

1. **In Firebase Console:**
   - Go to **Hosting** → **Add custom domain**

2. **Enter your domain:**
   - Type: `projectplanner.us`
   - Click **Continue**

3. **Add DNS records:**
   - Firebase will show you DNS records to add
   - You'll need to add these to your domain registrar (where you bought `projectplanner.us`)
   
   **Example DNS records:**
   ```
   Type: A
   Name: @
   Value: 151.101.1.195
   
   Type: A
   Name: @
   Value: 151.101.65.195
   
   Type: TXT
   Name: @
   Value: firebase=your-project-id
   ```

4. **Add DNS records in your registrar:**
   - Log in to where you bought the domain (e.g., Namecheap, GoDaddy)
   - Go to DNS settings
   - Add the A records and TXT record shown by Firebase

5. **Wait for verification:**
   - Firebase will automatically verify your domain (can take a few minutes to 24 hours)
   - You'll get an email when it's verified

6. **SSL Certificate:**
   - Firebase automatically provisions SSL certificate
   - This happens automatically after DNS verification

7. **Your custom domain is live:**
   - `https://projectplanner.us`
   - `https://projectplanner.us/setup-password.html`

---

## Troubleshooting

### ❌ "Command not found: firebase"

**Solution:** Firebase CLI not installed. Run:
```bash
npm install -g firebase-tools
```

### ❌ "Permission denied" when installing

**Solution:** Use sudo:
```bash
sudo npm install -g firebase-tools
```

### ❌ "Error: No Firebase project 'project-planner' found"

**Solution:** Make sure you selected the correct project during `firebase init hosting`. You can check in `.firebaserc` file.

### ❌ "Invalid invitation code" on website

**Solution:**
1. Check Firestore rules allow reading invitations (see Step 7)
2. Verify invitation code is correct
3. Check browser console for specific errors

### ❌ "Failed to set up password"

**Solution:**
1. Check Firebase Authentication is enabled in Firebase Console
2. Verify Email/Password provider is enabled
3. Check Firebase config values are correct in HTML files
4. Open browser console (F12) and check for error messages

### ❌ "Permission denied" when updating user document

**Solution:** Update Firestore rules (Step 7) to allow writing to user documents.

---

## Updating Your Website

When you make changes to your website files:

1. **Edit the files** in the `website` folder
2. **Deploy again:**
   ```bash
   cd website
   firebase deploy --only hosting
   ```

Your changes will be live in a few seconds!

---

## Quick Commands Reference

```bash
# Login to Firebase
firebase login

# Initialize hosting (first time only)
firebase init hosting

# Deploy website
firebase deploy --only hosting

# View deployment history
firebase hosting:channel:list

# View current project
firebase projects:list
```

---

## Next Steps

✅ Your website is live! 

**Don't forget to:**
1. ✅ Test password setup with a real invitation
2. ✅ Test password reset functionality
3. ✅ Update email links in your iOS app to use the new website URL
4. ✅ Set up custom domain (optional but recommended)

---

## Support

- **Firebase Docs:** https://firebase.google.com/docs/hosting
- **Firebase Console:** https://console.firebase.google.com/
- **Your Hosting URL:** Check after deployment in Firebase Console → Hosting

Need help? Check the browser console (F12) for error messages when testing your website!







