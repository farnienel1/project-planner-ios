#!/bin/sh
# Fails the Xcode build if the working launch shell is replaced.
# The shell that showed Home is key-host: makeKey on an already-rooted window only.
set -e
FILE="${SRCROOT:-.}/Project Planner/Project_PlannerApp.swift"
if [ ! -f "$FILE" ]; then
  echo "error: Launch shell file is missing: $FILE"
  exit 1
fi

fail() {
  echo "error: $1"
  echo "error: Keep the key-host launch shell. A splash, makeKeyAndVisible, a scene-phase gate, a color scheme on the WindowGroup, or ignoresSafeArea(edges:) on the root reader each left a white window."
  exit 1
}

grep -F -q 'PP_LAUNCH_BUILD key-host' "$FILE" || fail "PP_LAUNCH_BUILD key-host log is missing"
grep -F -q 'host.makeKey()' "$FILE" || fail "host.makeKey() is missing"
if grep -F -q 'makeKeyAndVisible(' "$FILE"; then fail "makeKeyAndVisible is forbidden in the launch shell"; fi
if grep -F -q 'UIWindow.appearance' "$FILE"; then fail "UIWindow.appearance is forbidden in the launch shell"; fi
if grep -F -q 'preferredColorScheme' "$FILE"; then fail "preferredColorScheme is forbidden on the launch WindowGroup"; fi
if grep -F -q 'AppLaunchSplashView' "$FILE"; then fail "AppLaunchSplashView must not cover the first frame"; fi
if grep -F -q 'ignoresSafeArea(edges:' "$FILE"; then fail "a partial ignoresSafeArea on the root reader blanks the window"; fi
if grep -F -q 'scenePhase' "$FILE"; then fail "a scene-phase gate is forbidden in the launch shell"; fi
if grep -F -q 'PP_LAUNCH_REVEAL' "$FILE"; then fail "PP_LAUNCH_REVEAL must not return"; fi
echo "Launch shell lock: key-host is intact"
