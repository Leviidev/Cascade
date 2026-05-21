#include "spu2.h"
#include <cstring>
#include <algorithm>
#include <cmath>

// ADPCM filter coefficients (standard PS1/PS2 values)
static const f32 k_coeff[5][2] = {
    { 0.f,       0.f       },
    { 60.f/64.f, 0.f       },
    {115.f/64.f,-52.f/64.f },
    { 98.f/64.f,-55.f/64.f },
    {122.f/64.f,-60.f/64.f },
};

// ADSR envelope rate table (increment per sample tick)
// Simplified: just encode as shift amounts
static i32 adsrRateToInc(int rate, bool exp) {
    if (rate < 0) rate = 0;
    if (rate > 127) rate = 127;
    // Very rough approximation of hardware envelope rates
    i32 inc = (i32)(1 << std::max(0, 7 - (rate >> 3)));
    return exp ? (inc * inc >> 15) + 1 : inc;
}

void SPU2::reset() {
    memset(sram, 0, sizeof(sram));
    memset(voices, 0, sizeof(voices));
    for (auto& v : voices) {
        v.phase    = SPU2Voice::STOPPED;
        v.blockPos = 28; // force decode on first use
        v.active   = false;
    }
    masterVolL   = 0x3FFF;
    masterVolR   = 0x3FFF;
    cycleAccum   = 0;
    // Both indices are now in SAMPLE-PAIR units (0 .. AUDIO_BUF_SIZE-1)
    audioBufHead = 0;
    audioBufTail = 0;
}

// ── Tick (called once per IOP cycle at ~36.864 MHz) ────────────────────────

void SPU2::tick() {
    cycleAccum++;
    if (cycleAccum >= CYCLES_PER_SAMPLE) {
        cycleAccum -= CYCLES_PER_SAMPLE;
        generateSample();
    }
}

// ── Generate one stereo sample ─────────────────────────────────────────────

void SPU2::generateSample() {
    i32 mixL = 0, mixR = 0;

    for (int i = 0; i < SPU2_VOICES; i++) {
        SPU2Voice& v = voices[i];
        if (!v.active) continue;

        stepADSR(v);
        if (v.phase == SPU2Voice::STOPPED) continue;

        i16 s = advanceVoice(v);

        // ADSR volume scale (0..0x7FFF) × voice volume (0..0x7FFF)
        i32 env   = (i32)v.adsrVolume;
        i32 scaled = (i32)s * env >> 15;

        // Panning
        mixL += scaled * (i32)v.volL >> 15;
        mixR += scaled * (i32)v.volR >> 15;
    }

    // Master volume
    i32 outL = (mixL * (i32)masterVolL) >> 15;
    i32 outR = (mixR * (i32)masterVolR) >> 15;

    // Hard-clamp to 16-bit
    i16 sL = (i16)std::max(-32768, std::min(32767, outL));
    i16 sR = (i16)std::max(-32768, std::min(32767, outR));

    // Compute next head position (ring buffer wraps at AUDIO_BUF_SIZE pairs)
    int nextHead = (audioBufHead + 1) % AUDIO_BUF_SIZE;
    if (nextHead == audioBufTail) {
        // Buffer full: drop oldest sample
        audioBufTail = (audioBufTail + 1) % AUDIO_BUF_SIZE;
    }

    audioBuf[audioBufHead * 2 + 0] = sL;
    audioBuf[audioBufHead * 2 + 1] = sR;
    audioBufHead = nextHead;
}

// ── Drain audio samples ────────────────────────────────────────────────────

int SPU2::getAudioSamples(i16* out, int maxPairs) {
    int written = 0;
    while (written < maxPairs && audioBufTail != audioBufHead) {
        out[written * 2 + 0] = audioBuf[audioBufTail * 2 + 0];
        out[written * 2 + 1] = audioBuf[audioBufTail * 2 + 1];
        audioBufTail = (audioBufTail + 1) % AUDIO_BUF_SIZE;
        written++;
    }
    return written;
}

// ── ADPCM block decode ────────────────────────────────────────────────────

