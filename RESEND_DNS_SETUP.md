# Resend DNS Setup - Quick Guide

## Short Answer: **You DON'T need DNS records to start!**

Resend works immediately with just your API key. DNS records are **optional** and only needed if you want to:
- Send from your custom domain (`info@projectplanner.us`)
- Improve email deliverability
- Avoid "via Resend" in email headers

## Current Setup (Works Now)

✅ **You can send emails RIGHT NOW** with just the API key
- No DNS setup needed
- Emails will work immediately
- May show "via Resend" in some email clients

## Optional: Domain Verification (Better Deliverability)

If you want to send from `info@projectplanner.us` without "via Resend", you can verify your domain:

### Step 1: Get DNS Records from Resend

1. Go to: https://resend.com
2. Click **"Domains"** in sidebar
3. Click **"Add Domain"**
4. Enter: `projectplanner.us`
5. Resend will show you DNS records to add

### Step 2: Add DNS Records to Namecheap (NOT Outlook!)

1. Go to: https://namecheap.com
2. Log in
3. Go to **Domain List**
4. Click **"Manage"** next to `projectplanner.us`
5. Click **"Advanced DNS"** tab
6. Add the DNS records Resend provides (usually CNAME or TXT records)
7. Wait 24-48 hours for DNS to propagate

### Step 3: Verify in Resend

1. Go back to Resend dashboard
2. Click **"Verify"** next to your domain
3. Status should show **"Verified"** ✅

## Important Notes

- **DNS records go in Namecheap** (your domain registrar)
- **Outlook is just an email client** - it doesn't manage DNS
- **You can send emails NOW** without DNS setup
- DNS setup is **optional** for better deliverability

## Recommendation

**Start without DNS records** - test that emails work first. Then add DNS records later if you want better deliverability or to remove "via Resend" from email headers.


