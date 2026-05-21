#include "spu2.h"
#include <cstring>
#include <algorithm>
#include <cmath>

// ADPCM filter coefficients (standard PS1/PS2 values)
static const f32 k_coeff[5][2] = {
    { 0.f,       0.f      },
    { 60.f/64.f, 0.f      },
    {115.f/64.f,-52.f/64.f},
    { 98.f/64.f,-55.f/64.f},
    {122.f/64.f,-60.f/64.f},
};

void SPU2::reset() {
    memset(sram, 0, sizeof(sram));
    memset(voices, 0, sizeof(voices));
    for (auto& v : voices) { v.phase = SPU2Voice::STOPPED; v.blockPos = 28; }
    masterVolL = masterVolR = 0x3FFF;
    cycleAccum = 0;
    audioBufWrite = audioBufRead = 0;
}

// ── Tick (called once per IOP cycle at ~36.864 MHz) ───────────────────────────

void SPU2::tick() {
    cycleAccum++;
    if (cycleAccum >= CYCLES_PER_SAMPLE) {
        cycleAccum -= CYCLES_PER_SAMPLE;
        generateSample();
    }
}

// ── Generate one stereo sample ────────────────────────────────────────────────

void SPU2::generateSample() {
    i32 mixL = 0, mixR = 0;
    for (int i = 0; i < SPU2_VOICES; i++) {
        SPU2Voice& v = voices[i];
        if (!v.active) continue;
        i16 s = advanceVoice(v);
        // Volume scale: 0x3FFF = 1.0
        mixL += (i32)s * (i32)v.volL >> 15;
        mixR += (i32)s * (i32)v.volR >> 15;
    }
    // Master volume
    i32 outL = (mixL * (i32)masterVolL) >> 15;
    i32 outR = (mixR * (i32)masterVolR) >> 15;
    // Clamp to 16-bit
    i16 sL = (i16)std::max(-32768, std::min(32767, outL));
    i16 sR = (i16)std::max(-32768, std::min(32767, outR));

    int next = (audioBufWrite + 2) % (AUDIO_BUF_SIZE * 2);
    if (next != audioBufRead * 2) { // buffer not full
        audioBuf[audioBufWrite & (AUDIO_BUF_SIZE * 2 - 1)] = sL;
        audioBuf[(audioBufWrite + 1) & (AUDIO_BUF_SIZE * 2 - 1)] = sR;
        audioBufWrite = (audioBufWrite + 2) % (AUDIO_BUF_SIZE * 2);
    }
}

int SPU2::getAudioSamples(i16* out, int maxPairs) {
    int written = 0;
    while (written < maxPairs && audioBufRead != audioBufWrite / 2) {
        out[written * 2 + 0] = audioBuf[audioBufRead * 2];
        out[written * 2 + 1] = audioBuf[audioBufRead * 2 + 1];
        audioBufRead = (audioBufRead + 1) % AUDIO_BUF_SIZE;
        written++;
    }
    return written;
}

// ── ADPCM decode ─────────────────────────────────────────────────────────────

void SPU2::decodeADPCMBlock(SPU2Voice& v) {
    u32 addr = v.curAddr;
    if (addr + 16 > SPU2_SRAM_SIZE) return;

    u8 shift    = sram[addr] & 0x0F;
    u8 filterN  = (sram[addr] >> 4) & 0x07;
    u8 flags    = sram[addr + 1];
    if (filterN > 4) filterN = 4;

    f32 f0 = k_coeff[filterN][0];
    f32 f1 = k_coeff[filterN][1];
    u32 realShift = (shift > 12) ? 0 : (12 - shift);

    // Each nibble is one sample
    for (int i = 0; i < 28; i++) {
        u8 byte = sram[addr + 2 + i / 2];
        i8 nibble;
        if (i & 1) nibble = (i8)(byte >> 4);
        else       nibble = (i8)((byte & 0x0F) << 4) >> 4;

        i32 sample = (i32)nibble << realShift;
        i32 result = sample + (i32)(f0 * v.prev1 + f1 * v.prev2);
        // Clamp to 16-bit
        result = std::max(-32768, std::min(32767, result));
        v.decoded[i] = (i16)result;
        v.prev2 = v.prev1;
        v.prev1 = result;
    }

    v.blockPos = 0;

    // Check loop flags
    bool loopEnd   = (flags >> 1) & 1;
    bool loopStart = flags & 1;
    (void)loopStart;
    if (loopEnd) {
        if ((flags >> 2) & 1) {
            v.curAddr = v.loopAddr;
        } else {
            v.active = false;
            v.phase = SPU2Voice::STOPPED;
            v.curAddr = v.loopAddr;
        }
    } else {
        v.curAddr += 16;
        if (v.curAddr >= SPU2_SRAM_SIZE) v.curAddr = v.loopAddr;
    }
}