void SPU2::decodeADPCMBlock(SPU2Voice& v) {
    u32 addr = v.curAddr;
    if (addr + 16 > SPU2_SRAM_SIZE) {
        v.active = false;
        v.phase  = SPU2Voice::STOPPED;
        return;
    }

    u8 shiftFilter = sram[addr];
    u8 flags       = sram[addr + 1];
    u8 shift  = shiftFilter & 0x0F;
    u8 filter = (shiftFilter >> 4) & 0x07;
    if (filter >= 5) filter = 0;

    f32 f0 = k_coeff[filter][0];
    f32 f1 = k_coeff[filter][1];

    // Decode 14 nibbles → 28 samples (2 nibbles per byte, bytes 2-15)
    for (int s = 0; s < 28; s++) {
        int byteIdx = 2 + (s / 2);
        u8 nibble   = (s & 1) ? (sram[addr + byteIdx] >> 4) : (sram[addr + byteIdx] & 0x0F);

        // Sign-extend nibble
        i16 raw = (i16)((nibble & 0x8) ? (i32)(nibble | 0xFFF0) : nibble);
        // Shift left to 16-bit range
        i32 s16 = (i32)raw << (12 - shift);

        // Apply filter
        f32 out = (f32)s16 + f0 * (f32)v.prev1 + f1 * (f32)v.prev2;
        i32 clamped = (i32)clampf(out, -32768.f, 32767.f);
        v.decoded[s] = (i16)clamped;
        v.prev2 = v.prev1;
        v.prev1 = clamped;
    }

    // Handle loop flags
    bool loopEnd   = (flags & 0x01) != 0;
    bool loopRepeat = (flags & 0x02) != 0;
    bool loopStart  = (flags & 0x04) != 0;

    if (loopStart) v.loopAddr = addr;

    if (loopEnd) {
        if (loopRepeat) {
            v.curAddr  = v.loopAddr;
        } else {
            v.active = false;
            v.phase  = SPU2Voice::STOPPED;
            return;
        }
    } else {
        v.curAddr = addr + 16;
    }

    v.blockPos = 0;
}

// ── Advance one voice by one output sample ────────────────────────────────

i16 SPU2::advanceVoice(SPU2Voice& v) {
    if (v.blockPos >= 28) {
        decodeADPCMBlock(v);
        if (!v.active) return 0;
    }

    // Current sample (integer position)
    i16 s0 = v.decoded[v.blockPos];

    // Simple nearest-neighbour resampling using 16.16 fixed-point pitch counter
    // pitch = freq * 4096 / 44100; we step samplePos by pitch each output sample
    v.samplePos += v.pitch;
    while (v.samplePos >= 0x1000) { // 0x1000 = one ADPCM sample step
        v.samplePos -= 0x1000;
        v.blockPos++;
        if (v.blockPos >= 28) {
            decodeADPCMBlock(v);
            if (!v.active) return s0;
        }
    }

    return s0;
}

// ── ADSR envelope stepping ────────────────────────────────────────────────

void SPU2::stepADSR(SPU2Voice& v) {
    switch (v.phase) {
    case SPU2Voice::ATTACK: {
        bool expMode = (v.adsrReg1 >> 15) & 1;
        int  rate    = (int)((v.adsrReg1 >> 8) & 0x7F);
        i32  inc     = adsrRateToInc(rate, expMode);
        v.adsrVolume += inc;
        if (v.adsrVolume >= 0x7FFF) {
            v.adsrVolume = 0x7FFF;
            v.phase = SPU2Voice::DECAY;
        }
        break;
    }
    case SPU2Voice::DECAY: {
        int rate     = (int)((v.adsrReg1 >> 4) & 0x0F) << 2; // 4-bit → 0-60
        i32 dec      = adsrRateToInc(rate, true);
        v.adsrVolume -= dec;
        i32 susLevel = (i32)((((v.adsrReg1 & 0xF) + 1) << 11)); // 0-15 → 0-0x7800
        if (v.adsrVolume <= susLevel || v.adsrVolume < 0) {
            v.adsrVolume = std::max(susLevel, 0);
            v.phase = SPU2Voice::SUSTAIN;
        }
        break;
    }
    case SPU2Voice::SUSTAIN: {
        bool dir  = (v.adsrReg2 >> 31) & 1; // 0=inc, 1=dec
        bool exp  = (v.adsrReg2 >> 30) & 1;
        int  rate = (int)((v.adsrReg2 >> 24) & 0x7F);
        i32  delta = adsrRateToInc(rate, exp);
        if (dir) v.adsrVolume -= delta;
        else     v.adsrVolume += delta;
        v.adsrVolume = std::max(0, std::min(0x7FFF, (int)v.adsrVolume));
        break;
    }
    case SPU2Voice::RELEASE: {
        bool exp  = (v.adsrReg2 >> 23) & 1;
        int  rate = (int)((v.adsrReg2 >> 16) & 0x1F) << 2;
        i32  dec  = adsrRateToInc(rate, exp);
        v.adsrVolume -= dec;
        if (v.adsrVolume <= 0) {
            v.adsrVolume = 0;
            v.phase      = SPU2Voice::STOPPED;
            v.active     = false;
        }
        break;
    }
    default:
        break;
    }
}

