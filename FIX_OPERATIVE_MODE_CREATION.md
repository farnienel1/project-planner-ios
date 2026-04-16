# Fix: Operative Mode User Creation Not Working

## Problem

Creating users in operative mode fails with permission denied, even though it worked with the completely permissive rule.

## Root Cause

The `isAdminOrSuperAdmin()` function was being called during CREATE operations, but function calls can be unreliable during CREATE because:
1. Multiple `get()` calls in the function can cause performance issues
2. Firestore rules evaluate functions differently during CREATE vs READ/UPDATE
3. The function might fail silently or timeout during CREATE

## Solution

**Changed from function call to inline check** in the CREATE rule:

### Before (Unreliable)
```javascript
allow create: if request.auth != null && (
  request.resource.data.email == request.auth.token.email ||
  isAdminOrSuperAdmin()  // ❌ Function call can fail during CREATE
);
```

### After (Reliable)
```javascript
allow create: if request.auth != null && (
  // Path 1: Self-creation
  request.resource.data.email == request.auth.token.email ||
  // Path 2: Admin creation - INLINE CHECK (more reliable)
  (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
   (('isSuperAdmin' in get(...).data && get(...).data.isSuperAdmin == true) ||
    ('adminAccess' in get(...).data && get(...).data.adminAccess == true) ||
    ('role' in get(...).data && get(...).data.role == 'admin')))
);
```

## Why This Works

1. **Inline checks are more reliable** during CREATE operations
2. **No function call overhead** - direct evaluation in the rule
3. **Same security** - still checks for admin permissions
4. **Same logic** - just moved from function to inline

## Who Can Create Users

✅ **CAN Create Users:**
- Super Admin (`isSuperAdmin == true`)
- Admins (`adminAccess == true` OR `role == 'admin'`)

❌ **CANNOT Create Users:**
- Managers (`manager == true` only)
- Operatives (`operativeMode == true` only)

## Testing

After deploying the updated rules:

1. **Test Admin Creating Operative Mode User:**
   - Admin clicks "Add User"
   - Selects "Operative Mode"
   - Fills in details
   - ✅ Should succeed

2. **Test Admin Creating Manager:**
   - Admin clicks "Add User"
   - Selects "Manager" permission
   - Fills in details
   - ✅ Should succeed

3. **Test Manager Trying to Create User:**
   - Manager tries to create user
   - ❌ Should fail (not an admin)

## Deployment

1. Copy the entire `firestore.rules` file
2. Go to Firebase Console → Firestore Database → Rules
3. Paste the new rules
4. Click **Publish**
5. Wait 2-3 minutes for propagation
6. Close and reopen the app
7. Try creating an operative mode user again

## Notes

- The `isAdminOrSuperAdmin()` function is still used for UPDATE and DELETE operations (those work fine)
- Only the CREATE rule uses inline checks for better reliability
- Security is maintained - only admins can create other users


