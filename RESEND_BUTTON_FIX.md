# ✅ Resend Sign-Up Email Button Fix

## Issue Fixed:

The "Resend Verification Email" button in `EditUserView` now automatically shows as "Send Sign-Up Email with Verification Code" for pending managers and operatives.

## How It Works:

1. **Button Visibility:**
   - Shows when: `!user.passwordSet && canEdit` (password not set AND admin can edit)
   - This applies to ALL pending users, including managers and operatives

2. **Button Behavior:**
   - For **pending managers/operatives**: 
     - Button text: "Send Sign-Up Email with Verification Code"
     - Button color: Blue
     - Icon: `envelope.badge.fill`
     - Sends sign-up email with verification code when clicked
   
   - For **other pending users**:
     - Button text: "Resend Verification Email"
     - Button color: Orange
     - Icon: `envelope.fill`
     - Sends regular verification email when clicked

3. **Detection Logic:**
   ```swift
   let isPendingManagerOrOperative = !user.passwordSet && 
                                    (user.permissions.manager || user.permissions.operativeMode) && 
                                    !user.permissions.adminAccess && 
                                    !user.isSuperAdmin
   ```

## Testing:

1. Navigate to "Manage Users"
2. Click on a pending manager (shows "Pending" badge)
3. Scroll to "Verification" section
4. Should see blue button: "Send Sign-Up Email with Verification Code"
5. Click button → Should send sign-up email with verification code

## If Button Still Doesn't Show:

Check:
- ✅ User has `passwordSet = false` (pending)
- ✅ Current user is admin/super admin (`canEdit = true`)
- ✅ User is a manager or operative (not admin)
- ✅ User is not super admin

The button should appear in the "Verification" section below the "Permissions" section.

