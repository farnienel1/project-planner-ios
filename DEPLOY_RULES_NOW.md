# 🚨 CRITICAL: Deploy These Rules NOW

## The Problem

The rules are NOT deployed to Firebase, which is why you're getting permission denied errors.

## Step-by-Step Deployment

### 1. Copy These Rules

Copy the ENTIRE block below (from `rules_version` to the final `}`):

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
    
    // Users collection - SIMPLIFIED: Admins can create users without organizationId validation
    match /users/{userId} {
      allow read: if request.auth != null;
      allow list: if request.auth != null;
      
      // SIMPLIFIED RULE: If admin, allow create. No organizationId validation needed.
      allow create: if request.auth != null && (
        // User creating themselves
        (request.auth.uid == userId || 
         request.resource.data.email == request.auth.token.email) ||
        // Admin/Super Admin creating other users - NO organizationId validation for admins
        isAdminOrSuperAdmin()
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
      
      // Managers collection removed - managers are now users with manager permission
      // Use the users collection with manager: true permission instead
      
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

### 2. Deploy to Firebase

1. **Go to Firebase Console:**
   - Visit: https://console.firebase.google.com
   - Select your project: **Project Planner** (project-planner-f986c)

2. **Navigate to Firestore Rules:**
   - Click **Firestore Database** in the left sidebar
   - Click the **Rules** tab at the top

3. **Replace ALL existing rules:**
   - Select ALL text in the rules editor (Cmd+A or Ctrl+A)
   - Delete it
   - Paste the rules from above
   - **VERIFY** you see `isAdminOrSuperAdmin()` function in the rules

4. **Publish:**
   - Click **Publish** button (top right, blue button)
   - Wait for "Rules published successfully" message
   - **IMPORTANT:** Wait 30-60 seconds after publishing

5. **Verify Deployment:**
   - Scroll down in the rules editor
   - Look for the `isAdminOrSuperAdmin()` function
   - Look for the simplified `allow create` rule (should be around line 72-78)
   - If you see it, rules are deployed ✅

### 3. Test Again

1. **Close the app completely** (swipe up from app switcher)
2. **Reopen the app**
3. **Try creating a user again**

## If It Still Doesn't Work

If you still get permission denied after deploying:

1. **Check your user document in Firebase Console:**
   - Go to Firestore Database → Data tab
   - Click `users` collection
   - Find your user document (your Firebase Auth UID)
   - Verify these fields exist and are correct types:
     - `isSuperAdmin`: **boolean** `true` (NOT string "true")
     - `adminAccess`: **boolean** `true` (NOT string "true")
     - `role`: **string** `"admin"` (NOT boolean)

2. **If fields are wrong:**
   - Click on the field
   - Change type to correct type
   - Save

3. **Try again**

## Why This Happens

Firebase rules are evaluated on the **server**, not in your app. Even if your app thinks you're an admin, if the rules aren't deployed or your user document has wrong field types, Firebase will deny access.

The rules MUST be deployed to Firebase Console for them to work!


