# Email Configuration Guide

## Current Setup: SendGrid ✅

The app is currently configured to use **SendGrid** for sending emails. This is the simplest solution and requires no backend server.

### SendGrid Configuration
- **API Key**: Already configured in `SendGridEmailService.swift`
- **From Email**: `noreply@projectplanner.app`
- **Status**: Ready to use

### How It Works
1. App calls `EmailService.shared.sendEmail()`
2. Routes to `CloudEmailService` 
3. Uses `SendGridEmailService` to send via SendGrid API
4. Email delivered directly

## Alternative: Outlook/Microsoft 365 SMTP

If you want to use Outlook (`info@raccordmep.co.uk`) instead, you'll need to:

### Option 1: Deploy Backend Server (Recommended for Outlook)

The backend code is ready in `backend/server.js` and uses Microsoft 365 SMTP.

#### Hosting Options:

**Railway** (Easiest):
```bash
cd backend
railway login
railway init
railway up
```

Set environment variables in Railway:
- `EMAIL_USER=info@raccordmep.co.uk`
- `EMAIL_PASSWORD=Raccord50!`
- `PORT=3000`

**Render** (Free tier available):
1. Create new Web Service
2. Connect GitHub repo
3. Root directory: `backend`
4. Build command: `npm install`
5. Start command: `node server.js`
6. Add environment variables:
   - `EMAIL_USER=info@raccordmep.co.uk`
   - `EMAIL_PASSWORD=Raccord50!`
   - `PORT=3000`

**Heroku**:
```bash
cd backend
heroku create project-planner-email-backend
heroku config:set EMAIL_USER=info@raccordmep.co.uk
heroku config:set EMAIL_PASSWORD=Raccord50!
git push heroku main
```

#### Update App After Deploying Backend:

1. Get your backend URL (e.g., `https://your-app.railway.app`)
2. Update `CloudEmailService.swift`:
```swift
let backendURL = "https://your-backend-url.com/send-email"
```

### Option 2: Microsoft Graph API (Advanced)

Requires Azure App Registration and OAuth2 setup. More complex but more secure.

## Current Email Flow

### Password Setup Email
When admin adds a new user:
1. Invitation created in Firestore
2. Email sent via SendGrid with:
   - Welcome message
   - Setup link: `https://projectplanner.us/setup-password?token={invitationId}`
   - Invitation code as fallback

## Testing

### Test SendGrid
1. Add a new user in the app
2. Check console logs for email status
3. Verify email arrives

### Test Outlook Backend (if deployed)
1. Update `CloudEmailService.swift` with backend URL
2. Test endpoint: `POST /test-email`
3. Verify SMTP credentials work

## Troubleshooting

### SendGrid Issues
- Check API key is valid in SendGrid dashboard
- Verify sender email is verified in SendGrid
- Check SendGrid dashboard for delivery status

### Outlook SMTP Issues
- Ensure SMTP AUTH is enabled for the email account
- Verify password is correct (may need app password if MFA enabled)
- Check Microsoft 365 admin center for SMTP settings
- Ensure account allows "less secure apps" or use app password

## Recommendation

**For now: Use SendGrid** - It's already configured and working. Switch to Outlook backend later if needed for branding or other requirements.







