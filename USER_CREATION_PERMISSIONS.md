# User Creation Permissions - Who Can Create Users?

## Summary

✅ **CAN Create Users:**
- Super Admin (`isSuperAdmin == true`)
- Admins (`adminAccess == true` OR `role == 'admin'`)

❌ **CANNOT Create Users:**
- Managers (`manager == true`)
- Operatives (`operativeMode == true`)
- Basic Users (no special permissions)

## How It Works

### The Two-Path Rule

```javascript
allow create: if request.auth != null && (
  // Path 1: Self-creation (email matches auth token)
  request.resource.data.email == request.auth.token.email ||
  // Path 2: Admin creation (admin/super admin creating other users)
  isAdminOrSuperAdmin()
);
```

### Path 1: Self-Creation (Everyone)
- **Who**: Anyone (including managers, operatives, basic users)
- **When**: User creates their own account via website signup
- **How**: Email in the new user document matches the authenticated user's email
- **Example**: User receives invitation email → clicks link → sets password → creates their own account

### Path 2: Admin Creation (Admins Only)
- **Who**: Super Admin or Admins only
- **When**: Admin uses "Add User" in the app to create another user
- **How**: `isAdminOrSuperAdmin()` function checks for admin permissions
- **Example**: Admin clicks "Add User" → fills in details → creates user document

## Permission Checks

The `isAdminOrSuperAdmin()` function checks for:

1. **Super Admin**: `isSuperAdmin == true`
   - Organization creator
   - Highest level of access
   - ✅ Can create users

2. **Admin Access**: `adminAccess == true`
   - User with admin permissions
   - Can manage users and organization
   - ✅ Can create users

3. **Admin Role**: `role == 'admin'`
   - User with admin role
   - Alternative way to grant admin permissions
   - ✅ Can create users

**NOT Checked** (so these users CANNOT create other users):
- ❌ `manager == true` - Managers cannot create users
- ❌ `operativeMode == true` - Operatives cannot create users
- ❌ `role == 'manager'` - Manager role cannot create users
- ❌ `role == 'operative'` - Operative role cannot create users

## Examples

### ✅ Super Admin Creating User
```
User: Super Admin (isSuperAdmin: true)
Action: Clicks "Add User" in app
Result: ✅ ALLOWED - isAdminOrSuperAdmin() returns true
```

### ✅ Admin Creating User
```
User: Admin (adminAccess: true)
Action: Clicks "Add User" in app
Result: ✅ ALLOWED - isAdminOrSuperAdmin() returns true
```

### ❌ Manager Trying to Create User
```
User: Manager (manager: true, adminAccess: false)
Action: Tries to create user via app
Result: ❌ BLOCKED - isAdminOrSuperAdmin() returns false
```

### ❌ Operative Trying to Create User
```
User: Operative (operativeMode: true, adminAccess: false)
Action: Tries to create user via app
Result: ❌ BLOCKED - isAdminOrSuperAdmin() returns false
```

### ✅ Manager Creating Their Own Account
```
User: Manager (manager: true)
Action: Receives invitation email → sets password on website
Result: ✅ ALLOWED - Email matches auth token (self-creation)
```

### ✅ Operative Creating Their Own Account
```
User: Operative (operativeMode: true)
Action: Receives invitation email → sets password on website
Result: ✅ ALLOWED - Email matches auth token (self-creation)
```

## Security

This approach ensures:
1. **Only admins can create other users** - Prevents privilege escalation
2. **Everyone can create their own account** - Allows signup flow to work
3. **Managers and operatives are restricted** - They can only create their own accounts, not other users

## Testing

To verify permissions are correct:

1. **Test Super Admin**: Create user as super admin → Should succeed
2. **Test Admin**: Create user as admin → Should succeed
3. **Test Manager**: Try to create user as manager → Should fail
4. **Test Operative**: Try to create user as operative → Should fail
5. **Test Self-Creation**: Manager/operative creates own account via website → Should succeed


