# Fix "Domain not allowlisted (auth/unauthorized-continue-uri)"

The password reset email uses this link: **https://projectplanner.us/reset-password-complete.html**

Firebase must have that link’s **domain** in its allowlist.

## Steps in Firebase Console

1. Open **https://console.firebase.google.com**
2. Select project **project-planner-f986c**
3. In the left sidebar, click **Build** → **Authentication**
4. Open the **Settings** tab (or the **⋮** menu → **Settings**)
5. Scroll to **Authorized domains**
6. Click **Add domain**
7. Enter exactly: **projectplanner.us** (no `https://`, no path, no trailing slash)
8. Save

If you also use **www.projectplanner.us**, add that as a second domain.

## After adding

- Wait a minute, then try “Send Reset Link” again.
- Make sure the **live** site is using the updated code (redeploy if you changed the website files).
- If you still see the error, try in an incognito/private window to avoid cache.

## If it still fails

- Confirm the domain in the list is exactly **projectplanner.us** (no typo, no `www` unless you added it).
- In **Authentication → Templates**, open the **Password reset** template and check there is no custom “Action URL” that might override the one we send.
