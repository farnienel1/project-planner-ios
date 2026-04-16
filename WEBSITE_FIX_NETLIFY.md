# 🔧 Fix Project Planner Website on Netlify

## Quick Fix Steps

### 1. Check Your Netlify Site Status

1. Go to [app.netlify.com](https://app.netlify.com)
2. Log in to your account
3. Find your Project Planner site
4. Check the **Deploys** tab - is there a recent successful deployment?

### 2. Verify Website Files Are Deployed

The website needs these files:
- ✅ `index.html` - Landing page
- ✅ `setup-password.html` - Password setup page (for new users)
- ✅ `reset-password.html` - Password reset page
- ✅ `reset-password-complete.html` - Password reset confirmation
- ✅ `styles.css` - Styling
- ✅ `config.js` - Firebase configuration
- ✅ `netlify.toml` - Netlify configuration (I just created this)

### 3. Update Netlify Deployment

**Option A: Drag & Drop (Easiest)**

1. On your Mac, go to: `Desktop > Project Planner > website`
2. Select ALL files in the website folder (Cmd+A)
3. Right-click → **Compress X items** (creates a ZIP file)
4. Go to [app.netlify.com](https://app.netlify.com)
5. Click on your Project Planner site
6. Go to **Deploys** tab
7. Drag the ZIP file into the deploy area, OR click **Deploy manually** and select the ZIP
8. Wait for deployment (30-60 seconds)

**Option B: Connect to Git (If you have GitHub)**

1. In Netlify dashboard, go to **Site settings**
2. Click **Build & deploy**
3. Click **Link to Git provider**
4. Follow the prompts to connect your repository

### 4. Update Email Links in iOS App

The email service needs to know your website URL. I need to update the email template to use the correct Netlify URL.

**What's your Netlify site URL?**
- It should be something like: `https://your-site-name.netlify.app`
- Or if you have a custom domain: `https://projectplanner.us`

Once you tell me the URL, I'll update the email templates in the iOS app to use the correct link.

### 5. Test the Website

1. Visit your Netlify site URL
2. Try: `https://your-site.netlify.app/setup-password.html`
3. You should see the password setup form
4. Try entering a test invitation code (from your iOS app)

### 6. Common Issues & Fixes

**Issue: "Site not found" or 404 error**
- **Fix**: Make sure `index.html` is in the root of your ZIP file
- **Fix**: Check that all HTML files are included in deployment

**Issue: "Firebase error" or "Permission denied"**
- **Fix**: Verify Firebase config in `setup-password.html` matches your Firebase project
- **Fix**: Check Firestore security rules allow reading invitations

**Issue: "Invalid invitation code"**
- **Fix**: Make sure Firestore rules allow public read for invitations:
  ```javascript
  match /invitations/{invitationId} {
    allow read: if true;
    allow write: if request.auth != null;
  }
  ```

**Issue: Website loads but password setup doesn't work**
- **Fix**: Check browser console (F12) for JavaScript errors
- **Fix**: Verify Firebase SDK is loading correctly
- **Fix**: Check that invitation codes are being created in Firestore

## Next Steps

1. **Tell me your Netlify site URL** - I'll update the email links
2. **Redeploy the website** - Use the steps above
3. **Test password setup** - Create a new user in the iOS app and try the setup link

## Files I've Created/Updated

✅ **`website/netlify.toml`** - Netlify configuration file
- Sets up proper redirects
- Configures security headers
- Allows Firebase SDK to load

This file should be included in your next deployment.


