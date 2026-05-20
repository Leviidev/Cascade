import Foundation
import AVFoundation

// MARK: - SPU2 (Sound Processing Unit 2)
// The PS2's audio processor. 48 hardware voices, ADPCM decoding,
// reverb, pitch modulation, and noise generation.

public final class SPU2 {

    // MARK: - Constants
    static let voiceCount = 48
    static let sampleRate: Double = 48000
    static let coreCount  = 2

    // MARK: - Voices

    struct Voice {
        var pitch: UInt16 = 0x1000     // 0x1000 = 44100 Hz
        var startAddress: UInt32 = 0
        var loopAddress: UInt32 = 0
        var currentAddress: UInt32 = 0
        var volumeL: Int16 = 0
        var volumeR: Int16 = 0
        var adsr: UInt32 = 0

        // ADSR state
        var adsrPhase: ADSRPhase = .off
        var adsrVolume: Int32 = 0
        var attackRate: Int32 = 0
        var decayRate: Int32 = 0
        var sustainLevel: Int32 = 0
        var sustainRate: Int32 = 0
        var releaseRate: Int32 = 0

        // ADPCM state
        var prevSample0: Int32 = 0
        var prevSample1: Int32 = 0
        var sampleBuffer: [Int16] = Array(repeating: 0, count: 28)
        var sampleIndex: Int = 28   // force first decode
        var loopFlag: Bool = false
        var endFlag: Bool = false

        var on: Bool = false
    }

    enum ADSRPhase { case off, attack, decay, sustain, release }

    var voices: [Voice] = Array(repeating: Voice(), count: SPU2.voiceCount)

    // MARK: - SPU2 Memory (2 MB)
    let memSize = 2 * 1024 * 1024
    var mem: [UInt8]

    // MARK: - Registers
    var masterVolL: Int16 = 0
    var masterVolR: Int16 = 0
    var reverbVolL: Int16 = 0
    var reverbVolR: Int16 = 0
    var voiceKeyOn:  [UInt32] = [0, 0]
    var voiceKeyOff: [UInt32] = [0, 0]
    var voiceNoise:  [UInt32] = [0, 0]
    var voiceReverbOn: [UInt32] = [0, 0]
    var voiceStatus: [UInt32] = [0, 0]

    // MARK: - AVAudio Output

    var audioEngine: AVAudioEngine?
    var playerNode: AVAudioPlayerNode?
    var outputFormat: AVAudioFormat?
    var mixBuffer: [Float] = Array(repeating: 0, count: 1024)

    // MARK: - Sample accumulator
    private var sampleAccum: Double = 0
    private let cyclesPerSample: Double = 36_864_000.0 / SPU2.sampleRate

    // MARK: - Init

    init() {
        mem = [UInt8](repeating: 0, count: memSize)
        setupAudio()
    }