// ── SPU2 IO register access ────────────────────────────────────────────────
// Offset is relative to 0x1000'A000.
// Voices occupy 0x000-0x5FF (0x30 bytes each × 48 voices = 0x5A0, padded to 0x600).
// Voice n base = n * 0x10 (first SPU2 core = 0, second = 0x400)

u32 SPU2::readIO(u32 offset) {
    // Voice registers: 2 cores × 24 voices × 0x10 bytes per voice
    // Core 0: voice 0-23 at 0x000 – 0x17F
    // Core 1: voice 24-47 at 0x400 – 0x57F
    if (offset < 0x180) {
        int vi = (int)(offset / 0x10);
        int reg = (int)(offset % 0x10);
        if (vi < 24) {
            SPU2Voice& v = voices[vi];
            switch (reg) {
            case 0x00: return (u32)v.volL;
            case 0x02: return (u32)v.volR;
            case 0x04: return (u32)v.pitch;
            case 0x06: return v.startAddr >> 3;
            case 0x08: return v.adsrReg1;
            case 0x0A: return v.adsrReg2;
            case 0x0C: return (u32)v.adsrVolume;
            case 0x0E: return v.loopAddr >> 3;
            default:   return 0;
            }
        }
    }
    if (offset >= 0x400 && offset < 0x580) {
        int vi = 24 + (int)((offset - 0x400) / 0x10);
        int reg = (int)((offset - 0x400) % 0x10);
        if (vi < 48) {
            SPU2Voice& v = voices[vi];
            switch (reg) {
            case 0x00: return (u32)v.volL;
            case 0x02: return (u32)v.volR;
            case 0x04: return (u32)v.pitch;
            case 0x06: return v.startAddr >> 3;
            case 0x08: return v.adsrReg1;
            case 0x0A: return v.adsrReg2;
            case 0x0C: return (u32)v.adsrVolume;
            case 0x0E: return v.loopAddr >> 3;
            default:   return 0;
            }
        }
    }
    // Core master volume / control registers
    if (offset == 0x180) return (u32)(u16)masterVolL; // Core 0 MVOL L
    if (offset == 0x182) return (u32)(u16)masterVolR; // Core 0 MVOL R
    if (offset == 0x580) return (u32)(u16)masterVolL; // Core 1
    if (offset == 0x582) return (u32)(u16)masterVolR;
    // SRAM transfer addr / data
    if (offset == 0x1A4) return transferAddr >> 3;
    // Status: always "ready"
    if (offset == 0x344 || offset == 0x744) return 0x80u;
    return 0u;
}