// ── Advance voice by one sample ───────────────────────────────────────────────

i16 SPU2::advanceVoice(SPU2Voice& v) {
    stepADSR(v);
    if (!v.active) return 0;

    // Get current decoded sample
    if (v.blockPos >= 28) decodeADPCMBlock(v);
    i16 raw = v.decoded[v.blockPos];

    // Advance sample position by pitch
    v.samplePos += v.pitch;
    while (v.samplePos >= 0x1000) {
        v.samplePos -= 0x1000;
        v.blockPos++;
        if (v.blockPos >= 28) { decodeADPCMBlock(v); break; }
    }

    // Scale by ADSR volume
    i32 out = ((i32)raw * v.adsrVolume) >> 15;
    return (i16)std::max(-32768, std::min(32767, out));
}

// ── ADSR envelope ─────────────────────────────────────────────────────────────

void SPU2::stepADSR(SPU2Voice& v) {
    if (!v.active) return;
    if (v.keyOff && v.phase != SPU2Voice::RELEASE) {
        v.phase = SPU2Voice::RELEASE;
        v.keyOff = false;
    }
    switch (v.phase) {
    case SPU2Voice::ATTACK: {
        i32 rate = adsrAttackRate(v.adsrReg1);
        v.adsrVolume = std::min(0x7FFF, v.adsrVolume + rate);
        if (v.adsrVolume >= 0x7FFF) v.phase = SPU2Voice::DECAY;
        break;
    }
    case SPU2Voice::DECAY: {
        i32 rate = adsrDecayRate(v.adsrReg1);
        v.adsrVolume = std::max(0, (i32)(v.adsrVolume * rate) >> 11);
        i32 sl = adsrSustainLevel(v.adsrReg1);
        if (v.adsrVolume <= sl) { v.adsrVolume = sl; v.phase = SPU2Voice::SUSTAIN; }
        break;
    }
    case SPU2Voice::SUSTAIN: {
        i32 rate = adsrSustainRate(v.adsrReg2);
        v.adsrVolume = std::max(0, std::min(0x7FFF, v.adsrVolume + rate));
        break;
    }
    case SPU2Voice::RELEASE: {
        i32 rate = adsrReleaseRate(v.adsrReg2);
        v.adsrVolume = std::max(0, v.adsrVolume - rate);
        if (v.adsrVolume == 0) { v.active = false; v.phase = SPU2Voice::STOPPED; }
        break;
    }
    default: break;
    }
}

i32 SPU2::adsrAttackRate(u32 adsr1) const {
    // Attack rate: bits [14:8] of adsr1, linear mode
    u32 ar = (adsr1 >> 8) & 0x7F;
    if (!ar) return 0x7FFF;
    return std::max(1, (i32)(0x7FFF >> (ar >> 2)));
}

i32 SPU2::adsrDecayRate(u32 adsr1) const {
    u32 dr = (adsr1 >> 4) & 0xF;
    if (!dr) return 0;
    return 2000 - (i32)dr * 120;
}

i32 SPU2::adsrSustainLevel(u32 adsr1) const {
    u32 sl = adsr1 & 0xF;
    return (i32)((sl + 1) * (0x7FFF / 16));
}

i32 SPU2::adsrSustainRate(u32 adsr2) const {
    i32 sr = (i32)((adsr2 >> 6) & 0x7F);
    bool dec = (adsr2 >> 14) & 1;
    if (!sr) return 0;
    i32 rate = std::max(1, 0x10 >> (sr >> 3));
    return dec ? -rate : rate;
}

i32 SPU2::adsrReleaseRate(u32 adsr2) const {
    u32 rr = adsr2 & 0x1F;
    if (!rr) return 0x7FFF;
    return std::max(1, 0x7FFF >> (int)rr);
}

// ── I/O register access ───────────────────────────────────────────────────────

u32 SPU2::readIO(u32 offset) {
    // Simplified: return 0 for most registers
    // Key status register at offset 0x1A0 (Voice KON/KOFF status)
    u32 idx = offset >> 1;
    if (idx < 48) {
        // Voice volume registers
    }
    return 0;
}

