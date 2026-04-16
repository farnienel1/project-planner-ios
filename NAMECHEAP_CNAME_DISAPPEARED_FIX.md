# 🔧 Namecheap CNAME Records Disappeared - Troubleshooting Guide

## 🚨 Why CNAME Records Disappear in Namecheap

### Common Causes:
1. ✅ **DNS propagation delay** - Records added but not showing yet
2. ✅ **Wrong DNS section** - Added to wrong area
3. ✅ **DNS conflict** - Conflicting records exist
4. ✅ **Namecheap caching** - Dashboard not refreshing
5. ✅ **Nameserver issue** - Using external nameservers

---

## 🔍 Step 1: Check Where You Added Records

### Option A: Advanced DNS Tab (Correct)
1. **Navigate to**:
   - Domain List → projectplanner.us → Manage
   - **Advanced DNS** tab
   - Look in "Host Records" section

### Option B: Check All DNS Sections
Sometimes records appear in different places:
1. **Advanced DNS** → Host Records
2. **DNS** tab (if different from Advanced DNS)
3. **Nameservers** section (shouldn't be here)

---

## 🔄 Step 2: Refresh and Check Again

1. **Refresh Browser**:
   - Hard refresh: Cmd+Shift+R (Mac) or Ctrl+Shift+R (Windows)
   - Or close and reopen the Advanced DNS page

2. **Wait a Few Minutes**:
   - Sometimes Namecheap dashboard takes time to update
   - Records might appear after a few minutes

3. **Log Out and Back In**:
   - Log out of Namecheap
   - Log back in
   - Check Advanced DNS again

---

## 🎯 Step 3: Check Nameserver Settings

**Important**: If your domain uses external nameservers, you need to add DNS records where those nameservers are managed, NOT in Namecheap!

### Check Your Nameservers:
1. **In Namecheap**:
   - Domain List → projectplanner.us → Manage
   - Click **"Nameservers"** section
   - Check what it shows:
     - ✅ **Namecheap BasicDNS** or **Namecheap Web Hosting DNS** = Add records in Namecheap
     - ⚠️ **Custom DNS** or other nameservers = Add records where those nameservers point to

2. **If Using Custom Nameservers**:
   - Find out where they're managed (Cloudflare, Netlify, etc.)
   - Add CNAME records there instead
   - Namecheap won't show those records

---

## ➕ Step 4: Add Records Again (If They're Really Gone)

If records are definitely gone, add them again:

1. **Go to Advanced DNS**:
   - Domain List → projectplanner.us → Manage → Advanced DNS

2. **Add Each CNAME Record**:
   - Click **"Add New Record"** button
   - **Type**: Select **CNAME Record**
   - **Host**: Enter the name from SendGrid (e.g., `em1234`)
   - **Value**: Enter the target from SendGrid (e.g., `u123456.wl123.sendgrid.net`)
   - **TTL**: Select "30 min" or "Automatic"
   - Click the **checkmark** (✓) to save
   - ⚠️ **Important**: Make sure you click save/checkmark - records won't save if you navigate away

3. **Verify Each Record Saved**:
   - After adding each record, it should appear in the list below
   - If it doesn't appear, try refreshing the page

---

## 🐛 Step 5: Common Issues & Fixes

### Issue: Records Save But Don't Appear
**Fix**:
- Refresh the page
- Check if you're in the right domain (make sure it's projectplanner.us)
- Wait 5-10 minutes and check again

### Issue: "Record Already Exists" Error
**Fix**:
- The record might actually be there but not visible
- Try refreshing or checking with a DNS lookup tool
- Use: https://www.whatsmydns.net/#CNAME/em1234.projectplanner.us
- Replace `em1234` with your actual SendGrid CNAME host

### Issue: Records Keep Disappearing
**Fix**:
- Check if you have multiple people/accounts managing DNS
- Someone else might be deleting them
- Check Namecheap account activity/logs

---

## 🔍 Step 6: Verify Records Actually Exist

Even if they don't show in Namecheap dashboard, they might exist:

1. **Use DNS Lookup Tool**:
   - Go to: https://www.whatsmydns.net/
   - Or: https://dnschecker.org/
   - Enter: `em1234.projectplanner.us` (use your actual SendGrid CNAME host)
   - Select **CNAME** record type
   - Click "Search"
   - If records exist, they'll show up here

2. **Command Line Check** (if you're comfortable):
   ```bash
   dig CNAME em1234.projectplanner.us
   ```
   - Replace `em1234` with your actual SendGrid CNAME host

---

## ✅ Step 7: Verify in SendGrid

1. **Go to SendGrid**:
   - Settings → Sender Authentication
   - Find your domain authentication
   - Click **"Verify"** or **"Check DNS"** button

2. **SendGrid Will Show**:
   - Which records are found ✅
   - Which records are missing ❌
   - This tells you if records actually exist

---

## 🚀 Quick Fix: Start Fresh

If nothing is working:

1. **Clear All SendGrid DNS Records** (if any exist):
   - Remove any CNAME records related to SendGrid from Namecheap
   - Start clean

2. **Get Fresh Records from SendGrid**:
   - Go to SendGrid → Settings → Sender Authentication
   - Either:
     - Delete existing domain authentication and create new one
     - Or just view the DNS records again (they should be the same)

3. **Add Records One at a Time**:
   - Add first CNAME record
   - Refresh page to verify it saved
   - Then add next one
   - Repeat for all records

4. **Wait 5 Minutes**:
   - After adding all records
   - Wait 5 minutes
   - Check again in Advanced DNS
   - Check with DNS lookup tool

---

## 📋 Checklist

- [ ] Checked Advanced DNS tab in Namecheap
- [ ] Refreshed browser and page
- [ ] Checked nameserver settings (using Namecheap DNS?)
- [ ] Verified records with DNS lookup tool
- [ ] Checked SendGrid verification status
- [ ] Added records one at a time and verified each saved
- [ ] Waited a few minutes after adding records

---

## 🆘 Still Not Working?

Tell me:
1. ✅ **What nameservers are you using?** (Namecheap BasicDNS or Custom?)
2. ✅ **Do records show in DNS lookup tools?** (Check whatsmydns.net)
3. ✅ **What does SendGrid verification show?** (Which records are found/missing?)
4. ✅ **Can you see ANY CNAME records in Advanced DNS?** (Or are all records missing?)

This will help me diagnose the exact issue! 🔍







