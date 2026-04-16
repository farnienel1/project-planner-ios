#!/bin/bash

# Script to fix dSYM issues during build
echo "🔧 Fixing dSYM issues for gRPC and other third-party frameworks..."

# Check if we're in a release build
if [ "${CONFIGURATION}" = "Release" ]; then
    echo "📱 Release build detected - applying dSYM fixes..."
    
    # Create dSYM directory if it doesn't exist
    DSYM_DIR="${DWARF_DSYM_FOLDER_PATH}"
    if [ ! -d "$DSYM_DIR" ]; then
        mkdir -p "$DSYM_DIR"
    fi
    
    # Copy dSYM files for frameworks that have them
    FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
    
    if [ -d "$FRAMEWORKS_DIR" ]; then
        echo "📁 Processing frameworks in: $FRAMEWORKS_DIR"
        
        # Find all .framework directories
        for framework in "$FRAMEWORKS_DIR"/*.framework; do
            if [ -d "$framework" ]; then
                framework_name=$(basename "$framework" .framework)
                echo "🔍 Processing framework: $framework_name"
                
                # Check if framework has dSYM
                if [ -d "$framework/$framework_name.dSYM" ]; then
                    echo "✅ Found dSYM for $framework_name"
                    # Copy dSYM to the main dSYM folder
                    cp -R "$framework/$framework_name.dSYM" "$DSYM_DIR/"
                else
                    echo "⚠️  No dSYM found for $framework_name (this is normal for binary frameworks)"
                fi
            fi
        done
    fi
    
    echo "✅ dSYM processing complete"
else
    echo "📱 Debug build - skipping dSYM processing"
fi




















