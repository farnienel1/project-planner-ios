# 🔧 Fix iOS Simulator Runtime Crash

## 🚨 Issue Found:
The crash is **NOT in Xcode** - it's in the **iOS 26.0 Simulator Runtime** itself!

The error shows:
- `update_dyld_sim_shared_cache` is crashing
- "Object has no pager because the backing vnode was force unmounted"
- This means the **iOS 26.0 simulator runtime is corrupted**

---

## ✅ Solution: Reinstall iOS Simulator Runtime

### Option 1: Delete and Reinstall iOS 26.0 Runtime (Recommended)

1. **Open Xcode** (if it opens)
2. **Go to:** Xcode → Settings → Platforms (or Components)
3. **Find:** iOS 26.0 Simulator
4. **Click:** The **"-"** button to remove it
5. **Wait** for it to uninstall
6. **Click:** The **"+"** button to reinstall iOS 26.0 Simulator
7. **Wait** for download and installation

### Option 2: Use Terminal to Remove Runtime

```bash
# List installed runtimes
xcrun simctl runtime list

# Delete iOS 26.0 runtime (if it shows as corrupted)
xcrun simctl runtime delete "iOS 26.0"

# Then reinstall via Xcode Settings → Platforms
```

### Option 3: Use a Different iOS Version (Quick Fix)

**If you don't need iOS 26.0 specifically:**

1. **Open Xcode** → Settings → Platforms
2. **Download iOS 17.5** or **iOS 18.0** simulator
3. **In your project:** Change deployment target to match
4. **Use that simulator** instead

---

## 🔍 Verify the Fix:

1. **Open Xcode**
2. **Go to:** Window → Devices and Simulators
3. **Click:** Simulators tab
4. **Try creating a new simulator** with iOS 26.0
5. **If it still crashes**, the runtime is still corrupted - try Option 2

---

## 🚨 If Xcode Still Won't Open:

The simulator crash might be preventing Xcode from starting. Try:

### Step 1: Kill All Simulator Processes
```bash
killall -9 com.apple.CoreSimulator.CoreSimulatorService
killall -9 Simulator
killall -9 simdiskimaged
```

### Step 2: Remove Simulator Data
```bash
rm -rf ~/Library/Developer/CoreSimulator
```

### Step 3: Try Opening Xcode Again
```bash
open -a Xcode "Project Planner.xcodeproj"
```

---

## 📋 Alternative: Use Real Device

If simulators keep crashing:
1. **Connect your iPhone/iPad**
2. **In Xcode:** Select your device instead of simulator
3. **Build and run** on the real device

---

## ✅ Summary:

**The issue is:**
- ❌ NOT your Xcode project file
- ❌ NOT Xcode itself
- ✅ **Corrupted iOS 26.0 Simulator Runtime**

**The fix:**
1. Reinstall iOS 26.0 simulator runtime
2. OR use a different iOS version
3. OR use a real device

**Your Xcode project file is fine!** The crash is in the simulator system, not your code.

---

**Try reinstalling the iOS 26.0 simulator runtime first!** 🚀

