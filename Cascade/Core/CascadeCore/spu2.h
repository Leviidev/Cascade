#pragma once
#include "types.h"

// ── SPU2: 48-voice ADPCM audio processor ─────────────────────────────────────
// Sound RAM: 2 MB
// Voices: 48 (24 per core)
// Output: stereo 44100 Hz

static constexpr int SPU2_SRAM_SIZE    = 2 * 1024 * 1024;
static constexpr int SPU2_VOICES       = 48;
static constexpr int AUDIO_SAMPLE_RATE = 44100;

struct SPU2Voice {
    u32   startAddr  = 0;   // ADPCM start address in SRAM (byte)
    u32   loopAddr   = 0;
    u32   curAddr    = 0;   // Current decode position (byte, aligned to 16)
    u16   pitch      = 0;   // pitch = freq * 4096 / 44100
    u16   volL       = 0;   // volume left  (0x0000 – 0x7FFF)
    u16   volR       = 0;   // volume right

    // ADSR envelope
    u32   adsrReg1   = 0;
    u32   adsrReg2   = 0;
    enum AdsrPhase { ATTACK, DECAY, SUSTAIN, RELEASE, STOPPED } phase = STOPPED;
    i32   adsrVolume = 0;   // current ADSR volume (0 – 0x7FFF)

    // ADPCM decoder state
    i32   prev1 = 0, prev2 = 0;
    int   blockPos = 28;    // position within decoded block (0-27)
    i16   decoded[28] = {};

    bool  active = false;

    // Sub-sample position (16.16 fixed, steps by `pitch` per output sample)
    u32   samplePos = 0;
};

struct SPU2 {
    u8         sram[SPU2_SRAM_SIZE] = {};
    SPU2Voice  voices[SPU2_VOICES]  = {};

    // Global volumes
    i16 masterVolL   = 0x3FFF, masterVolR = 0x3FFF;
    u32 irqAddr      = 0;
    u32 transferAddr = 0;

    // Audio output ring buffer (stereo i16, indexed by sample-pair)
    // Head = write position, Tail = read position (pair units)
    static constexpr int AUDIO_BUF_SIZE = 8192; // pairs
    i16  audioBuf[AUDIO_BUF_SIZE * 2] = {};     // interleaved L/R
    int  audioBufHead = 0; // next write slot  (pair index)
    int  audioBufTail = 0; // next read slot   (pair index)

    // Sub-cycle accumulator (we tick at IOP rate, generate samples at 44100)
    u32  cycleAccum = 0;
    // IOP runs at 36864000 Hz → sample every 36864000/44100 ≈ 836 cycles
    static constexpr u32 CYCLES_PER_SAMPLE = 836;

    void reset();
    void tick();                              // called once per IOP cycle
    int  getAudioSamples(i16* out, int maxPairs);

    u32  readIO (u32 offset);
    void writeIO(u32 offset, u32 value);

private:
    void generateSample();
    void decodeADPCMBlock(SPU2Voice& v);
    i16  advanceVoice(SPU2Voice& v);
    void stepADSR(SPU2Voice& v);
};
