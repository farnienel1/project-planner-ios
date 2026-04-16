# Deploy Backend to Railway - Quick Guide

## Why Railway?
- ✅ Free tier available (500 hours/month)
- ✅ Easy deployment (one command)
- ✅ Already have `railway.json` configured
- ✅ Automatic HTTPS
- ✅ Environment variables easy to set

## Quick Deploy Steps

### 1. Install Railway CLI (if not already installed)
```bash
npm install -g @railway/cli
```

### 2. Login to Railway
```bash
railway login
```

### 3. Navigate to backend folder and deploy
```bash
cd backend
railway init
railway up
```

### 4. Set Environment Variables in Railway Dashboard

After deployment, go to Railway dashboard → Your project → Variables tab, and add:

```
EMAIL_USER=info@raccordmep.co.uk
EMAIL_PASSWORD=Raccord50!
PORT=3000
```

### 5. Get Your Railway URL

After deployment, Railway will give you a URL like:
`https://your-project-name.up.railway.app`

### 6. Update App Code

In `CloudEmailService.swift`, update the `backendURL`:
```swift
let backendURL = "https://your-project-name.up.railway.app/send-email"
```

## Alternative: Use Render (Also Free)

### Steps:
1. Go to https://render.com
2. Click "New" → "Web Service"
3. Connect your GitHub repo
4. Settings:
   - **Root Directory**: `backend`
   - **Build Command**: `npm install`
   - **Start Command**: `node server.js`
5. Add Environment Variables:
   - `EMAIL_USER=info@raccordmep.co.uk`
   - `EMAIL_PASSWORD=Raccord50!`
   - `PORT=10000` (Render uses port 10000)

## What You Get

Once deployed, emails will be sent from:
- **From**: info@raccordmep.co.uk
- **SMTP**: Microsoft 365 (smtp.office365.com)
- **Delivery**: Direct from your Outlook account

## Benefits Over SendGrid

- ✅ Uses YOUR email (info@raccordmep.co.uk)
- ✅ No third-party service needed
- ✅ Professional appearance (emails from your domain)
- ✅ Free to host (Railway/Render free tiers)

## Testing

After deployment, test the endpoint:
```bash
curl -X POST https://your-url.up.railway.app/test-email \
  -H "Content-Type: application/json" \
  -d '{"testEmail": "your-email@example.com"}'
```

## Notes

- Railway free tier sleeps after inactivity, but wakes up on first request
- Render free tier also available with similar features
- Both platforms auto-restart on crashes
- HTTPS included automatically