void SPU2::writeIO(u32 offset, u32 value) {
    // Determine which core (0x000-0x17F = Core0, 0x400-0x57F = Core1)
    // Each voice occupies 16 bytes in the I/O range
    // Offset layout (per core):
    //  voice*0x10 + 0  = VOLL  (left vol)
    //  voice*0x10 + 2  = VOLR
    //  voice*0x10 + 4  = PITCH
    //  voice*0x10 + 6  = ADSR1
    //  voice*0x10 + 8  = ADSR2
    //  voice*0x10 + 0xA = ENVX
    //  voice*0x10 + 0xC = ADDRSA (start addr / 8)
    //  voice*0x10 + 0xE = ADDRLO

    int core = (offset >= 0x400) ? 1 : 0;
    u32 cOff = offset - (core ? 0x400u : 0u);

    if (cOff < 0x180) { // Voice registers
        int vIdx = core * 24 + (int)(cOff / 16);
        int reg  = (int)(cOff % 16);
        if (vIdx >= SPU2_VOICES) return;
        SPU2Voice& v = voices[vIdx];
        switch (reg) {
        case 0x00: v.volL  = (u16)(value & 0x7FFF); break;
        case 0x02: v.volR  = (u16)(value & 0x7FFF); break;
        case 0x04: v.pitch = (u16)(value & 0x3FFF); break;
        case 0x06: v.adsrReg1 = value & 0xFFFF; break;
        case 0x08: v.adsrReg2 = value & 0xFFFF; break;
        case 0x0C: v.startAddr = (value & 0xFFFF) << 3; break;
        case 0x0E: v.loopAddr  = (value & 0xFFFF) << 3; break;
        default: break;
        }
    } else if (cOff == 0x1A0) { // KON low (voices 0-15)
        for (int i = 0; i < 16; i++) {
            if ((value >> i) & 1) {
                int vIdx = core * 24 + i;
                if (vIdx < SPU2_VOICES) {
                    voices[vIdx].curAddr   = voices[vIdx].startAddr;
                    voices[vIdx].blockPos  = 28;
                    voices[vIdx].prev1 = voices[vIdx].prev2 = 0;
                    voices[vIdx].samplePos = 0;
                    voices[vIdx].adsrVolume = 0;
                    voices[vIdx].phase  = SPU2Voice::ATTACK;
                    voices[vIdx].active = true;
                    voices[vIdx].keyOn  = true;
                    voices[vIdx].keyOff = false;
                }
            }
        }
    } else if (cOff == 0x1A2) { // KON high (voices 16-23)
        for (int i = 0; i < 8; i++) {
            if ((value >> i) & 1) {
                int vIdx = core * 24 + 16 + i;
                if (vIdx < SPU2_VOICES) {
                    voices[vIdx].curAddr  = voices[vIdx].startAddr;
                    voices[vIdx].blockPos = 28;
                    voices[vIdx].prev1 = voices[vIdx].prev2 = 0;
                    voices[vIdx].adsrVolume = 0;
                    voices[vIdx].phase  = SPU2Voice::ATTACK;
                    voices[vIdx].active = true;
                }
            }
        }
    } else if (cOff == 0x1A4) { // KOFF low
        for (int i = 0; i < 16; i++) {
            if ((value >> i) & 1) {
                int vIdx = core * 24 + i;
                if (vIdx < SPU2_VOICES) voices[vIdx].keyOff = true;
            }
        }
    } else if (cOff == 0x1A6) { // KOFF high
        for (int i = 0; i < 8; i++) {
            if ((value >> i) & 1) {
                int vIdx = core * 24 + 16 + i;
                if (vIdx < SPU2_VOICES) voices[vIdx].keyOff = true;
            }
        }
    } else if (cOff == 0x1C0) { // Transfer address
        transferAddr = (value & 0xFFFF) << 3;
    } else if (cOff == 0x1C4) { // Transfer data
        u16 data16 = (u16)value;
        if (transferAddr + 1 < SPU2_SRAM_SIZE) {
            write_le<u16>(sram + transferAddr, data16);
            transferAddr += 2;
        }
    } else if (cOff == 0x1A8) { // Master vol L
        masterVolL = (i16)(value & 0x7FFF);
    } else if (cOff == 0x1AA) { // Master vol R
        masterVolR = (i16)(value & 0x7FFF);
    }
}
