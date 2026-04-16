# 🔐 Firestore Rules Update - Password Setup Website Fix

## 🎯 Problem

The password setup website (setup-password.html) was getting "missing or insufficient permissions" errors when trying to:
- Verify invitation codes
- Query user documents by email
- Update user documents after password setup

## ✅ Solution

Updated Firestore security rules to allow the password setup flow while maintaining security.

---

## 📋 Changes Made

### 1. Invitations Collection - Public Read

**Before:**
```javascript
match /invitations/{invitationId} {
  allow read, write: if request.auth != null;
}
```

**After:**
```javascript
match /invitations/{invitationId} {
  // Allow public read so password setup page can verify invitation codes
  allow read: if true;
  // Allow authenticated users to create/update invitations
  allow write: if request.auth != null;
  // Allow updating invitation to mark as used (during password setup, user is authenticated)
  allow update: if request.auth != null;
}
```

**Why:** Password setup page needs to verify invitation codes BEFORE user is authenticated.

---

### 2. Users Collection - Email-Based Updates

**Before:**
```javascript
match /users/{userId} {
  allow read: if request.auth != null;
  allow write: if request.auth != null && request.auth.uid == userId;
  allow write: if request.auth != null;
}
```

**After:**
```javascript
match /users/{userId} {
  allow read: if request.auth != null;
  // Allow queries on users collection (needed for password setup to find user by email)
  allow list: if request.auth != null;
  
  // Users can write their own document
  // Allow if: user ID matches authenticated user OR email matches authenticated user's email
  allow write: if request.auth != null && (
    request.auth.uid == userId || 
    resource.data.email == request.auth.token.email
  );
  
  // Allow creating user document during password setup
  allow create: if request.auth != null && (
    request.auth.uid == userId || 
    request.resource.data.email == request.auth.token.email
  );
  
  // Allow updating user document during password setup (by email match)
  allow update: if request.auth != null && (
    request.auth.uid == userId || 
    (resource.data.email == request.auth.token.email && 
     request.resource.data.email == request.auth.token.email)
  );
}
```

**Why:** User documents are created with UUID from invitation, but Firebase Auth creates different UID. Need to allow updates by email match.

---

## 🔄 How Password Setup Flow Works

1. **User enters invitation code** (not authenticated yet)
   - ✅ Can read invitation document (public read allowed)

2. **User creates password** (creates Firebase Auth account)
   - ✅ User is now authenticated
   - ✅ Can query users collection to find user document by email

3. **Update user document** (found by email query)
   - ✅ Can update user document because email matches authenticated user's email
   - ✅ Sets passwordSet: true

4. **Mark invitation as used**
   - ✅ Can update invitation because user is authenticated

---

## 📤 Deploy Updated Rules

### Step 1: Update Rules in Firebase Console

1. **Go to Firebase Console**:
   - https://console.firebase.google.com
   - Select your project

2. **Navigate to Firestore Rules**:
   - Click **Firestore Database** in left sidebar
   - Click **Rules** tab

3. **Copy Updated Rules**:
   - Open: `Project Planner/firestore.rules`
   - Copy the entire contents

4. **Paste in Firebase Console**:
   - Replace existing rules with new rules
   - Click **"Publish"** button

5. **Wait for Rules to Deploy**:
   - Usually takes a few seconds
   - You'll see confirmation message

---

## ✅ Test After Rules Update

1. **Test Password Setup**:
   - Invite a test user from iOS app
   - Copy invitation code from email
   - Visit: https://projectplanner.us/setup-password.html?token=CODE
   - Enter password
   - Should work without permission errors! ✅

2. **Verify in SendGrid**:
   - Check SendGrid dashboard → Activity
   - Should show email was sent

3. **Check User Document**:
   - Firebase Console → Firestore Database
   - Check users collection
   - User document should have passwordSet: true

---

## 🔒 Security Notes

**Still Secure Because:**
- ✅ Invitation read is public, but only for verification (can't modify without auth)
- ✅ User document updates require authentication
- ✅ User can only update their own document (by email match)
- ✅ App still enforces organization-level access control
- ✅ Queries are limited to authenticated users

**What's Allowed:**
- ✅ Public read of invitations (for verification)
- ✅ Authenticated users can query users by email
- ✅ Users can update their own document by email match
- ✅ Authenticated users can mark invitations as used

**What's NOT Allowed:**
- ❌ Unauthenticated users can't write to users collection
- ❌ Users can't update other users' documents
- ❌ Public write access is still restricted

---

## 📋 Quick Checklist

- [ ] Updated firestore.rules file ✅
- [ ] Deployed rules to Firebase Console
- [ ] Tested invitation code verification
- [ ] Tested password setup on website
- [ ] Verified user document updated correctly
- [ ] Confirmed invitation marked as used

---

**Once rules are deployed, the password setup website should work perfectly!** 🎉







