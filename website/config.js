// Firebase Configuration
// UPDATE THIS with your actual Firebase project configuration
// You can find these values in:
// 1. Firebase Console → Project Settings → General → Your apps → Web app
// 2. Or in your iOS app's GoogleService-Info.plist

// Website URLs (update after deployment)
const WEBSITE_URLS = {
    base: "https://projectplanner.us",
    setupPassword: "https://projectplanner.us/setup-password.html",
    resetPassword: "https://projectplanner.us/reset-password.html",
    resetPasswordComplete: "https://projectplanner.us/reset-password-complete.html"
};

// Web app config — must match Firebase Console → Project settings → Your apps → Web app.
const FIREBASE_CONFIG = {
    apiKey: "AIzaSyCPafzxnt3q2Q_xQ4N6BYrhNyUOJSiL1Yc",
    authDomain: "project-planner-f986c.firebaseapp.com",
    projectId: "project-planner-f986c",
    storageBucket: "project-planner-f986c.appspot.com",
    messagingSenderId: "980527300983",
    appId: "1:980527300983:web:89bd0c7a69881d1b1be172"
};

// Used by static HTML pages (reset password, etc.) that load this file before a module script.
if (typeof window !== "undefined") {
    window.FIREBASE_WEB_CONFIG = FIREBASE_CONFIG;
    window.FIREBASE_RESET_CONTINUE_URL = WEBSITE_URLS.resetPasswordComplete;
}

// App Store link – opens App Store (user can Open if installed or Get if not). Replace with your real app ID when live: https://apps.apple.com/app/idXXXXXXXXX
const APP_STORE_URL = "https://apps.apple.com/app/project-planner";
