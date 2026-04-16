# Debugging User Creation Permission Denied

## Steps to Fix

### Step 1: Check Console Logs
When you try to create a user, check the Xcode console for these debug messages:
- `🔥🔥🔥 DEBUG: Current user (inviter) data:`
- Look for `isSuperAdmin`, `adminAccess`, and `role` values

### Step 2: Verify User Document in Firebase
1. Go to Firebase Console → Firestore Database
2. Navigate to `users` collection
3. Find the document for `farnienelyt@gmail.com` (document ID is the Firebase Auth UID)
4. Check if these fields exist and are set correctly:
   - `isSuperAdmin` = `true` (boolean)
   - `adminAccess` = `true` (boolean)  
   - `role` = `"admin"` (string)

### Step 3: Fix User Document if Needed
If the fields are missing or incorrect:

**Option A: Manual Fix in Firebase Console**
1. Edit the user document
2. Add/update:
   ```json
   {
     "isSuperAdmin": true,
     "adminAccess": true,
     "role": "admin"
   }
   ```
3. Save

**Option B: Auto-Fix via App**
1. Sign out and sign back in
2. The app should auto-fix the user document (see UserStore.swift)
3. Try creating a user again

### Step 4: Verify Rules Are Deployed
1. Go to Firebase Console → Firestore Database → Rules
2. Verify the rules include the `isAdminOrSuperAdmin()` function
3. Verify the `allow create` rule includes `isAdminOrSuperAdmin()`

### Step 5: Test Again
After fixing the user document:
1. Sign out and sign back in
2. Try creating a new user
3. Check console logs for any errors

## Temporary Workaround
The rules now include a temporary workaround that allows any user in the same organization to create users. This should work even if the user document isn't properly set up, but it's less secure. Once the user document is fixed, the proper admin checks will work.

## Common Issues

### Issue: Fields don't exist
**Solution:** Add the fields manually in Firebase Console

### Issue: Fields are false/null
**Solution:** Set them to `true` (for isSuperAdmin/adminAccess) or `"admin"` (for role)

### Issue: Rules not deployed
**Solution:** Deploy the rules again in Firebase Console

### Issue: User document doesn't exist
**Solution:** Sign out and sign back in - the app should create it



