# Resend Email Templates Guide

## Current Setup: HTML Direct (What We're Using Now)

**We're currently sending HTML directly** - this works perfectly and doesn't require any setup in Resend dashboard. The HTML is embedded in the code.

**Pros:**
- ✅ No setup needed
- ✅ Works immediately
- ✅ Full control over HTML
- ✅ Easy to customize

**Cons:**
- HTML is in the code (not reusable across projects)

## Option 1: Keep HTML Direct (Recommended for Now)

**What we're doing:** Sending HTML content directly in the API call.

**Example from our code:**
```swift
let emailData: [String: Any] = [
    "from": "Project Planner <\(fromEmail)>",
    "to": [email],
    "subject": subject,
    "html": htmlContent  // ← HTML sent directly
]
```

**This works great!** No changes needed.

## Option 2: Use Resend Templates (Optional)

Resend templates let you:
- Store HTML in Resend dashboard
- Reuse templates across projects
- Update templates without code changes
- Use template variables

### How to Set Up Templates:

1. **Go to Resend Dashboard:**
   - https://resend.com
   - Click "Templates" in sidebar

2. **Create a Template:**
   - Click "Create Template"
   - Name it (e.g., "Password Setup")
   - Paste your HTML
   - Use variables like `{{firstName}}`, `{{invitationCode}}`

3. **Use Template in Code:**
   ```swift
   let emailData: [String: Any] = [
       "from": "Project Planner <\(fromEmail)>",
       "to": [email],
       "template_id": "your-template-id",
       "template_data": [
           "firstName": firstName,
           "invitationCode": invitationCode
       ]
   ]
   ```

### When to Use Templates:

- ✅ You want to update emails without code changes
- ✅ You have multiple projects using same templates
- ✅ Non-technical team members need to edit emails
- ✅ You want version control for email designs

### When to Keep HTML Direct:

- ✅ You want full control in code
- ✅ You're fine with code deployments for email changes
- ✅ Simpler setup (no dashboard configuration)

## Recommendation

**For now, keep HTML direct** (what we're using). It's simpler and works perfectly. You can always switch to templates later if you need the flexibility.

If you want to use templates, I can update the code to use Resend templates instead. Just let me know!


