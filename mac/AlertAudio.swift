import Foundation

// All waveforms are original procedural synthesis; no sampled commercial assets.
enum AlertAudioCue: Hashable, CaseIterable {
    case defaultWarning, monitorBeat, monitorFlatline, terminal, reactor, starship, matrix
    case countdown(Int), burnout
    static var allCases: [AlertAudioCue] { [.defaultWarning, .monitorBeat, .monitorFlatline, .terminal, .reactor, .starship, .matrix, .countdown(5), .countdown(1), .burnout] }
    var duration: Double {
        switch self {
        case .defaultWarning: return 1.2
        case .monitorBeat: return 0.09
        case .monitorFlatline: return 1
        case .terminal: return 5.9
        case .reactor: return 15
        case .starship: return 17
        case .matrix: return 4
        case .countdown: return 0.22
        case .burnout: return 1.4
        }
    }
    var peakLimit: Double {
        switch self {
        case .defaultWarning: return 0.24
        case .monitorBeat: return 0.28
        case .monitorFlatline: return 0.18
        case .terminal, .countdown, .burnout: return 0.21
        case .reactor: return 0.28
        case .starship: return 0.18
        case .matrix: return 0.20
        }
    }
}

enum AlertAudioSynthesis {
    static let sampleRate = 44_100.0
    static let mixerVolume: Float = 0.9 // Preserve the previous mixer setting.
    private static func sine(_ frequency: Double, _ time: Double) -> Double { sin(2 * .pi * frequency * time) }
    private static func envelope(_ time: Double, _ length: Double, attack: Double = 0.004, release: Double = 0.018) -> Double {
        guard time >= 0, time < length else { return 0 }
        return min(1, min(time / attack, (length - time) / release))
    }
    static func render(_ cue: AlertAudioCue) -> [Float] {
        let count = Int(sampleRate * cue.duration)
        var samples = [Float](repeating: 0, count: count)
        var seed: UInt32 = 0xB477E123
        var rumble = 0.0, phase = 0.0
        for index in 0..<count {
            let t = Double(index) / sampleRate
            seed = 1664525 &* seed &+ 1013904223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            rumble += 0.008 * (noise - rumble)
            var signal: Double
            switch cue {
            case .defaultWarning:
                // Recognizable warning pair, with silence between repeats.
                signal = 0.9 * sine(780, t) * envelope(t, 0.16)
                signal += 0.75 * sine(880, t - 0.24) * envelope(t - 0.24, 0.12)
            case .monitorBeat:
                // Clean clinical monitor pip, driven by the actual ECG beat callback.
                signal = sine(1000, t) * envelope(t, cue.duration, attack: 0.003, release: 0.012)
            case .monitorFlatline:
                // Exactly 1,000 cycles per buffer for a seamless sustained flatline.
                signal = sine(1000, t)
            case .terminal:
                let packet = Int(t / 0.18)
                let local = t.truncatingRemainder(dividingBy: 0.18)
                let frequency = [420.0, 610, 490, 760, 550, 680][packet % 6]
                signal = 0.60 * sine(frequency, local) * envelope(local, 0.035)
                signal += 0.13 * noise * envelope(local - 0.055, 0.024)
            case .countdown(let remaining):
                let urgency = Double(5 - max(0, min(5, remaining)))
                let pitch = 720 + urgency * 65
                signal = (0.82 * sine(pitch, t) + 0.18 * sine(pitch * 2, t)) * envelope(t, cue.duration)
            case .burnout:
                let fade = pow(max(0, 1 - t / cue.duration), 2)
                signal = (0.45 * noise + 0.35 * sine(95, t) + 0.20 * rumble) * fade * min(1, t / 0.015)
            case .reactor:
                // Industrial rising/falling siren, low machinery and containment hiss.
                let urgency = min(1, t / 12)
                let sweep = (sin(2 * .pi * (0.65 + urgency * 0.35) * t) + 1) / 2
                phase += 2 * .pi * (260 + 380 * sweep) / sampleRate
                signal = 0.53 * sin(phase) + 0.16 * sin(phase * 3)
                signal += 0.18 * sine(58, t) + 0.08 * rumble + 0.035 * noise
                signal *= envelope(t, cue.duration, attack: 0.025, release: 0.025)
            case .starship:
                // Original bridge distress chord over a quiet propulsion hum.
                let local = t.truncatingRemainder(dividingBy: 1.8)
                let phrase = envelope(local, 0.23, attack: 0.01, release: 0.06)
                let answer = envelope(local - 0.34, 0.31, attack: 0.01, release: 0.07)
                signal = (0.37 * sine(660, t) + 0.23 * sine(990, t)) * phrase
                signal += (0.34 * sine(440, t) + 0.20 * sine(660, t)) * answer
                signal += 0.10 * sine(72, t) + 0.06 * sine(108, t)
                signal *= envelope(t, cue.duration, attack: 0.03, release: 0.03)
            case .matrix:
                // Irregular digital packets, bit ticks and downsampled data chatter.
                let packet = Int(t / 0.12), local = t.truncatingRemainder(dividingBy: 0.12)
                let pattern = [0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0]
                let frequency = [310.0, 740, 430, 960, 560, 380, 820][packet % 7]
                let chirp = sin(2 * .pi * (frequency * local + 1500 * local * local))
                let quantized = (chirp * 5).rounded() / 5
                signal = 0.68 * quantized * envelope(local, pattern[packet % pattern.count] == 1 ? 0.065 : 0.027)
                signal += 0.12 * noise * envelope(local - 0.07, 0.009, attack: 0.002, release: 0.003)
                signal *= envelope(t, cue.duration, attack: 0.015, release: 0.015)
            }
            samples[index] = Float(max(-1, min(1, signal)) * cue.peakLimit)
        }
        return samples
    }
}

protocol AlertAudioOutput: AnyObject {
    func play(_ cue: AlertAudioCue, looping: Bool)
    func stop()
}

// Mute preserves a requested loop, never replays an old one-shot, and stop clears it.
final class AlertAudioPlayback {
    private let output: AlertAudioOutput
    private var cue: AlertAudioCue?
    private var looping = false
    private(set) var isMuted = false
    init(output: AlertAudioOutput) { self.output = output }
    func play(_ cue: AlertAudioCue, looping: Bool = false) {
        self.cue = cue
        self.looping = looping
        if !isMuted { output.play(cue, looping: looping) }
    }
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if muted { output.stop() }
        else if looping, let cue { output.play(cue, looping: true) }
    }
    func stop() {
        cue = nil
        looping = false
        output.stop()
    }
}

struct SelfDestructCountdownAudio {
    private var lastSecond: Int?
    mutating func reset() { lastSecond = nil }
    mutating func cue(for remaining: Int) -> AlertAudioCue? {
        guard lastSecond != remaining else { return nil }
        lastSecond = remaining
        return .countdown(remaining)
    }
}
