# Firestore Rules Fix for Super Admin User Creation

## Issue
Super admin (farnienelyt@gmail.com) was getting "Permission denied" error when trying to create new users.

## Root Cause
The Firestore security rules for the `users` collection only allowed:
1. Users creating themselves (same UID or email)
2. Did NOT allow admins/super admins to create other users

## Fix Applied

### 1. Added Helper Function
Added `isAdminOrSuperAdmin()` function that checks if the current user:
- Has `isSuperAdmin == true`, OR
- Has `adminAccess == true`, OR
- Has `role == 'admin'`

### 2. Updated Users Collection Rules

**Before:**
```javascript
allow create: if request.auth != null && (
  request.auth.uid == userId || 
  request.resource.data.email == request.auth.token.email
)
```

**After:**
```javascript
allow create: if request.auth != null && (
  // User creating themselves
  (request.auth.uid == userId || 
   request.resource.data.email == request.auth.token.email) ||
  // Admin/Super Admin creating other users
  isAdminOrSuperAdmin()
)
```

### 3. Updated User Update Rules
Also allowed admins/super admins to update other users (for user management).

### 4. Added User Delete Rule
Admins/super admins can now delete users (for user management).

## Deployment Steps

**IMPORTANT: You must deploy these updated rules to Firebase for the fix to work!**

### Option 1: Firebase Console
1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project
3. Go to **Firestore Database** → **Rules**
4. Copy the contents of `Project Planner/firestore.rules`
5. Paste into the rules editor
6. Click **Publish**

### Option 2: Firebase CLI
```bash
firebase deploy --only firestore:rules
```

## Verification

After deploying the rules, verify:
1. Super admin can create new users ✅
2. Admins (with adminAccess) can create new users ✅
3. Regular users cannot create other users ✅
4. Users can still create their own accounts ✅

## Important Notes

- The super admin's user document in Firebase must have:
  - `isSuperAdmin: true`, OR
  - `adminAccess: true`, OR
  - `role: "admin"`
  
- If the super admin document doesn't have these fields, the rules won't work. Check the user document in Firebase Console.

## Debugging

If you still get permission errors after deploying rules:

1. **Check User Document in Firebase:**
   - Go to Firestore Database → `users` collection
   - Find the document for farnienelyt@gmail.com
   - Verify it has `isSuperAdmin: true` or `adminAccess: true`

2. **Check Console Logs:**
   - Look for "🔥🔥🔥 DEBUG: Current user (inviter) data:" messages
   - Verify `isSuperAdmin` and `adminAccess` values

3. **Verify Rules Deployed:**
   - Go to Firebase Console → Firestore → Rules
   - Verify the `isAdminOrSuperAdmin()` function exists
   - Verify the `allow create` rule includes `isAdminOrSuperAdmin()`



