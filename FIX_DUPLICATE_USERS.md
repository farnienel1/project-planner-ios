# 🔧 Fix Duplicate Users Issue

## The Problem

If there are **two user documents with the same email or details**, the Firestore rules might be checking the **wrong** user document for permissions, causing permission denied errors.

## How to Check for Duplicates

### Step 1: Check Firebase Console

1. Go to **Firebase Console** → **Firestore Database** → **Data** tab
2. Click on the **`users`** collection
3. Look for:
   - **Multiple documents with the same email**
   - **Multiple documents with the same Firebase Auth UID** (shouldn't happen, but check)
   - **Your own user document appearing twice**

### Step 2: Identify Which User is Correct

For each duplicate:
- Check which one has the correct `isSuperAdmin`, `adminAccess`, and `role` fields
- Check which one has the correct `organizationId`
- Check the `createdAt` timestamp (the older one is likely the original)

## How to Fix

### Option 1: Delete Duplicate User Documents (Recommended)

1. In Firebase Console → Firestore Database → `users` collection
2. Find the duplicate user documents
3. **For each duplicate:**
   - Click on the document
   - Click the **Delete** button (trash icon)
   - Confirm deletion
4. **Keep only ONE user document** per email address
5. **Make sure the remaining document has:**
   - `isSuperAdmin`: `true` (boolean, not string)
   - `adminAccess`: `true` (boolean, not string)
   - `role`: `"admin"` (string, not boolean)
   - Correct `organizationId`

### Option 2: Merge Duplicate Data

If you need to keep data from both documents:

1. Identify which document has the most complete/correct data
2. Copy any missing fields from the duplicate to the main document
3. Delete the duplicate document

## Important: Check YOUR User Document

The most critical thing is to ensure **YOUR user document** (the one you're logged in with) is correct:

1. Find your user document in Firebase Console
   - It will have your Firebase Auth UID as the document ID
   - Or search by your email address
2. Verify it has:
   - `isSuperAdmin`: **boolean** `true`
   - `adminAccess`: **boolean** `true`
   - `role`: **string** `"admin"`
   - `organizationId`: (your organization ID)
3. If there are **TWO documents with your email or UID**, delete the duplicate

## After Fixing Duplicates

1. **Close the app completely**
2. **Reopen the app**
3. **Try creating a user again**

## Why This Causes Permission Errors

When Firestore rules check `isAdminOrSuperAdmin()`, they:
1. Look up your user document using `request.auth.uid`
2. Check if `isSuperAdmin`, `adminAccess`, or `role` is set correctly

If there are duplicate documents:
- The rules might check the wrong document
- Or there might be a conflict in the query
- Or the duplicate might not have admin permissions

## Prevention

To prevent duplicates in the future:
- The app checks for existing users before creating new ones
- But if you manually create users in Firebase Console, be careful not to create duplicates
- Always use the "Add User" flow in the app, not manual creation


