# DNS Troubleshooting Guide - projectplanner.us

## Why DNS is Still "Propagating" After 48 Hours

If Netlify shows "DNS propagating" for more than 24-48 hours, there's usually a configuration issue.

## Step-by-Step Troubleshooting

### 1. Check Your Domain Registrar (Namecheap/GoDaddy/etc.)

**Go to your domain registrar's DNS settings and verify:**

#### Option A: Using Netlify's Nameservers (RECOMMENDED - Easiest)
1. In Netlify → Domain settings → projectplanner.us
2. Look for "Use Netlify DNS" or "Change nameservers"
3. Netlify will show you nameservers like:
   ```
   dns1.p01.nsone.net
   dns2.p01.nsone.net
   dns3.p01.nsone.net
   dns4.p01.nsone.net
   ```
4. Go to your domain registrar (Namecheap, etc.)
5. Find "Nameservers" or "DNS" settings
6. Change from "Default" to "Custom"
7. Enter the 4 nameservers Netlify provided
8. Save and wait 1-24 hours

**This is the EASIEST method - Netlify manages all DNS automatically!**

#### Option B: Using A Records (Manual DNS)
If you're using A records instead of nameservers:

1. **In Netlify:**
   - Go to Domain settings → projectplanner.us
   - Click "DNS" tab
   - Note the IP addresses shown (usually 4 A records)

2. **In Your Domain Registrar:**
   - Go to DNS/Advanced DNS settings
   - Delete any old A records for `@` or root domain
   - Add NEW A records:
     ```
     Type: A
     Name: @ (or leave blank for root)
     Value: 75.2.60.5
     TTL: Automatic (or 3600)
     
     Type: A
     Name: @
     Value: 99.83.190.102
     TTL: Automatic
     
     (Add all 4 IPs Netlify shows)
     ```

3. **Remove conflicting records:**
   - Delete any CNAME records for `@` (root domain can't use CNAME)
   - Delete any old A records pointing to different IPs

### 2. Verify DNS Records Are Correct

**Use online DNS checker tools:**

1. Go to: https://dnschecker.org
2. Enter: `projectplanner.us`
3. Select: "A" record type
4. Check if the IPs match Netlify's IPs

**Or use terminal:**
```bash
dig projectplanner.us
nslookup projectplanner.us
```

**Expected result:** Should show Netlify's IP addresses (75.2.60.5, 99.83.190.102, etc.)

### 3. Common Issues

#### Issue: Wrong Nameservers
**Symptom:** DNS checker shows different nameservers than Netlify
**Fix:** Update nameservers at your registrar to match Netlify's

#### Issue: Old DNS Records
**Symptom:** DNS checker shows old IP addresses
**Fix:** Delete old A records and add new ones from Netlify

#### Issue: CNAME on Root Domain
**Symptom:** Registrar shows CNAME for `@` (root domain)
**Fix:** Root domain MUST use A records, not CNAME. Delete CNAME and use A records.

#### Issue: DNS Caching
**Symptom:** Some tools show correct IPs, others don't
**Fix:** Wait 24-48 hours for global DNS propagation. This is normal.

### 4. Quick Fix: Use Netlify's Nameservers

**This is the FASTEST solution:**

1. **In Netlify:**
   - Site settings → Domain management → projectplanner.us
   - Click "DNS" tab
   - Look for "Use Netlify DNS" or "Change nameservers"
   - Copy the 4 nameservers shown

2. **In Namecheap (or your registrar):**
   - Domain List → projectplanner.us → Manage
   - Go to "Nameservers" section
   - Select "Custom DNS"
   - Enter the 4 nameservers from Netlify
   - Save

3. **Wait 1-24 hours** for nameserver propagation

**Benefits:**
- Netlify manages all DNS automatically
- SSL certificates work automatically
- No manual A record management
- Faster setup

### 5. Verify It's Working

**After updating DNS, check:**

1. **DNS Propagation:**
   - https://dnschecker.org/#A/projectplanner.us
   - Should show Netlify IPs globally within 24 hours

2. **Netlify Status:**
   - Netlify dashboard should show "DNS verified" (green checkmark)
   - SSL certificate should auto-generate

3. **Website Access:**
   - Visit: `https://projectplanner.us`
   - Should load your website (not show "propagating")

### 6. Still Not Working?

**Contact Netlify Support:**
1. Go to: https://app.netlify.com/support
2. Explain: "DNS still showing as propagating after 48 hours"
3. Include:
   - Your domain: projectplanner.us
   - Your registrar: (Namecheap/GoDaddy/etc.)
   - Screenshot of DNS settings

**Or check Netlify status:**
- https://www.netlifystatus.com
- Check for any DNS-related outages

## Expected Timeline

- **Nameserver change:** 1-24 hours
- **A record change:** 1-48 hours (usually faster)
- **Global propagation:** 24-48 hours maximum

**If it's been 48+ hours, there's definitely a configuration issue!**

## Next Steps

1. ✅ Check if you're using nameservers OR A records (pick one!)
2. ✅ Verify DNS records match Netlify's requirements
3. ✅ Use DNS checker tools to verify propagation
4. ✅ Contact Netlify support if still stuck

---

**Remember:** The React/Next.js vulnerability notice does NOT apply to your website - you're using static HTML/JavaScript, not React!


