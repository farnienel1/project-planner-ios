# Complete SendGrid Setup Guide for Project Planner

This guide will help you configure SendGrid to send all emails from your app, including:
- ✅ Password setup emails (new user invitations)
- ✅ Password reset emails
- ✅ Verification emails
- ✅ Schedule emails (weekly schedules to operatives/managers)
- ✅ Notification emails

---

## Step 1: Create SendGrid Account (Free Tier Available)

1. **Sign Up**: Go to https://sendgrid.com
2. **Create Account**: Sign up with your email (you can use any email address)
3. **Free Tier**: SendGrid offers **100 emails per day forever** for free accounts
4. **Verify Email**: Check your inbox and verify your SendGrid account

---

## Step 2: Create API Key

1. **Navigate to Settings**:
   - Log into SendGrid dashboard
   - Go to **Settings** → **API Keys** (left sidebar)

2. **Create API Key**:
   - Click **"Create API Key"** button
   - **Name**: "Project Planner App" (or any name you like)
   - **API Key Permissions**: Select **"Full Access"** (or "Mail Send" for security)
   - Click **"Create & View"**

3. **Copy API Key**:
   - ⚠️ **IMPORTANT**: Copy the API key immediately - you won't be able to see it again!
   - It looks like: `<SENDGRID_API_KEY>`

---

## Step 3: Verify Sender Email Address

1. **Navigate to Sender Authentication**:
   - Go to **Settings** → **Sender Authentication**
   - Click **"Verify a Single Sender"**

2. **Add Your Email**:
   - **From Email**: `noreply@projectplanner.app` (or your preferred email)
   - **From Name**: "Project Planner"
   - Fill in the required fields (Name, Address, City, State, Zip, Country)
   - Click **"Create"**

3. **Verify Email**:
   - SendGrid will send a verification email to the address you provided
   - Check your inbox and click the verification link
   - ⚠️ **Important**: You must verify this email before sending emails

**Alternative**: If you have your own domain (e.g., `projectplanner.app`), you can:
- **Domain Authentication** (Recommended for production):
  - Go to **Settings** → **Sender Authentication** → **Authenticate Your Domain**
  - Follow the DNS setup instructions
  - This allows you to send from any email on your domain (e.g., `noreply@projectplanner.app`, `support@projectplanner.app`)

---

## Step 4: Update Your App Code

1. **Open**: `Project Planner/SendGridEmailService.swift`

2. **Update API Key** (Line 9):
   ```swift
   private let apiKey = "YOUR_SENDGRID_API_KEY_HERE"
   ```
   Replace `YOUR_SENDGRID_API_KEY_HERE` with the API key you copied in Step 2

3. **Update From Email** (Line 10):
   ```swift
   private let fromEmail = "noreply@projectplanner.app" // Use your verified email
   ```
   Replace with the email you verified in Step 3 (must be verified!)

---

## Step 5: Test Email Sending

### Test 1: Password Setup Email
1. Open your app
2. Go to **Settings** → **Add User**
3. Enter a test email address
4. Create the user invitation
5. Check the test email inbox - you should receive the password setup email

### Test 2: Password Reset
1. Go to login screen
2. Click "Forgot Password"
3. Enter your email
4. Check inbox for password reset email

### Test 3: Schedule Email (if implemented)
1. Go to Schedule view
2. Send weekly schedule to an operative/manager
3. Check inbox for schedule email

---

## Step 6: Monitor Email Delivery

1. **SendGrid Dashboard**:
   - Go to **Activity** → **Email Activity** in SendGrid dashboard
   - You can see all emails sent, their status (delivered, bounced, etc.)
   - Useful for debugging delivery issues

2. **Check Spam Folder**:
   - If emails don't arrive, check spam/junk folders
   - Recipients may need to mark emails as "Not Spam"

3. **Email Statistics**:
   - Go to **Stats** → **Email Activity** for delivery statistics
   - Monitor bounce rates, spam reports, etc.

---

## Troubleshooting

### Error: "Unauthorized - Invalid API key"
- **Solution**: Check that your API key is correct in `SendGridEmailService.swift`
- Ensure there are no extra spaces or characters

### Error: "Unprocessable Entity - Sender email not verified"
- **Solution**: Verify your sender email in SendGrid dashboard
- Go to **Settings** → **Sender Authentication** → verify the email address

### Error: "Forbidden - Domain not verified"
- **Solution**: If using a custom domain, authenticate it in SendGrid
- Or use a verified single sender email address instead

### Emails Going to Spam
- **Solution**: 
  - Use Domain Authentication (more trusted)
  - Ask recipients to mark emails as "Not Spam"
  - SendGrid's free tier may have lower deliverability - consider upgrading for production

### Rate Limiting (429 Error)
- **Free Tier**: 100 emails per day
- **Solution**: 
  - Wait 24 hours for limit to reset
  - Upgrade to paid plan for higher limits
  - Or distribute email sending throughout the day

---

## SendGrid Pricing (Reference)

- **Free**: 100 emails/day forever
- **Essentials** ($19.95/month): 50,000 emails/month
- **Pro** ($89.95/month): 100,000 emails/month
- **Advanced**: Custom pricing for high volume

For most apps, the free tier is sufficient during development and for small teams.

---

## Current Configuration in Your App

✅ **SendGrid is already configured** in:
- `SendGridEmailService.swift` - Main email service
- `CloudEmailService.swift` - Routes to SendGrid
- `FirebaseBackend.swift` - Uses SendGrid for password setup emails
- `EmailVerificationService.swift` - Uses SendGrid for verification/reset emails

**Email Types Supported**:
1. ✅ Password Setup (New User Invitations)
2. ✅ Password Reset
3. ✅ Email Verification
4. ✅ Schedule Emails (Weekly schedules)
5. ✅ Notification Emails

---

## Next Steps

1. ✅ Follow Steps 1-4 above to configure SendGrid
2. ✅ Update API key and sender email in code
3. ✅ Test email sending with your test account
4. ✅ Monitor email delivery in SendGrid dashboard
5. ✅ If using in production, consider Domain Authentication for better deliverability

---

## Security Best Practices

1. **Never commit API keys to Git**:
   - Consider using environment variables or secure key storage
   - For now, the API key is in code - keep your code private

2. **Use Domain Authentication**:
   - More secure and trusted
   - Better deliverability

3. **Monitor Email Activity**:
   - Regularly check for bounces or spam reports
   - Remove invalid email addresses from your system

---

## Support

- **SendGrid Documentation**: https://docs.sendgrid.com
- **SendGrid Support**: Available in dashboard (for paid accounts)
- **API Status**: https://status.sendgrid.com

---

**You're all set!** Once you've updated the API key and verified your sender email, all emails from your app will be sent via SendGrid. 🎉







