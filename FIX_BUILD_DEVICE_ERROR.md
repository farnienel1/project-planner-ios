# 🔧 Fix "A build on device cannot be used to run this target"

## 🚨 Error Meaning:
Xcode built for one destination (device/simulator) but you're trying to run on a different one.

---

## ✅ Quick Fixes:

### Fix 1: Clean Build Folder (Most Common Fix)

1. **In Xcode:**
   - Press: **Shift + Cmd + K** (Clean Build Folder)
   - Or: **Product → Clean Build Folder**

2. **Then rebuild:**
   - Press: **Cmd + B** (Build)
   - Then: **Cmd + R** (Run)

### Fix 2: Check Your Scheme Destination

1. **At the top of Xcode**, next to the Run button
2. **Click the device/simulator selector**
3. **Make sure it matches what you want:**
   - If you want **Simulator**: Select an iPhone/iPad simulator
   - If you want **Device**: Select your connected iPhone/iPad

4. **Then build and run again**

### Fix 3: Reset Scheme

1. **In Xcode:** Click the scheme selector (next to device selector)
2. **Click:** "Edit Scheme..."
3. **Click:** "Run" (left sidebar)
4. **Under "Executable":** Make sure it shows your app
5. **Click:** "Close"
6. **Build and run again**

### Fix 4: Check Build Settings

1. **Select your project** in navigator
2. **Select your target** ("Project Planner")
3. **Go to:** Build Settings tab
4. **Search for:** "Build Active Architecture Only"
5. **Set to:** `Yes` for Debug, `No` for Release

---

## 🔍 More Detailed Fixes:

### If Building for Device:

1. **Make sure your device is:**
   - Connected via USB
   - Unlocked
   - Trusted (if first time)

2. **Check signing:**
   - Select project → Target → Signing & Capabilities
   - Make sure "Automatically manage signing" is checked
   - Select your team

3. **Select device as destination:**
   - Top bar → Click device selector
   - Choose your iPhone/iPad

### If Building for Simulator:

1. **Make sure simulator is:**
   - Selected in device selector
   - Not running another app
   - iOS version matches deployment target

2. **Check deployment target:**
   - Project → Target → General
   - Minimum Deployments should be ≤ Simulator iOS version

---

## 🚨 If Still Not Working:

### Option 1: Delete Derived Data
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData
```
Then rebuild in Xcode.

### Option 2: Reset Simulator (if using simulator)
1. **Window → Devices and Simulators**
2. **Right-click your simulator**
3. **Erase All Content and Settings**
4. **Try again**

### Option 3: Check for Build Errors
1. **Press Cmd + B** to build
2. **Check the Issue Navigator** (left sidebar, triangle icon)
3. **Fix any red errors** first
4. **Then try running**

---

## ✅ Most Likely Solution:

**90% of the time, this fixes it:**

1. **Clean Build Folder:** Shift + Cmd + K
2. **Select correct destination** (device or simulator)
3. **Build:** Cmd + B
4. **Run:** Cmd + R

---

**Try the clean build first - that usually fixes it!** 🚀

