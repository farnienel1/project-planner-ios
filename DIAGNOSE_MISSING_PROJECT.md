# 🔍 Diagnostic Guide: Missing Project for farnienelyt@gmail.com

## 📋 What to Check

### Step 1: Check Firebase Console
1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project
3. Go to **Firestore Database**

### Step 2: Find the User Document
1. Navigate to `users` collection
2. Search for documents where `email` field = `farnienelyt@gmail.com`
3. **Check if the document has:**
   - ✅ `organizationId` field (should be a UUID string)
   - ✅ `role` field
   - ✅ `email` field matches

**If `organizationId` is MISSING:**
- The user lost their organization link
- Projects are still in Firestore but not accessible
- **Fix:** See "Fix Missing Organization Link" below

### Step 3: Check the Organization
1. If `organizationId` exists, go to `organizations` collection
2. Open the document with that `organizationId`
3. **Check if:**
   - ✅ Organization document exists
   - ✅ Organization has a `name` field
   - ✅ Organization has `members` or `adminUserId` field

**If organization document is MISSING:**
- Organization was deleted
- Projects are orphaned but still exist
- **Fix:** See "Recover Orphaned Projects" below

### Step 4: Check Projects Collection
1. Go to `organizations/{organizationId}/projects` subcollection
2. **Check if:**
   - ✅ Any project documents exist
   - ✅ Projects have correct data structure
   - ✅ Projects are not marked as deleted

**If projects exist but user can't see them:**
- Likely a sync/loading issue
- **Fix:** See "Force Reload Projects" below

## 🔧 Fixes

### Fix 1: Missing Organization Link
If user document exists but has no `organizationId`:

1. **Find the correct organization:**
   - Check `organizations` collection
   - Look for organizations where `adminUserId` = the user's Firebase UID
   - Or check `members` field for the user's email

2. **Update user document:**
   - In Firestore Console, edit `users/{userId}` document
   - Add field: `organizationId` (string) = the organization UUID
   - Add field: `role` (string) = "admin" or "basic" (depending on permissions)

3. **Test in app:**
   - User should sign out and sign back in
   - Projects should appear

### Fix 2: Recover Orphaned Projects
If organization was deleted but projects still exist:

1. **Find orphaned projects:**
   - In Firestore, search all `organizations` subcollections
   - Look for `projects` subcollections with data
   - Note the parent organization ID

2. **Recreate organization:**
   - Create new organization document in `organizations` collection
   - Use the same organization ID (or create new and migrate)
   - Set `name`, `adminUserId`, `createdAt`, etc.

3. **Link user to organization:**
   - Update `users/{userId}` document
   - Set `organizationId` = the organization ID

4. **Verify projects:**
   - Projects should now be accessible under `organizations/{organizationId}/projects`

### Fix 3: Force Reload Projects
If projects exist but app shows empty:

1. **Clear app cache:**
   - Delete and reinstall app (or clear app data)
   - Sign out and sign back in

2. **Check Firestore Security Rules:**
   - Ensure rules allow authenticated users to read:
     - `users/{userId}` documents
     - `organizations/{organizationId}` documents
     - `organizations/{organizationId}/projects` subcollection

3. **Check app logs:**
   - Look for Firebase debug logs (lines starting with `🔥🔥🔥 DEBUG:`)
   - Check for permission errors or missing data errors

## 🚨 Emergency Recovery Script

If you need to manually recover data, you can use this Node.js script (run in Firebase Functions or locally with Firebase Admin SDK):

```javascript
const admin = require('firebase-admin');
admin.initializeApp();

async function recoverUserProject(userEmail) {
  const db = admin.firestore();
  
  // 1. Find user by email
  const usersSnapshot = await db.collection('users')
    .where('email', '==', userEmail)
    .get();
  
  if (usersSnapshot.empty) {
    console.log('❌ User not found');
    return;
  }
  
  const userDoc = usersSnapshot.docs[0];
  const userData = userDoc.data();
  const userId = userDoc.id;
  
  console.log('✅ Found user:', userId);
  console.log('📧 Email:', userData.email);
  console.log('🏢 Organization ID:', userData.organizationId || 'MISSING');
  
  // 2. Check if organization exists
  if (userData.organizationId) {
    const orgDoc = await db.collection('organizations')
      .doc(userData.organizationId)
      .get();
    
    if (orgDoc.exists) {
      console.log('✅ Organization exists:', orgDoc.data().name);
      
      // 3. Check projects
      const projectsSnapshot = await db.collection('organizations')
        .doc(userData.organizationId)
        .collection('projects')
        .get();
      
      console.log(`📦 Found ${projectsSnapshot.size} projects`);
      projectsSnapshot.forEach(doc => {
        console.log('  -', doc.id, doc.data().siteName || 'No name');
      });
    } else {
      console.log('❌ Organization document missing');
      console.log('🔍 Searching for orphaned projects...');
      
      // Search all organizations for projects
      const orgsSnapshot = await db.collection('organizations').get();
      for (const orgDoc of orgsSnapshot.docs) {
        const projectsSnapshot = await orgDoc.ref.collection('projects').get();
        if (projectsSnapshot.size > 0) {
          console.log(`📦 Found ${projectsSnapshot.size} projects in org ${orgDoc.id}`);
        }
      }
    }
  } else {
    console.log('❌ No organizationId in user document');
    console.log('🔍 Searching for organizations with this user...');
    
    // Search for organizations where user is admin
    const orgsSnapshot = await db.collection('organizations')
      .where('adminUserId', '==', userId)
      .get();
    
    if (!orgsSnapshot.empty) {
      const orgDoc = orgsSnapshot.docs[0];
      console.log('✅ Found organization:', orgDoc.id);
      
      // Update user document
      await db.collection('users').doc(userId).update({
        organizationId: orgDoc.id
      });
      console.log('✅ Updated user document with organizationId');
    }
  }
}

// Run: recoverUserProject('farnienelyt@gmail.com');
```

## 📞 Next Steps

1. **Check Firebase Console first** (Steps 1-4 above)
2. **If organizationId is missing:** Use Fix 1
3. **If organization is deleted:** Use Fix 2
4. **If projects exist but not showing:** Use Fix 3
5. **If still stuck:** Run the recovery script or contact support

## 🔐 Security Note

Make sure Firestore security rules allow:
- Users to read their own user document
- Users to read their organization document
- Users to read projects in their organization

Example rules:
```javascript
match /users/{userId} {
  allow read: if request.auth != null && request.auth.uid == userId;
}

match /organizations/{orgId} {
  allow read: if request.auth != null && 
    get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == orgId;
  
  match /projects/{projectId} {
    allow read: if request.auth != null && 
      get(/databases/$(database)/documents/users/$(request.auth.uid)).data.organizationId == orgId;
  }
}
```



