# Microsoft 365 Business Email Setup for Project Planner

## Current Configuration
- **Domain**: `projectplanner.us` (hosted on Namecheap)
- **Email**: `info@projectplanner.us` (will be hosted on Microsoft 365)
- **Use Case**: Automated email sending from Node.js backend

## Step 1: Get Microsoft 365 Business

1. Go to: https://www.microsoft.com/en-us/microsoft-365/business
2. Click "Buy now" or "Try for free"
3. Select **Microsoft 365 Business Basic** ($6/user/month) or Business Standard ($12.50/user/month)
4. Complete the purchase

## Step 2: Add Domain to Microsoft 365

1. Sign in to Microsoft 365 Admin Center: https://admin.microsoft.com
2. Go to **Settings** → **Domains**
3. Click **Add domain**
4. Enter `projectplanner.us`
5. Select **Add a domain**
6. Choose **I'll manage my own DNS records**
7. Click **Next**

## Step 3: Microsoft will provide DNS records

Microsoft will show you the DNS records you need to add. You'll see records like:

### MX Record:
```
Type: MX
Priority: 0
Value: projectplanner-us.mail.protection.outlook.com
```

### TXT Record (for verification):
```
Type: TXT
Value: MS=ms12345678 (or similar verification code)
```

### CNAME Records (for autodiscover):
```
Type: CNAME
Host: autodiscover
Value: autodiscover.outlook.com
```

### SPF Record:
```
Type: TXT
Value: v=spf1 include:spf.protection.outlook.com -all
```

### Additional records may be needed (DKIM, etc.)

## Step 4: Update DNS in Namecheap

1. Log in to Namecheap: https://www.namecheap.com
2. Go to **Domain List**
3. Click **Manage** next to `projectplanner.us`
4. Go to **Advanced DNS** tab
5. **IMPORTANT**: First, remove any existing MX records that point to `mail.privateemail.com`

### Remove Old Namecheap Email Records:
- Delete any MX records pointing to `mail.privateemail.com`
- Delete any CNAME records for email

### Add Microsoft 365 Records:
Add the exact records Microsoft provides in Step 3. The most important ones are:
- **MX Record** (incoming email)
- **TXT Record** (verification)
- **TXT Record** (SPF)
- **CNAME Record** (autodiscover)

## Step 5: Verify Domain in Microsoft 365

1. Go back to Microsoft 365 Admin Center
2. Click **Verify** next to your domain
3. Wait for DNS propagation (can take up to 48 hours, usually much faster)
4. Once verified, you can create email addresses

## Step 6: Create Email Address

1. Go to **Users** → **Active users**
2. Click **Add a user**
3. Fill in:
   - First name: Info
   - Last name: Support
   - Username: `info`
   - Domain: `@projectplanner.us`
   - Display name: Info Project Planner
4. Create a password (save this!)
5. Assign a **Microsoft 365 Business Basic** license
6. Click **Add**

## Step 7: Update Backend .env File

You need to update the `.env` file with your new Microsoft 365 credentials.

**Location**: `backend/.env`

**Current contents** (for reference):
```
EMAIL_USER=support@projectplanner.us
EMAIL_PASSWORD=Acimaxmst802!
PORT=3000
```

**Update to**:
```
EMAIL_USER=info@projectplanner.us
EMAIL_PASSWORD=YOUR_MICROSOFT_365_PASSWORD_HERE
PORT=3000
```

### How to Edit .env File:

**Option 1: Using Terminal**
```bash
cd "/Users/farnienel/Desktop/Project Planner/backend"
nano .env
```
- Change `EMAIL_USER` to `info@projectplanner.us`
- Change `EMAIL_PASSWORD` to your Microsoft 365 password
- Save: Press `Ctrl+X`, then `Y`, then `Enter`

**Option 2: Using VS Code**
```bash
code "/Users/farnienel/Desktop/Project Planner/backend/.env"
```
- Edit the file in VS Code
- Save

**Option 3: Using Finder**
- Navigate to: `/Users/farnienel/Desktop/Project Planner/backend/`
- Double-click `.env` to open in TextEdit
- Make changes and save

## Step 8: Enable SMTP Auth for App Passwords (IMPORTANT!)

Microsoft 365 requires an **App Password** for programmatic access, not your regular password.

### To Create an App Password:

1. Go to: https://myaccount.microsoft.com/security
2. Sign in with `info@projectplanner.us`
3. Go to **Security** → **Additional security verification**
4. If you see "App passwords", click on it
5. If not:
   - Go to **Security** → **Advanced security options**
   - Click **Create and manage app passwords**
6. Click **Create new app password**
7. Give it a name: "Project Planner Backend"
8. Copy the generated password (it's a long string like: `abcd-efgh-ijkl-mnop`)
9. **Use this app password in your .env file**, NOT your regular password!

### Update .env Again:
```env
EMAIL_USER=info@projectplanner.us
EMAIL_PASSWORD=abcd-efgh-ijkl-mnop  # Your app password here
PORT=3000
```

## Step 9: Test the Email Service

Once everything is configured:

1. Restart the backend:
```bash
cd "/Users/farnienel/Desktop/Project Planner/backend"
npm start
```

2. Test the email:
```bash
curl -X POST http://localhost:3000/test-email \
  -H "Content-Type: application/json" \
  -d '{"testEmail": "your-email@example.com"}'
```

You should receive a test email!

## Troubleshooting

### "Invalid login" Error
- Make sure you're using an **App Password**, not your regular Microsoft 365 password
- Check that your DNS records have propagated (can take up to 48 hours)

### "Domain not verified" Error
- Make sure you've added the TXT verification record to Namecheap DNS
- Wait for DNS propagation (check with: `dig TXT projectplanner.us`)

### Emails going to spam
- Once working, set up SPF, DKIM, and DMARC records (Microsoft will provide these)
- Make sure the "From" address matches your authenticated email address

## Important Notes

- **Keep Namecheap for domain hosting** - It works great for that!
- **Use Microsoft 365 for email** - Much more reliable SMTP
- **App Passwords are required** - Regular passwords won't work for SMTP
- **DNS propagation can take time** - Be patient (usually 10 minutes to 2 hours)

## Cost

- Microsoft 365 Business Basic: ~$6/month
- Very reliable email delivery
- 50GB mailbox storage
- Access to Outlook, Teams, etc.

Good luck! Let me know when you have Microsoft 365 set up and we'll configure the backend.











