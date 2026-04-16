# Firebase Backend Setup Guide for projectplanner.us

## Overview
This guide will help you set up a complete Firebase backend for your Project Planner app with domain projectplanner.us.

## Step 1: Create Firebase Project

### 1.1 Go to Firebase Console
1. Visit [https://console.firebase.google.com/](https://console.firebase.google.com/)
2. Click "Create a project" or "Add project"

### 1.2 Project Configuration
- **Project name:** `project-planner-us`
- **Project ID:** `project-planner-us` (or similar if taken)
- **Enable Google Analytics:** Yes (recommended)
- **Analytics account:** Create new account or use existing

### 1.3 Wait for Project Creation
- Firebase will create your project (takes 1-2 minutes)
- Click "Continue" when ready

## Step 2: Add iOS App to Firebase

### 2.1 Add iOS App
1. In Firebase console, click "Add app" → iOS
2. **iOS bundle ID:** `farnie.Project-Planner` (from your Xcode project)
3. **App nickname:** `Project Planner iOS`
4. **App Store ID:** Leave blank for now
5. Click "Register app"

### 2.2 Download Configuration File
1. Download `GoogleService-Info.plist`
2. **Important:** This file is already in your project, but we need to update it

### 2.3 Add to Xcode Project
1. Drag `GoogleService-Info.plist` into your Xcode project
2. Make sure "Copy items if needed" is checked
3. Add to target "Project Planner"

## Step 3: Enable Firebase Services

### 3.1 Authentication
1. In Firebase console, go to "Authentication"
2. Click "Get started"
3. Go to "Sign-in method" tab
4. Enable the following providers:
   - **Email/Password** (Primary)
   - **Anonymous** (for demo accounts)

### 3.2 Firestore Database
1. Go to "Firestore Database"
2. Click "Create database"
3. **Security rules:** Start in test mode (we'll secure later)
4. **Location:** Choose closest to your users (e.g., us-central1)

### 3.3 Storage (Optional)
1. Go to "Storage"
2. Click "Get started"
3. **Security rules:** Start in test mode
4. **Location:** Same as Firestore

## Step 4: Configure Security Rules

### 4.1 Firestore Security Rules
```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users can only access their own data
    match /users/{userId} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Organizations - users can access their org data
    match /organizations/{orgId} {
      allow read, write: if request.auth != null && 
        resource.data.members[request.auth.uid] != null;
      
      // Subcollections under organizations
      match /projects/{projectId} {
        allow read, write: if request.auth != null && 
          resource.data.organizationId != null;
      }
      
      match /operatives/{operativeId} {
        allow read, write: if request.auth != null && 
          resource.data.organizationId != null;
      }
      
      match /clients/{clientId} {
        allow read, write: if request.auth != null && 
          resource.data.organizationId != null;
      }
      
      match /bookings/{bookingId} {
        allow read, write: if request.auth != null && 
          resource.data.organizationId != null;
      }
      
      match /managers/{managerId} {
        allow read, write: if request.auth != null && 
          resource.data.organizationId != null;
      }
      
      match /qualifications/{qualificationId} {
        allow read, write: if request.auth != null;
      }
      
      match /skills/{skillId} {
        allow read, write: if request.auth != null;
      }
    }
  }
}
```

### 4.2 Storage Security Rules
```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /users/{userId}/{allPaths=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
    
    match /organizations/{orgId}/{allPaths=**} {
      allow read, write: if request.auth != null && 
        firestore.get(/databases/(default)/documents/organizations/$(orgId)).data.members[request.auth.uid] != null;
    }
  }
}
```

## Step 5: Install Firebase SDK

### 5.1 Add Firebase to Xcode
1. In Xcode, go to File → Add Package Dependencies
2. Enter URL: `https://github.com/firebase/firebase-ios-sdk`
3. Add the following products:
   - FirebaseAuth
   - FirebaseFirestore
   - FirebaseStorage (optional)

### 5.2 Update Package.swift (if using Swift Package Manager)
```swift
dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "10.0.0")
]
```

## Step 6: Configure Firebase in App

### 6.1 Update App Delegate
```swift
import Firebase

@main
struct Project_PlannerApp: App {
    init() {
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

## Step 7: Database Schema Design

### 7.1 Collections Structure
```
firestore-root/
├── users/
│   └── {userId}/
│       ├── email: string
│       ├── displayName: string
│       ├── organizationId: string
│       ├── role: string
│       └── createdAt: timestamp
├── organizations/
│   └── {orgId}/
│       ├── name: string
│       ├── members: map
│       ├── settings: map
│       └── createdAt: timestamp
├── projects/
│   └── {projectId}/
│       ├── jobNumber: string
│       ├── siteName: string
│       ├── client: map
│       ├── organizationId: string
│       └── ... (other project fields)
├── operatives/
│   └── {operativeId}/
│       ├── name: string
│       ├── organizationId: string
│       └── ... (other operative fields)
└── bookings/
    └── {bookingId}/
        ├── operativeId: string
        ├── projectId: string
        ├── organizationId: string
        └── ... (other booking fields)
```

## Step 8: Environment Configuration

### 8.1 Development vs Production
Create separate Firebase projects for:
- **Development:** `project-planner-dev`
- **Production:** `project-planner-prod`

### 8.2 Configuration Files
- `GoogleService-Info-Dev.plist` (development)
- `GoogleService-Info-Prod.plist` (production)

## Step 9: Testing Setup

### 9.1 Test Users
Create test users in Firebase Authentication:
1. Go to Authentication → Users
2. Click "Add user"
3. Create test accounts for development

### 9.2 Test Data
Use Firebase console to add test data:
1. Go to Firestore Database
2. Create test documents in each collection

## Step 10: Monitoring and Analytics

### 10.1 Enable Analytics
1. Go to Analytics → Dashboard
2. Set up custom events for app usage

### 10.2 Set up Alerts
1. Go to Project Settings → Monitoring
2. Set up alerts for errors and performance

## Next Steps

After completing this setup:
1. Update your iOS app to use Firebase
2. Migrate existing data to Firestore
3. Test authentication and data sync
4. Set up website hosting
5. Configure email services

## Support

If you encounter issues:
1. Check Firebase console for errors
2. Review Firebase documentation
3. Contact Firebase support
4. Check Xcode console for debugging info

## Cost Estimation

### Firebase Pricing (Free Tier)
- **Authentication:** 10,000 users/month free
- **Firestore:** 1GB storage, 50K reads, 20K writes free
- **Storage:** 1GB free
- **Hosting:** 10GB bandwidth free

### Expected Monthly Cost
- **Development:** $0 (free tier)
- **Production (100 users):** $0-25/month
- **Production (1000+ users):** $25-100/month


