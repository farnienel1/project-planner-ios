# 🚀 Quick Fix: Project Planner Website on Netlify

## Step 1: Check Your Netlify Site

1. Go to [app.netlify.com](https://app.netlify.com)
2. Log in
3. Find your "Project Planner" site
4. **What's the site URL?**
   - Is it: `https://projectplanner.us` (custom domain)?
   - Or: `https://something-123.netlify.app` (Netlify subdomain)?

## Step 2: Redeploy Website Files

### Quick Method (Drag & Drop):

1. **On your Mac:**
   - Open Finder
   - Go to: `Desktop > Project Planner > website`
   - Select ALL files (Cmd+A)
   - Right-click → **Compress X items**
   - This creates `Archive.zip` (or similar)

2. **In Netlify:**
   - Go to your site dashboard
   - Click **Deploys** tab
   - Drag the ZIP file into the deploy area
   - OR click **Deploy manually** → Select ZIP file
   - Wait 30-60 seconds for deployment

3. **Verify:**
   - Visit your site URL
   - Try: `https://your-site.netlify.app/setup-password.html`
   - You should see the password setup form

## Step 3: Test the Website

1. **Test Password Setup Page:**
   - Visit: `https://your-site.netlify.app/setup-password.html`
   - You should see: "Set Up Your Account Password" form
   - Try entering a test invitation code

2. **Test with Token in URL:**
   - Visit: `https://your-site.netlify.app/setup-password.html?token=TEST123`
   - The invitation code field should auto-fill with "TEST123"

## Step 4: Update Email Links (If Needed)

If your Netlify URL is different from `projectplanner.us`, I need to update the email templates.

**Tell me:**
- What's your Netlify site URL?
- Is `projectplanner.us` connected to Netlify?

Then I'll update the email links in the iOS app to match your actual website URL.

## Common Issues

### ❌ "Site not found" or 404
**Fix:** Make sure all files are in the ZIP root (not in a nested folder)

### ❌ "Firebase error" or blank page
**Fix:** Check browser console (F12) for errors. Verify Firebase config is correct.

### ❌ "Invalid invitation code"
**Fix:** 
1. Check Firestore rules allow reading invitations
2. Verify invitation codes are being created in Firestore
3. Check invitation hasn't expired (7 days)

### ❌ Website loads but password setup doesn't work
**Fix:**
1. Open browser console (F12)
2. Look for JavaScript errors
3. Check Network tab - are Firebase SDK files loading?

## Files Included in Deployment

Make sure these files are in your ZIP:
- ✅ `index.html`
- ✅ `setup-password.html` ⭐ (Most important!)
- ✅ `reset-password.html`
- ✅ `reset-password-complete.html`
- ✅ `styles.css`
- ✅ `config.js`
- ✅ `netlify.toml` (I just created this)
- ✅ `app.js` (if used)
- ✅ Any other JS/CSS files

## Next Steps

1. ✅ Redeploy website to Netlify
2. ✅ Test the setup-password.html page
3. ⏳ **Tell me your Netlify URL** - I'll update email links
4. ⏳ Test creating a new user in iOS app
5. ⏳ Verify email link works

---

**Need Help?**
- Check Netlify dashboard → Deploys tab for deployment logs
- Check browser console (F12) for errors
- Verify Firebase config matches your Firebase project


