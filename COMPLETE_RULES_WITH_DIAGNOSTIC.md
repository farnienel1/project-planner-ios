# 🔍 Complete Rules with Diagnostic Test

## The Issue

Even with relaxed rules, you're still getting permission denied. This means either:
1. The rules aren't actually deployed
2. There's a caching issue
3. The `isAdminOrSuperAdmin()` function is failing during CREATE

## Step 1: Deploy COMPLETELY PERMISSIVE Test Rule

Let's test if ANY rule will work for CREATE operations.

### Copy This ENTIRE Rules File

```javascript
rules_version = '2';
service cloud.firestore {
  // Helper functions (keep these)
  function getUserOrganizationId() {
    return request.auth != null && 
           exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data
           ? get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId
           : null;
  }
  
  function isMemberOfOrganization(organizationId) {
    return request.auth != null &&
           exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
           'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
           request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members;
  }
  
  function belongsToOrganization(organizationId) {
    return request.auth != null && (
      getUserOrganizationId() == organizationId ||
      isMemberOfOrganization(organizationId)
    );
  }
  
  function isOrganizationAdmin(organizationId) {
    return request.auth != null && 
           exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
           get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId &&
           (get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin' || 
            get(/databases/$(database)/documents/users/$(request.auth.uid)).data.isSuperAdmin == true);
  }
  
  function isAdminOrSuperAdmin() {
    if request.auth == null {
      return false;
    }
    
    let userDocPath = /databases/$(database)/documents/users/$(request.auth.uid);
    if !exists(userDocPath) {
      return false;
    }
    
    let userData = get(userDocPath).data;
    
    if 'isSuperAdmin' in userData && userData.isSuperAdmin == true {
      return true;
    }
    
    if 'adminAccess' in userData && userData.adminAccess == true {
      return true;
    }
    
    if 'role' in userData && userData.role == 'admin' {
      return true;
    }
    
    return false;
  }
  
  function organizationExists(organizationId) {
    return exists(/databases/$(database)/documents/organizations/$(organizationId));
  }
  
  match /databases/{database}/documents {
    match /invitations/{invitationId} {
      allow read: if true;
      allow write: if request.auth != null;
      allow update: if request.auth != null;
    }
    
    // Users collection - TEST: COMPLETELY PERMISSIVE
    match /users/{userId} {
      allow read: if request.auth != null;
      allow list: if request.auth != null;
      
      // TEST RULE: Allow ANY authenticated user to create users
      // If this works, we know the issue is with isAdminOrSuperAdmin()
      // If this doesn't work, there's a deeper issue
      allow create: if request.auth != null;
      
      allow update: if request.auth != null && (
        request.auth.uid == userId ||
        (resource.data.email == request.auth.token.email && 
         request.resource.data.email == request.auth.token.email) ||
        isAdminOrSuperAdmin()
      ) && (
        request.auth.uid == userId ||
        !('organizationId' in request.resource.data) ||
        (('organizationId' in resource.data && request.resource.data.organizationId == resource.data.organizationId) ||
         (organizationExists(request.resource.data.organizationId) && isAdminOrSuperAdmin()))
      );
      
      allow delete: if request.auth != null && (
        request.auth.uid == userId || 
        isAdminOrSuperAdmin()
      );
    }
    
    // Organizations
    match /organizations/{organizationId} {
      allow read: if request.auth != null && (
        (exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
         'organizationId' in get(/databases/$(database)/documents/users/$(request.auth.uid)).data &&
         get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == organizationId) ||
        (exists(/databases/$(database)/documents/organizations/$(organizationId)) &&
         'members' in get(/databases/$(database)/documents/organizations/$(organizationId)).data &&
         request.auth.uid in get(/databases/$(database)/documents/organizations/$(organizationId)).data.members)
      );
      
      allow list: if request.auth != null;
      
      allow create: if request.auth != null && 
                     request.resource.data.members[request.auth.uid] == 'admin';
      
      allow update: if (isOrganizationAdmin(organizationId) &&
                        'name' in request.resource.data &&
                        'members' in request.resource.data) ||
                     (request.auth != null &&
                      'members' in request.resource.data &&
                      request.auth.uid in request.resource.data.members &&
                      organizationExists(organizationId));
      
      allow delete: if false;
      
      // Subcollections
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

## Key Change

**Line 74**: `allow create: if request.auth != null;`

This allows ANY authenticated user to create users. No admin check, no validation, nothing.

## Deploy This

1. Copy the ENTIRE rules block above
2. Go to Firebase Console → Firestore Database → Rules
3. Select all and delete
4. Paste the new rules
5. **Publish**
6. **Wait 2-3 minutes** (rules can take time to propagate)
7. **Close the app completely**
8. **Reopen the app**
9. **Try creating a user**

## What This Tells Us

- **If it works**: The issue is with `isAdminOrSuperAdmin()` function
- **If it still fails**: There's a deeper issue (maybe rules caching, or something else blocking)

After testing, we'll know exactly what to fix!


