# Namecheap Email Setup Guide

## Step 1: Purchase Namecheap Private Email

1. **Go to Namecheap.com**
2. **Navigate to**: Email → Private Email
3. **Choose a plan** (Basic plan is sufficient for most needs)
4. **Select your domain**: `projectplanner.us` (or your domain)
5. **Create email accounts**:
   - `info@projectplanner.us` (main email)
   - `noreply@projectplanner.us` (system emails)

## Step 2: Get SMTP Settings

After setting up your email accounts, Namecheap will provide:

- **SMTP Server**: `mail.privateemail.com`
- **Port**: `587` (TLS) or `465` (SSL)
- **Username**: Your full email address (e.g., `info@projectplanner.us`)
- **Password**: The password you set for the email account

## Step 3: Update Backend Configuration

### 3.1 Create Environment File
Create a file called `.env` in the `backend` folder with:

```env
# Namecheap Private Email Configuration
EMAIL_USER=info@projectplanner.us
EMAIL_PASSWORD=your_actual_password_here

# Server Configuration
PORT=3000
```

### 3.2 Update Backend Code
The backend code has already been updated to use Namecheap settings:
- SMTP Server: `mail.privateemail.com`
- Port: `587`
- TLS: Enabled

## Step 4: Test Email Configuration

### 4.1 Test Locally
```bash
cd backend
npm start
```

### 4.2 Test Email Sending
```bash
curl -X POST http://localhost:3000/test-email \
  -H "Content-Type: application/json" \
  -d '{"testEmail": "your-test-email@example.com"}'
```

## Step 5: Deploy to Production

### 5.1 Update Heroku Environment Variables
```bash
heroku config:set EMAIL_USER=info@projectplanner.us
heroku config:set EMAIL_PASSWORD=your_actual_password_here
```

### 5.2 Deploy Backend
```bash
git add .
git commit -m "Update email configuration for Namecheap"
git push heroku main
```

## Step 6: DNS Settings (Optional)

If you want to use a custom domain for email:

### 6.1 Add MX Records
In your domain's DNS settings, add these MX records:
- **Priority**: 10
- **Value**: `mail.privateemail.com`

### 6.2 Add SPF Record
Add a TXT record:
- **Name**: `@`
- **Value**: `v=spf1 include:privateemail.com ~all`

### 6.3 Add DKIM Record
Namecheap will provide DKIM settings in your email control panel.

## Troubleshooting

### Common Issues:

1. **Authentication Failed**: Double-check your email and password
2. **Connection Timeout**: Verify the SMTP server and port
3. **TLS Issues**: Try port 465 with SSL instead of 587 with TLS

### Test Commands:

```bash
# Test SMTP connection
telnet mail.privateemail.com 587

# Test email sending
curl -X POST http://localhost:3000/test-email \
  -H "Content-Type: application/json" \
  -d '{"testEmail": "test@example.com"}'
```

## Cost

- **Namecheap Private Email**: ~$1-2/month per mailbox
- **Much cheaper** than Microsoft 365
- **More reliable** for SMTP authentication
- **Better deliverability** for transactional emails

## Next Steps

1. ✅ Set up Namecheap email accounts
2. ✅ Update `.env` file with your credentials
3. ✅ Test email sending locally
4. ✅ Deploy to production
5. ✅ Test the "Create User" feature in the app

Once this is set up, the "Create User" button will work perfectly and send actual invitation emails!










