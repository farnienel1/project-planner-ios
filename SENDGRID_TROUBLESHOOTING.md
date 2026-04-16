# SendGrid Email Test Troubleshooting

## Quick Diagnosis

When the test email fails, check:

### 1. Check the Error Message in the App
The test function now shows detailed error messages. Look for:
- **401 Unauthorized**: API key is invalid
- **403 Forbidden**: Domain not verified
- **422 Unprocessable**: Sender email not verified

### 2. Check Console/Xcode Logs
Look for lines starting with:
- `📧 Response status: [number]` - Shows HTTP status code
- `❌ SendGrid error response: [details]` - Shows actual error from SendGrid

### 3. Check SendGrid Dashboard
1. Go to: https://app.sendgrid.com
2. Navigate to **Activity** → **Email Activity**
3. Look for the test email attempt
4. Check the status and error details

## Common Issues and Fixes

### Issue 1: 401 Unauthorized - Invalid API Key
**Symptoms:**
- Error message: "Unauthorized - Invalid API key"
- Status code: 401

**Fix:**
1. Go to SendGrid Dashboard → Settings → API Keys
2. Verify the API key in `SendGridEmailService.swift` matches your SendGrid API key
3. Make sure the API key has "Mail Send" permissions
4. If needed, create a new API key with full access

### Issue 2: 422 Unprocessable - Sender Email Not Verified
**Symptoms:**
- Error message: "Unprocessable Entity - Sender email not verified"
- Status code: 422

**Fix:**
1. Go to SendGrid Dashboard → Settings → Sender Authentication
2. Click "Verify a Single Sender"
3. Enter: `info@projectplanner.us`
4. SendGrid will send a verification email
5. Check your inbox (may be in spam)
6. Click the verification link
7. Status should show "Verified"

### Issue 3: 403 Forbidden - Domain Not Verified
**Symptoms:**
- Error message: "Forbidden - Domain not verified"
- Status code: 403

**Fix:**
1. Go to SendGrid Dashboard → Settings → Sender Authentication
2. Click "Authenticate Your Domain"
3. Enter: `projectplanner.us`
4. SendGrid will provide DNS records (CNAME records)
5. Add these to your domain's DNS settings (Namecheap, etc.)
6. Wait for DNS propagation (can take up to 48 hours)
7. Click "Verify" in SendGrid

### Issue 4: Network Error
**Symptoms:**
- Error message: "Failed to send email: [network error]"
- No HTTP status code

**Fix:**
1. Check your internet connection
2. Try again after a few minutes
3. Check if SendGrid API is down: https://status.sendgrid.com

## Step-by-Step Verification

### Step 1: Verify API Key
1. Open `SendGridEmailService.swift`
2. Check line 9: `private let apiKey = "SG..."`
3. Go to SendGrid Dashboard → Settings → API Keys
4. Verify the key exists and is active
5. Make sure it has "Mail Send" permission

### Step 2: Verify Sender Email
1. Go to SendGrid Dashboard → Settings → Sender Authentication
2. Look for `info@projectplanner.us`
3. Status should be "Verified" (green checkmark)
4. If not verified:
   - Click "Verify a Single Sender"
   - Enter `info@projectplanner.us`
   - Check email inbox for verification email
   - Click verification link

### Step 3: Test Again
1. Go back to app → Settings → Test Email Sending
2. Enter your email address
3. Tap "Send Test Email"
4. Check the detailed error message if it fails
5. Check SendGrid Dashboard → Activity for the attempt

## What to Check in Console Logs

When you run the test, look for these log messages:

```
📧 Sending email to: [your-email]
📧 From: info@projectplanner.us
📧 Subject: Welcome to Project Planner - Set Up Your Account
📧 Response status: [status-code]
```

If status code is NOT 202:
```
❌ SendGrid error response: [detailed error from SendGrid]
```

The error response will contain specific information about what's wrong.

## Quick Test Checklist

- [ ] API key is correct in `SendGridEmailService.swift`
- [ ] API key has "Mail Send" permission
- [ ] `info@projectplanner.us` is verified in SendGrid
- [ ] Internet connection is working
- [ ] Checked SendGrid Activity dashboard for errors
- [ ] Checked console logs for detailed error messages

## Still Not Working?

If you've verified everything above and it still doesn't work:

1. **Check SendGrid Account Status:**
   - Make sure your SendGrid account is active
   - Check for any account limitations or suspensions

2. **Try a Different Email Address:**
   - Some email providers block SendGrid emails
   - Try with a Gmail address to test

3. **Check SendGrid Activity Dashboard:**
   - Go to SendGrid → Activity → Email Activity
   - Look for your test email attempt
   - Check the detailed error message there

4. **Contact SendGrid Support:**
   - If account is verified and API key is correct
   - SendGrid support can check account-level issues

## Note About Firestore Permission Error

**Important:** The SendGrid email test is separate from the Firestore permission error. Even if email works, you still need to fix the Firestore rules to create users. The email only sends AFTER the user is successfully created in Firestore.