    private func setupAudio() {
        audioEngine = AVAudioEngine()
        playerNode  = AVAudioPlayerNode()
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: SPU2.sampleRate, channels: 2)
        guard let engine = audioEngine, let player = playerNode, let fmt = outputFormat else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
        player.play()
    }

    // MARK: - Tick (called once per IOP clock)

    func tick() {
        sampleAccum += 1
        guard sampleAccum >= cyclesPerSample else { return }
        sampleAccum -= cyclesPerSample
        generateSample()
    }

    private func generateSample() {
        var outL: Float = 0
        var outR: Float = 0

        for i in 0..<SPU2.voiceCount {
            guard voices[i].on else { continue }
            let sample = decodeSample(voice: i)
            let env    = Float(voices[i].adsrVolume) / 32768.0
            outL += Float(sample) * Float(voices[i].volumeL) / 32768.0 * env
            outR += Float(sample) * Float(voices[i].volumeR) / 32768.0 * env
            tickADSR(voice: i)
        }

        outL *= Float(masterVolL) / 32768.0
        outR *= Float(masterVolR) / 32768.0

        queueSamples(l: outL, r: outR)
    }

    // MARK: - ADPCM Decoding

    private static let filter0: [Int32] = [0, 60, 115, 98, 122]
    private static let filter1: [Int32] = [0, 0, -52, -55, -60]

    private func decodeSample(voice idx: Int) -> Int16 {
        var v = voices[idx]
        defer { voices[idx] = v }

        if v.sampleIndex >= 28 {
            decodeADPCMBlock(voice: &v)
            v.sampleIndex = 0
        }
        let sample = v.sampleBuffer[v.sampleIndex]
        v.sampleIndex += 1
        return sample
    }

    private func decodeADPCMBlock(voice: inout Voice) {
        let addr = Int(voice.currentAddress) % memSize
        guard addr + 16 <= memSize else { return }
        let header = mem[addr]
        let flags  = mem[addr + 1]
        let shift  = Int(header & 0x0F)
        let filter = Int((header >> 4) & 0x07)
        let f0 = SPU2.filter0[min(filter, 4)]
        let f1 = SPU2.filter1[min(filter, 4)]

        var prev0 = voice.prevSample0
        var prev1 = voice.prevSample1
        for i in 0..<14 {
            let byte = Int(mem[addr + 2 + i])
            voice.sampleBuffer[i * 2]     = decodeNibble(nibble: byte & 0xF,        shift: shift, f0: f0, f1: f1, prev0: &prev0, prev1: &prev1)
            voice.sampleBuffer[i * 2 + 1] = decodeNibble(nibble: (byte >> 4) & 0xF, shift: shift, f0: f0, f1: f1, prev0: &prev0, prev1: &prev1)
        }
        voice.prevSample0 = prev0
        voice.prevSample1 = prev1

        if flags & 0x04 != 0 { voice.loopAddress = voice.currentAddress }
        voice.loopFlag = flags & 0x02 != 0
        voice.endFlag  = flags & 0x01 != 0

        voice.currentAddress += 16
        if voice.loopFlag { voice.currentAddress = voice.loopAddress }
        if voice.endFlag && !voice.loopFlag { voice.on = false }
    }

    private func decodeNibble(nibble: Int, shift: Int, f0: Int32, f1: Int32, prev0: inout Int32, prev1: inout Int32) -> Int16 {
        let s = nibble >= 8 ? nibble - 16 : nibble
        var sample = Int32(s << (12 - shift))
        sample += (prev0 * f0 + prev1 * f1 + 32) >> 6
        sample = max(-32768, min(32767, sample))
        prev1 = prev0
        prev0 = sample
        return Int16(sample)
    }

    // MARK: - ADSR Envelope

    private func tickADSR(voice idx: Int) {
        switch voices[idx].adsrPhase {
        case .attack:
            voices[idx].adsrVolume = min(32767, voices[idx].adsrVolume + voices[idx].attackRate)
            if voices[idx].adsrVolume >= 32767 { voices[idx].adsrPhase = .decay }
        case .decay:
            voices[idx].adsrVolume = max(0, voices[idx].adsrVolume - voices[idx].decayRate)
            if voices[idx].adsrVolume <= voices[idx].sustainLevel { voices[idx].adsrPhase = .sustain }
        case .sustain:
            voices[idx].adsrVolume = max(0, min(32767, voices[idx].adsrVolume + voices[idx].sustainRate))
        case .release:
            voices[idx].adsrVolume = max(0, voices[idx].adsrVolume - voices[idx].releaseRate)
            if voices[idx].adsrVolume == 0 { voices[idx].on = false; voices[idx].adsrPhase = .off }
        case .off:
            break
        }
    }

    // MARK: - Audio Queuing

    private var pendingL: [Float] = []
    private var pendingR: [Float] = []
    private let batchSize = 512

    private func queueSamples(l: Float, r: Float) {
        pendingL.append(l); pendingR.append(r)
        guard pendingL.count >= batchSize, let player = playerNode, let fmt = outputFormat else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(batchSize)) else { return }
        buf.frameLength = AVAudioFrameCount(batchSize)
        let chL = buf.floatChannelData![0]
        let chR = buf.floatChannelData![1]
        for i in 0..<batchSize { chL[i] = pendingL[i]; chR[i] = pendingR[i] }
        pendingL.removeAll(); pendingR.removeAll()
        player.scheduleBuffer(buf)
    }

    // MARK: - Key On/Off

    func keyOn(core: Int, mask: UInt32) {
        let base = core * 24
        for i in 0..<24 {
            guard mask & (1 << i) != 0 else { continue }
            let vi = base + i
            voices[vi].on = true
            voices[vi].currentAddress = voices[vi].startAddress
            voices[vi].sampleIndex = 28
            voices[vi].prevSample0 = 0
            voices[vi].prevSample1 = 0
            voices[vi].adsrPhase = .attack
            voices[vi].adsrVolume = 0
            parseADSR(voice: vi)
        }
    }

    func keyOff(core: Int, mask: UInt32) {
        let base = core * 24
        for i in 0..<24 {
            guard mask & (1 << i) != 0 else { continue }
            voices[base + i].adsrPhase = .release
        }
    }

    private func parseADSR(voice vi: Int) {
        let adsr = voices[vi].adsr
        voices[vi].attackRate  = max(1, Int32((adsr & 0x7F) + 1) * 2)
        voices[vi].decayRate   = max(1, Int32(((adsr >> 4) & 0xF) + 1) * 8)
        voices[vi].sustainLevel = Int32(((adsr >> 8) & 0xF) << 11)
        voices[vi].sustainRate  = Int32((adsr >> 6) & 0x7F)
        voices[vi].releaseRate  = max(1, Int32((adsr >> 16) & 0x1F) * 8)
    }

    // MARK: - I/O

    func readIO(offset: UInt32) -> UInt32 {
        let voice = Int(offset / 0x10) % SPU2.voiceCount
        switch offset & 0xF {
        case 0x0: return UInt32(bitPattern: Int32(voices[voice].volumeL))
        case 0x2: return UInt32(bitPattern: Int32(voices[voice].volumeR))
        case 0x4: return UInt32(voices[voice].pitch)
        case 0x6: return voices[voice].startAddress >> 3
        case 0x8: return voices[voice].adsr
        default:  return 0
        }
    }

    func writeIO(offset: UInt32, value: UInt32) {
        let voice = Int(offset / 0x10) % SPU2.voiceCount
        switch offset & 0xF {
        case 0x0: voices[voice].volumeL = Int16(bitPattern: UInt16(value & 0xFFFF))
        case 0x2: voices[voice].volumeR = Int16(bitPattern: UInt16(value & 0xFFFF))
        case 0x4: voices[voice].pitch = UInt16(value & 0xFFFF)
        case 0x6: voices[voice].startAddress = (value & 0xFFFF) << 3
        case 0x8: voices[voice].adsr = value
        default: break
        }
    }
}
