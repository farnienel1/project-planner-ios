# Email Test vs Firestore Permission Error

## Important: Two Separate Issues

### Current Error (Firestore Permission - Code 7)
**Error:** `Missing or insufficient permissions` (Code 7)
**Location:** When trying to **create a user document** in Firestore
**Cause:** Firestore security rules are blocking the operation
**NOT related to email sending**

### Email Sending (Separate Issue)
**What it does:** Sends password setup emails via SendGrid
**When it runs:** After successfully creating the user document
**If email fails:** User is still created, just no email sent

## How to Test Email Separately

### Option 1: Use the Test Function in Settings
1. Open the app
2. Go to **Settings** (bottom menu → More → Settings)
3. Scroll to **"Email Testing"** section (only visible to admins)
4. Tap **"Test Email Sending"**
5. Enter your email address
6. Tap **"Send Test Email"**
7. Check your inbox and SendGrid dashboard

### Option 2: Check SendGrid Dashboard
1. Go to: https://app.sendgrid.com
2. Navigate to **Activity** → **Email Activity**
3. Look for recent emails sent
4. Check status (Delivered, Bounced, etc.)

## Understanding the Error Flow

When creating a new user:

1. **Step 1: Create User Document** ← **THIS IS FAILING** (Firestore permission error)
   - App tries to save user to Firestore
   - Firestore rules check: `isAdminOrSuperAdmin()`
   - Rules return `false` → Permission denied
   - **Error happens here, before email is even attempted**

2. **Step 2: Send Email** (Only runs if Step 1 succeeds)
   - If user document created successfully
   - Then sends password setup email via SendGrid
   - If email fails, user is still created

## Why Email Test is Useful

Even though the current error is Firestore permissions, testing email separately helps:
- ✅ Verify SendGrid is configured correctly
- ✅ Confirm `info@projectplanner.us` is verified
- ✅ Test email delivery before fixing Firestore rules
- ✅ Rule out email issues as a contributing factor

## Fixing the Firestore Permission Error

The email test won't fix the permission error. To fix that:

1. **Deploy Firestore Rules:**
   - Copy rules from `VERIFIED_FIRESTORE_RULES.md`
   - Paste into Firebase Console → Firestore Database → Rules
   - Click "Publish"
   - Wait 2-3 minutes

2. **Verify User Document Field Types:**
   - Go to Firebase Console → Firestore Database → `users` collection
   - Find your user document
   - Check `isSuperAdmin` and `adminAccess` are **boolean** (not string)
   - Fix if needed

3. **Check Debug Output:**
   - Look for permission check logs when creating user
   - Verify what Firestore sees for your permissions

## Summary

- **Current Error:** Firestore permission (Code 7) - rules blocking user creation
- **Email Test:** Separate functionality - can test independently in Settings
- **Email is NOT the issue** - the error happens before email is attempted
- **Fix:** Deploy Firestore rules and verify field types

Use the email test to verify SendGrid works, but the main issue is Firestore rules that need to be deployed.


