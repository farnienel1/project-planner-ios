# 🔗 Connect projectplanner.us to Netlify

## Current Situation

✅ **Your website IS deployed on Netlify!**
- Netlify URL: `https://bespoke-bienenstitch-88f9ea.netlify.app`
- Custom domain: `projectplanner.us` (needs to be connected)

## Step 1: Connect Custom Domain in Netlify

1. **Go to Netlify Dashboard:**
   - Visit: [app.netlify.com](https://app.netlify.com)
   - Click on your site (the one with URL `bespoke-bienenstitch-88f9ea.netlify.app`)

2. **Add Custom Domain:**
   - Click **Domain settings** (in the left sidebar)
   - Click **Add custom domain**
   - Enter: `projectplanner.us`
   - Click **Verify**

3. **Netlify will show you DNS records to add:**
   - It will show something like:
     - **A Record**: `@` → `75.2.60.5` (or similar IP)
     - **CNAME**: `www` → `bespoke-bienenstitch-88f9ea.netlify.app`

## Step 2: Add DNS Records in Namecheap

1. **Go to Namecheap:**
   - Log in to [namecheap.com](https://namecheap.com)
   - Go to **Domain List**
   - Click **Manage** next to `projectplanner.us`

2. **Go to Advanced DNS:**
   - Click **Advanced DNS** tab
   - Scroll to **Host Records** section

3. **Add/Update Records:**
   
   **For the root domain (@):**
   - **Type**: A Record
   - **Host**: `@`
   - **Value**: The IP address Netlify provides (e.g., `75.2.60.5`)
   - **TTL**: Automatic (or 30 min)
   - Click **Save**

   **For www subdomain:**
   - **Type**: CNAME Record
   - **Host**: `www`
   - **Value**: `bespoke-bienenstitch-88f9ea.netlify.app`
   - **TTL**: Automatic (or 30 min)
   - Click **Save**

4. **Remove conflicting records:**
   - If you have other A records or CNAME records for `@` or `www`, remove them
   - Only keep the Netlify records

## Step 3: Wait for DNS Propagation

- DNS changes can take **15 minutes to 48 hours** to propagate
- Usually works within **1-2 hours**
- Netlify will automatically issue an SSL certificate once DNS is verified

## Step 4: Verify It's Working

1. **Check Netlify:**
   - Go back to Netlify → Domain settings
   - `projectplanner.us` should show as **"Verified"** (green checkmark)
   - SSL certificate should show as **"Active"**

2. **Test the website:**
   - Visit: `https://projectplanner.us`
   - Should show the same content as the Netlify subdomain
   - Visit: `https://projectplanner.us/setup-password.html`
   - Should show the password setup form

## Important Notes

### Both URLs Will Work

Once configured:
- ✅ `https://bespoke-bienenstitch-88f9ea.netlify.app` (Netlify subdomain - always works)
- ✅ `https://projectplanner.us` (Custom domain - works after DNS setup)

### Email Links Are Already Correct

The iOS app email links already use `https://projectplanner.us`, so once DNS is configured, everything will work!

### If DNS Takes Too Long

If you need to test immediately:
- Use the Netlify subdomain: `https://bespoke-bienenstitch-88f9ea.netlify.app/setup-password.html`
- But update email links temporarily (I can help with this if needed)

## Troubleshooting

### ❌ "Domain not verified" in Netlify
**Fix:** 
- Double-check DNS records in Namecheap
- Make sure you're using the exact IP/CNAME Netlify provides
- Wait for DNS propagation (can take up to 48 hours)

### ❌ "SSL certificate pending"
**Fix:**
- Wait for DNS to fully propagate
- Netlify automatically issues SSL once DNS is verified
- Can take a few hours after DNS is verified

### ❌ projectplanner.us shows different content
**Fix:**
- Make sure DNS records point to Netlify
- Clear browser cache
- Try incognito/private browsing mode

## Quick Checklist

- [ ] Added `projectplanner.us` as custom domain in Netlify
- [ ] Added A record for `@` in Namecheap
- [ ] Added CNAME record for `www` in Namecheap
- [ ] Removed conflicting DNS records
- [ ] Waited for DNS propagation (15 min - 48 hours)
- [ ] Verified domain shows as "Verified" in Netlify
- [ ] Tested `https://projectplanner.us` works
- [ ] Tested `https://projectplanner.us/setup-password.html` works

Once all checked, your website will be fully functional at `projectplanner.us`! 🎉


