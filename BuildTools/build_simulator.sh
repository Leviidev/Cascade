#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Cascade — Build & Launch in Simulator
#  Requires: macOS with Xcode 16+
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

PROJECT="Cascade.xcodeproj"
SCHEME="Cascade"
DERIVED_DATA="build/DerivedData"
SIM_NAME="${1:-iPhone 16 Pro}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌊 Cascade Simulator Build"
echo "  Simulator : $SIM_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SIM_ID=$(xcrun simctl list devices available | grep "$SIM_NAME" | head -1 | grep -oE '[A-F0-9-]{36}')

if [[ -z "$SIM_ID" ]]; then
  echo "❌  Simulator '$SIM_NAME' not found."
  echo "    Available simulators:"
  xcrun simctl list devices available | grep -E "iPhone|iPad" | head -20
  exit 1
fi

echo "✅  Using simulator: $SIM_NAME ($SIM_ID)"

xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$SIM_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  | xcpretty

APP=$(find "$DERIVED_DATA" -name "Cascade.app" -path "*/Debug-iphonesimulator/*" | head -1)

xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl launch "$SIM_ID" com.cascade.ps2emulator
open -a Simulator
echo "✅  Launched in $SIM_NAME!"
