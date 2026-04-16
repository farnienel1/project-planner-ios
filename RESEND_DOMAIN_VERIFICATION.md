# Resend Domain Verification - Step by Step

## Quick Fix: Use Default Domain (Works Now!)

I've updated the code to use Resend's default domain `onboarding@resend.dev` which **works immediately** without any verification. Test emails should work now!

## Proper Solution: Verify Your Domain

If you want to send from `info@projectplanner.us`, follow these steps:

### Step 1: Add Domain in Resend (2 minutes)

1. Go to: https://resend.com
2. Log in to your account
3. Click **"Domains"** in the left sidebar
4. Click **"Add Domain"** button
5. Enter: `projectplanner.us`
6. Click **"Add"**

### Step 2: Get DNS Records from Resend (1 minute)

After adding the domain, Resend will show you DNS records to add:
- **SPF record** (TXT type)
- **DKIM record** (TXT type)

**Copy these records** - you'll need them for Namecheap.

### Step 3: Add DNS Records to Namecheap (5 minutes)

1. Go to: https://namecheap.com
2. Log in
3. Click **"Domain List"**
4. Find `projectplanner.us` and click **"Manage"**
5. Click **"Advanced DNS"** tab
6. Click **"Add New Record"**

**Add SPF Record:**
- **Type:** TXT Record
- **Host:** `@`
- **Value:** (Paste the SPF value from Resend)
- **TTL:** Automatic (or 3600)
- Click **"Save"**

**Add DKIM Record:**
- **Type:** TXT Record
- **Host:** `resend._domainkey` (or what Resend shows)
- **Value:** (Paste the DKIM value from Resend)
- **TTL:** Automatic (or 3600)
- Click **"Save"**

### Step 4: Wait for DNS Propagation (5 minutes to 48 hours)

- DNS changes can take time to propagate
- Usually works within 1-2 hours
- Can take up to 48 hours

**Check if DNS is ready:**
- Use: https://dnschecker.org
- Search for your domain
- Check if TXT records are visible

### Step 5: Verify in Resend (1 minute)

1. Go back to Resend dashboard
2. Click **"Domains"**
3. Find `projectplanner.us`
4. Click **"Verify"** button
5. Status should change to **"Verified"** ✅

### Step 6: Update Code to Use Your Domain

Once verified, update `ResendEmailService.swift`:

```swift
private let fromEmail = "info@projectplanner.us" // Your verified domain
// Remove or comment out: onboarding@resend.dev
```

## Current Setup (Testing)

Right now, the code uses `onboarding@resend.dev` which:
- ✅ Works immediately
- ✅ No verification needed
- ✅ Perfect for testing
- ⚠️ Shows "via Resend" in some email clients

## After Verification

Once your domain is verified:
- ✅ Send from `info@projectplanner.us`
- ✅ Better deliverability
- ✅ No "via Resend" in headers
- ✅ Professional appearance

## Troubleshooting

**If verification fails:**
1. Wait 24 hours for DNS propagation
2. Double-check DNS records match exactly (no typos)
3. Some DNS providers add domain automatically - add a trailing `.` if needed
4. Use https://dnschecker.org to verify records are live

**Quick test:**
- Use default domain (`onboarding@resend.dev`) for now
- Verify domain later when you have time
- Update code once verified


