# 📊 Complete DNS Records Table for Namecheap

## Important Note
**All DNS records are in Namecheap** - Netlify doesn't have DNS records. The CSV you sent shows what's currently in Namecheap.

## Current DNS Records (From Your CSV)

| Action | Host/Name | Type | Value | Purpose | Status |
|--------|-----------|------|-------|---------|--------|
| ✅ **KEEP** | `projectplanner.us` | NETLIFY | `bespoke-bienenstitch-88f9ea.netlify.app` | Website hosting | Keep as-is |
| ✅ **KEEP** | `www.projectplanner.us` | NETLIFY | `bespoke-bienenstitch-88f9ea.netlify.app` | Website hosting | Keep as-is |
| ❌ **DELETE** | `em6301.projectplanner.us` | CNAME | `u56462991.wl242.sendgrid.net` | SendGrid (old) | Delete |
| ❌ **DELETE** | `s1._domainkey.projectplanner.us` | CNAME | `s1.domainkey.u56462991.wl242.sendgrid.net` | SendGrid DKIM (old) | Delete |
| ❌ **DELETE** | `s2._domainkey.projectplanner.us` | CNAME | `s2.domainkey.u56462991.wl242.sendgrid.net` | SendGrid DKIM (old) | Delete |
| ⚠️ **UPDATE** | `projectplanner.us` | TXT | `v=spf1 include:spf.protection.outlook.com -all` | SPF (email auth) | Update to include Resend |
| ✅ **KEEP** | `projectplanner.us` | MX | `projectplanner-us.mail.protection.outlook.com` | Email receiving | Keep as-is |
| ✅ **KEEP** | `autodiscover.projectplanner.us` | CNAME | `autodiscover.outlook.com` | Microsoft 365 autodiscover | Keep as-is |

## Final DNS Records (What Should Be in Namecheap)

| Host/Name | Type | Value | Purpose | Source |
|-----------|------|-------|---------|--------|
| `projectplanner.us` | NETLIFY | `bespoke-bienenstitch-88f9ea.netlify.app` | Website hosting | Keep existing |
| `www.projectplanner.us` | NETLIFY | `bespoke-bienenstitch-88f9ea.netlify.app` | Website hosting | Keep existing |
| `projectplanner.us` | TXT | `v=spf1 include:spf.protection.outlook.com include:resend.com -all` | SPF (email auth) | Update existing |
| `projectplanner.us` | MX | `projectplanner-us.mail.protection.outlook.com` | Email receiving | Keep existing |
| `autodiscover.projectplanner.us` | CNAME | `autodiscover.outlook.com` | Microsoft 365 autodiscover | Keep existing |
| `[Resend verification]` | TXT | `[Value from Resend]` | Resend domain verification | **ADD from Resend** |
| `resend._domainkey.projectplanner.us` | CNAME | `[Value from Resend]` | Resend DKIM | **ADD from Resend** |
| `[Additional Resend records]` | CNAME/TXT | `[Values from Resend]` | Resend email auth | **ADD from Resend** |

## Action Summary

### ✅ Keep (No Changes Needed)
- `projectplanner.us` → NETLIFY → `bespoke-bienenstitch-88f9ea.netlify.app`
- `www.projectplanner.us` → NETLIFY → `bespoke-bienenstitch-88f9ea.netlify.app`
- `projectplanner.us` → MX → `projectplanner-us.mail.protection.outlook.com`
- `autodiscover.projectplanner.us` → CNAME → `autodiscover.outlook.com`

### ❌ Delete (SendGrid - No Longer Used)
- `em6301.projectplanner.us` → CNAME → `u56462991.wl242.sendgrid.net`
- `s1._domainkey.projectplanner.us` → CNAME → `s1.domainkey.u56462991.wl242.sendgrid.net`
- `s2._domainkey.projectplanner.us` → CNAME → `s2.domainkey.u56462991.wl242.sendgrid.net`

### ⚠️ Update (Add Resend to SPF)
**Current:**
```
projectplanner.us → TXT → v=spf1 include:spf.protection.outlook.com -all
```

**Updated:**
```
projectplanner.us → TXT → v=spf1 include:spf.protection.outlook.com include:resend.com -all
```

### ➕ Add (Get from Resend Dashboard)
1. Go to: https://resend.com → Domains → `projectplanner.us`
2. Copy all DNS records Resend shows
3. Add them to Namecheap

**Typical Resend records include:**
- TXT record for domain verification
- CNAME records for DKIM (usually `resend._domainkey.projectplanner.us` or similar)
- May include additional TXT/CNAME records

## Step-by-Step Instructions

### Step 1: Delete SendGrid Records
In Namecheap → Domain List → `projectplanner.us` → Manage → Advanced DNS:

1. Find and delete: `em6301.projectplanner.us` (CNAME)
2. Find and delete: `s1._domainkey.projectplanner.us` (CNAME)
3. Find and delete: `s2._domainkey.projectplanner.us` (CNAME)

### Step 2: Update SPF Record
1. Find the TXT record: `projectplanner.us` → `v=spf1 include:spf.protection.outlook.com -all`
2. Click **Edit** (pencil icon)
3. Change value to: `v=spf1 include:spf.protection.outlook.com include:resend.com -all`
4. Click **Save**

### Step 3: Add Resend Records
1. Go to Resend dashboard → Domains → `projectplanner.us`
2. Click **View DNS Records** or check verification status
3. Copy all DNS records shown
4. In Namecheap, click **Add New Record** for each one
5. Add all Resend records (TXT and CNAME)
6. Click **Save** after each

## Final Checklist

After all changes, verify you have:

- [ ] ✅ 2 NETLIFY records (website) - kept
- [ ] ✅ 1 MX record (Microsoft 365) - kept
- [ ] ✅ 1 autodiscover CNAME (Microsoft 365) - kept
- [ ] ✅ 1 updated SPF TXT (includes Resend) - updated
- [ ] ✅ Resend DNS records - added
- [ ] ❌ No SendGrid records - all 3 deleted

## Quick Reference: What Each Record Does

| Record | Purpose |
|--------|---------|
| NETLIFY records | Makes `projectplanner.us` point to your Netlify website |
| MX record | Receives emails sent TO `info@projectplanner.us` (goes to Outlook) |
| Autodiscover CNAME | Helps email clients find Microsoft 365 settings |
| SPF TXT | Authorizes who can send emails FROM `projectplanner.us` |
| Resend records | Allows Resend to send emails FROM `info@projectplanner.us` |

## Need Help Getting Resend Records?

1. Visit: https://resend.com
2. Log in
3. Click **Domains** in sidebar
4. Find `projectplanner.us`
5. Click on it or **View DNS Records**
6. Copy all records shown
7. Add them to Namecheap

---

**Remember:** All DNS records go in **Namecheap**, not Netlify. Netlify just tells you what to add, but the records themselves are managed in Namecheap.


