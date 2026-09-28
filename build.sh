#!/usr/bin/env bash
# Convenience build script for StatusBarMover.
# Run on a machine that has Theos installed (macOS or Linux/WSL + iOS SDK).
set -e

if [ -z "$THEOS" ]; then
  echo "ERROR: \$THEOS is not set. Install Theos first: https://theos.dev/docs/installation"
  exit 1
fi

cd "$(dirname "$0")"

echo ">> Cleaning…"
make clean || true

echo ">> Building rootless package…"
make package FINALPACKAGE=1

echo
echo ">> Done. Package(s):"
ls -1 packages/*.deb
echo
echo "Install with Sileo/Zebra on your XinaA15 device, or push directly with:"
echo "  make do THEOS_DEVICE_IP=<phone-ip> THEOS_DEVICE_PORT=22"
