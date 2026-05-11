# SendGrid Quick Setup Guide

## Current Status

Your app already has SendGrid configured with:
- API Key: `<SENDGRID_API_KEY>`
- From Email: noreply@projectplanner.app

## What You Need to Do

### Step 1: Verify Your SendGrid Account

1. Go to https://app.sendgrid.com
2. Log in with the account that has the API key above
3. Check if your account is verified and active

### Step 2: Verify Sender Email

The from email "noreply@projectplanner.app" needs to be verified in SendGrid:

1. In SendGrid dashboard, go to Settings → Sender Authentication
2. Click "Verify a Single Sender"
3. Add email: noreply@projectplanner.app
4. Fill in required information (your name, address, etc.)
5. Click "Create"
6. Check your email inbox for verification email
7. Click the verification link

Important: You cannot send emails until the sender email is verified.

### Step 3: Alternative - Use a Real Email Address

If you don't have access to projectplanner.app domain, use a real email you control:

1. Go to Settings → Sender Authentication → Verify a Single Sender
2. Add your real email (e.g., info@projectplanner.us or your personal email)
3. Verify it
4. Update the code:

Open: Project Planner/SendGridEmailService.swift
Find line 10: private let fromEmail = "noreply@projectplanner.app"
Change to: private let fromEmail = "your-verified-email@domain.com"

### Step 4: Test Email Sending

1. Open your iOS app
2. Go to Settings → Add User
3. Enter a test email address
4. Create user invitation
5. Check if email arrives (check spam folder too)

### Step 5: Check SendGrid Dashboard

1. Go to Activity → Email Activity
2. You can see if emails were sent and their status
3. Look for any errors or bounces

## Common Issues and Solutions

### Issue: "Unauthorized - Invalid API key"
Solution:
- Verify the API key is correct in SendGridEmailService.swift
- Make sure there are no extra spaces
- Check in SendGrid dashboard that the API key hasn't been deleted

### Issue: "Unprocessable Entity - Sender email not verified"
Solution:
- The from email must be verified in SendGrid
- Go to Settings → Sender Authentication
- Verify the email address you're using

### Issue: Emails not arriving
Solutions:
- Check spam/junk folder
- Verify sender email is verified in SendGrid
- Check SendGrid dashboard Activity section for delivery status
- Make sure recipient email is valid

### Issue: Rate limiting (too many emails)
Solution:
- Free tier allows 100 emails per day
- Wait 24 hours or upgrade to paid plan

## Quick Checklist

- [ ] SendGrid account is active
- [ ] Sender email is verified in SendGrid dashboard
- [ ] API key is correct in code (already set)
- [ ] Test email sending from app
- [ ] Check SendGrid Activity dashboard for delivery status

## Need to Change API Key?

If you need to create a new API key:

1. Go to SendGrid dashboard → Settings → API Keys
2. Click "Create API Key"
3. Name it "Project Planner App"
4. Select "Full Access" or "Mail Send" permissions
5. Copy the key immediately (you won't see it again)
6. Update in SendGridEmailService.swift line 9

## Need to Use Different Email Address?

If you want to use a different "from" email:

1. In SendGrid dashboard, verify the new email first
2. Update SendGridEmailService.swift line 10 with the verified email
3. Make sure it's exactly the same email you verified in SendGrid

## Current Email Types Configured

Your app can send:
- Password setup emails (new user invitations)
- Password reset emails
- Verification emails
- Schedule emails
- Notification emails

All use the same SendGrid setup.

## Testing

To test if SendGrid is working:

1. In your app, invite a new user
2. Check SendGrid dashboard → Activity → Email Activity
3. You should see the email attempt with status (delivered, bounced, etc.)
4. Check the recipient's inbox (and spam folder)

## Support

- SendGrid Dashboard: https://app.sendgrid.com
- SendGrid Docs: https://docs.sendgrid.com
- Check email activity: Activity → Email Activity in dashboard







