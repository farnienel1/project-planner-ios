# 🔒 Permission Denied Fix Guide

## This is NOT an Email Issue

The "Permission denied" error occurs **before** any email is sent. It happens when trying to create the user document in Firestore, not when sending emails.

## Quick Diagnosis

When you try to create a user, the app will now show you:
- Your current permissions (isSuperAdmin, adminAccess, role)
- Specific instructions on how to fix the issue
- Your user document ID for reference

## Most Common Causes & Fixes

### 1. User Document Missing Permissions

**Problem**: Your user document in Firebase doesn't have admin permissions set.

**Fix**:
1. Go to [Firebase Console](https://console.firebase.google.com)
2. Navigate to: Firestore Database → `users` collection
3. Find your user document (search by your email or use the user ID from the error message)
4. Verify these fields exist and are the **correct type**:
   - `isSuperAdmin`: Must be **boolean** `true` (not string `"true"`)
   - `adminAccess`: Must be **boolean** `true` (not string `"true"`)
   - `role`: Must be **string** `"admin"` (not `"basic"` or missing)

**Important**: If the fields show as strings (`"true"`), delete them and recreate as booleans (`true`).

### 2. Firestore Rules Not Deployed

**Problem**: The Firestore security rules haven't been published to Firebase.

**Fix**:
1. Go to Firebase Console → Firestore Database → Rules tab
2. Copy the rules from `Project Planner/firestore.rules` file
3. Paste them into the Rules editor
4. Click **"Publish"** button
5. Wait for confirmation that rules are deployed

### 3. User Document Doesn't Exist

**Problem**: Your user document hasn't been created in Firestore yet.

**Fix**:
1. Sign out of the app
2. Sign back in
3. The app should create your user document automatically
4. If it doesn't, manually create it in Firebase Console with the required fields

## Verification Steps

After fixing, verify:

1. **Check your user document**:
   ```json
   {
     "isSuperAdmin": true,        // boolean, not string
     "adminAccess": true,         // boolean, not string
     "role": "admin",             // string
     "organizationId": "...",     // your org ID
     "email": "your@email.com"
   }
   ```

2. **Check Firestore rules are deployed**:
   - Go to Firebase Console → Firestore Database → Rules
   - Verify the rules are published (not in draft)
   - The `isAdminOrSuperAdmin()` function should be present

3. **Try creating a user again**:
   - The improved error message will show you exactly what's wrong
   - Check the Xcode console for detailed debug logs (look for `🔥🔥🔥 DEBUG:`)

## Debug Logs

When you try to create a user, check the Xcode console for logs starting with `🔥🔥🔥 DEBUG:`. These will show:
- Your current user's permissions
- Whether the permission check passes
- The exact error from Firestore
- Your user document ID

## Still Having Issues?

If you've verified all the above and still get permission denied:

1. **Check the debug logs** in Xcode console - they'll show exactly what Firestore sees
2. **Verify your user ID** matches between:
   - Firebase Auth (Authentication → Users)
   - Firestore (users collection document ID)
3. **Try signing out and back in** to refresh your authentication token
4. **Check if you're the organization creator** - if so, you should automatically have super admin permissions

## Email Configuration (Separate Issue)

Email sending is configured separately and uses:
- **From**: `info@projectplanner.us` (via SendGrid)
- **Service**: SendGrid API

If emails aren't being sent, that's a separate issue from the permission error. The permission error happens **before** any email is attempted.


