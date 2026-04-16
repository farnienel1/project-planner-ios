# 🔧 Fix Xcode Crash - iOS Deployment Target Issue

## 🚨 Problem Found:
Your Xcode project has **invalid iOS deployment target** settings that cause Xcode to crash:

- ❌ `IPHONEOS_DEPLOYMENT_TARGET = 26.0` (iOS 26 doesn't exist!)
- ❌ `LastSwiftUpdateCheck = 2600` (Invalid version)
- ❌ `LastUpgradeCheck = 2600` (Invalid version)

## ✅ Fix Applied:
I've updated the project file to use valid values:
- ✅ `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (iOS 17.0 - current standard)
- ✅ `LastSwiftUpdateCheck = 1600` (Xcode 16.0)
- ✅ `LastUpgradeCheck = 1600` (Xcode 16.0)

---

## 🧪 Test the Fix:

1. **Quit Xcode completely** (if it's open)
2. **Open the project again:**
   ```bash
   open "Project Planner.xcodeproj"
   ```
3. **Xcode should now open without crashing!**

---

## 📋 If Xcode Still Crashes:

### Option 1: Clean Derived Data
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData
```
Then try opening the project again.

### Option 2: Reset Xcode Caches
```bash
# Quit Xcode first, then:
rm -rf ~/Library/Caches/com.apple.dt.Xcode
```
Then reopen Xcode.

### Option 3: Check Xcode Version
Make sure you're using a compatible Xcode version:
- **Minimum:** Xcode 15.0 (for iOS 17.0)
- **Recommended:** Xcode 16.0 or later

---

## ✅ What Changed:

**Before:**
- Deployment target: iOS 26.0 ❌ (doesn't exist)
- Xcode version: 26.0 ❌ (doesn't exist)

**After:**
- Deployment target: iOS 17.0 ✅ (valid)
- Xcode version: 16.0 ✅ (valid)

---

## 🎯 Next Steps:

1. **Try opening the project** - it should work now!
2. **If it opens successfully:**
   - Build the project (Cmd+B)
   - Run it (Cmd+R)
3. **If you need a different iOS version:**
   - You can change `17.0` to `16.0` or `18.0` in the project settings
   - But **never use 26.0** - that version doesn't exist!

---

**The project file has been fixed. Try opening it now!** 🚀

