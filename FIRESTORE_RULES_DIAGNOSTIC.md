# Firestore Rules Diagnostic Guide

## The Problem
You're getting "Permission denied" even though the app confirms you have admin permissions. This means **the Firestore rules are not recognizing your admin status**.

## Most Common Causes

### 1. Rules Not Deployed (90% of cases)
**Solution:**
1. Go to Firebase Console: https://console.firebase.google.com
2. Select your project
3. Go to **Firestore Database** → **Rules** tab
4. Copy the rules from `VERIFIED_FIRESTORE_RULES.md`
5. Paste into the editor
6. Click **"Publish"**
7. Wait 2-3 minutes for propagation

### 2. Wrong Field Types in User Document (80% of remaining cases)
**The Problem:** Firestore rules check for `isSuperAdmin == true` (boolean), but if your document has `isSuperAdmin: "true"` (string), it will fail.

**How to Check:**
1. Go to Firebase Console → Firestore Database
2. Open the `users` collection
3. Find your user document (by your email or UID)
4. Check these fields:

**CORRECT (Boolean):**
- `isSuperAdmin`: Should show as `true` or `false` (boolean type)
- `adminAccess`: Should show as `true` or `false` (boolean type)
- `role`: Should show as `"admin"` (string type)

**WRONG (String):**
- `isSuperAdmin`: Shows as `"true"` or `"false"` (string type) ❌
- `adminAccess`: Shows as `"true"` or `"false"` (string type) ❌

**How to Fix:**
1. Click on the field value
2. Change the type from "string" to "boolean"
3. Set the value to `true` (not `"true"`)
4. Save

### 3. User Document Doesn't Exist
**Check:**
1. Go to Firebase Console → Firestore Database → `users` collection
2. Look for a document with your Firebase Auth UID (not email)
3. If it doesn't exist, the rules will fail

**How to Find Your UID:**
- In the app, check the debug logs - it will show "Current user ID: [UID]"
- Or go to Firebase Console → Authentication → Users → Find your email → Copy the UID

### 4. Rules Caching (Rare)
**Solution:**
1. Log out of the app completely
2. Close the app
3. Wait 2-3 minutes
4. Log back in
5. Try creating a user again

## Step-by-Step Verification

### Step 1: Verify Rules Are Deployed
1. Go to Firebase Console → Firestore Database → Rules
2. Look at the `isAdminOrSuperAdmin()` function
3. It should match exactly what's in `VERIFIED_FIRESTORE_RULES.md`
4. Check the timestamp - it should show when rules were last published

### Step 2: Verify Your User Document
1. Go to Firebase Console → Firestore Database → `users` collection
2. Find your user document (by UID from Authentication)
3. Check these fields exist and have correct types:
   ```
   isSuperAdmin: true (boolean)
   adminAccess: true (boolean)
   role: "admin" (string)
   ```

### Step 3: Test the Rules
The rules check this function:
```javascript
function isAdminOrSuperAdmin() {
  return request.auth != null && 
         exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
         (('isSuperAdmin' in get(...).data && 
           get(...).data.isSuperAdmin == true) ||
          ('adminAccess' in get(...).data && 
           get(...).data.adminAccess == true) ||
          ('role' in get(...).data && 
           get(...).data.role == 'admin'));
}
```

This function will return `true` if:
- Your user document exists
- AND (`isSuperAdmin` is `true` OR `adminAccess` is `true` OR `role` is `"admin"`)

## Quick Fix Script

If you want to manually fix your user document in Firebase Console:

1. Go to Firestore Database → `users` → [Your UID]
2. Edit these fields:
   - `isSuperAdmin`: Change type to **boolean**, set value to `true`
   - `adminAccess`: Change type to **boolean**, set value to `true`
   - `role`: Change type to **string**, set value to `"admin"`
3. Save

## Still Not Working?

If you've verified:
- ✅ Rules are deployed
- ✅ Field types are correct (boolean, not string)
- ✅ User document exists
- ✅ Waited 3+ minutes after deploying

Then check:
1. **Are you logged in with the correct Firebase account?** The UID in Authentication must match the UID in the users collection
2. **Is the organizationId correct?** The new user's organizationId must match your organizationId
3. **Check the debug logs** - they will show exactly what the rules are checking

## Debug Output to Look For

When you try to create a user, look for these debug messages:
```
🔥🔥🔥 DEBUG: Current user (inviter) Firebase document data:
🔥🔥🔥 DEBUG: - isSuperAdmin: [value] (type: [type])
🔥🔥🔥 DEBUG: - adminAccess: [value] (type: [type])
🔥🔥🔥 DEBUG: - role: [value] (type: [type])
```

If the types show as `String` instead of `Bool`, that's your problem!