void SPU2::writeIO(u32 offset, u32 value) {
    // Core 0 voices: 0x000 – 0x17F
    if (offset < 0x180) {
        int vi  = (int)(offset / 0x10);
        int reg = (int)(offset % 0x10);
        if (vi < 24) {
            SPU2Voice& v = voices[vi];
            switch (reg) {
            case 0x00: v.volL     = (u16)(value & 0x7FFF); break;
            case 0x02: v.volR     = (u16)(value & 0x7FFF); break;
            case 0x04: v.pitch    = (u16)(value & 0x3FFF); break;
            case 0x06: v.startAddr = (value & 0xFFFF) << 3; break;
            case 0x08: v.adsrReg1 = value & 0xFFFF; break;
            case 0x0A: v.adsrReg2 = value & 0xFFFF; break;
            case 0x0C: v.adsrVolume = (i32)(value & 0x7FFF); break;
            case 0x0E: v.loopAddr  = (value & 0xFFFF) << 3; break;
            default:   break;
            }
        }
        return;
    }
    // Core 1 voices: 0x400 – 0x57F
    if (offset >= 0x400 && offset < 0x580) {
        int vi  = 24 + (int)((offset - 0x400) / 0x10);
        int reg = (int)((offset - 0x400) % 0x10);
        if (vi < 48) {
            SPU2Voice& v = voices[vi];
            switch (reg) {
            case 0x00: v.volL     = (u16)(value & 0x7FFF); break;
            case 0x02: v.volR     = (u16)(value & 0x7FFF); break;
            case 0x04: v.pitch    = (u16)(value & 0x3FFF); break;
            case 0x06: v.startAddr = (value & 0xFFFF) << 3; break;
            case 0x08: v.adsrReg1 = value & 0xFFFF; break;
            case 0x0A: v.adsrReg2 = value & 0xFFFF; break;
            case 0x0C: v.adsrVolume = (i32)(value & 0x7FFF); break;
            case 0x0E: v.loopAddr  = (value & 0xFFFF) << 3; break;
            default:   break;
            }
        }
        return;
    }

    // Core 0: KON/KOFF (key on/off) at 0x188 / 0x18C
    if (offset == 0x188 || offset == 0x18A) { // KON core 0 (low/high 16 bits of 24-voice mask)
        u32 mask = (offset == 0x18A) ? (value << 16) : (value & 0xFFFF);
        for (int i = 0; i < 24; i++) {
            if (mask & (1u << i)) {
                SPU2Voice& v = voices[i];
                v.curAddr    = v.startAddr;
                v.samplePos  = 0;
                v.blockPos   = 28;
                v.prev1 = v.prev2 = 0;
                v.phase      = SPU2Voice::ATTACK;
                v.adsrVolume = 0;
                v.active     = true;
            }
        }
        return;
    }
    if (offset == 0x18C || offset == 0x18E) { // KOFF core 0
        u32 mask = (offset == 0x18E) ? (value << 16) : (value & 0xFFFF);
        for (int i = 0; i < 24; i++) {
            if (mask & (1u << i)) {
                if (voices[i].phase != SPU2Voice::STOPPED)
                    voices[i].phase = SPU2Voice::RELEASE;
            }
        }
        return;
    }
    // Core 1: KON/KOFF at 0x588 / 0x58C
    if (offset == 0x588 || offset == 0x58A) {
        u32 mask = (offset == 0x58A) ? (value << 16) : (value & 0xFFFF);
        for (int i = 0; i < 24; i++) {
            if (mask & (1u << i)) {
                SPU2Voice& v = voices[24 + i];
                v.curAddr    = v.startAddr;
                v.samplePos  = 0;
                v.blockPos   = 28;
                v.prev1 = v.prev2 = 0;
                v.phase      = SPU2Voice::ATTACK;
                v.adsrVolume = 0;
                v.active     = true;
            }
        }
        return;
    }
    if (offset == 0x58C || offset == 0x58E) {
        u32 mask = (offset == 0x58E) ? (value << 16) : (value & 0xFFFF);
        for (int i = 0; i < 24; i++) {
            if (mask & (1u << i)) {
                if (voices[24 + i].phase != SPU2Voice::STOPPED)
                    voices[24 + i].phase = SPU2Voice::RELEASE;
            }
        }
        return;
    }

    // Master volumes
    if (offset == 0x180) { masterVolL = (i16)(value & 0x7FFF); return; }
    if (offset == 0x182) { masterVolR = (i16)(value & 0x7FFF); return; }
    if (offset == 0x580) { masterVolL = (i16)(value & 0x7FFF); return; }
    if (offset == 0x582) { masterVolR = (i16)(value & 0x7FFF); return; }

    // SRAM transfer address
    if (offset == 0x1A4) { transferAddr = (value & 0xFFFF) << 3; return; }
    if (offset == 0x5A4) { transferAddr = (value & 0xFFFF) << 3; return; }

    // SRAM data port — write to SRAM at transferAddr
    if (offset == 0x1A8 || offset == 0x5A8) {
        if (transferAddr + 1 < SPU2_SRAM_SIZE) {
            write_le<u16>(sram + transferAddr, (u16)value);
            transferAddr += 2;
        }
        return;
    }
    // IRQ address
    if (offset == 0x19C) { irqAddr = (value & 0xFFFF) << 3; return; }
    if (offset == 0x59C) { irqAddr = (value & 0xFFFF) << 3; return; }
}
