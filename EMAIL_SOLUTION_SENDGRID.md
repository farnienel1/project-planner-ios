# Better Email Solution: Use SendGrid

## Why SendGrid?
✅ **No tenant-level SMTP auth issues** - SendGrid is designed for apps
✅ **Free tier: 100 emails/day** - Perfect for testing
✅ **Easy setup** - Just sign up and get an API key
✅ **More reliable** - Designed for transactional emails
✅ **Better for production** - Scales as your app grows

---

## Quick Setup Steps

### 1. Sign Up for SendGrid
Go to: https://sendgrid.com

Sign up for a free account (100 emails/day free).

### 2. Get API Key
1. Go to: https://app.sendgrid.com/settings/api_keys
2. Click "Create API Key"
3. Name it: "Project Planner Email Service"
4. Select "Full Access" or "Restricted Access" > "Mail Send"
5. Copy the API key (you'll only see it once!)

### 3. Update Backend

Replace the SMTP configuration in `backend/server.js` with SendGrid:

```javascript
const nodemailer = require('nodemailer');

// SendGrid Configuration
const transporter = nodemailer.createTransport({
    service: 'SendGrid',
    auth: {
        user: 'apikey',
        pass: process.env.SENDGRID_API_KEY || 'your_api_key_here'
    }
});

const fromEmail = process.env.EMAIL_USER || 'info@projectplanner.us';
```

### 4. Update `.env` file
```env
EMAIL_USER=info@projectplanner.us
SENDGRID_API_KEY=your_api_key_here
PORT=3000
```

### 5. Restart Backend
```bash
pkill -f "node server.js"
cd backend
npm start
```

---

## Benefits of SendGrid

- ✅ **No Microsoft 365 tenant issues**
- ✅ **Better deliverability** (emails won't go to spam)
- ✅ **Email analytics** (see when emails are opened)
- ✅ **Email templates** (make your emails look professional)
- ✅ **Free for up to 100 emails/day**
- ✅ **Easy to upgrade** when you need more

---

## Cost

- **Free tier**: 100 emails/day
- **Paid tier**: $15/month for 40,000 emails/month
- Much cheaper than dealing with Microsoft 365 complications!

---

## Alternative: Keep Trying Microsoft 365

If you want to stick with Microsoft 365, you'll need:
- Admin access to your tenant
- PowerShell on Windows OR
- Contact Microsoft support to enable SMTP auth

---

**Recommendation: Use SendGrid** 🎯

It will save you hours of troubleshooting and work immediately.











