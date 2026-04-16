# Implementation Plan - User Requested Features

## Status: In Progress

### ✅ Step 1: User Name Display - COMPLETED
- Updated HomeView to show first name instead of email
- Settings page already shows full name correctly

### 🔄 Step 2: Notification Badge System - IN PROGRESS
**Requirements:**
- Red notification badge with number (top right)
- View latest 100 notifications per user
- Permission-based filtering (operatives see their tasks, admins see user creation, etc.)
- Clicking notification navigates to relevant page
- Filter options: date, newest, oldest
- Show "0" when no notifications

**Implementation needed:**
1. Add notification badge to ContentView/HomeView
2. Create NotificationsView with list and filters
3. Update NotificationService to filter by user permissions
4. Add navigation logic for each notification type
5. Store notifications in Firebase with userId

### ⏳ Step 3: Maps Feature Fix - PENDING
**Issue:** Maps dialog only appears when clicking back
**Fix needed:** Show confirmationDialog immediately when button is tapped

### ⏳ Step 4: Completed Task Images/Files - PENDING
**Requirements:**
- Display images/files when viewing completed tasks
- Persist even if task marked as not completed
- Store in Firebase Storage
- Accessible to all users with task view permission

**Implementation needed:**
1. Check Firebase Storage integration
2. Fix image/file display in TaskDetailView
3. Ensure persistence logic
4. Add download/view functionality

### ⏳ Step 5: UK GDPR Privacy Policy - PENDING
**Requirements:**
- Create UK GDPR-compliant privacy policy
- Add to Settings page
- Add to organization setup flow (last step, "I Accept" button)

### ⏳ Step 6: First Login Policy Acceptance - PENDING
**Requirements:**
- Show policy on first login only
- Store acceptance in user account
- Don't show again after acceptance
- Policy accessible in Settings

**Implementation needed:**
1. Add `policyAccepted: Bool` to AppUser model
2. Create PolicyAcceptanceView
3. Check on login and show if not accepted
4. Update user document when accepted

---

## Priority Order:
1. ✅ Step 1 (Done)
2. Step 3 (Quick fix)
3. Step 6 (Foundation for Step 5)
4. Step 5 (Content creation)
5. Step 4 (Requires Firebase Storage setup)
6. Step 2 (Most complex, requires UI and logic)


