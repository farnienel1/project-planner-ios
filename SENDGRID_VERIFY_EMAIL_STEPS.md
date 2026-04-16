# 📧 How to Verify Email in SendGrid - Step by Step

## 🎯 Goal: Verify info@projectplanner.us in SendGrid

---

## ✅ Step 1: Log Into SendGrid

1. **Go to SendGrid**:
   - Visit: https://app.sendgrid.com
   - Log in with your SendGrid account

2. **Navigate to Settings**:
   - Click the **gear icon** ⚙️ (Settings) in the left sidebar
   - Or click **"Settings"** in the menu

---

## ✅ Step 2: Go to Sender Authentication

1. **In Settings menu**, find **"Sender Authentication"**
2. **Click on it**

You'll see options like:
- Verify a Single Sender
- Authenticate Your Domain

---

## ✅ Step 3: Verify Single Sender

1. **Click "Verify a Single Sender"** button

2. **Fill in the form**:
   - **From Email**: Enter `info@projectplanner.us`
   - **From Name**: Enter `Project Planner` (or your company name)
   - **Reply To**: Enter `info@projectplanner.us` (same email)
   - **Address**: Your street address (required)
   - **City**: Your city
   - **State**: Your state/region
   - **Zip Code**: Your postal code
   - **Country**: Select your country
   - **Website**: Optional (e.g., `https://projectplanner.us`)

3. **Click "Create"** button

---

## ✅ Step 4: Check Your Email

1. **SendGrid will send a verification email** to `info@projectplanner.us`

2. **Access the inbox** for `info@projectplanner.us`:
   - Log into Namecheap
   - Go to email inbox for that address
   - OR check if emails are forwarded to another address
   - OR access through your email provider

3. **Find the verification email**:
   - **From**: SendGrid or Twilio SendGrid
   - **Subject**: Usually "Verify Your Sender Identity" or similar
   - **Check spam folder** if you don't see it

---

## ✅ Step 5: Click Verification Link

1. **Open the verification email** from SendGrid
2. **Click the verification link** in the email
3. **Or copy the verification code** if there's a code to enter

---

## ✅ Step 6: Confirm Verification

1. **Go back to SendGrid dashboard**
2. **Refresh the Sender Authentication page**
3. **You should see**:
   - `info@projectplanner.us` listed
   - Status: **"Verified"** ✅ (green checkmark)

---

## ⚠️ If You Can't Access info@projectplanner.us Inbox

### Option A: Check Email Forwarding

1. **In Namecheap**:
   - Domain List → projectplanner.us → Manage → Email
   - Check if `info@projectplanner.us` is forwarded
   - If forwarded, check the forwarding address

2. **The verification email might be forwarded** to your personal email

### Option B: Use Domain Authentication Instead

If you can't access the inbox, use domain authentication:

1. **In SendGrid** → Settings → Sender Authentication
2. **Click "Authenticate Your Domain"**
3. **Enter**: `projectplanner.us`
4. **Get DNS records** from SendGrid
5. **Add DNS records in Netlify** (we set this up earlier)
6. **Wait for verification** (1-24 hours)

Once domain is authenticated, ANY email on that domain works (info@, noreply@, etc.)

### Option C: Verify Different Email Temporarily

If you can't verify info@projectplanner.us right now:

1. **Verify your Gmail/personal email** in SendGrid (same steps above)
2. **Use that email temporarily**:
   - I'll update the code to use your verified email
   - Emails will work immediately
   - Switch back to info@projectplanner.us later

---

## 🧪 Step 7: Test Email Sending

Once verified:

1. **Open your iOS app**
2. **Go to Settings → Add User**
3. **Invite a test user** (use your own email to test)
4. **Check SendGrid Dashboard**:
   - Activity → Email Activity
   - You should see the email sent
   - Status: "Delivered" ✅

5. **Check test email inbox**:
   - Email should arrive from `info@projectplanner.us`
   - Check spam folder too

---

## ✅ Verification Checklist

- [ ] Logged into SendGrid dashboard
- [ ] Went to Settings → Sender Authentication
- [ ] Clicked "Verify a Single Sender"
- [ ] Filled in form with info@projectplanner.us
- [ ] Clicked "Create"
- [ ] Checked inbox for info@projectplanner.us
- [ ] Found verification email from SendGrid
- [ ] Clicked verification link
- [ ] Confirmed status shows "Verified" in SendGrid
- [ ] Tested sending email from app
- [ ] Verified email arrived in test inbox

---

## 🐛 Troubleshooting

### Problem: Verification email never arrived
**Solutions**:
- Check spam/junk folder
- Check email forwarding settings in Namecheap
- Wait 10-15 minutes (sometimes takes time)
- Try resending verification in SendGrid dashboard

### Problem: Can't access info@projectplanner.us inbox
**Solutions**:
- Check if email forwarding is set up in Namecheap
- Use domain authentication instead (authenticates entire domain)
- Verify a different email you control (Gmail, etc.) temporarily

### Problem: "Email already verified" error
**Solutions**:
- Check SendGrid → Sender Authentication
- See if info@projectplanner.us is already listed as verified
- If yes, you're done! ✅

### Problem: Verification link expired
**Solutions**:
- Go back to SendGrid → Sender Authentication
- Find the sender
- Click "Resend Verification" or similar button
- Check inbox again

---

## 📸 Visual Guide

### In SendGrid Dashboard:
```
Settings (⚙️)
  └── Sender Authentication
      └── Verify a Single Sender (button)
          └── Fill form → Create
              └── Check email inbox
                  └── Click verification link
                      └── ✅ Verified!
```

---

## 🎉 Once Verified

**You're done!** ✅

- All emails from your app will work
- No code changes needed
- Just test sending an email to confirm

**What Works**:
- ✅ Password setup emails
- ✅ Password reset emails
- ✅ Verification emails
- ✅ Schedule emails
- ✅ Notification emails

**All coming from**: `info@projectplanner.us` 🎯

---

**Need help?** If you get stuck on any step, tell me which step and I'll help troubleshoot! 🚀







