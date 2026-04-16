# 🔧 Fix Recreated User Document

## The Problem

Your user documents show creation dates of **December 1st and 4th**, but your account has been around much longer. This means:

1. **Your user document was recreated** (possibly deleted and recreated)
2. **The recreated document likely lost your admin permissions**
3. **The Firestore rules are checking the recreated document, which doesn't have admin permissions**

## Quick Fix Options

### Option 1: Use the In-App Fix Tool (Easiest)

1. **Open the app**
2. Go to **Settings**
3. Scroll down to **Troubleshooting**
4. Tap **"Fix Permission Errors"**
5. Tap **"Check Permissions"** to see what's wrong
6. If it shows no admin permissions, tap **"Fix Permissions"**
7. This will update your user document with:
   - `isSuperAdmin: true`
   - `adminAccess: true`
   - `role: "admin"`

### Option 2: Fix Manually in Firebase Console

1. **Go to Firebase Console:**
   - https://console.firebase.google.com
   - Select **Project Planner** (project-planner-f986c)
   - Click **Firestore Database** → **Data** tab

2. **Find your user document:**
   - Click on **`users`** collection
   - Find the document with your **Firebase Auth UID** (this is the one the rules check)
   - **OR** find documents with email `farnienelyt@gmail.com`

3. **Check which document is correct:**
   - Look at the document ID - it should match your Firebase Auth UID
   - Check the `createdAt` field - ignore this, focus on permissions
   - Check if it has `isSuperAdmin`, `adminAccess`, or `role` set correctly

4. **Update the correct document:**
   - Click on the document that has your Firebase Auth UID as the document ID
   - Add/update these fields:
     - `isSuperAdmin`: Click "Add field" → Type: **Boolean** → Value: **true**
     - `adminAccess`: Click "Add field" → Type: **Boolean** → Value: **true**
     - `role`: Click "Add field" → Type: **String** → Value: **"admin"**
   - **IMPORTANT:** Make sure the types are correct (Boolean for isSuperAdmin/adminAccess, String for role)

5. **Delete duplicate documents:**
   - If there are multiple documents with your email, delete the ones that don't have your Firebase Auth UID as the document ID
   - Keep only the one with your Firebase Auth UID

## How to Find Your Firebase Auth UID

1. **In the app:**
   - Go to **Settings** → **Fix Permission Errors**
   - It will show your User ID at the top

2. **Or check Xcode console:**
   - Look for debug messages like: `🔥🔥🔥 DEBUG: Current user ID: [your-uid-here]`

3. **Or in Firebase Console:**
   - Go to **Authentication** → **Users** tab
   - Find your email: `farnienelyt@gmail.com`
   - The **UID** column shows your Firebase Auth UID

## Why This Happened

User documents can be recreated if:
- The document was accidentally deleted
- The app tried to create a new user document
- There was an error during user creation that created a duplicate

The **Firestore rules check your user document using your Firebase Auth UID**, so:
- The document ID must match your Firebase Auth UID
- That document must have the correct permissions

## After Fixing

1. **Close the app completely**
2. **Reopen the app**
3. **Try creating a user again**

The permission errors should be resolved once your user document has the correct permissions!


