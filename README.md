# Cascade

<p align="center">
  <img src="docs/icon.png" width="120" alt="Cascade Logo" />
</p>

<p align="center">
  <strong>A PlayStation 2 emulator for iPhone and iPad — written in Swift 6</strong><br/>
  Native iOS 26 Liquid Glass UI · Metal · CHD v5 · GameShark Cheats
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-16%2B-blue?style=flat-square&logo=apple" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift" />
  <img src="https://img.shields.io/badge/Metal-GPU-silver?style=flat-square" />
  <img src="https://img.shields.io/badge/TrollStore-supported-purple?style=flat-square" />
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square" />
</p>

---

## What is Cascade?

Cascade is a PlayStation 2 emulator for iOS. It runs PS2 game images directly on your iPhone or iPad with a clean, native Liquid Glass UI. It targets accuracy, performance, and a polished user experience — with full support for sideloading on iOS 16+ via TrollStore, AltStore, or Sideloadly.

---

## Features

| Feature | Status |
|---|---|
| MIPS R5900 Emotion Engine interpreter | ✅ |
| Block-recompiling JIT (with JITless fallback) | ✅ |
| Software Graphics Synthesizer via Metal | ✅ |
| 48-voice SPU2 ADPCM audio | ✅ |
| ISO · BIN/CUE · CHD v5 disc images | ✅ |
| 8 save-state slots per game | ✅ |
| GameShark / CodeBreaker cheat codes | ✅ |
| In-game cheat toggle from pause menu | ✅ |
| On-screen DualShock 2 controller | ✅ |
| MFi / Bluetooth physical controller | ✅ |
| Game library with collections & favourites | ✅ |
| Crash reporter with shareable logs | ✅ |
| Background keep-alive | ✅ |
| iOS 16+ deployment (TrollStore sideloading) | ✅ |
| iOS 26 Liquid Glass UI | ✅ |

---

## Installation

### Option 1 — AltStore / SideStore source (easiest)

Add the Cascade source URL to AltStore or SideStore:

```
https://raw.githubusercontent.com/leviidev/Cascade/main/source.json
```

Search for **Cascade** and tap **Install**.

### Option 2 — TrollStore (iOS 16 / 17, permanent install)

1. Download the latest `Cascade.ipa` from [Releases](https://github.com/leviidev/Cascade/releases).
2. Open it with **TrollStore** on your device.

### Option 3 — Sideloadly / AltStore direct IPA

1. Download the latest `Cascade.ipa` from [Releases](https://github.com/leviidev/Cascade/releases).
2. Sideload with Sideloadly, AltStore, or any compatible tool.

---

## Getting Started

### 1. Add your BIOS

Open **Cascade** → **Settings → BIOS** and import your legally-dumped PS2 BIOS (`SCPH-70012.bin` recommended). Cascade detects the BIOS region automatically.

### 2. Add games

Tap **＋** in the Library tab and import a game image from the Files app. Supported formats: `.iso`, `.bin` (with `.cue`), `.chd`.

### 3. Play

Tap any game to launch it. Use the on-screen DualShock 2 controller or connect an MFi/Bluetooth controller (DualSense, DualShock 4, Xbox Series, Switch Pro all work).

---

## In-Game Controls

| Action | How |
|---|---|
| Open pause menu | Swipe down from top of screen |
| Save / Load state | Pause menu → Save State / Load State |
| Toggle cheats | Pause menu → Cheats |
| Screenshot | Pause menu → Screenshot |
| Exit to library | Pause menu → Exit to Library |

---

## Cheat Codes

Cascade supports **GameShark / CodeBreaker** style codes in the format:

```
XXXXXXXX YYYYYYYY
```

- Bits 31–28 of the address word select write width: `0` = 8-bit, `1` = 16-bit, `2+` = 32-bit.
- Bits 24–0 are the PS2 RAM offset.

**Managing cheats:**
- *Before launching* — tap the game in your library → scroll to the **Cheats** section → tap **+**.
- *Mid-game* — open the pause menu → tap **Cheats** to toggle any code live.

---

## Supported Disc Formats

| Format | Notes |
|---|---|
| `.iso` | Single-track ISO 9660 |
| `.bin` / `.cue` | Multi-track BIN/CUE |
| `.chd` | CHD v5 — NONE, ZLIB, LZMA compression |

---

## Compatibility

See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for the current game compatibility list.

To submit a report, open an [Issue](https://github.com/leviidev/Cascade/issues) with:
- Game title and Disc ID (shown in the game detail screen)
- iOS device model and iOS version
- What happens — boots? crashes? graphical issues?
- Any crash log exported from **Settings → Diagnostics → Share Latest Log**

---

## Building from Source

Requires **macOS with Xcode 16+**.

```bash
# Clone
git clone https://github.com/leviidev/Cascade.git
cd Cascade

# Build unsigned IPA (Release)
bash BuildTools/build_ipa.sh --release

# Build unsigned IPA (Debug)
bash BuildTools/build_ipa.sh --debug

# Build & run in Simulator
bash BuildTools/build_simulator.sh
```

Output: `build/IPA/Cascade.ipa`

---

## Project Structure

```
Cascade/
├── App/
│   ├── CascadeApp.swift              # @main entry point
│   └── Info.plist
├── Core/
│   ├── PS2Emulator.swift             # Orchestrator, run loop, cheat application
│   ├── EmulatorState.swift           # SwiftUI ObservableObject
│   ├── GameLibraryManager.swift      # Library persistence
│   ├── CrashReporter.swift           # Error logging + log export
│   └── PS2/
│       ├── EmotionEngine.swift       # EE CPU (MIPS R5900)
│       ├── COP0.swift                # System coprocessor + TLB
│       ├── MemoryBus.swift           # 32 MB RAM + BIOS + memory map
│       ├── GraphicsSynthesizer.swift
│       ├── IOP.swift                 # MIPS R3000A
│       ├── SPU2.swift                # 48-voice audio
│       ├── CDVD.swift                # Disc/ISO/CHD reader
│       ├── CHDReader.swift           # CHD v5 decompressor
│       ├── DMAC.swift                # DMA + INTC + EETimer
│       ├── PadManager.swift          # Controller input
│       └── CheatManager.swift        # GameShark/CodeBreaker cheat engine
├── UI/
│   ├── ContentView.swift
│   ├── LibraryView.swift
│   ├── GameDetailView.swift
│   ├── EmulatorView.swift            # Full-screen game + pause menu + cheat sheet
│   ├── OnScreenControllerView.swift
│   ├── SettingsView.swift
│   └── ViewHelpers.swift             # PulseIfAvailable, ShareSheet, IdentifiableURL
└── Assets.xcassets/
source.json                           # AltStore / SideStore source
```

---

## Requirements

- **iOS 16.0 or later** (iPhone or iPad)
- A legally-dumped PS2 BIOS
- PS2 game images in ISO, BIN/CUE, or CHD format

The UI targets **iOS 26 Liquid Glass** and degrades gracefully on iOS 16–17.

---

## Contributing

Pull requests and compatibility reports are welcome. Please open an issue before starting large features.

---

## Legal

Cascade is an emulator. It does not include any Sony intellectual property, BIOS files, or game images. You are responsible for the legality of your BIOS dumps and game images in your jurisdiction.

PlayStation and PlayStation 2 are trademarks of Sony Interactive Entertainment.
