#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Cascade IPA Builder
#  Requires: macOS with Xcode 16+ installed
#  Usage:    ./BuildTools/build_ipa.sh [--release] [--device-id <UDID>]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

PROJECT="Cascade.xcodeproj"
SCHEME="Cascade"
BUNDLE_ID="com.cascade.ps2emulator"
ARCHIVE_PATH="build/Cascade.xcarchive"
IPA_DIR="build/IPA"
DERIVED_DATA="build/DerivedData"

# ── Parse flags ──────────────────────────────────────────────────────────────
CONFIGURATION="Debug"
DEVICE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)      CONFIGURATION="Release"; shift ;;
    --device-id)    DEVICE_ID="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌊 Cascade IPA Builder"
echo "  Configuration : $CONFIGURATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
  echo "❌  xcodebuild not found."
  echo "    Install Xcode from the Mac App Store and run:"
  echo "    xcode-select --install"
  exit 1
fi

XCODE_VERSION=$(xcodebuild -version | head -1)
echo "✅  $XCODE_VERSION"

# ── Clean previous build ──────────────────────────────────────────────────────
mkdir -p build
rm -rf "$ARCHIVE_PATH" "$IPA_DIR"

# ── Build & Archive ───────────────────────────────────────────────────────────
echo ""
echo "▶  Archiving ($CONFIGURATION)…"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  | xcpretty 2>/dev/null || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "❌  Archive failed. Check the log above."
  exit 1
fi

echo "✅  Archive created: $ARCHIVE_PATH"

# ── Export IPA (unsigned) ─────────────────────────────────────────────────────
echo ""
echo "▶  Exporting unsigned IPA…"

EXPORT_PLIST=$(mktemp /tmp/cascade_export.XXXXXX.plist)
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>ad-hoc</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$IPA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="-" \
  | xcpretty 2>/dev/null || true

rm -f "$EXPORT_PLIST"

# ── Find the IPA ──────────────────────────────────────────────────────────────
IPA_FILE=$(find "$IPA_DIR" -name "*.ipa" 2>/dev/null | head -1)

if [[ -z "$IPA_FILE" ]]; then
  # Fallback: manually zip the .app from the archive
  echo "⚠️   xcodebuild export didn't produce an IPA — packaging manually…"
  APP_PATH=$(find "$ARCHIVE_PATH/Products/Applications" -name "*.app" | head -1)
  mkdir -p "$IPA_DIR/Payload"
  cp -R "$APP_PATH" "$IPA_DIR/Payload/"
  (cd "$IPA_DIR" && zip -qr "Cascade.ipa" Payload/)
  rm -rf "$IPA_DIR/Payload"
  IPA_FILE="$IPA_DIR/Cascade.ipa"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  IPA ready: $IPA_FILE"
echo "      Size: $(du -sh "$IPA_FILE" | cut -f1)"
echo ""
echo "  Install with:"
echo "    AltStore  — Open AltStore → tap + → select the IPA"
echo "    Sideloadly — Drag the IPA into Sideloadly"
echo "    TrollStore — AirDrop the IPA to your device (A12+)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Optional: install directly to a connected device ──────────────────────────
if [[ -n "$DEVICE_ID" ]]; then
  if command -v ios-deploy &>/dev/null; then
    echo ""
    echo "▶  Installing to device $DEVICE_ID…"
    ios-deploy --id "$DEVICE_ID" --bundle "$(find "$ARCHIVE_PATH" -name "*.app" | head -1)"
    echo "✅  Installed!"
  else
    echo "ℹ️   ios-deploy not found — skipping device install."
    echo "    Install with: brew install ios-deploy"
  fi
fi
