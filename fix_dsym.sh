#!/bin/bash

# Script to fix dSYM issues with gRPC framework
echo "🔧 Fixing dSYM issues for gRPC framework..."

# Add build settings to disable dSYM validation for third-party frameworks
echo "Adding build settings to project..."

# Use sed to add the necessary build settings
sed -i '' 's/DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT = NO;/DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT = NO;\
				STRIP_INSTALLED_PRODUCT = NO;/' "Project Planner.xcodeproj/project.pbxproj"

echo "✅ Build settings updated"
echo "📱 You can now archive your app without dSYM warnings for gRPC framework"




















