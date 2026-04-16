# 🔧 DNS Records Explained - What Goes Where

## Important: All DNS Records Go in Namecheap!

**Netlify does NOT have DNS records** - they just tell you what to add to Namecheap.

## Where DNS Records Live

### ✅ Namecheap (Your Domain Registrar)
- **This is where ALL DNS records go**
- Controls where `projectplanner.us` points
- You manage this at: namecheap.com → Domain List → projectplanner.us → Advanced DNS

### ❌ Netlify
- **Does NOT have DNS records**
- Only provides instructions on what to add to Namecheap
- You configure the domain in Netlify dashboard, but DNS records go in Namecheap

## What DNS Records You Need

### 1. Website Hosting (Netlify)

**Purpose:** Make `projectplanner.us` point to your Netlify website

**Records to add in Namecheap:**
- **A Record**: `@` → Netlify IP (e.g., `75.2.60.5`)
- **CNAME Record**: `www` → `bespoke-bienenstitch-88f9ea.netlify.app`

**Where to get these:**
- Go to Netlify → Your site → Domain settings → Add custom domain
- Netlify will show you the exact values

### 2. Email Sending (Resend)

**Purpose:** Allow Resend to send emails from `info@projectplanner.us`

**Records to add in Namecheap:**
- **TXT Record**: For domain verification (Resend provides)
- **DKIM Records**: For email authentication (Resend provides)
- **SPF Record**: For email authentication (Resend provides)

**Where to get these:**
- Go to Resend dashboard → Domains → projectplanner.us
- Resend will show you the exact DNS records to add

### 3. Email Receiving (Microsoft 365/Outlook)

**Purpose:** Receive emails sent TO `info@projectplanner.us`

**Records to add in Namecheap:**
- **MX Record**: Points to Microsoft 365 (e.g., `projectplanner-us.mail.protection.outlook.com`)

**Where to get these:**
- From Microsoft 365 admin center → Domains → projectplanner.us

## What to Remove

### ❌ SendGrid DNS Records

**Remove these from Namecheap:**
- Any TXT records mentioning "sendgrid"
- Any CNAME records for SendGrid
- Any SPF records that only mention SendGrid

**Why:** You're using Resend now, not SendGrid

## Complete DNS Setup Checklist

### In Namecheap Advanced DNS:

**Website (Netlify):**
- [ ] A Record: `@` → Netlify IP
- [ ] CNAME: `www` → `bespoke-bienenstitch-88f9ea.netlify.app`

**Email Sending (Resend):**
- [ ] TXT Record: Domain verification (from Resend)
- [ ] CNAME Records: DKIM records (from Resend, usually 2-3 records)
- [ ] TXT Record: SPF record (from Resend)

**Email Receiving (Microsoft 365):**
- [ ] MX Record: Points to Microsoft 365

**Removed:**
- [ ] All SendGrid DNS records removed

## Step-by-Step: Clean Up DNS Records

### Step 1: Check Current DNS Records

1. Go to Namecheap → Domain List → projectplanner.us → Manage → Advanced DNS
2. Look at all current records
3. Identify which are for:
   - Website (Netlify)
   - Email sending (Resend or SendGrid)
   - Email receiving (Microsoft 365)

### Step 2: Remove SendGrid Records

1. Find any records mentioning "sendgrid"
2. Click the trash icon to delete them
3. Common SendGrid records to remove:
   - TXT records with "sendgrid" in the value
   - CNAME records pointing to sendgrid domains
   - SPF records only mentioning SendGrid

### Step 3: Add/Verify Netlify Records

1. Go to Netlify → Your site → Domain settings
2. Add `projectplanner.us` as custom domain (if not already added)
3. Netlify will show you DNS records to add
4. Add these to Namecheap:
   - A Record for `@`
   - CNAME for `www`

### Step 4: Verify Resend Records

1. Go to Resend dashboard → Domains → projectplanner.us
2. Check if domain shows as "Verified"
3. If not verified, Resend will show DNS records to add
4. Add all Resend DNS records to Namecheap

### Step 5: Verify Microsoft 365 MX Record

1. Check if MX record exists for email receiving
2. Should point to: `projectplanner-us.mail.protection.outlook.com` (or similar)
3. If missing, add it from Microsoft 365 admin center

## Common Mistakes

### ❌ Adding DNS records to Netlify
**Correct:** Add DNS records to Namecheap, Netlify just tells you what to add

### ❌ Keeping SendGrid records when using Resend
**Correct:** Remove SendGrid records, add Resend records

### ❌ Conflicting A records
**Correct:** Only one A record for `@` should exist (pointing to Netlify)

### ❌ Missing www CNAME
**Correct:** Add CNAME for `www` pointing to Netlify subdomain

## Quick Reference

**Namecheap DNS Records Needed:**
```
Type    Host    Value
A       @       [Netlify IP]
CNAME   www     bespoke-bienenstitch-88f9ea.netlify.app
MX      @       [Microsoft 365 MX]
TXT     @       [Resend verification]
CNAME   [Resend DKIM 1]
CNAME   [Resend DKIM 2]
TXT     @       [Resend SPF]
```

**What NOT to have:**
- ❌ SendGrid TXT records
- ❌ SendGrid CNAME records
- ❌ Multiple A records for `@`

## Need Help?

If you're unsure about a DNS record:
1. Check what it's for (website, email sending, email receiving)
2. If it mentions "sendgrid" → Remove it
3. If it's for Resend → Keep it
4. If it's for Netlify → Keep it
5. If it's for Microsoft 365 → Keep it


