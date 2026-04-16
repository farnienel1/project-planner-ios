# 🌐 Netlify + SendGrid DNS Setup Guide

## 📋 Overview

If your domain `projectplanner.us` uses Netlify's nameservers, you need to add SendGrid's CNAME records in Netlify, not Namecheap.

---

## 🔍 Step 1: Verify You're Using Netlify Nameservers

1. **Check in Namecheap**:
   - Domain List → projectplanner.us → Manage → Nameservers
   - If it shows Netlify nameservers (like `dns1.p04.nsone.net` or similar), you're using Netlify DNS
   - If it shows Namecheap BasicDNS, you should add records in Namecheap instead

2. **Or Check in Netlify**:
   - Go to Netlify dashboard
   - Click on your site
   - Go to "Domain settings"
   - If your domain is listed there, you're using Netlify nameservers

---

## 🔐 Step 2: Get DNS Records from SendGrid

1. **Log into SendGrid**:
   - Go to https://app.sendgrid.com
   - Sign in

2. **Navigate to Domain Authentication**:
   - Click **Settings** (gear icon) → **Sender Authentication**
   - Click **"Authenticate Your Domain"**

3. **Enter Domain**:
   - Domain: `projectplanner.us` (without www)
   - Click **Next**

4. **Choose DNS Host**:
   - Select **"Other"** or **"Generic"** (Netlify might not be listed)
   - Click **Next**

5. **Get DNS Records**:
   - SendGrid will show you CNAME records like:
     ```
     Type: CNAME
     Host: em1234
     Value: u123456.wl123.sendgrid.net
     ```
   - You'll see 2-3 CNAME records
   - **Copy all of them** - you'll need:
     - The Host/Name part
     - The Value/Target part

---

## ➕ Step 3: Add DNS Records in Netlify

### Method A: Through Domain Settings

1. **Go to Netlify Dashboard**:
   - Go to https://app.netlify.com
   - Log in

2. **Navigate to Domain Settings**:
   - Click on your site (or go to Domain settings from main menu)
   - Click **"Domain settings"** tab
   - Find `projectplanner.us` in the list
   - Click on it

3. **Go to DNS**:
   - Look for **"DNS"** or **"DNS records"** section
   - Or click **"Manage DNS"** button

4. **Add CNAME Records**:
   - Click **"Add DNS record"** or **"Add new record"**
   - For each CNAME from SendGrid:
     - **Type**: Select **CNAME**
     - **Name/Host**: Enter the host from SendGrid (e.g., `em1234`)
       - ⚠️ **Important**: Just the host part, NOT the full domain
       - If SendGrid says `em1234.projectplanner.us`, just enter `em1234`
     - **Value/Target**: Enter the target from SendGrid (e.g., `u123456.wl123.sendgrid.net`)
     - Click **"Save"** or **"Add"**
   - Repeat for ALL CNAME records from SendGrid

### Method B: Through Netlify DNS Management

If you can't find DNS records in domain settings:

1. **Go to Netlify Dashboard**:
   - Click your profile → **"Site management"** or look for DNS section

2. **Find DNS Management**:
   - Look for **"DNS"** in left sidebar
   - Or search for "DNS" in Netlify dashboard

3. **Add Records**:
   - Same process as Method A above

---

## ⚠️ Important Notes

