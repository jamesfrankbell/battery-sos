import AVFoundation
import Foundation

final class AVAlertAudioOutput: AlertAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AlertAudioSynthesis.sampleRate, channels: 1)!
    private var buffers: [AlertAudioCue: AVAudioPCMBuffer] = [:]
    private let manualRendering: Bool
    private var outputGain: Float = 1

    init(manualRendering: Bool = false) throws {
        self.manualRendering = manualRendering
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = AlertAudioSynthesis.mixerVolume
        player.volume = outputGain
        if manualRendering {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
    }
    deinit { player.stop(); engine.stop() }

    func play(_ cue: AlertAudioCue, looping: Bool) {
        // Stop/reset cancels the complete prior queue, including loops.
        player.stop()
        player.reset()
        do {
            if !engine.isRunning { engine.prepare(); try engine.start() }
            guard let buffer = buffer(for: cue) else { return }
            player.scheduleBuffer(buffer, at: nil, options: looping ? .loops : [], completionHandler: nil)
            player.play()
        } catch {
            // A transient device failure can retry at the next sound event.
            player.stop()
        }
    }
    func setOutputGain(_ gain: Float) {
        outputGain = min(1, max(0, gain))
        player.volume = outputGain
    }
    func stop() {
        player.stop()
        player.reset()
        engine.pause()
    }
    private func buffer(for cue: AlertAudioCue) -> AVAudioPCMBuffer? {
        if let cached = buffers[cue] { return cached }
        let samples = AlertAudioSynthesis.render(cue)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        buffers[cue] = buffer
        return buffer
    }
    // Offline integration testing uses the actual engine/player without speakers.
    func renderOffline(_ frames: AVAudioFrameCount = 1024) throws -> [Float] {
        guard manualRendering, frames <= 4096 else { throw NSError(domain: "BatterySOS.AudioTest", code: 1) }
        if !engine.isRunning { engine.prepare(); try engine.start() }
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else { throw NSError(domain: "BatterySOS.AudioTest", code: 2) }
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
