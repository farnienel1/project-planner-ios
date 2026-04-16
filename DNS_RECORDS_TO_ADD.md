# 📋 DNS Records to Add/Remove in Namecheap

Based on your current DNS records, here's what you need to do:

## ✅ KEEP These Records (Already Correct)

### Website Hosting (Netlify)
- ✅ `projectplanner.us` → `bespoke-bienenstitch-88f9ea.netlify.app` (NETLIFY type - this is correct)
- ✅ `www.projectplanner.us` → `bespoke-bienenstitch-88f9ea.netlify.app` (NETLIFY type - this is correct)

### Email Receiving (Microsoft 365)
- ✅ `projectplanner.us` → MX → `projectplanner-us.mail.protection.outlook.com`
- ✅ `autodiscover.projectplanner.us` → CNAME → `autodiscover.outlook.com`

## ❌ REMOVE These Records (SendGrid - Not Used Anymore)

1. ❌ `em6301.projectplanner.us` → CNAME → `u56462991.wl242.sendgrid.net`
2. ❌ `s1._domainkey.projectplanner.us` → CNAME → `s1.domainkey.u56462991.wl242.sendgrid.net`
3. ❌ `s2._domainkey.projectplanner.us` → CNAME → `s2.domainkey.u56462991.wl242.sendgrid.net`

## ⚠️ UPDATE This Record (SPF - Add Resend)

**Current SPF Record:**
```
projectplanner.us → TXT → v=spf1 include:spf.protection.outlook.com -all
```

**Updated SPF Record (to include Resend):**
```
projectplanner.us → TXT → v=spf1 include:spf.protection.outlook.com include:resend.com -all
```

**OR if Resend provides a specific SPF record, use that instead.**

## ➕ ADD These Records (Resend - For Email Sending)

You need to get these from Resend dashboard:

1. **Go to Resend Dashboard:**
   - Visit: https://resend.com
   - Click **Domains** in sidebar
   - Find `projectplanner.us`
   - Click **View DNS Records** or **Verify**

2. **Resend will show you DNS records to add:**
   - Usually includes:
     - **TXT Record** for domain verification
     - **CNAME Records** for DKIM (usually 2-3 records like `resend._domainkey.projectplanner.us`)
     - **TXT Record** for SPF (or update existing SPF)

3. **Add all Resend DNS records to Namecheap**

## Step-by-Step Instructions

### Step 1: Remove SendGrid Records

1. Go to Namecheap → Domain List → `projectplanner.us` → Manage → Advanced DNS
2. Find and delete these 3 records:
   - `em6301.projectplanner.us` (CNAME)
   - `s1._domainkey.projectplanner.us` (CNAME)
   - `s2._domainkey.projectplanner.us` (CNAME)
3. Click **Save** after deleting each one

### Step 2: Update SPF Record

1. In Namecheap Advanced DNS, find the TXT record:
   - `projectplanner.us` → TXT → `v=spf1 include:spf.protection.outlook.com -all`
2. Click **Edit** (pencil icon)
3. Update the value to include Resend:
   - Change to: `v=spf1 include:spf.protection.outlook.com include:resend.com -all`
   - **OR** use the exact SPF value Resend provides (if different)
4. Click **Save**

### Step 3: Add Resend DNS Records

1. **Get DNS records from Resend:**
   - Go to Resend dashboard → Domains → `projectplanner.us`
   - Click **View DNS Records** or check verification status
   - Copy all DNS records Resend shows

2. **Add to Namecheap:**
   - In Namecheap Advanced DNS, click **Add New Record**
   - Add each record Resend provides:
     - **TXT records** for verification/SPF
     - **CNAME records** for DKIM (usually start with `resend._domainkey` or similar)
   - Click **Save** after adding each record

### Step 4: Verify Everything

**In Namecheap, you should have:**

✅ **Website (Netlify):**
- `projectplanner.us` → NETLIFY → `bespoke-bienenstitch-88f9ea.netlify.app`
- `www.projectplanner.us` → NETLIFY → `bespoke-bienenstitch-88f9ea.netlify.app`

✅ **Email Receiving (Microsoft 365):**
- `projectplanner.us` → MX → `projectplanner-us.mail.protection.outlook.com`
- `autodiscover.projectplanner.us` → CNAME → `autodiscover.outlook.com`

✅ **Email Sending (Resend):**
- `projectplanner.us` → TXT → [Resend verification record]
- `resend._domainkey.projectplanner.us` → CNAME → [Resend DKIM record] (or similar)
- Additional Resend CNAME records as provided

✅ **Email Sending (SPF - Updated):**
- `projectplanner.us` → TXT → `v=spf1 include:spf.protection.outlook.com include:resend.com -all`

❌ **Removed:**
- All SendGrid records (em6301, s1._domainkey, s2._domainkey)

## Quick Checklist

- [ ] Removed 3 SendGrid CNAME records from Namecheap
- [ ] Updated SPF TXT record to include Resend
- [ ] Got DNS records from Resend dashboard
- [ ] Added all Resend DNS records to Namecheap
- [ ] Verified Resend domain shows "Verified" in Resend dashboard
- [ ] Verified Netlify domain shows "Verified" in Netlify dashboard
- [ ] Tested website: `https://projectplanner.us`
- [ ] Tested email sending from iOS app

## After Making Changes

1. **Wait 15 minutes to 2 hours** for DNS propagation
2. **Check Resend dashboard** - domain should show "Verified" ✅
3. **Check Netlify dashboard** - domain should show "Verified" ✅
4. **Test email sending** from iOS app

## Need Help Getting Resend DNS Records?

1. Go to: https://resend.com
2. Log in
3. Click **Domains** in sidebar
4. Find `projectplanner.us`
5. Click on it or click **View DNS Records**
6. Copy all records shown
7. Add them to Namecheap

If Resend shows the domain as already verified, you might already have the records - just make sure they're in Namecheap and not SendGrid records!


