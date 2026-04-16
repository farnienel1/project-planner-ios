#!/bin/bash
cd "$(dirname "$0")"
echo "Starting password reset setup..."
echo ""
node setup-password-reset.js
echo ""
read -p "Press Enter to close this window."
