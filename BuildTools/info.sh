#!/usr/bin/env bash
cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🌊  Cascade — iOS PS2 Emulator
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  This is a Swift/iOS project. Replit is your code editor
  and version control hub — building the IPA requires
  macOS with Xcode 16+ on your own machine.

  ── To build on your Mac ─────────────────────────────
  1. Clone or download this project
  2. Open a terminal in the project folder
  3. Run one of:

     bash BuildTools/build_ipa.sh --release   (Release IPA)
     bash BuildTools/build_ipa.sh             (Debug IPA)
     bash BuildTools/build_simulator.sh       (Simulator)

  ── Output ───────────────────────────────────────────
  Unsigned IPA → build/IPA/Cascade.ipa

  ── Sideloading ──────────────────────────────────────
  AltStore    Open AltStore → tap + → select the IPA
  Sideloadly  Drag the IPA into Sideloadly
  TrollStore  AirDrop the IPA to your device (A12+)

  ── Requirements ─────────────────────────────────────
  • iOS 26+ device or simulator
  • A legally dumped PS2 BIOS (SCPH-70012.bin recommended)
  • PS2 game images in ISO or BIN format

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
