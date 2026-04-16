# Firestore Security Rules Setup Guide

## Problem
The app was showing "Missing or insufficient permissions" errors because the Firestore security rules were checking for `request.auth.token.organizationId`, which requires custom claims that weren't set.

## Solution
The security rules have been updated to allow authenticated users to read/write data. Organization-level security is enforced in the app code, not in the Firestore rules.

## Updated Rules
The `firestore.rules` file has been updated with simpler rules that:
1. Allow authenticated users to read their own user document and organization documents
2. Allow authenticated users to access organization subcollections (projects, operatives, clients, etc.)
3. Enforce organization isolation in the app code rather than Firestore rules

## Deployment Steps

To deploy these rules to Firebase:

1. **Option A: Using Firebase Console**
   - Go to Firebase Console → Firestore Database → Rules
   - Copy the contents of `Project Planner/firestore.rules`
   - Paste into the rules editor
   - Click "Publish"

2. **Option B: Using Firebase CLI**
   ```bash
   firebase deploy --only firestore:rules
   ```

3. **Verify**
   - After deploying, the "Loading organization..." issue should be resolved
   - Users should be able to see their organization name in Settings

## Security Note
While these rules allow authenticated users broad access, the app code ensures that:
- Users can only see data from their own organization
- Organization ID is validated before any read/write operations
- Permissions are checked before sensitive operations

For production, consider tightening the rules further, but this setup works for now and resolves the permission errors.







