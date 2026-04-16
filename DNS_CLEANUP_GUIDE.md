# 🧹 DNS Records Cleanup Guide

## Important Clarification

**Netlify does NOT have DNS records!**
- Netlify just tells you what DNS records to add
- All DNS records go in **Namecheap** (your domain registrar)
- You cannot add/remove DNS records in Netlify

## Where Everything Goes

### ✅ Namecheap (Domain Registrar)
- **ALL DNS records go here**
- This is where you manage DNS for `projectplanner.us`
- Location: namecheap.com → Domain List → projectplanner.us → Advanced DNS

### ❌ Netlify
- **Does NOT have DNS records**
- Only provides instructions on what to add to Namecheap
- You configure the domain in Netlify dashboard, but DNS records go in Namecheap

## What You Need to Do

### Step 1: Remove SendGrid DNS Records from Namecheap

1. **Go to Namecheap:**
   - Log in to [namecheap.com](https://namecheap.com)
   - Go to **Domain List**
   - Click **Manage** next to `projectplanner.us`
   - Click **Advanced DNS** tab

2. **Find and Remove SendGrid Records:**
   - Look for any records mentioning "sendgrid"
   - Common SendGrid records to remove:
     - **TXT records** with "sendgrid" in the value
     - **CNAME records** pointing to sendgrid domains (e.g., `sendgrid.net`)
     - **SPF records** that only mention SendGrid
   - Click the **trash icon** to delete each one

3. **What SendGrid records look like:**
   ```
   Type: TXT
   Host: @
   Value: v=spf1 include:sendgrid.net ~all
   
   Type: CNAME
   Host: [something]
   Value: [something].sendgrid.net
   ```

### Step 2: Keep/Add Resend DNS Records in Namecheap

1. **Check Resend Dashboard:**
   - Go to [resend.com](https://resend.com)
   - Click **Domains** in sidebar
   - Find `projectplanner.us`
   - Check if it shows "Verified" ✅

2. **If Not Verified:**
   - Resend will show DNS records to add
   - Add these to **Namecheap** (not Netlify!)
   - Usually includes:
     - TXT record for domain verification
     - CNAME records for DKIM (usually 2-3 records)
     - TXT record for SPF

3. **Verify in Namecheap:**
   - Make sure all Resend DNS records are present
   - They should NOT mention "sendgrid"

### Step 3: Add Netlify DNS Records to Namecheap

1. **Get DNS Records from Netlify:**
   - Go to [app.netlify.com](https://app.netlify.com)
   - Click your site (`bespoke-bienenstitch-88f9ea`)
   - Click **Domain settings**
   - Add `projectplanner.us` as custom domain (if not already added)
   - Netlify will show you DNS records to add

2. **Add to Namecheap:**
   - Go to Namecheap → Domain List → projectplanner.us → Advanced DNS
   - Add these records:
     - **A Record**: `@` → [Netlify IP address]
     - **CNAME Record**: `www` → `bespoke-bienenstitch-88f9ea.netlify.app`

### Step 4: Keep Microsoft 365 MX Record

1. **Check for MX Record:**
   - In Namecheap Advanced DNS
   - Look for MX record pointing to Microsoft 365
   - Should be something like: `projectplanner-us.mail.protection.outlook.com`
   - **Keep this** - it's for receiving emails

## Complete DNS Records Checklist

### In Namecheap Advanced DNS, you should have:

**Website (Netlify):**
- ✅ A Record: `@` → [Netlify IP]
- ✅ CNAME: `www` → `bespoke-bienenstitch-88f9ea.netlify.app`

**Email Sending (Resend):**
- ✅ TXT Record: Domain verification (from Resend)
- ✅ CNAME Records: DKIM records (from Resend, usually 2-3)
- ✅ TXT Record: SPF record (from Resend)

**Email Receiving (Microsoft 365):**
- ✅ MX Record: Points to Microsoft 365

**Removed:**
- ❌ All SendGrid DNS records (removed)

## Step-by-Step Cleanup

### 1. Open Namecheap Advanced DNS
- Go to: namecheap.com → Domain List → projectplanner.us → Manage → Advanced DNS

### 2. List All Current Records
- Write down or screenshot all current DNS records
- Note which are for:
  - Website (Netlify)
  - Email sending (Resend/SendGrid)
  - Email receiving (Microsoft 365)

### 3. Remove SendGrid Records
- Find any record with "sendgrid" in the value
- Delete it (click trash icon)
- Common ones:
  - SPF records mentioning sendgrid.net
  - CNAME records pointing to sendgrid.net
  - TXT records for SendGrid verification

### 4. Verify Resend Records
- Check Resend dashboard → Domains → projectplanner.us
- If not verified, add missing DNS records to Namecheap
- Make sure all Resend records are present

### 5. Add Netlify Records
- Get DNS records from Netlify dashboard
- Add A record for `@` (root domain)
- Add CNAME for `www`
- Make sure no conflicting records exist

### 6. Verify MX Record
- Check MX record exists for Microsoft 365
- Should point to: `projectplanner-us.mail.protection.outlook.com` (or similar)

## Common Mistakes to Avoid

### ❌ Trying to add DNS records in Netlify
**Correct:** Add DNS records in Namecheap, Netlify just tells you what to add

### ❌ Keeping SendGrid records when using Resend
**Correct:** Remove all SendGrid records, keep only Resend records

### ❌ Multiple A records for `@`
**Correct:** Only one A record for `@` should exist (pointing to Netlify)

### ❌ Removing Microsoft 365 MX record
**Correct:** Keep the MX record - it's for receiving emails

## Quick Reference: What Each Record Does

| Record Type | Host | Purpose | Where to Get |
|------------|------|---------|--------------|
| A | @ | Website hosting (Netlify) | Netlify dashboard |
| CNAME | www | Website hosting (Netlify) | Netlify dashboard |
| MX | @ | Email receiving (Microsoft 365) | Microsoft 365 admin |
| TXT | @ | Email sending (Resend SPF) | Resend dashboard |
| CNAME | [Resend DKIM] | Email sending (Resend DKIM) | Resend dashboard |
| TXT | @ | Email sending (Resend verification) | Resend dashboard |

## After Cleanup

Once you've cleaned up DNS records:
1. ✅ Wait 15 minutes to 2 hours for DNS propagation
2. ✅ Check Resend dashboard - domain should show "Verified"
3. ✅ Check Netlify dashboard - domain should show "Verified"
4. ✅ Test website: `https://projectplanner.us`
5. ✅ Test email sending from iOS app

## Need Help?

If you're unsure about a DNS record:
1. **Check the value** - does it mention "sendgrid"? → Remove it
2. **Check the purpose** - is it for website, email sending, or email receiving?
3. **Check the source** - where did you get this record from?
4. **When in doubt** - keep it for now, we can verify later


