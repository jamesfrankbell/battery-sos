import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard value() else { fatalError("line \(line): \(message)") }
}
final class RecordingAudioOutput: AlertAudioOutput {
    var plays: [(AlertAudioCue, Bool)] = []
    var stops = 0
    var gain: Float = 1
    func play(_ cue: AlertAudioCue, looping: Bool) { plays.append((cue, looping)) }
    func stop() { stops += 1 }
    func setOutputGain(_ gain: Float) { self.gain = gain }
}

@main enum AudioTests {
    static func main() throws {
        var signatures = Set<String>()
        for cue in AlertAudioCue.allCases {
            let samples = AlertAudioSynthesis.render(cue)
            expect(samples.count == Int(cue.duration * AlertAudioSynthesis.sampleRate), "sample length")
            expect(samples.allSatisfy { $0.isFinite }, "finite waveform")
            expect(samples.map { abs($0) }.max()! <= Float(cue.peakLimit) + 0.000001, "conservative peak limit")
            expect(samples.contains { abs($0) > 0.01 }, "non-silent cue")
            let second = AlertAudioSynthesis.render(cue)
            expect(samples == second, "reproducible original synthesis")
            signatures.insert("\(samples.count):\(samples.prefix(4410).reduce(0.0) { $0 + Double(abs($1)) })")
        }
        expect(signatures.count == AlertAudioCue.allCases.count, "distinct cue fingerprints")
        expect(AlertAudioSynthesis.mixerVolume == 0.9, "mixer volume preserved")
        print("PASS original finite, distinct, reproducible and peak-limited PCM cues")

        let output = RecordingAudioOutput(), playback = AlertAudioPlayback(output: output)
        playback.setMuted(true)
        playback.play(.reactor, looping: true)
        expect(output.plays.isEmpty, "muted loop never scheduled")
        playback.setMuted(false)
        expect(output.plays.last?.0 == .reactor && output.plays.last?.1 == true, "unmute resumes desired loop")
        playback.setMuted(true)
        let count = output.plays.count
        playback.play(.monitorBeat)
        playback.setMuted(false)
        expect(output.plays.count == count, "unmute never replays old beat")
        playback.play(.matrix, looping: true)
        playback.stop()
        playback.setMuted(true); playback.setMuted(false)
        expect(output.plays.last?.0 == .matrix && output.plays.count == count + 1, "stop clears pending loop")
        expect(output.stops >= 3, "mute/dismiss stop output")
        playback.setGain(0.4)
        expect(abs(output.gain - 0.4) < 0.0001, "theme or calm gain reaches the output")
        playback.setGain(.nan)
        expect(output.gain == 1, "invalid gain falls back to full")
        print("PASS mute, unmute, one-shot and stop state transitions")

        var countdown = SelfDestructCountdownAudio(), events: [AlertAudioCue] = []
        for second in stride(from: 5, through: 0, by: -1) {
            for _ in 0..<20 { if let cue = countdown.cue(for: second) { events.append(cue) } }
        }
        expect(events == stride(from: 5, through: 0, by: -1).map { .countdown($0) }, "one cue per visible countdown second")
        countdown.reset()
        expect(countdown.cue(for: 5) == .countdown(5), "repeat preview resets countdown")
        print("PASS countdown frame deduplication and restart")

        let engineOutput = try AVAlertAudioOutput(manualRendering: true)
        let actualPlayback = AlertAudioPlayback(output: engineOutput)
        for cue: AlertAudioCue in [.terminal, .reactor, .starship, .matrix, .monitorFlatline] {
            actualPlayback.play(cue, looping: true)
            var signal = [Float]()
            for _ in 0..<4 { signal += try engineOutput.renderOffline() }
            expect(signal.contains { abs($0) > 0.001 }, "actual engine triggers each mode")
        }
        actualPlayback.play(.defaultWarning, looping: true)
        var audible = [Float]()
        for _ in 0..<4 { audible += try engineOutput.renderOffline() }
        expect(audible.contains { abs($0) > 0.001 }, "actual AVAudioPlayerNode emits cue offline")
        actualPlayback.setMuted(true)
        let muted = try engineOutput.renderOffline()
        expect(muted.allSatisfy { abs($0) < 0.000001 }, "actual engine silent after mute")
        actualPlayback.setMuted(false)
        let resumed = try engineOutput.renderOffline()
        expect(resumed.contains { abs($0) > 0.001 }, "actual loop resumes after unmute")
        actualPlayback.play(.monitorFlatline, looping: true)
        _ = try engineOutput.renderOffline()
        actualPlayback.stop()
        let stopped = try engineOutput.renderOffline()
        expect(stopped.allSatisfy { abs($0) < 0.000001 }, "actual player queue silent after dismiss/stop")
        print("PASS actual offline AVAudioEngine trigger/mute/resume/stop; no speakers used")
        print("4 audio test groups passed")
    }
}
