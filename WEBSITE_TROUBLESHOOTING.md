# 🔧 Troubleshooting: projectplanner.us Not Working

## Quick Checks

### 1. Is the Site Deployed on Netlify?

1. Go to [app.netlify.com](https://app.netlify.com)
2. Log in
3. Check if you see a site for "Project Planner"
4. Check the **Deploys** tab - is there a successful deployment?

**If no site exists:**
- You need to deploy the website (see Step 2 below)

**If site exists but shows errors:**
- Check the deployment logs
- Look for build errors or missing files

### 2. Is DNS Configured Correctly?

1. Go to Netlify dashboard → Your site → **Domain settings**
2. Check if `projectplanner.us` is listed as a custom domain
3. If not listed:
   - Click **Add custom domain**
   - Enter: `projectplanner.us`
   - Follow DNS setup instructions

4. **Check DNS Records:**
   - Go to where you manage DNS (Namecheap, etc.)
   - Verify these records exist:
     - **A Record**: `@` → Netlify IP (Netlify will provide)
     - **CNAME**: `www` → `your-site.netlify.app`
   - DNS changes can take 24-48 hours to propagate

### 3. Test the Website Directly

**Test Netlify subdomain first:**
1. In Netlify dashboard, find your site's Netlify URL (e.g., `https://something-123.netlify.app`)
2. Visit: `https://your-netlify-url.netlify.app/setup-password.html`
3. Does it work?

**If Netlify URL works but projectplanner.us doesn't:**
- DNS issue - wait for DNS propagation or check DNS records

**If Netlify URL doesn't work:**
- Deployment issue - see Step 4 below

### 4. Redeploy Website Files

**If website isn't working at all:**

1. **On your Mac:**
   - Go to: `Desktop > Project Planner > website`
   - Select ALL files (Cmd+A)
   - Right-click → **Compress X items**

2. **In Netlify:**
   - Go to your site → **Deploys** tab
   - Drag ZIP file into deploy area
   - OR click **Deploy manually** → Select ZIP
   - Wait for deployment

3. **Verify files are deployed:**
   - Check Netlify → **Deploys** → Latest deploy → **Published files**
   - Should see: `index.html`, `setup-password.html`, etc.

### 5. Check Browser Console for Errors

1. Visit: `https://projectplanner.us/setup-password.html`
2. Open browser console (F12 or Cmd+Option+I)
3. Look for errors:
   - **Red errors** = JavaScript/Firebase issues
   - **404 errors** = Missing files
   - **CORS errors** = Security/header issues

### 6. Common Issues & Fixes

#### ❌ "Site not found" or "This site can't be reached"
**Possible causes:**
- DNS not configured
- Domain not connected to Netlify
- DNS propagation delay (wait 24-48 hours)

**Fix:**
1. Check Netlify → Domain settings
2. Verify DNS records in your domain registrar
3. Wait for DNS propagation

#### ❌ "404 Not Found" when visiting setup-password.html
**Possible causes:**
- File not deployed
- Wrong file path
- Netlify redirects misconfigured

**Fix:**
1. Check Netlify → Published files
2. Verify `setup-password.html` exists
3. Check `netlify.toml` redirects

#### ❌ Page loads but shows "Firebase error" or blank
**Possible causes:**
- Firebase config incorrect
- Firestore rules blocking access
- JavaScript errors

**Fix:**
1. Check browser console (F12) for errors
2. Verify Firebase config in `setup-password.html`
3. Check Firestore security rules

#### ❌ "Invalid invitation code" error
**Possible causes:**
- Firestore rules blocking invitation reads
- Invitation code doesn't exist
- Invitation expired (7 days)

**Fix:**
1. Check Firestore rules allow reading invitations:
   ```javascript
   match /invitations/{invitationId} {
     allow read: if true;
   }
   ```
2. Verify invitation exists in Firestore
3. Check invitation hasn't expired

## Step-by-Step Fix

### If Website Completely Not Working:

1. **Check Netlify Dashboard:**
   - Is site deployed? → If no, deploy (Step 4 above)
   - Are there errors? → Check deployment logs

2. **Test Netlify Subdomain:**
   - Visit: `https://your-site.netlify.app/setup-password.html`
   - Does it work? → If yes, DNS issue. If no, deployment issue.

3. **Redeploy:**
   - Follow Step 4 above to redeploy files

4. **Check DNS:**
   - Verify `projectplanner.us` points to Netlify
   - Wait for DNS propagation (can take 24-48 hours)

5. **Test Again:**
   - Visit: `https://projectplanner.us/setup-password.html`
   - Check browser console for errors
   - Try with a test invitation code

## What to Tell Me

If it's still not working, tell me:
1. ✅ What happens when you visit `https://projectplanner.us`?
2. ✅ What happens when you visit `https://projectplanner.us/setup-password.html`?
3. ✅ Any errors in browser console (F12)?
4. ✅ What's your Netlify site URL (the .netlify.app one)?
5. ✅ Is the site deployed in Netlify dashboard?

Then I can help fix the specific issue!


