# Netlify Hosting - Simple Step by Step

## Step 1: Create Netlify Account

1. Go to netlify.com
2. Click Sign up button (top right)
3. Choose Sign up with Google (easiest) or use email
4. Complete the signup process

## Step 2: Prepare Your Website Files

1. On your Mac, open Finder
2. Navigate to: Desktop > Project Planner > website
3. Select all files in the website folder (press Cmd+A or select manually)
4. Files to include: index.html, setup-password.html, reset-password.html, reset-password-complete.html, styles.css, config.js
5. Right-click on selected files
6. Choose "Compress X items"
7. This creates a ZIP file (usually called Archive.zip or website.zip)

## Step 3: Deploy to Netlify

1. Go to app.netlify.com (login if needed)
2. Look for the main dashboard
3. Find the area that says "Want to deploy a new site without connecting to Git?" or "Drag and drop your site output folder here"
4. Drag your ZIP file into that area, OR click "Browse to upload" and select your ZIP file
5. Wait for upload and deployment (takes about 30-60 seconds)
6. Netlify will show "Site is live" when ready
7. Your website URL will be shown (something like https://random-name-123.netlify.app)

## Step 4: Get Your Firebase Configuration

1. Go to console.firebase.google.com
2. Select your Project Planner project
3. Click the Settings gear icon, then choose Project Settings
4. Scroll down to the "Your apps" section
5. Click on the Web app icon (looks like </>)
6. If you don't have a Web app, click "Add app" and create one
7. You will see a config object that looks like this:
   - apiKey: "AIzaSyC..."
   - authDomain: "your-project.firebaseapp.com"
   - projectId: "your-project-id"
   - storageBucket: "your-project.appspot.com"
   - messagingSenderId: "123456789"
   - appId: "1:123456789:web:abc123"
8. Copy these values, you will need them

## Step 5: Update HTML Files with Firebase Config

1. On your Mac, open Finder and go to Desktop > Project Planner > website
2. Open setup-password.html in TextEdit (right-click > Open with > TextEdit)
3. Press Cmd+F to open Find
4. Search for "YOUR_API_KEY"
5. Replace the firebaseConfig section with your actual values:
   - Change apiKey: "YOUR_API_KEY" to your actual API key
   - Change authDomain: "YOUR_PROJECT_ID.firebaseapp.com" to your actual auth domain
   - Change projectId: "YOUR_PROJECT_ID" to your actual project ID
   - Change storageBucket: "YOUR_PROJECT_ID.appspot.com" to your actual storage bucket
   - Change messagingSenderId: "YOUR_SENDER_ID" to your actual sender ID
   - Change appId: "YOUR_APP_ID" to your actual app ID
6. Save the file (Cmd+S)
7. Repeat steps 2-6 for reset-password.html
8. Repeat steps 2-6 for reset-password-complete.html

## Step 6: Upload Updated Files

1. Create a new ZIP file with your updated HTML files (same as Step 2)
2. Go back to app.netlify.com
3. Click on your deployed site
4. Go to the Deploys tab
5. Drag and drop your new ZIP file, or click "Deploy manually" and upload
6. Netlify will automatically update your site

## Step 7: Update Firestore Security Rules

1. Go to console.firebase.google.com
2. Select your Project Planner project
3. Click on Firestore Database in the left menu
4. Click on the Rules tab
5. Find the section that says "match /invitations"
6. If it doesn't exist, add this rule before the closing brace:
   
   match /invitations/{invitationId} {
     allow read: if true;
     allow write: if request.auth != null;
   }
   
7. Click the Publish button

## Step 8: Test Your Website

1. Copy your Netlify URL (from Step 3)
2. Test password setup page:
   - Visit: your-netlify-url.netlify.app/setup-password.html
   - You should see an invitation code input form
3. Test password reset page:
   - Visit: your-netlify-url.netlify.app/reset-password.html
   - You should see an email input form

## Updating Your Website Later

When you need to make changes to your website files:

1. On your Mac, open Finder and go to Desktop > Project Planner > website
2. Edit the files you need to change (use TextEdit or any text editor)
3. Save your changes
4. Select all the files in the website folder (Cmd+A)
5. Right-click and choose "Compress X items" to create a new ZIP file
6. Go to app.netlify.com and click on your deployed site
7. Go to the Deploys tab
8. Drag and drop your new ZIP file into the deploy area, OR click "Deploy manually" and select your ZIP file
9. Wait for deployment (usually 30-60 seconds)
10. Your site will automatically update with the new files
11. Visit your website URL to verify the changes are live

Note: If you only changed one or two files, you still need to upload all files in a ZIP. Netlify will replace the old files with the new ones.

## Setting Up Custom Domain (Optional)

1. In Netlify dashboard, click on your site
2. Go to Domain settings tab
3. Click Add custom domain
4. Enter: projectplanner.us
5. Click Verify
6. Netlify will show you DNS records to add
7. Go to where you bought your domain (Namecheap, etc.)
8. Add the DNS records Netlify provides (usually A records)
9. Wait for verification (can take a few minutes to 24 hours)
10. Your site will be available at projectplanner.us

## Troubleshooting

Problem: Site failed to deploy
Solution: Make sure your ZIP file contains the HTML files directly (not in a nested folder). The index.html should be in the root of the ZIP.

Problem: Page not found when visiting
Solution: Check that all files (HTML, CSS) are included in your ZIP and that index.html exists.

Problem: Invalid invitation code error on website
Solution: Check that Firebase config is correct in all 3 HTML files. Also verify Firestore rules allow reading invitations (Step 7).

Problem: Permission denied errors
Solution: Make sure Firestore rules are updated (Step 7) to allow reading invitations.

