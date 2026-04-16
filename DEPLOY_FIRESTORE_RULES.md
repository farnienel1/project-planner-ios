# 🚀 Deploy Firestore Rules - Step by Step Guide

## The Problem
You're seeing: **"You have admin permissions, but Firestore rules may not be deployed"**

This means:
- ✅ Your user document has admin permissions (isSuperAdmin, adminAccess, or role='admin')
- ❌ The Firestore security rules aren't deployed or aren't working correctly

## Solution: Deploy the Firestore Rules

### Step 1: Open Firebase Console
1. Go to [Firebase Console](https://console.firebase.google.com)
2. Select your project
3. Click on **"Firestore Database"** in the left sidebar
4. Click on the **"Rules"** tab at the top

### Step 2: Copy the Rules
Copy the entire contents of the rules below and paste them into the Rules editor:

```javascript
rules_version = '2';
service cloud.firestore {
  // Helper function to get user's organization ID (safe - returns null if not found)
  function getUserOrganizationId() {
    return request.auth != null && 
           exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data
           ? get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId
           : null;
  }
  
  // Helper function to check if user is a member of organization (by checking members field)
  function isMemberOfOrganization(organizationId) {
    return request.auth != null &&
           exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members;
  }
  
  // Helper function to check if user belongs to organization
  // Checks both user document organizationId AND organization members field
  function belongsToOrganization(organizationId) {
    return request.auth != null && (
      getUserOrganizationId() == organizationId ||
      isMemberOfOrganization(organizationId)
    );
  }
  
  // Helper function to check if user is admin of organization
  function isOrganizationAdmin(organizationId) {
    return request.auth != null && 
           exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId &&
           (get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin' || 
            get(/databases/$(database)/documents/users/$(request.auth.uid)).data.isSuperAdmin == true);
  }
  
  // Helper function to check if current user is super admin or has admin access
  function isAdminOrSuperAdmin() {
    return request.auth != null && 
           exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           (('isSuperAdmin' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data && 
             get(/databases/$(database)/documents/users/$(request.auth.uid)).data.isSuperAdmin == true) ||
            ('adminAccess' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data && 
             get(/databases/$(database)/documents/users/$(request.auth.uid)).data.adminAccess == true) ||
            ('role' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data && 
             get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin'));
  }
  
  // Helper function to validate organizationId exists
  function organizationExists(organizationId) {
    return exists(/databases/$(database)/documents/organizations/$(organizationId));
  }
  
  match /databases/{database}/documents {
    // Invitations - allow public read for verification (before user is authenticated)
    match /invitations/{invitationId} {
      allow read: if true;
      allow write: if request.auth != null;
      allow update: if request.auth != null;
    }
    
    // Users collection - with better validation
    match /users/{userId} {
      allow read: if request.auth != null;
      allow list: if request.auth != null;
      
      // Allow create if:
      // 1. User is creating themselves (same UID or same email), OR
      // 2. Current user is super admin or has admin access (can create other users)
      // SECURITY: Only admins/super admins can create other users - no exceptions
      allow create: if request.auth != null && (
        // User creating themselves
        (request.auth.uid == userId || 
         request.resource.data.email == request.auth.token.email) ||
        // Admin/Super Admin creating other users - REQUIRED for creating other users
        isAdminOrSuperAdmin()
      ) && (
        // If user is creating themselves, allow even if organizationId doesn't exist yet (for initial setup)
        request.auth.uid == userId ||
        request.resource.data.email == request.auth.token.email ||
        !('organizationId' in request.resource.data) ||
        organizationExists(request.resource.data.organizationId) ||
        isMemberOfOrganization(request.resource.data.organizationId)
      );
      
      // Allow update if:
      // 1. User updating themselves (always allow - they can update their own document including organizationId), OR
      // 2. Admin/Super Admin updating other users (for user management)
      allow update: if request.auth != null && (
        // User updating themselves - always allow (most permissive - can update anything including organizationId)
        request.auth.uid == userId ||
        // User updating themselves by email match
        (resource.data.email == request.auth.token.email && 
         request.resource.data.email == request.auth.token.email) ||
        // Admin/Super Admin updating other users
        isAdminOrSuperAdmin()
      ) && (
        // If user is updating themselves, allow any update (including organizationId)
        // If admin is updating others, validate organizationId changes
        request.auth.uid == userId ||
        !('organizationId' in request.resource.data) ||
        (('organizationId' in resource.data && request.resource.data.organizationId == resource.data.organizationId) ||
         // Allow setting organizationId if organization exists (for manual linking)
         (organizationExists(request.resource.data.organizationId) && isAdminOrSuperAdmin()))
      );
      
      // Allow write (delete) if:
      // 1. User deleting themselves, OR
      // 2. Admin/Super Admin (for user management)
      allow delete: if request.auth != null && (
        request.auth.uid == userId || 
        isAdminOrSuperAdmin()
      );
    }
    
    // Organizations - with strict access control
    match /organizations/{organizationId} {
      // CRITICAL FIX: Allow read if user is authenticated AND:
      // 1. User document exists AND has organizationId field AND it matches, OR
      // 2. Organization's members field contains user's UID (for recovery)
      // We check the user document directly in the rule to avoid function call issues
      allow read: if request.auth != null && (
        // Primary check: user document has matching organizationId
        (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
         'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
         get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
        // Fallback: check organization members field (for recovery - get() works during rule eval)
        (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
         'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
         request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
      );
      
      // Allow listing organizations for recovery
      allow list: if request.auth != null;
      
      // Only admins can create/update organizations
      allow create: if request.auth != null && 
                     request.resource.data.members[request.auth.uid] == 'admin';
      
      allow update: if (isOrganizationAdmin(organizationId) &&
                        'name' in request.resource.data &&
                        'members' in request.resource.data) ||
                     // Allow user to add themselves to members field (for manual linking)
                     // This allows the user to add themselves even if their user doc doesn't have organizationId yet
                     (request.auth != null &&
                      'members' in request.resource.data &&
                      request.auth.uid in request.resource.data.members &&
                      organizationExists(organizationId));
      
      // Prevent organization deletion (only allow soft delete via flag)
      allow delete: if false;
      
      // Subcollections within organizations
      // CRITICAL FIX: Check user document directly (not via function) to avoid evaluation issues
      // For subcollections, we verify user belongs to organization by checking user document directly
      match /projects/{projectId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow create, update: if request.auth != null && 
                                request.resource.data.organizationId == organizationId &&
                                ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                                  'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                                  get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                                 (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                                  'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                                  request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
        allow delete: if isOrganizationAdmin(organizationId);
      }
      
      match /smallWorks/{smallWorkId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow create, update: if request.auth != null && 
                                request.resource.data.organizationId == organizationId &&
                                ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                                  'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                                  get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                                 (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                                  'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                                  request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
        allow delete: if isOrganizationAdmin(organizationId);
      }
      
      match /clients/{clientId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow create, update: if request.auth != null && 
                                request.resource.data.organizationId == organizationId &&
                                ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                                  'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                                  get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                                 (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                                  'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                                  request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
        allow delete: if isOrganizationAdmin(organizationId);
      }
      
      match /operatives/{operativeId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow create, update: if request.auth != null && 
                                request.resource.data.organizationId == organizationId &&
                                ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                                  'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                                  get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                                 (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                                  'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                                  request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
        allow delete: if isOrganizationAdmin(organizationId);
      }
      
      match /managers/{managerId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow create, update: if request.auth != null && 
                                request.resource.data.organizationId == organizationId &&
                                ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                                  'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                                  get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                                 (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                                  'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                                  request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
        allow delete: if isOrganizationAdmin(organizationId);
      }
      
      match /bookings/{bookingId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow create, update: if request.auth != null && 
                                request.resource.data.organizationId == organizationId &&
                                ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                                  'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                                  get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                                 (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                                  'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                                  request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
        allow delete: if isOrganizationAdmin(organizationId);
      }
      
      // Qualifications and Skills subcollections (missing from previous rules)
      match /qualifications/{qualificationId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow write: if request.auth != null && 
                      ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                        'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                       (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                        'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                        request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
      }
      
      match /skills/{skillId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow write: if request.auth != null && 
                      ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                        'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                       (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                        'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                        request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
      }
      
      match /settings/{settingId} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow write: if isOrganizationAdmin(organizationId);
      }
      
      // Catch-all for any other subcollections
      match /{collection}/{document=**} {
        allow read: if request.auth != null && (
          (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
          (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
        );
        allow write: if request.auth != null && 
                      ((exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
                        'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
                        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
                       (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
                        'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
                        request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members));
      }
    }
  }
}
```

### Step 3: Validate the Rules
1. Click the **"Validate"** button (if available) to check for syntax errors
2. Make sure there are no red error messages

### Step 4: Publish the Rules
1. Click the **"Publish"** button at the top
2. Wait for confirmation that rules are published
3. You should see a success message like "Rules published successfully"

### Step 5: Verify Deployment
1. The Rules tab should show "Published" status (not "Draft")
2. You should see a timestamp showing when rules were last published

### Step 6: Test in the App
1. Go back to your app
2. Try creating a new user again
3. It should work now!

## Troubleshooting

### If you get syntax errors:
- Make sure you copied the entire rules file
- Check for any missing closing braces `}`
- The rules should start with `rules_version = '2';` and end with `}`

### If rules publish but still don't work:
1. Wait 1-2 minutes for rules to propagate
2. Sign out and sign back into the app to refresh your auth token
3. Try creating a user again

### If you still get permission denied:
1. Double-check your user document has:
   - `isSuperAdmin: true` (boolean)
   - `adminAccess: true` (boolean)  
   - `role: "admin"` (string)
2. Verify the rules were actually published (check the timestamp)
3. Check the Xcode console for detailed debug logs

## Quick Checklist
- [ ] Opened Firebase Console → Firestore Database → Rules
- [ ] Copied the complete rules file
- [ ] Pasted into Rules editor
- [ ] Clicked "Publish"
- [ ] Saw success confirmation
- [ ] Rules show "Published" status
- [ ] Tried creating a user in the app

Once you've deployed the rules, try creating a user again. It should work!


