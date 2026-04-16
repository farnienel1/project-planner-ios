# Simplest Way to Enable SMTP Authentication (Web Interface)

## Use the Microsoft Admin Center Web Interface

Since PowerShell might be complicated on Mac, let's use the **web browser** approach.

---

## Step 1: Open Exchange Admin Center

The link should have just opened in your browser:
**https://admin.exchange.microsoft.com**

Sign in with your Microsoft 365 admin account.

---

## Step 2: Look for These Settings

Once you're in the Exchange Admin Center, you're looking for one of these:

### Option A: Authentication Settings
1. In the left sidebar, look for **"Settings"**
2. Click on it
3. Look for **"Mail flow"** or **"Authentication"**
4. Find **"SMTP AUTH"** or **"Client authentication"**
5. Enable it ✅

### Option B: Organization Settings
1. In the left sidebar, look for **"Settings"**
2. Click **"Organization"** or **"Org settings"**
3. Look for **"Mail"** tab
4. Find **"SMTP authentication"**
5. Enable it ✅

### Option C: Mail Flow Settings
1. In the left sidebar, click **"Mail flow"**
2. Look for **"Settings"** or **"Configure"**
3. Find **"Client authentication settings"**
4. Enable **"SMTP AUTH"** ✅

---

## What You're Looking For

The setting might be called:
- ☑ **"SMTP AUTH"**
- ☑ **"Authenticated SMTP"**
- ☑ **"Enable SMTP client authentication"**
- ☑ **"Allow SMTP AUTH"**

It's usually a **checkbox** or **toggle switch**.

---

## If You Can't Find It

Sometimes the interface changes. Try this link instead:

**https://admin.microsoft.com/Adminportal/Home#/Settings/Services/:/Settings/L1/Mail**

This should take you directly to the SMTP settings.

---

## After Enabling

1. Click **"Save"** or **"Apply"**
2. Wait 10-15 minutes for changes to propagate
3. Restart your backend
4. Test email sending

---

## Visual Guide

```
┌─────────────────────────────────────────┐
│  Microsoft Exchange Admin Center         │
├─────────────────────────────────────────┤
│ [Settings] [Mail flow] [Recipients]     │
│                                          │
│  Configuration                           │
│  ┌────────────────────────────────┐    │
│  │ ☑ SMTP AUTH                    │ ← Check this
│  │ ☐ POP3                         │
│  │ ☐ IMAP                         │
│  │                                 │    │
│  │         [Save]                  │
│  └────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

---

## Need Help?

Let me know what you see on the Exchange Admin Center page:
- What sections appear in the left sidebar?
- What's on the main screen?
- Do you see "Settings", "Mail flow", "Organization"?

Then I can give you **exact click-by-click instructions**! 🎯