### Name Format:
- ✅ **Correct**: Host = `em1234`, creates `em1234.projectplanner.us`
- ❌ **Wrong**: Host = `em1234.projectplanner.us` (don't include full domain)

### Value Format:
- ✅ **Correct**: `u123456.wl123.sendgrid.net`
- ❌ **Wrong**: `u123456.wl123.sendgrid.net.` (don't add trailing dot unless required)

### Multiple Records:
- You'll need to add 2-3 CNAME records from SendGrid
- Add each one separately
- Make sure all are added

---

## ⏳ Step 4: Wait for DNS Propagation

1. **Wait Time**: 1-24 hours (usually 1-4 hours)

2. **Verify Records Added**:
   - In Netlify, check your DNS records
   - All CNAME records should be listed
   - They should show as active/valid

3. **Test with DNS Lookup**:
   - Go to: https://www.whatsmydns.net/
   - Enter: `em1234.projectplanner.us` (use your actual SendGrid host)
   - Select: **CNAME**
   - Click Search
   - Should show the SendGrid target

---

## ✅ Step 5: Verify in SendGrid

1. **Go to SendGrid**:
   - Settings → Sender Authentication
   - Find your domain authentication
   - Click **"Verify"** or **"Check DNS"** button

2. **Status Should Show**:
   - ✅ **"Verified"** once DNS propagates
   - ⏳ **"Pending"** or **"Verifying"** while waiting

3. **Check Individual Records**:
   - SendGrid will show which records are found ✅
   - And which are missing ❌
   - Make sure all show as found

---

## 🔄 Step 6: Update Your Code

Once domain is verified in SendGrid:

1. **Open**: `Project Planner/SendGridEmailService.swift`

2. **Update Line 10**:
   ```swift
   private let fromEmail = "noreply@projectplanner.us"
   ```
   Or use:
   ```swift
   private let fromEmail = "info@projectplanner.us"
   ```
   Any email on `projectplanner.us` will work! ✅

---

## 🐛 Troubleshooting

### Problem: Can't Find DNS Settings in Netlify
**Solution**:
- Look for "Domain settings" → "DNS" or "DNS records"
- Or go to Netlify main dashboard → look for "DNS" in sidebar
- If you're on free plan, DNS might be under domain settings only

### Problem: Records Not Saving
**Solution**:
- Make sure you click "Save" or "Add" button
- Don't navigate away before saving
- Refresh page and check if records appear

### Problem: "Invalid Record" Error
**Solution**:
- Check host name is correct (just the part before .projectplanner.us)
- Check value doesn't have trailing dots
- Make sure it's CNAME type, not A or TXT

### Problem: SendGrid Still Shows Missing Records
**Solution**:
- Wait longer (up to 24 hours for DNS propagation)
- Double-check records match exactly what SendGrid provided
- Use DNS lookup tool to verify records exist
- Try clicking "Verify" again in SendGrid

---

## 📋 Quick Checklist

- [ ] Verified domain uses Netlify nameservers
- [ ] Got all CNAME records from SendGrid
- [ ] Added all CNAME records in Netlify DNS
- [ ] Verified records appear in Netlify DNS list
- [ ] Waited for DNS propagation (1-24 hours)
- [ ] Checked records with DNS lookup tool
- [ ] Verified domain in SendGrid dashboard
- [ ] Updated code with verified email address

---

## 🎯 Example: What Records Look Like

**In SendGrid, you'll see:**
```
CNAME Record 1:
Host: em1234
Target: u123456.wl123.sendgrid.net

CNAME Record 2:
Host: s1._domainkey
Target: s1.domainkey.u123456.wl123.sendgrid.net

CNAME Record 3:
Host: s2._domainkey
Target: s2.domainkey.u123456.wl123.sendgrid.net
```

**In Netlify, add them as:**
- Record 1: Name = `em1234`, Value = `u123456.wl123.sendgrid.net`
- Record 2: Name = `s1._domainkey`, Value = `s1.domainkey.u123456.wl123.sendgrid.net`
- Record 3: Name = `s2._domainkey`, Value = `s2.domainkey.u123456.wl123.sendgrid.net`

---

## 🚀 Ready to Start?

1. ✅ Get DNS records from SendGrid (Step 2)
2. ✅ Add them in Netlify DNS (Step 3)
3. ✅ Wait and verify (Steps 4-5)
4. ✅ Update code (Step 6)

Let me know when you've added the records and we can verify they're working! 🔍







