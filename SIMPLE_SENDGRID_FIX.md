# Simple SendGrid Fix - 3 Steps

## Step 1: Verify Your Email (2 minutes)

1. Go to: https://app.sendgrid.com
2. Click **Settings** (gear icon, top right)
3. Click **Sender Authentication**
4. Click **Verify a Single Sender**
5. Enter: `info@projectplanner.us`
6. Fill in the form (name, company, etc.)
7. Click **Create**
8. **Check your email inbox** (may be in spam) for verification email
9. **Click the link** in the email
10. Status should show **"Verified"** ✅

## Step 2: Check API Key (1 minute)

1. In SendGrid, click **Settings** → **API Keys**
2. Look for an API key (or create new one)
3. Copy the API key (starts with `SG.`)
4. Open `SendGridEmailService.swift` in your project
5. Find line 9: `private let apiKey = "SG..."`
6. Replace with your API key
7. Save the file

## Step 3: Test (1 minute)

1. Run the app
2. Go to Settings → Test Email Sending
3. Enter your email
4. Click Send
5. Check your inbox

**That's it!** If it still doesn't work, the API key might need "Mail Send" permission - just create a new one with "Full Access".


