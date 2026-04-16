# Web App Setup Instructions

The Project Planner web app is now complete. Here's what was created and how to set it up.

## Files Created

### Core Pages
- login.html - User login page
- dashboard.html - Main dashboard showing organization info and navigation
- settings.html - Account settings page
- projects.html - Live projects list
- managers.html - Managers list (admin only)
- operatives.html - Operatives list (if permissions allow)

### Supporting Files
- app-styles.css - Shared styling for the web app
- app.js - Dashboard functionality and authentication
- settings.js - Account settings functionality
- projects.js - Projects list functionality
- managers.js - Managers list functionality
- operatives.js - Operatives list functionality

## Features

### Authentication
- Users log in with email and password
- Session management using Firebase Auth
- Automatic redirect to login if not authenticated

### Dashboard
- Shows welcome message with user's name
- Displays organization name
- Shows cards for Projects, Managers, Operatives, and Settings
- Cards are shown/hidden based on user permissions
- Shows count of live projects, managers, and operatives

### Account Settings
- View personal information (name, email, role)
- View organization name
- Change password link
- View user permissions (Admin Access, Operatives, Skills, Qualifications)
- Permission status shown with color coding (green for enabled, orange for disabled)

### Projects
- Lists all live projects
- Shows project name, job number, address, and dates
- Available to all users

### Managers
- Lists all active managers
- Shows manager name, email, mobile, and department
- Only visible to users with Admin Access permission

### Operatives
- Lists all active operatives
- Shows operative name, email, phone, skills, and hourly rate
- Only visible to users with Operatives permission or Admin Access

### Permission System
The web app respects the same permission system as the iOS app:
- Admin Access: Can view Managers
- Operatives: Can view Operatives
- Skills: Can view Skills (to be implemented)
- Qualifications: Can view Qualifications (to be implemented)
- Super Admin: Has access to everything

## Setup Instructions

### Step 1: Update Firebase Config

You need to update the Firebase configuration in all JavaScript files:

1. Get your Firebase config from Firebase Console (Project Settings > Your apps > Web app)
2. Update these files with your actual config:
   - app.js (line ~10)
   - settings.js (line ~10)
   - projects.js (line ~10)
   - managers.js (line ~10)
   - operatives.js (line ~10)
   - login.html (in the script section, around line 103)

Replace:
```javascript
const firebaseConfig = {
    apiKey: "YOUR_API_KEY",
    authDomain: "YOUR_PROJECT_ID.firebaseapp.com",
    projectId: "YOUR_PROJECT_ID",
    storageBucket: "YOUR_PROJECT_ID.appspot.com",
    messagingSenderId: "YOUR_SENDER_ID",
    appId: "YOUR_APP_ID"
};
```

With your actual Firebase configuration values.

### Step 2: Deploy to Netlify

1. Create a ZIP file with all your website files
2. Deploy to Netlify (drag and drop)
3. Your web app will be live at your Netlify URL

### Step 3: Test

1. Visit your Netlify URL + /login.html
2. Log in with an existing user account
3. Test the dashboard and all pages
4. Verify permissions are working correctly

## How It Works

### Authentication Flow
1. User visits login.html
2. Enters email and password
3. Firebase Auth authenticates
4. User data is loaded from Firestore
5. User is redirected to dashboard
6. Session is stored in browser

### Permission Checking
- Each page checks user permissions before loading data
- If user lacks permission, appropriate message is shown
- Dashboard cards are hidden if user doesn't have access

### Data Loading
- All data is loaded from Firestore based on user's organizationId
- Projects, managers, and operatives are filtered by organization
- Only active items are shown (isLive for projects, isActive for managers/operatives)

## Linking iOS and Web App

Both apps use the same Firebase project, so:
- Users can log in to either app with the same credentials
- Data is shared between both platforms
- Permissions are synchronized
- Organization data is the same

Users can work on projects from either their iPhone/iPad or from a web browser.

## Customization

### Styling
- All styling is in app-styles.css
- Colors match iOS app design (#007AFF for primary color)
- Responsive design works on desktop and mobile browsers

### Adding Features
To add new features:
1. Create new HTML page
2. Create corresponding JavaScript file
3. Import Firebase config
4. Add authentication check
5. Add permission checks if needed
6. Load data from Firestore
7. Add link from dashboard

## Troubleshooting

### Login not working
- Check Firebase config is correct
- Verify Firebase Auth is enabled in Firebase Console
- Check Email/Password provider is enabled

### No data showing
- Verify user has organizationId in Firestore
- Check Firestore rules allow reading data
- Check browser console for errors

### Permission errors
- Verify user document has correct permission fields
- Check isSuperAdmin flag if user should have full access
- Verify Firestore rules allow reading user documents







