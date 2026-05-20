# Cascade — iOS PS2 Emulator

## Overview

Cascade is a PlayStation 2 emulator for iPhone and iPad, written in Swift 6 with a native iOS 26 "Liquid Glass" UI. It implements the core PS2 hardware in software:

- **Emotion Engine** — Full MIPS R5900 interpreter with 128-bit GPR, FPU (COP1), and MMI SIMD extensions
- **IOP** — MIPS R3000A secondary processor for I/O, audio, and peripherals
- **Graphics Synthesizer** — Software rasterizer outputting to a 4 MB VRAM buffer, delivered to Metal
- **SPU2** — 48-voice ADPCM audio engine with ADSR envelopes, streamed via AVAudio
- **CDVD** — ISO 9660 disc reader with SYSTEM.CNF parsing and region detection
- **DMAC / INTC / EETimer** — DMA controller, interrupt controller, and EE timers
- **PadManager** — DualShock 2 emulation with on-screen controls and MFi/Bluetooth controller support

## Project Structure

```
Cascade/
├── App/
│   ├── CascadeApp.swift          # @main entry point
│   └── Info.plist
├── Core/
│   ├── PS2Emulator.swift         # Orchestrator, run loop, save states
│   ├── EmulatorState.swift       # SwiftUI ObservableObject
│   ├── GameLibraryManager.swift  # Library persistence
│   └── PS2/
│       ├── EmotionEngine.swift   # EE CPU (MIPS R5900)
│       ├── COP0.swift            # System coprocessor + TLB
│       ├── MemoryBus.swift       # 32 MB RAM + BIOS + memory map
│       ├── GraphicsSynthesizer.swift
│       ├── IOP.swift             # MIPS R3000A
│       ├── SPU2.swift            # 48-voice audio
│       ├── CDVD.swift            # Disc/ISO reader
│       ├── DMAC.swift            # DMA + INTC + EETimer
│       └── PadManager.swift      # Controller input
├── UI/
│   ├── ContentView.swift
│   ├── LibraryView.swift         # Game grid
│   ├── GameDetailView.swift      # Game metadata + launch
│   ├── EmulatorView.swift        # Full-screen game + in-game menu
│   ├── OnScreenControllerView.swift  # Liquid Glass DualShock
│   └── SettingsView.swift
└── Assets.xcassets/
Cascade.xcodeproj/
BuildTools/
├── build_ipa.sh                  # Build + export unsigned IPA
└── build_simulator.sh            # Build + launch in simulator
docs/
└── COMPATIBILITY.md
```

## Building

Building requires **macOS with Xcode 16+**. Use the Replit workflows:

- **Build IPA (Release)** — Produces `build/IPA/Cascade.ipa` (unsigned, for sideloading)
- **Build IPA (Debug)** — Same but with debug symbols

Or run manually:
```bash
bash BuildTools/build_ipa.sh --release
```

## Requirements (Runtime)

- iOS 18+ device or simulator (deployment target; UI targets iOS 26 Liquid Glass style)
- A legally dumped PS2 BIOS (`SCPH-70012.bin` recommended)
- PS2 game images in ISO or BIN format

## User Preferences

- iOS 26 "Liquid Glass" UI style throughout
- Dark mode preferred
- Glassmorphism buttons with spring animations and haptic feedback
- PRs and contributions are welcome
