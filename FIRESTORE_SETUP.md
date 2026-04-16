# Firestore Database Setup - projectplanner.us

## ✅ What You Need to Do (5 minutes)

### 1. Enable Firestore Database
**Go to:** Firebase Console → Firestore Database
**Click:** "Create database"
**Choose:** "Start in production mode" (more secure)
**Select:** Location closest to your users (e.g., us-central1)

### 2. Set Up Security Rules
**Go to:** Firestore Database → Rules
**Replace default rules with:**

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users can only access their own organization's data
    match /organizations/{organizationId} {
      allow read, write: if request.auth != null 
        && request.auth.token.organizationId == organizationId;
      
      // Subcollections within organizations
      match /{document=**} {
        allow read, write: if request.auth != null 
          && request.auth.token.organizationId == organizationId;
      }
    }
  }
}
```

### 3. Test Database Connection
**Go to:** Firestore Database → Data
**You should see:** Empty database (collections will appear when users start using the app)

## 🚫 What You DON'T Need to Do

### ❌ Create Collections Manually
- Collections are created automatically
- No need to pre-create anything
- Your app will create them as needed

### ❌ Add Sample Data
- Your app will create real data
- No need for test data
- Users will populate the database

### ❌ Configure Complex Rules
- Basic security rules are sufficient
- Can be refined later
- Focus on getting the app working first

## 🎯 What Happens When Users Use Your App

### First User Signs Up:
```
organizations/
  └── {new-organization-id}/
      ├── projects/ (empty initially)
      ├── operatives/ (empty initially)
      ├── bookings/ (empty initially)
      └── users/
          └── {user-id}/
              ├── email: "user@example.com"
              ├── role: "admin"
              └── createdAt: timestamp
```

### User Creates First Project:
```
organizations/
  └── {organization-id}/
      ├── projects/
      │   └── {project-id}/
      │       ├── jobNumber: "C001"
      │       ├── siteName: "Construction Site"
      │       ├── client: {...}
      │       └── ...
      ├── operatives/ (still empty)
      └── bookings/ (still empty)
```

### User Adds First Operative:
```
organizations/
  └── {organization-id}/
      ├── projects/ (existing projects)
      ├── operatives/
      │   └── {operative-id}/
      │       ├── name: "John Smith"
      │       ├── email: "john@company.com"
      │       ├── skills: [...]
      │       └── ...
      └── bookings/ (still empty)
```

## 🔧 Security Rules Explanation

### Current Rules:
```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users can only access their own organization's data
    match /organizations/{organizationId} {
      allow read, write: if request.auth != null 
        && request.auth.token.organizationId == organizationId;
      
      // Subcollections within organizations
      match /{document=**} {
        allow read, write: if request.auth != null 
          && request.auth.token.organizationId == organizationId;
      }
    }
  }
}
```

### What This Means:
- **Only authenticated users** can access data
- **Users can only see their organization's data**
- **No cross-organization data access**
- **Secure by default**

## 🧪 Testing Your Setup

### 1. Run Your App
- Open Xcode
- Run your Project Planner app
- Try to sign up with a new account

### 2. Check Firestore Console
- Go to Firebase Console → Firestore Database → Data
- You should see collections appear automatically
- Check that data is being saved

### 3. Verify Security
- Try accessing data from different accounts
- Ensure users can't see other organizations' data
- Test that unauthenticated users can't access data

## 🚨 Common Issues

### Issue 1: "Permission Denied" Errors
**Cause:** Security rules too restrictive
**Fix:** Temporarily use test mode rules:
```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if true;
    }
  }
}
```
**Note:** Only use this for testing, then switch back to secure rules

### Issue 2: Collections Not Appearing
**Cause:** App not saving data properly
**Fix:** Check your FirebaseBackend.swift implementation
**Debug:** Add console logs to see if data is being saved

### Issue 3: Authentication Errors
**Cause:** Firebase Auth not properly configured
**Fix:** Check Authentication settings in Firebase Console
**Verify:** Email/Password sign-in is enabled

## 📋 Quick Setup Checklist

### Firebase Console Setup (5 minutes):
- [ ] Go to Firestore Database
- [ ] Click "Create database"
- [ ] Choose "Start in production mode"
- [ ] Select location (us-central1 recommended)
- [ ] Go to Rules tab
- [ ] Paste security rules
- [ ] Click "Publish"

### Test Your App (5 minutes):
- [ ] Run your iOS app
- [ ] Try signing up with new account
- [ ] Check Firestore Console for new collections
- [ ] Verify data is being saved

### Verify Security (2 minutes):
- [ ] Check that collections are private
- [ ] Test with different user accounts
- [ ] Ensure no cross-organization access

## 🎯 Success Criteria

### Firestore Setup Complete When:
- [ ] Database created in production mode
- [ ] Security rules configured
- [ ] App can save data to Firestore
- [ ] Collections appear automatically
- [ ] Data is secure and private

### Ready for Testing When:
- [ ] Users can sign up successfully
- [ ] Data appears in Firestore Console
- [ ] No permission errors
- [ ] Collections structure is correct

## 🚀 Next Steps After Setup

### 1. Test Complete Flow
- Sign up new user
- Create first project
- Add first operative
- Make first booking
- Verify all data appears in Firestore

### 2. Monitor Usage
- Check Firestore Console regularly
- Monitor data growth
- Watch for any errors

### 3. Refine Security Rules
- Adjust rules based on usage patterns
- Add more specific permissions if needed
- Consider role-based access control

## 📞 Need Help?

### If Collections Don't Appear:
- Check your app's Firebase integration
- Verify authentication is working
- Check console for error messages

### If Permission Errors:
- Temporarily use test mode rules
- Debug authentication flow
- Check user organization assignment

### If Data Not Saving:
- Check FirebaseBackend.swift
- Verify Firestore configuration
- Test with simple data first

## 🎉 You're Ready!

Once you've completed this 5-minute setup, your Firestore database will be ready to automatically create collections as users start using your app. No manual collection creation needed!













