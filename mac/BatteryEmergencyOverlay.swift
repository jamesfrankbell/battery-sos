import Cocoa
import AVFoundation
import IOKit.ps
import ServiceManagement
import Sparkle

private struct BatteryState {
    let percent: Int
    let isCharging: Bool
}

private enum OverlayMode: String {
    case defaultWarning = "Default Warning"
    case vitalsMonitor = "Vitals Monitor"
    case selfDestruct = "Self-Destruct"
    case reactorMeltdown = "Reactor Meltdown"
    case starshipLifeSupport = "Starship Life Support"
    case matrixBinary = "Matrix"
}

private final class MonetizationManager {
    private let licenseKeyStorageKey = "BatterySOS.licenseKey"
    private let defaults = UserDefaults.standard

    var isProUnlocked: Bool {
        defaults.string(forKey: licenseKeyStorageKey) != nil
    }

    var hasProAccess: Bool {
        isProUnlocked
    }

    var statusSummary: String {
        if isProUnlocked {
            return "Pro Unlocked"
        }
        return "Free (Default mode only)"
    }

    func clearLicense() {
        defaults.removeObject(forKey: licenseKeyStorageKey)
    }

    func storeActivatedLicense(_ key: String) {
        let normalized = key.uppercased().replacingOccurrences(of: " ", with: "")
        defaults.set(normalized, forKey: licenseKeyStorageKey)
    }

    var storedLicenseKey: String? {
        defaults.string(forKey: licenseKeyStorageKey)
    }
}

private final class AlertTonePlayer {
    private let sampleRate: Double = 44_100
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private lazy var sourceNode: AVAudioSourceNode = {
        AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let isFlatlineOn = self.flatlineEnabled
            let muted = self.isMuted
            let frequencyStep = (2.0 * Double.pi * self.flatlineFrequency) / self.sampleRate

            for frame in 0..<Int(frameCount) {
                let sampleValue: Float
                if isFlatlineOn && !muted {
                    let waveform = sin(self.flatlinePhase)
                    sampleValue = Float(waveform * self.flatlineVolume)
                    self.flatlinePhase += frequencyStep
                    if self.flatlinePhase >= 2.0 * Double.pi {
                        self.flatlinePhase -= 2.0 * Double.pi
                    }
                } else {
                    sampleValue = 0
                }

                for buffer in abl {
                    let pointer = buffer.mData!.assumingMemoryBound(to: Float.self)
                    pointer[frame] = sampleValue
                }
            }
            return noErr
        }
    }()
    private let format: AVAudioFormat
    private var isReady = false
    private var isMuted = false
    private var flatlineEnabled = false
    private var flatlinePhase = 0.0
    private var flatlineFrequency = 1380.0
    private var flatlineVolume = 0.18
    private var modeLoopTimer: Timer?
    private var modeLoopTick: Int = 0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        configureAudioEngine()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            player.stop()
            player.reset()
            flatlinePhase = 0
        }
    }

    func playBeat() {
        stopFlatlineTone()
        playTone(
            frequency: 1040,
            duration: 0.11,
            volume: 0.34,
            attack: 0.003,
            release: 0.05,
            vibratoDepth: 5,
            vibratoRate: 24,
            harmonicBlend: 0.22
        )
    }

    func startFlatlineLoop() {
        stopModeLoop()
        player.stop()
        player.reset()
        flatlinePhase = 0
        flatlineEnabled = true
    }

    func startDefaultWarningLoop() {
        startModeLoop(interval: 1.0) { [weak self] tick in
            guard let self else { return }
            let base = tick.isMultiple(of: 2) ? 780.0 : 700.0
            self.playTone(
                frequency: base,
                duration: 0.16,
                volume: 0.24,
                attack: 0.006,
                release: 0.07,
                harmonicBlend: 0.16
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.playTone(
                    frequency: base * 1.13,
                    duration: 0.10,
                    volume: 0.20,
                    attack: 0.004,
                    release: 0.05,
                    harmonicBlend: 0.1
                )
            }
        }
    }

    func startSelfDestructLoop() {
        startModeLoop(interval: 0.62) { [weak self] tick in
            guard let self else { return }
            let phrase: [Double] = [930, 740, 880, 620]
            let frequency = phrase[tick % phrase.count]
            self.playTone(
                frequency: frequency,
                duration: 0.11,
                volume: 0.21,
                attack: 0.004,
                release: 0.05,
                vibratoDepth: 2,
                vibratoRate: 10,
                harmonicBlend: 0.2
            )
        }
    }

    func startReactorLoop() {
        startModeLoop(interval: 0.46) { [weak self] tick in
            guard let self else { return }
            let frequency = tick.isMultiple(of: 2) ? 670.0 : 540.0
            self.playTone(
                frequency: frequency,
                duration: 0.17,
                volume: 0.28,
                attack: 0.004,
                release: 0.07,
                harmonicBlend: 0.24
            )
        }
    }

    func startStarshipLoop() {
        startModeLoop(interval: 1.26) { [weak self] tick in
            guard let self else { return }
            self.playTone(
                frequency: 920,
                duration: 0.08,
                volume: 0.18,
                attack: 0.003,
                release: 0.05,
                vibratoDepth: 3,
                vibratoRate: 13,
                harmonicBlend: 0.08
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                self?.playTone(
                    frequency: tick.isMultiple(of: 2) ? 620 : 560,
                    duration: 0.10,
                    volume: 0.14,
                    attack: 0.003,
                    release: 0.06,
                    harmonicBlend: 0.1
                )
            }
        }
    }

    func startMatrixLoop() {
        startModeLoop(interval: 0.72) { [weak self] _ in
            guard let self else { return }
            let base: [Double] = [210, 260, 320, 420, 520, 610]
            let frequency = base.randomElement() ?? 320
            self.playTone(
                frequency: frequency,
                duration: 0.07,
                volume: 0.20,
                attack: 0.002,
                release: 0.035,
                vibratoDepth: 4,
                vibratoRate: 19,
                harmonicBlend: 0.35
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.playTone(
                    frequency: frequency * Double.random(in: 1.35...1.95),
                    duration: 0.045,
                    volume: 0.12,
                    attack: 0.001,
                    release: 0.03,
                    harmonicBlend: 0.4
                )
            }
        }
    }

    func stopAll() {
        stopModeLoop()
        stopFlatlineTone()
        player.stop()
        player.reset()
    }

    private func stopFlatlineTone() {
        flatlineEnabled = false
        flatlinePhase = 0
    }

    private func startModeLoop(interval: TimeInterval, event: @escaping (Int) -> Void) {
        stopFlatlineTone()
        stopModeLoop()
        modeLoopTick = 0
        event(modeLoopTick)

        modeLoopTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.modeLoopTick += 1
            event(self.modeLoopTick)
        }
        if let modeLoopTimer {
            RunLoop.main.add(modeLoopTimer, forMode: .common)
        }
    }

    private func stopModeLoop() {
        modeLoopTimer?.invalidate()
        modeLoopTimer = nil
        modeLoopTick = 0
    }

    private func configureAudioEngine() {
        engine.attach(player)
        engine.attach(sourceNode)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9

        do {
            try engine.start()
            isReady = true
        } catch {
            isReady = false
        }
    }

    private func playTone(
        frequency: Double,
        duration: Double,
        volume: Double,
        attack: Double,
        release: Double,
        vibratoDepth: Double = 0,
        vibratoRate: Double = 0,
        harmonicBlend: Double = 0
    ) {
        guard isReady, !isMuted else {
            return
        }

        if !engine.isRunning {
            try? engine.start()
        }

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = frameCount
        var phase = 0.0

        for index in 0..<Int(frameCount) {
            let time = Double(index) / sampleRate
            let attackGain = min(1.0, time / attack)
            let releaseGain = min(1.0, max(0.0, duration - time) / release)
            let envelope = min(attackGain, releaseGain)

            let vibrato = vibratoDepth > 0 ? sin(2.0 * Double.pi * vibratoRate * time) * vibratoDepth : 0
            let currentFrequency = max(1, frequency + vibrato)
            phase += (2.0 * Double.pi * currentFrequency) / sampleRate

            let fundamental = sin(phase)
            let harmonic = sin(phase * 2.02)
            let blended = (fundamental * (1.0 - harmonicBlend)) + (harmonic * harmonicBlend)
            channel[index] = Float(blended * volume * envelope)
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }
}

private func readBatteryState() -> BatteryState? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
          !sources.isEmpty else {
        return nil
    }

    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            continue
        }

        guard let current = description[kIOPSCurrentCapacityKey as String] as? Int,
              let max = description[kIOPSMaxCapacityKey as String] as? Int,
              max > 0 else {
            continue
        }

        let percentage = Int((Double(current) / Double(max) * 100.0).rounded())
        let state = description[kIOPSPowerSourceStateKey as String] as? String
        let chargingFlag = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let charging = chargingFlag || state == (kIOPSACPowerValue as String)

        return BatteryState(percent: percentage, isCharging: charging)
    }

    return nil
}

private final class OverlayView: NSView {
    var onDismiss: (() -> Void)?
    var mode: OverlayMode = .defaultWarning {
        didSet {
            applyMode()
        }
    }
    private let tonePlayer = AlertTonePlayer()

    override var acceptsFirstResponder: Bool {
        true
    }

    private final class EKGMonitorView: NSView {
        private let totalBeats = 20
        private let timelineWidth: TimeInterval = 12.0
        private let targetFrameRate: TimeInterval = 1.0 / 30.0
        private let sweepCycle: TimeInterval = 1.8

        private var timer: Timer?
        private var startedAt: Date?
        private var lastEmittedBeatIndex = -1
        private var didEmitFlatline = false

        var onBeat: ((Int, Int) -> Void)?
        var onFlatline: (() -> Void)?

        private lazy var beatIntervals: [TimeInterval] = {
            // Explicit accelerating progression (seconds between beats).
            [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
        }()

        private lazy var beatStartTimes: [TimeInterval] = {
            var starts: [TimeInterval] = []
            var running: TimeInterval = 0
            for interval in beatIntervals {
                running += interval
                starts.append(running)
            }
            return starts
        }()

        private lazy var beatWindow: TimeInterval = {
            beatIntervals.reduce(0, +)
        }()

        private let gridLayer = CAShapeLayer()
        private let trackLayer = CAShapeLayer()
        private let waveGlowLayer = CAShapeLayer()
        private let waveLayer = CAShapeLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        deinit {
            stop()
        }

        override func layout() {
            super.layout()
            updateLayerFrames()
            updateGridPath()
            updateWave()
        }

        func start() {
            stop()
            startedAt = Date()
            lastEmittedBeatIndex = -1
            didEmitFlatline = false
            updateWave()

            timer = Timer.scheduledTimer(withTimeInterval: targetFrameRate, repeats: true) { [weak self] _ in
                self?.tick()
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            startedAt = nil
        }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = NSColor(calibratedRed: 0.01, green: 0.08, blue: 0.05, alpha: 0.80).cgColor
            layer?.cornerRadius = 18
            layer?.borderColor = NSColor.green.withAlphaComponent(0.42).cgColor
            layer?.borderWidth = 1

            gridLayer.strokeColor = NSColor.green.withAlphaComponent(0.12).cgColor
            gridLayer.fillColor = NSColor.clear.cgColor
            gridLayer.lineWidth = 1

            trackLayer.strokeColor = NSColor.green.withAlphaComponent(0.26).cgColor
            trackLayer.fillColor = NSColor.clear.cgColor
            trackLayer.lineWidth = 2
            trackLayer.lineCap = .round

            waveGlowLayer.strokeColor = NSColor.green.withAlphaComponent(0.30).cgColor
            waveGlowLayer.fillColor = NSColor.clear.cgColor
            waveGlowLayer.lineWidth = 9
            waveGlowLayer.lineCap = .round
            waveGlowLayer.lineJoin = .round
            waveGlowLayer.shadowColor = NSColor.green.cgColor
            waveGlowLayer.shadowOpacity = 0.65
            waveGlowLayer.shadowRadius = 12
            waveGlowLayer.shadowOffset = .zero

            waveLayer.strokeColor = NSColor.green.withAlphaComponent(0.98).cgColor
            waveLayer.fillColor = NSColor.clear.cgColor
            waveLayer.lineWidth = 3.2
            waveLayer.lineCap = .round
            waveLayer.lineJoin = .round

            layer?.addSublayer(gridLayer)
            layer?.addSublayer(trackLayer)
            layer?.addSublayer(waveGlowLayer)
            layer?.addSublayer(waveLayer)
        }

        private func updateLayerFrames() {
            gridLayer.frame = bounds
            trackLayer.frame = bounds
            waveGlowLayer.frame = bounds
            waveLayer.frame = bounds
        }

        private func updateGridPath() {
            let insetBounds = bounds.insetBy(dx: 10, dy: 10)
            let gridPath = CGMutablePath()
            let spacing: CGFloat = 24

            var x = insetBounds.minX
            while x <= insetBounds.maxX {
                gridPath.move(to: CGPoint(x: x, y: insetBounds.minY))
                gridPath.addLine(to: CGPoint(x: x, y: insetBounds.maxY))
                x += spacing
            }

            var y = insetBounds.minY
            while y <= insetBounds.maxY {
                gridPath.move(to: CGPoint(x: insetBounds.minX, y: y))
                gridPath.addLine(to: CGPoint(x: insetBounds.maxX, y: y))
                y += spacing
            }

            gridLayer.path = gridPath
        }

        private func tick() {
            guard let startedAt else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            updateWave(elapsed: elapsed)
            let emittedBeatCount = beatStartTimes.filter { elapsed >= $0 }.count
            if emittedBeatCount > 0 && emittedBeatCount - 1 > lastEmittedBeatIndex {
                let start = lastEmittedBeatIndex + 1
                let end = emittedBeatCount - 1
                if start <= end {
                    for beatIndex in start...end {
                        let bpm = max(1, Int((60.0 / beatIntervals[beatIndex]).rounded()))
                        onBeat?(beatIndex, bpm)
                    }
                }
                lastEmittedBeatIndex = end
            }

            if elapsed >= beatWindow && !didEmitFlatline {
                didEmitFlatline = true
                onFlatline?()
            }

            let activeDuration = beatWindow + timelineWidth + 1.0
            if elapsed >= activeDuration {
                stop()
            }
        }

        private func updateWave(elapsed: TimeInterval? = nil) {
            guard bounds.width > 20, bounds.height > 20 else { return }

            let baselineY = bounds.midY
            let amplitude = bounds.height * 0.34
            let path = CGMutablePath()
            let step: CGFloat = 2
            guard let startedAt else {
                let flatline = CGMutablePath()
                flatline.move(to: CGPoint(x: 10, y: baselineY))
                flatline.addLine(to: CGPoint(x: bounds.maxX - 10, y: baselineY))
                trackLayer.path = flatline
                waveGlowLayer.path = flatline
                waveLayer.path = flatline
                return
            }

            let activeElapsed = elapsed ?? Date().timeIntervalSince(startedAt)
            let innerWidth = max(1, bounds.width - 20)

            var didMove = false
            var x: CGFloat = 10
            while x <= bounds.maxX - 10 {
                let normalized = (x - 10) / innerWidth
                let sampleTime = activeElapsed - TimeInterval(1 - normalized) * timelineWidth
                let signal = ekgSignal(at: sampleTime)
                let y = baselineY + CGFloat(signal) * amplitude
                let point = CGPoint(x: x, y: y)

                if !didMove {
                    path.move(to: point)
                    didMove = true
                } else {
                    path.addLine(to: point)
                }
                x += step
            }

            let flatline = CGMutablePath()
            flatline.move(to: CGPoint(x: 10, y: baselineY))
            flatline.addLine(to: CGPoint(x: bounds.maxX - 10, y: baselineY))
            trackLayer.path = flatline
            waveGlowLayer.path = path
            waveLayer.path = path
        }

        private func ekgSignal(at time: TimeInterval) -> Double {
            if time < 0 {
                return 0
            }

            if time >= beatWindow {
                return 0
            }

            var beatIndex = -1
            for index in 0..<beatStartTimes.count {
                let start = beatStartTimes[index]
                let end = start + beatIntervals[index]
                if time >= start && time < end {
                    beatIndex = index
                    break
                }
            }

            if beatIndex < 0 {
                return 0
            }

            let phase = (time - beatStartTimes[beatIndex]) / beatIntervals[beatIndex]
            return pqrstTemplate(phase: phase)
        }

        private func pqrstTemplate(phase: Double) -> Double {
            // Piecewise linear template for stable, monitor-like PQRST geometry.
            if phase < 0.10 { return 0.0 }
            if phase < 0.14 { return ramp(phase, 0.10, 0.14, 0.0, 0.16) }   // P rise
            if phase < 0.18 { return ramp(phase, 0.14, 0.18, 0.16, 0.0) }   // P fall
            if phase < 0.24 { return 0.0 }                                   // PR segment
            if phase < 0.27 { return ramp(phase, 0.24, 0.27, 0.0, -0.28) }  // Q
            if phase < 0.30 { return ramp(phase, 0.27, 0.30, -0.28, 1.35) } // R up
            if phase < 0.33 { return ramp(phase, 0.30, 0.33, 1.35, -0.60) } // S down
            if phase < 0.37 { return ramp(phase, 0.33, 0.37, -0.60, 0.0) }  // back to baseline
            if phase < 0.45 { return 0.0 }                                   // ST segment
            if phase < 0.54 { return ramp(phase, 0.45, 0.54, 0.0, 0.28) }   // T rise
            if phase < 0.64 { return ramp(phase, 0.54, 0.64, 0.28, 0.0) }   // T fall
            return 0.0                                                       // baseline
        }

        private func ramp(_ x: Double, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
            guard x1 > x0 else { return y1 }
            let t = (x - x0) / (x1 - x0)
            return y0 + ((y1 - y0) * t)
        }

    }

    private final class TelemetryStripView: NSView {
        enum Style {
            case respiration
            case pleth
        }

        private let style: Style
        private let tint: NSColor

        private var timer: Timer?
        private var phase: Double = 0

        private let gridLayer = CAShapeLayer()
        private let waveLayer = CAShapeLayer()
        private let glowLayer = CAShapeLayer()

        init(style: Style, tint: NSColor) {
            self.style = style
            self.tint = tint
            super.init(frame: .zero)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            stop()
        }

        override func layout() {
            super.layout()
            gridLayer.frame = bounds
            waveLayer.frame = bounds
            glowLayer.frame = bounds
            updateGridPath()
            updateWavePath()
        }

        func start() {
            stop()
            phase = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase += 0.04
                self.updateWavePath()
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.83).cgColor
            layer?.cornerRadius = 10
            layer?.borderColor = tint.withAlphaComponent(0.32).cgColor
            layer?.borderWidth = 1

            gridLayer.strokeColor = tint.withAlphaComponent(0.10).cgColor
            gridLayer.fillColor = NSColor.clear.cgColor
            gridLayer.lineWidth = 1

            glowLayer.strokeColor = tint.withAlphaComponent(0.28).cgColor
            glowLayer.fillColor = NSColor.clear.cgColor
            glowLayer.lineWidth = 7
            glowLayer.lineCap = .round
            glowLayer.lineJoin = .round
            glowLayer.shadowColor = tint.cgColor
            glowLayer.shadowOpacity = 0.45
            glowLayer.shadowRadius = 6
            glowLayer.shadowOffset = .zero

            waveLayer.strokeColor = tint.withAlphaComponent(0.96).cgColor
            waveLayer.fillColor = NSColor.clear.cgColor
            waveLayer.lineWidth = 2.2
            waveLayer.lineCap = .round
            waveLayer.lineJoin = .round

            layer?.addSublayer(gridLayer)
            layer?.addSublayer(glowLayer)
            layer?.addSublayer(waveLayer)
        }

        private func updateGridPath() {
            let inset = bounds.insetBy(dx: 6, dy: 6)
            let path = CGMutablePath()
            let spacing: CGFloat = 18

            var x = inset.minX
            while x <= inset.maxX {
                path.move(to: CGPoint(x: x, y: inset.minY))
                path.addLine(to: CGPoint(x: x, y: inset.maxY))
                x += spacing
            }

            var y = inset.minY
            while y <= inset.maxY {
                path.move(to: CGPoint(x: inset.minX, y: y))
                path.addLine(to: CGPoint(x: inset.maxX, y: y))
                y += spacing
            }

            gridLayer.path = path
        }

        private func updateWavePath() {
            guard bounds.width > 20, bounds.height > 20 else { return }

            let baseline = bounds.midY
            let amplitude = bounds.height * 0.38
            let innerWidth = max(1, bounds.width - 16)
            let path = CGMutablePath()

            var moved = false
            var x: CGFloat = 8
            while x <= bounds.maxX - 8 {
                let n = (x - 8) / innerWidth
                let y = baseline + CGFloat(signal(at: Double(n))) * amplitude
                let point = CGPoint(x: x, y: y)

                if !moved {
                    path.move(to: point)
                    moved = true
                } else {
                    path.addLine(to: point)
                }

                x += 2
            }

            glowLayer.path = path
            waveLayer.path = path
        }

        private func signal(at normalizedX: Double) -> Double {
            switch style {
            case .respiration:
                let a = sin((normalizedX * 8.0) + (phase * 0.9)) * 0.48
                let b = sin((normalizedX * 17.5) + (phase * 1.5)) * 0.22
                let c = sin((normalizedX * 31.0) + (phase * 0.45)) * 0.08
                return a + b + c
            case .pleth:
                let cycle = ((normalizedX * 4.1) + (phase * 0.72)).truncatingRemainder(dividingBy: 1)
                if cycle < 0.12 {
                    return (cycle / 0.12) * 0.95
                }
                if cycle < 0.34 {
                    return 0.95 - ((cycle - 0.12) / 0.22) * 0.65
                }
                if cycle < 0.72 {
                    return 0.30 - ((cycle - 0.34) / 0.38) * 0.24
                }
                return 0.06 - ((cycle - 0.72) / 0.28) * 0.06
            }
        }
    }

    private final class SelfDestructConsoleView: NSView {
        private enum Stage {
            case boot
            case identity
            case docs
            case countdown
            case complete
        }

        private let agentName: String
        private var timer: Timer?
        private var stage: Stage = .boot
        private var stageStartedAt: Date = Date()
        private var lastDocFrameSwitchAt: Date = Date()
        private var documentFrameIndex = 0

        private let shellView = NSView()
        private let topLineLabel = NSTextField(labelWithString: "IMF/OPS//1996 LEGACY TERMINAL")
        private let statusLineLabel = NSTextField(labelWithString: "INITIALIZING SECURE PORTAL...")
        private let centerFrameView = NSView()
        private let centerTextLabel = NSTextField(labelWithString: "BOOTSTRAP")
        private let classifiedStampLabel = NSTextField(labelWithString: "CLASSIFIED")
        private let redactionBlockLabel = NSTextField(labelWithString: "")
        private let bottomLineLabel = NSTextField(labelWithString: "")

        init(agentName: String) {
            self.agentName = agentName
            super.init(frame: .zero)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            stop()
        }

        func start() {
            stop()
            stage = .boot
            stageStartedAt = Date()
            lastDocFrameSwitchAt = stageStartedAt
            documentFrameIndex = 0
            applyCurrentStage(elapsed: 0)

            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor

            shellView.wantsLayer = true
            shellView.layer?.backgroundColor = NSColor(calibratedRed: 0.90, green: 0.98, blue: 0.98, alpha: 0.97).cgColor
            shellView.layer?.borderColor = NSColor(calibratedWhite: 0.72, alpha: 1).cgColor
            shellView.layer?.borderWidth = 3
            shellView.translatesAutoresizingMaskIntoConstraints = false

            topLineLabel.font = NSFont(name: "SF Mono Bold", size: 24) ?? NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
            topLineLabel.textColor = NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.32, alpha: 1)
            topLineLabel.translatesAutoresizingMaskIntoConstraints = false

            statusLineLabel.font = NSFont(name: "SF Mono Bold", size: 28) ?? NSFont.monospacedSystemFont(ofSize: 28, weight: .bold)
            statusLineLabel.textColor = NSColor(calibratedRed: 0.03, green: 0.20, blue: 0.20, alpha: 1)
            statusLineLabel.translatesAutoresizingMaskIntoConstraints = false

            centerFrameView.wantsLayer = true
            centerFrameView.layer?.borderColor = NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.55, alpha: 0.9).cgColor
            centerFrameView.layer?.borderWidth = 2
            centerFrameView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
            centerFrameView.translatesAutoresizingMaskIntoConstraints = false

            centerTextLabel.alignment = .center
            centerTextLabel.font = NSFont(name: "SF Pro Display Bold", size: 70) ?? NSFont.systemFont(ofSize: 70, weight: .bold)
            centerTextLabel.textColor = NSColor(calibratedRed: 0.05, green: 0.13, blue: 0.13, alpha: 1)
            centerTextLabel.translatesAutoresizingMaskIntoConstraints = false

            classifiedStampLabel.alignment = .center
            classifiedStampLabel.font = NSFont(name: "SF Pro Display Heavy", size: 98) ?? NSFont.systemFont(ofSize: 98, weight: .heavy)
            classifiedStampLabel.textColor = NSColor.systemRed.withAlphaComponent(0.70)
            classifiedStampLabel.translatesAutoresizingMaskIntoConstraints = false

            redactionBlockLabel.alignment = .left
            redactionBlockLabel.maximumNumberOfLines = 0
            redactionBlockLabel.lineBreakMode = .byWordWrapping
            redactionBlockLabel.font = NSFont(name: "SF Mono Regular", size: 24) ?? NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
            redactionBlockLabel.textColor = NSColor(calibratedRed: 0.07, green: 0.20, blue: 0.20, alpha: 0.95)
            redactionBlockLabel.translatesAutoresizingMaskIntoConstraints = false

            bottomLineLabel.font = NSFont(name: "SF Mono Bold", size: 24) ?? NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
            bottomLineLabel.textColor = NSColor(calibratedRed: 0.04, green: 0.28, blue: 0.28, alpha: 1)
            bottomLineLabel.translatesAutoresizingMaskIntoConstraints = false

            addSubview(shellView)
            shellView.addSubview(topLineLabel)
            shellView.addSubview(statusLineLabel)
            shellView.addSubview(centerFrameView)
            shellView.addSubview(redactionBlockLabel)
            shellView.addSubview(bottomLineLabel)
            centerFrameView.addSubview(centerTextLabel)
            centerFrameView.addSubview(classifiedStampLabel)

            NSLayoutConstraint.activate([
                shellView.centerXAnchor.constraint(equalTo: centerXAnchor),
                shellView.centerYAnchor.constraint(equalTo: centerYAnchor),
                shellView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.84),
                shellView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.84),

                topLineLabel.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 24),
                topLineLabel.topAnchor.constraint(equalTo: shellView.topAnchor, constant: 18),
                topLineLabel.trailingAnchor.constraint(lessThanOrEqualTo: shellView.trailingAnchor, constant: -24),

                statusLineLabel.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 24),
                statusLineLabel.topAnchor.constraint(equalTo: topLineLabel.bottomAnchor, constant: 10),
                statusLineLabel.trailingAnchor.constraint(lessThanOrEqualTo: shellView.trailingAnchor, constant: -24),

                centerFrameView.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 24),
                centerFrameView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -24),
                centerFrameView.topAnchor.constraint(equalTo: statusLineLabel.bottomAnchor, constant: 20),
                centerFrameView.heightAnchor.constraint(equalTo: shellView.heightAnchor, multiplier: 0.54),

                centerTextLabel.centerXAnchor.constraint(equalTo: centerFrameView.centerXAnchor),
                centerTextLabel.centerYAnchor.constraint(equalTo: centerFrameView.centerYAnchor),

                classifiedStampLabel.centerXAnchor.constraint(equalTo: centerFrameView.centerXAnchor),
                classifiedStampLabel.centerYAnchor.constraint(equalTo: centerFrameView.centerYAnchor),

                redactionBlockLabel.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 24),
                redactionBlockLabel.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -24),
                redactionBlockLabel.topAnchor.constraint(equalTo: centerFrameView.bottomAnchor, constant: 16),

                bottomLineLabel.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 24),
                bottomLineLabel.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -24),
                bottomLineLabel.bottomAnchor.constraint(equalTo: shellView.bottomAnchor, constant: -12)
            ])
        }

        private func tick() {
            let elapsed = Date().timeIntervalSince(stageStartedAt)
            applyCurrentStage(elapsed: elapsed)

            switch stage {
            case .boot where elapsed >= 1.9:
                transition(to: .identity)
            case .identity where elapsed >= 1.8:
                transition(to: .docs)
            case .docs where elapsed >= 2.2:
                transition(to: .countdown)
            case .countdown where elapsed >= 6.0:
                transition(to: .complete)
            default:
                break
            }
        }

        private func transition(to newStage: Stage) {
            stage = newStage
            stageStartedAt = Date()
            lastDocFrameSwitchAt = stageStartedAt
            applyCurrentStage(elapsed: 0)
        }

        private func applyCurrentStage(elapsed: TimeInterval) {
            classifiedStampLabel.isHidden = true

            switch stage {
            case .boot:
                statusLineLabel.stringValue = "INITIALIZING SECURE PORTAL..."
                centerTextLabel.stringValue = "PORTAL ONLINE"
                redactionBlockLabel.stringValue = "ROUTING AUTH THROUGH LEGACY GATEWAY...\nCHECKSUM VALID // SIGNAL CLEAN"
                bottomLineLabel.stringValue = "MISSION REF \(missionCode()) // AGENT \(agentName)"
                centerFrameView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor

            case .identity:
                statusLineLabel.stringValue = "AGENT IDENTITY CONFIRMED"
                centerTextLabel.stringValue = "ACCESS GRANTED"
                redactionBlockLabel.stringValue = "CLEARANCE: OMEGA-7\nBIOMETRIC LOCK ACCEPTED\nAUTH TOKEN: VERIFIED"
                bottomLineLabel.stringValue = "AGENT \(agentName) // SESSION ACTIVE"
                centerFrameView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.42).cgColor

            case .docs:
                statusLineLabel.stringValue = "DISPLAYING REDACTED FILES"
                centerTextLabel.stringValue = "FILE \(documentFrameIndex % 4 + 1) / 4"
                redactionBlockLabel.stringValue = redactedFrame(index: documentFrameIndex)
                bottomLineLabel.stringValue = "PROTOCOL 21(A) // DENIABILITY CLAUSE"
                classifiedStampLabel.isHidden = false
                classifiedStampLabel.alphaValue = documentFrameIndex.isMultiple(of: 2) ? 0.78 : 0.42
                centerFrameView.layer?.backgroundColor = NSColor.white.withAlphaComponent(documentFrameIndex.isMultiple(of: 2) ? 0.30 : 0.48).cgColor
                if Date().timeIntervalSince(lastDocFrameSwitchAt) >= 0.18 {
                    documentFrameIndex += 1
                    lastDocFrameSwitchAt = Date()
                }

            case .countdown:
                let remaining = max(0, 5 - Int(elapsed.rounded(.down)))
                statusLineLabel.stringValue = "SELF-DESTRUCT SEQUENCE INITIATED..."
                centerTextLabel.stringValue = "\(remaining)"
                redactionBlockLabel.stringValue = "THIS MESSAGE WILL SELF-DESTRUCT IN \(remaining) SECONDS.\nATTACH DEVICE TO POWER TO ABORT EMERGENCY LOCKDOWN."
                bottomLineLabel.stringValue = "DESTRUCT TIMER LIVE // MISSION \(missionCode())"
                classifiedStampLabel.isHidden = false
                classifiedStampLabel.alphaValue = 0.55
                centerFrameView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.40).cgColor

            case .complete:
                statusLineLabel.stringValue = "SELF-DESTRUCT READY"
                centerTextLabel.stringValue = "0"
                redactionBlockLabel.stringValue = "COUNTDOWN COMPLETE.\nWAITING FOR POWER RESTORATION OR MANUAL OVERRIDE."
                bottomLineLabel.stringValue = "FAILSAFE ENGAGED // AGENT \(agentName)"
                classifiedStampLabel.isHidden = false
                classifiedStampLabel.alphaValue = 0.72
                centerFrameView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.40).cgColor
            }
        }

        private func redactedFrame(index: Int) -> String {
            let frames = [
                "SUBJECT: [REDACTED]\nORIGIN: [BLACK SITE 4]\nACTION: █████ ████ █████",
                "PAYLOAD ID: 7F-██-21\nEXFIL WINDOW: ██:██ UTC\nACCESS: DENIED // REDACTED",
                "IMF PROTOCOL #12339-78\nAGENCY WILL EXPLICITLY DENY\nINVOLVEMENT IN COVERT OPERATIONS.",
                "CLASSIFIED HANDLER NOTES:\n███ ████ ███████ ███\nDO NOT ARCHIVE TO OPEN CHANNELS."
            ]
            return frames[index % frames.count]
        }

        private func missionCode() -> String {
            let suffix = Int(Date().timeIntervalSince1970) % 100000
            return "877462068-23H-\(suffix)"
        }
    }

    private final class MeterBarView: NSView {
        private let trackLayer = CALayer()
        private let fillLayer = CALayer()
        private var level: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override func layout() {
            super.layout()
            trackLayer.frame = bounds
            let clamped = max(0, min(1, level))
            fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
            let radius = bounds.height / 2
            trackLayer.cornerRadius = radius
            fillLayer.cornerRadius = radius
        }

        func setLevel(_ level: CGFloat, color: NSColor) {
            self.level = max(0, min(1, level))
            fillLayer.backgroundColor = color.cgColor
            needsLayout = true
        }

        private func setup() {
            wantsLayer = true
            trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            fillLayer.backgroundColor = NSColor.systemGreen.cgColor
            layer?.addSublayer(trackLayer)
            layer?.addSublayer(fillLayer)
        }
    }

    private final class ReactorMeltdownView: NSView {
        private var timer: Timer?
        private var startedAt: Date = Date()

        private let shell = NSView()
        private let headerLabel = NSTextField(labelWithString: "REACTOR CONTROL // CONTAINMENT GRID")
        private let statusLabel = NSTextField(labelWithString: "MONITORING CORE...")
        private let tempValueLabel = NSTextField(labelWithString: "CORE TEMP 0000C")
        private let pressureValueLabel = NSTextField(labelWithString: "PRESSURE 000%")
        private let integrityValueLabel = NSTextField(labelWithString: "CONTAINMENT 100%")
        private let countdownLabel = NSTextField(labelWithString: "CONTAINMENT BREACH IN --")
        private let alertLabel = NSTextField(labelWithString: "PLUG IN POWER NOW TO PREVENT MELTDOWN")
        private let tempBar = MeterBarView(frame: .zero)
        private let pressureBar = MeterBarView(frame: .zero)
        private let integrityBar = MeterBarView(frame: .zero)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit { stop() }

        func start() {
            stop()
            startedAt = Date()
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.tick()
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.03, blue: 0.02, alpha: 0.90).cgColor

            shell.wantsLayer = true
            shell.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            shell.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.65).cgColor
            shell.layer?.borderWidth = 2
            shell.translatesAutoresizingMaskIntoConstraints = false

            [headerLabel, statusLabel, tempValueLabel, pressureValueLabel, integrityValueLabel, countdownLabel, alertLabel].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
            }

            headerLabel.font = NSFont(name: "SF Mono Bold", size: 26) ?? NSFont.monospacedSystemFont(ofSize: 26, weight: .bold)
            headerLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.2, alpha: 1)

            statusLabel.font = NSFont(name: "SF Pro Display Bold", size: 42) ?? NSFont.systemFont(ofSize: 42, weight: .bold)
            statusLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.52, alpha: 1)

            tempValueLabel.font = NSFont(name: "SF Mono Bold", size: 30) ?? NSFont.monospacedSystemFont(ofSize: 30, weight: .bold)
            pressureValueLabel.font = tempValueLabel.font
            integrityValueLabel.font = tempValueLabel.font
            [tempValueLabel, pressureValueLabel, integrityValueLabel].forEach { $0.textColor = NSColor.white }

            countdownLabel.font = NSFont(name: "SF Pro Display Heavy", size: 64) ?? NSFont.systemFont(ofSize: 64, weight: .heavy)
            countdownLabel.textColor = NSColor.systemRed.withAlphaComponent(0.95)
            countdownLabel.alignment = .center

            alertLabel.font = NSFont(name: "SF Pro Display Bold", size: 34) ?? NSFont.systemFont(ofSize: 34, weight: .bold)
            alertLabel.textColor = NSColor.white
            alertLabel.alignment = .center

            [tempBar, pressureBar, integrityBar].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                shell.addSubview($0)
            }

            addSubview(shell)
            shell.addSubview(headerLabel)
            shell.addSubview(statusLabel)
            shell.addSubview(tempValueLabel)
            shell.addSubview(pressureValueLabel)
            shell.addSubview(integrityValueLabel)
            shell.addSubview(countdownLabel)
            shell.addSubview(alertLabel)

            NSLayoutConstraint.activate([
                shell.centerXAnchor.constraint(equalTo: centerXAnchor),
                shell.centerYAnchor.constraint(equalTo: centerYAnchor),
                shell.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.82),
                shell.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.72),

                headerLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                headerLabel.topAnchor.constraint(equalTo: shell.topAnchor, constant: 18),

                statusLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                statusLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 18),

                tempValueLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                tempValueLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 32),
                tempBar.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                tempBar.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -22),
                tempBar.topAnchor.constraint(equalTo: tempValueLabel.bottomAnchor, constant: 8),
                tempBar.heightAnchor.constraint(equalToConstant: 22),

                pressureValueLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                pressureValueLabel.topAnchor.constraint(equalTo: tempBar.bottomAnchor, constant: 18),
                pressureBar.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                pressureBar.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -22),
                pressureBar.topAnchor.constraint(equalTo: pressureValueLabel.bottomAnchor, constant: 8),
                pressureBar.heightAnchor.constraint(equalToConstant: 22),

                integrityValueLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                integrityValueLabel.topAnchor.constraint(equalTo: pressureBar.bottomAnchor, constant: 18),
                integrityBar.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 22),
                integrityBar.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -22),
                integrityBar.topAnchor.constraint(equalTo: integrityValueLabel.bottomAnchor, constant: 8),
                integrityBar.heightAnchor.constraint(equalToConstant: 22),

                countdownLabel.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
                countdownLabel.topAnchor.constraint(equalTo: integrityBar.bottomAnchor, constant: 34),
                countdownLabel.widthAnchor.constraint(equalTo: shell.widthAnchor, multiplier: 0.9),

                alertLabel.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
                alertLabel.bottomAnchor.constraint(equalTo: shell.bottomAnchor, constant: -22),
                alertLabel.widthAnchor.constraint(equalTo: shell.widthAnchor, multiplier: 0.9)
            ])
        }

        private func tick() {
            let cycle = 15.0
            let elapsed = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)
            let normalized = min(1.0, elapsed / (cycle - 3.0))
            let tempLevel = CGFloat(min(1.0, 0.15 + normalized * 0.92))
            let pressureLevel = CGFloat(min(1.0, 0.10 + normalized * 1.05))
            let integrityLevel = CGFloat(max(0.02, 1.0 - normalized * 1.05))

            let tempC = Int(430 + (normalized * 1180))
            let pressure = Int(40 + (normalized * 230))
            let integrity = Int(max(0, 100 - (normalized * 105)))

            tempValueLabel.stringValue = "CORE TEMP \(tempC)C"
            pressureValueLabel.stringValue = "PRESSURE \(pressure)%"
            integrityValueLabel.stringValue = "CONTAINMENT \(integrity)%"

            tempBar.setLevel(tempLevel, color: NSColor.systemOrange)
            pressureBar.setLevel(pressureLevel, color: NSColor.systemRed)
            integrityBar.setLevel(integrityLevel, color: integrity < 35 ? NSColor.systemRed : NSColor.systemYellow)

            if elapsed < 5.0 {
                statusLabel.stringValue = "MONITORING CORE..."
            } else if elapsed < 9.5 {
                statusLabel.stringValue = "RUNAWAY REACTION DETECTED"
            } else {
                statusLabel.stringValue = "SCRAM ATTEMPT FAILED"
            }

            if elapsed < 9.5 {
                countdownLabel.stringValue = "CONTAINMENT BREACH IN --"
            } else {
                let remaining = max(0, 5 - Int((elapsed - 9.5).rounded(.down)))
                countdownLabel.stringValue = "CONTAINMENT BREACH IN \(remaining)"
            }

            let pulse = (sin(Date().timeIntervalSince1970 * 6.0) + 1.0) / 2.0
            alertLabel.alphaValue = elapsed > 9.5 ? (0.45 + (0.55 * pulse)) : 0.9
            if elapsed > 13.6 {
                alertLabel.stringValue = "SCRAM FAILED - PLUG IN POWER NOW"
            } else {
                alertLabel.stringValue = "PLUG IN POWER NOW TO PREVENT MELTDOWN"
            }
        }
    }

    private final class StarshipLifeSupportView: NSView {
        private var timer: Timer?
        private var startedAt: Date = Date()
        private var starLayers: [CALayer] = []

        private let shell = NSView()
        private let headerLabel = NSTextField(labelWithString: "STARSHIP LIFE SUPPORT // LONG-RANGE HUD")
        private let vesselLabel = NSTextField(labelWithString: "")
        private let statusLabel = NSTextField(labelWithString: "NAVIGATION DRIFT DETECTED")
        private let radarView = NSView()
        private let radarGridLayer = CAShapeLayer()
        private let radarSweepLayer = CAShapeLayer()
        private let radarBlipLayer = CAShapeLayer()

        private let o2Card = NSView()
        private let o2ValueLabel = NSTextField(labelWithString: "100%")
        private let o2CaptionLabel = NSTextField(labelWithString: "OXYGEN RESERVE")

        private let cellsCard = NSView()
        private let cellsValueLabel = NSTextField(labelWithString: "12")
        private let cellsCaptionLabel = NSTextField(labelWithString: "POWER CELLS")

        private let hullCard = NSView()
        private let hullValueLabel = NSTextField(labelWithString: "100%")
        private let hullCaptionLabel = NSTextField(labelWithString: "HAB STABILITY")

        private let dockLabel = NSTextField(labelWithString: "DOCKING POWER WINDOW T-10")
        private let routeLabel = NSTextField(labelWithString: "COURSE: AUXILIARY DOCK // VECTOR LOCK")
        private let warningLabel = NSTextField(labelWithString: "ATTACH POWER TO MAINTAIN LIFE SUPPORT")

        init(vesselName: String) {
            super.init(frame: .zero)
            vesselLabel.stringValue = "VESSEL: \(vesselName)"
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit { stop() }

        override func layout() {
            super.layout()
            reseedStarsIfNeeded()
            updateRadarLayers()
        }

        func start() {
            stop()
            startedAt = Date()
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = NSColor(calibratedRed: 0.01, green: 0.03, blue: 0.08, alpha: 0.95).cgColor

            shell.wantsLayer = true
            shell.layer?.backgroundColor = NSColor(calibratedRed: 0.02, green: 0.07, blue: 0.15, alpha: 0.62).cgColor
            shell.layer?.borderColor = NSColor(calibratedRed: 0.20, green: 0.92, blue: 1.0, alpha: 0.68).cgColor
            shell.layer?.borderWidth = 1.5
            shell.layer?.cornerRadius = 18
            shell.translatesAutoresizingMaskIntoConstraints = false

            [headerLabel, vesselLabel, statusLabel, dockLabel, routeLabel, warningLabel].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
            }
            headerLabel.font = NSFont(name: "SF Mono Bold", size: 26) ?? NSFont.monospacedSystemFont(ofSize: 26, weight: .bold)
            headerLabel.textColor = NSColor(calibratedRed: 0.45, green: 0.98, blue: 1.0, alpha: 0.95)
            vesselLabel.font = NSFont(name: "SF Mono Regular", size: 20) ?? NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
            vesselLabel.textColor = NSColor(calibratedRed: 0.62, green: 0.95, blue: 1.0, alpha: 1)
            statusLabel.font = NSFont(name: "SF Pro Display Heavy", size: 46) ?? NSFont.systemFont(ofSize: 46, weight: .heavy)
            statusLabel.textColor = NSColor(calibratedRed: 0.72, green: 0.98, blue: 1.0, alpha: 1)
            dockLabel.font = NSFont(name: "SF Pro Display Heavy", size: 44) ?? NSFont.systemFont(ofSize: 44, weight: .heavy)
            dockLabel.textColor = NSColor.systemCyan
            dockLabel.alignment = .center
            routeLabel.font = NSFont(name: "SF Mono Regular", size: 22) ?? NSFont.monospacedSystemFont(ofSize: 22, weight: .regular)
            routeLabel.textColor = NSColor(calibratedRed: 0.65, green: 0.92, blue: 1.0, alpha: 0.88)
            warningLabel.font = NSFont(name: "SF Pro Display Bold", size: 30) ?? NSFont.systemFont(ofSize: 30, weight: .bold)
            warningLabel.textColor = NSColor.white
            warningLabel.alignment = .center

            radarView.wantsLayer = true
            radarView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
            radarView.layer?.cornerRadius = 160
            radarView.layer?.borderWidth = 1.5
            radarView.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.36).cgColor
            radarView.translatesAutoresizingMaskIntoConstraints = false

            radarGridLayer.strokeColor = NSColor.systemCyan.withAlphaComponent(0.20).cgColor
            radarGridLayer.fillColor = NSColor.clear.cgColor
            radarGridLayer.lineWidth = 1

            radarSweepLayer.strokeColor = NSColor.systemCyan.withAlphaComponent(0.9).cgColor
            radarSweepLayer.fillColor = NSColor.clear.cgColor
            radarSweepLayer.lineWidth = 2
            radarSweepLayer.lineCap = .round

            radarBlipLayer.strokeColor = NSColor.clear.cgColor
            radarBlipLayer.fillColor = NSColor.systemMint.withAlphaComponent(0.9).cgColor

            radarView.layer?.addSublayer(radarGridLayer)
            radarView.layer?.addSublayer(radarSweepLayer)
            radarView.layer?.addSublayer(radarBlipLayer)

            setupMetricCard(o2Card, valueLabel: o2ValueLabel, captionLabel: o2CaptionLabel)
            setupMetricCard(cellsCard, valueLabel: cellsValueLabel, captionLabel: cellsCaptionLabel)
            setupMetricCard(hullCard, valueLabel: hullValueLabel, captionLabel: hullCaptionLabel)

            let metricsColumn = NSStackView(views: [o2Card, cellsCard, hullCard])
            metricsColumn.orientation = .vertical
            metricsColumn.alignment = .leading
            metricsColumn.spacing = 16
            metricsColumn.translatesAutoresizingMaskIntoConstraints = false

            addSubview(shell)
            shell.addSubview(headerLabel)
            shell.addSubview(vesselLabel)
            shell.addSubview(statusLabel)
            shell.addSubview(radarView)
            shell.addSubview(metricsColumn)
            shell.addSubview(dockLabel)
            shell.addSubview(routeLabel)
            shell.addSubview(warningLabel)

            NSLayoutConstraint.activate([
                shell.centerXAnchor.constraint(equalTo: centerXAnchor),
                shell.centerYAnchor.constraint(equalTo: centerYAnchor),
                shell.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.88),
                shell.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.82),

                headerLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 24),
                headerLabel.topAnchor.constraint(equalTo: shell.topAnchor, constant: 18),
                vesselLabel.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -24),
                vesselLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

                statusLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 24),
                statusLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 14),
                statusLabel.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -24),

                radarView.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 28),
                radarView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
                radarView.widthAnchor.constraint(equalToConstant: 320),
                radarView.heightAnchor.constraint(equalToConstant: 320),

                metricsColumn.leadingAnchor.constraint(equalTo: radarView.trailingAnchor, constant: 26),
                metricsColumn.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -24),
                metricsColumn.topAnchor.constraint(equalTo: radarView.topAnchor),

                o2Card.widthAnchor.constraint(equalTo: metricsColumn.widthAnchor),
                cellsCard.widthAnchor.constraint(equalTo: metricsColumn.widthAnchor),
                hullCard.widthAnchor.constraint(equalTo: metricsColumn.widthAnchor),
                o2Card.heightAnchor.constraint(equalToConstant: 92),
                cellsCard.heightAnchor.constraint(equalToConstant: 92),
                hullCard.heightAnchor.constraint(equalToConstant: 92),

                dockLabel.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
                dockLabel.topAnchor.constraint(equalTo: radarView.bottomAnchor, constant: 20),
                dockLabel.widthAnchor.constraint(equalTo: shell.widthAnchor, multiplier: 0.92),

                routeLabel.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
                routeLabel.topAnchor.constraint(equalTo: dockLabel.bottomAnchor, constant: 10),
                routeLabel.widthAnchor.constraint(equalTo: shell.widthAnchor, multiplier: 0.92),

                warningLabel.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
                warningLabel.bottomAnchor.constraint(equalTo: shell.bottomAnchor, constant: -16),
                warningLabel.widthAnchor.constraint(equalTo: shell.widthAnchor, multiplier: 0.92)
            ])
        }

        private func setupMetricCard(_ card: NSView, valueLabel: NSTextField, captionLabel: NSTextField) {
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
            card.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.35).cgColor
            card.layer?.borderWidth = 1
            card.layer?.cornerRadius = 12
            card.translatesAutoresizingMaskIntoConstraints = false

            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            captionLabel.translatesAutoresizingMaskIntoConstraints = false
            valueLabel.font = NSFont(name: "SF Pro Display Heavy", size: 46) ?? NSFont.systemFont(ofSize: 46, weight: .heavy)
            valueLabel.textColor = .white
            captionLabel.font = NSFont(name: "SF Mono Bold", size: 18) ?? NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
            captionLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.95, blue: 1.0, alpha: 0.95)

            card.addSubview(valueLabel)
            card.addSubview(captionLabel)
            NSLayoutConstraint.activate([
                valueLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                valueLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),

                captionLabel.leadingAnchor.constraint(equalTo: valueLabel.leadingAnchor),
                captionLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
                captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12)
            ])
        }

        private func reseedStarsIfNeeded() {
            guard let layer else { return }
            let targetCount = 55
            if starLayers.count == targetCount { return }
            starLayers.forEach { $0.removeFromSuperlayer() }
            starLayers.removeAll()
            for _ in 0..<targetCount {
                let star = CALayer()
                let size = CGFloat.random(in: 1.2...2.6)
                star.frame = CGRect(
                    x: CGFloat.random(in: 0...max(1, bounds.width - size)),
                    y: CGFloat.random(in: 0...max(1, bounds.height - size)),
                    width: size,
                    height: size
                )
                star.cornerRadius = size / 2
                star.backgroundColor = NSColor.white.withAlphaComponent(CGFloat.random(in: 0.25...0.85)).cgColor
                layer.addSublayer(star)
                starLayers.append(star)
            }
        }

        private func tick() {
            let cycle = 17.0
            let elapsed = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)
            let depletion = min(1.0, elapsed / 13.0)

            let o2 = max(0, Int(100 - depletion * 94))
            let cells = max(0, Int(12 - depletion * 10))
            let hull = max(4, Int(100 - depletion * 86))
            o2ValueLabel.stringValue = "\(o2)%"
            cellsValueLabel.stringValue = "\(cells)"
            hullValueLabel.stringValue = "\(hull)%"

            let status: String
            if elapsed < 5.2 {
                status = "NAVIGATION DRIFT DETECTED"
            } else if elapsed < 10.5 {
                status = "ATMOSPHERE LEAK EXPANDING"
            } else {
                status = "CRITICAL LIFE SUPPORT FAILURE"
            }
            statusLabel.stringValue = status

            let dockCountdown = max(0, 10 - Int(elapsed.rounded(.down)))
            dockLabel.stringValue = "DOCKING POWER WINDOW T-\(dockCountdown)"
            routeLabel.stringValue = dockCountdown > 0
                ? "COURSE: AUXILIARY DOCK // VECTOR LOCK"
                : "POWER WINDOW CLOSED // MANUAL POWER ATTACH REQUIRED"

            let warningPulse = (sin(Date().timeIntervalSince1970 * 7.5) + 1.0) / 2.0
            warningLabel.alphaValue = dockCountdown == 0 ? (0.45 + warningPulse * 0.55) : 1.0
            warningLabel.stringValue = dockCountdown == 0
                ? "ATTACH POWER TO MAINTAIN LIFE SUPPORT"
                : "ROUTE AUX POWER NOW // CONNECT CHARGER"

            updateCardStyle(card: o2Card, isAlert: o2 < 34)
            updateCardStyle(card: cellsCard, isAlert: cells < 4)
            updateCardStyle(card: hullCard, isAlert: hull < 40)

            twinkleStars()
            updateRadarLayers()
        }

        private func updateCardStyle(card: NSView, isAlert: Bool) {
            let color = isAlert
                ? NSColor.systemRed.withAlphaComponent(0.72)
                : NSColor.systemCyan.withAlphaComponent(0.35)
            card.layer?.borderColor = color.cgColor
        }

        private func twinkleStars() {
            for (index, star) in starLayers.enumerated() where index.isMultiple(of: 4) {
                if Bool.random() {
                    star.opacity = Float.random(in: 0.22...0.92)
                }
            }
        }

        private func updateRadarLayers() {
            guard radarView.bounds.width > 10, radarView.bounds.height > 10 else { return }
            radarGridLayer.frame = radarView.bounds
            radarSweepLayer.frame = radarView.bounds
            radarBlipLayer.frame = radarView.bounds

            let center = CGPoint(x: radarView.bounds.midX, y: radarView.bounds.midY)
            let radius = min(radarView.bounds.width, radarView.bounds.height) * 0.44

            let grid = CGMutablePath()
            for factor in [1.0, 0.75, 0.50, 0.25] {
                let r = radius * factor
                grid.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            grid.move(to: CGPoint(x: center.x - radius, y: center.y))
            grid.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            grid.move(to: CGPoint(x: center.x, y: center.y - radius))
            grid.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            radarGridLayer.path = grid

            let angle = CGFloat(Date().timeIntervalSince(startedAt) * 1.45)
            let sweepEnd = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let sweep = CGMutablePath()
            sweep.move(to: center)
            sweep.addLine(to: sweepEnd)
            radarSweepLayer.path = sweep

            let blips = CGMutablePath()
            for index in 0..<4 {
                let theta = angle + CGFloat(index) * 1.6
                let r = radius * CGFloat(0.2 + 0.18 * CGFloat(index))
                let point = CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r)
                blips.addEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            }
            radarBlipLayer.path = blips
        }
    }

    private final class MatrixBinaryView: NSView {
        private final class BinaryCanvasView: NSView {
            private struct Column {
                var offset: CGFloat
                var speed: CGFloat
                var values: [Character]
            }

            private var timer: Timer?
            private var columns: [Column] = []
            private let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                layer?.backgroundColor = NSColor.black.cgColor
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func layout() {
                super.layout()
                if columns.isEmpty || Int(bounds.width) != Int((CGFloat(columns.count) * 14)) {
                    resetColumns()
                }
            }

            func start() {
                stop()
                resetColumns()
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 18.0, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            }

            func stop() {
                timer?.invalidate()
                timer = nil
            }

            override func draw(_ dirtyRect: NSRect) {
                NSColor.black.setFill()
                dirtyRect.fill()
                guard !columns.isEmpty else { return }

                let attrsDim: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor(calibratedRed: 0.0, green: 0.75, blue: 0.25, alpha: 0.55)
                ]
                let attrsBright: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.70, alpha: 0.95)
                ]

                let lineHeight = font.ascender - font.descender + 2
                let colWidth: CGFloat = 14
                for (columnIndex, column) in columns.enumerated() {
                    let x = CGFloat(columnIndex) * colWidth + 4
                    for rowIndex in 0..<column.values.count {
                        let y = bounds.height - (CGFloat(rowIndex) * lineHeight) + column.offset
                        if y < -lineHeight || y > bounds.height + lineHeight { continue }
                        let ch = String(column.values[rowIndex])
                        let attrs = rowIndex == 0 ? attrsBright : attrsDim
                        ch.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
                    }
                }
            }

            private func resetColumns() {
                let colCount = max(12, Int(bounds.width / 14))
                columns = (0..<colCount).map { _ in
                    Column(offset: CGFloat.random(in: 0...40),
                           speed: CGFloat.random(in: 6...22),
                           values: randomValues(count: Int.random(in: 24...64)))
                }
                needsDisplay = true
            }

            private func tick() {
                let lineHeight = (font.ascender - font.descender + 2)
                for i in columns.indices {
                    columns[i].offset -= columns[i].speed
                    if Bool.random() && !columns[i].values.isEmpty {
                        let randomIndex = Int.random(in: 0..<columns[i].values.count)
                        columns[i].values[randomIndex] = Bool.random() ? "0" : "1"
                    }
                    if columns[i].offset < -lineHeight {
                        columns[i].offset += lineHeight
                        columns[i].values.insert(Bool.random() ? "0" : "1", at: 0)
                        if columns[i].values.count > 80 {
                            columns[i].values.removeLast(columns[i].values.count - 80)
                        }
                    }
                    if Bool.random() && Int.random(in: 0...20) == 0 {
                        columns[i].speed = CGFloat.random(in: 6...22)
                    }
                }
                needsDisplay = true
            }

            private func randomValues(count: Int) -> [Character] {
                (0..<count).map { _ in Bool.random() ? "0" : "1" }
            }
        }

        private var timer: Timer?
        private var startedAt: Date = Date()
        private let canvas = BinaryCanvasView(frame: .zero)
        private let headlineLabel = NSTextField(labelWithString: "MATRIX PROCESS LOOP DETECTED")
        private let statusLabel = NSTextField(labelWithString: "POWER SOURCE ANOMALY // CONNECT CHARGER")
        private let counterLabel = NSTextField(labelWithString: "000000")
        private let overlayPanel = NSView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit { stop() }

        func start() {
            stop()
            startedAt = Date()
            canvas.start()
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                self?.tick()
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            canvas.stop()
        }

        private func setup() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor

            canvas.translatesAutoresizingMaskIntoConstraints = false

            overlayPanel.wantsLayer = true
            overlayPanel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            overlayPanel.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.55).cgColor
            overlayPanel.layer?.borderWidth = 1
            overlayPanel.translatesAutoresizingMaskIntoConstraints = false

            [headlineLabel, statusLabel, counterLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
            headlineLabel.font = NSFont(name: "SF Mono Bold", size: 42) ?? NSFont.monospacedSystemFont(ofSize: 42, weight: .bold)
            headlineLabel.textColor = NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.7, alpha: 1)
            headlineLabel.alignment = .center
            statusLabel.font = NSFont(name: "SF Mono Regular", size: 24) ?? NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
            statusLabel.textColor = NSColor.systemGreen.withAlphaComponent(0.9)
            statusLabel.alignment = .center
            counterLabel.font = NSFont(name: "SF Mono Bold", size: 68) ?? NSFont.monospacedSystemFont(ofSize: 68, weight: .bold)
            counterLabel.textColor = NSColor.white
            counterLabel.alignment = .center

            addSubview(canvas)
            addSubview(overlayPanel)
            overlayPanel.addSubview(headlineLabel)
            overlayPanel.addSubview(statusLabel)
            overlayPanel.addSubview(counterLabel)

            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
                canvas.topAnchor.constraint(equalTo: topAnchor),
                canvas.bottomAnchor.constraint(equalTo: bottomAnchor),

                overlayPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
                overlayPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
                overlayPanel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.72),
                overlayPanel.heightAnchor.constraint(equalToConstant: 250),

                headlineLabel.leadingAnchor.constraint(equalTo: overlayPanel.leadingAnchor, constant: 16),
                headlineLabel.trailingAnchor.constraint(equalTo: overlayPanel.trailingAnchor, constant: -16),
                headlineLabel.topAnchor.constraint(equalTo: overlayPanel.topAnchor, constant: 18),

                statusLabel.leadingAnchor.constraint(equalTo: headlineLabel.leadingAnchor),
                statusLabel.trailingAnchor.constraint(equalTo: headlineLabel.trailingAnchor),
                statusLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: 14),

                counterLabel.leadingAnchor.constraint(equalTo: headlineLabel.leadingAnchor),
                counterLabel.trailingAnchor.constraint(equalTo: headlineLabel.trailingAnchor),
                counterLabel.bottomAnchor.constraint(equalTo: overlayPanel.bottomAnchor, constant: -24)
            ])
        }

        private func tick() {
            let elapsed = Date().timeIntervalSince(startedAt)
            let value = Int((elapsed * 173.0).truncatingRemainder(dividingBy: 1_000_000))
            counterLabel.stringValue = String(format: "%06d", value)
            let pulse = (sin(elapsed * 3.0) + 1.0) / 2.0
            overlayPanel.alphaValue = 0.82 + (0.16 * pulse)
            if Int(elapsed) % 4 == 0 {
                statusLabel.stringValue = "POWER SOURCE ANOMALY // CONNECT CHARGER"
            } else {
                statusLabel.stringValue = "EXIT LOOP: ATTACH DEVICE TO POWER"
            }
        }
    }

    private final class CountdownCircleView: NSView {
        private let duration: TimeInterval = 60

        private var countdownTimer: Timer?
        private var startedAt: Date?

        private let fillLayer = CAShapeLayer()
        private let trackLayer = CAShapeLayer()
        private let progressLayer = CAShapeLayer()

        private let valueLabel: NSTextField = {
            let label = NSTextField(labelWithString: "60s")
            label.alignment = .center
            label.textColor = .white
            label.font = NSFont(name: "SF Pro Display Bold", size: 36) ?? NSFont.systemFont(ofSize: 36, weight: .bold)
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        deinit {
            stop()
        }

        override func layout() {
            super.layout()
            updateCirclePath()
        }

        func start() {
            stop()
            startedAt = Date()
            updateDisplay(remaining: duration)

            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            if let countdownTimer {
                RunLoop.main.add(countdownTimer, forMode: .common)
            }
        }

        func stop() {
            countdownTimer?.invalidate()
            countdownTimer = nil
            startedAt = nil
        }

        private func setup() {
            wantsLayer = true

            fillLayer.fillColor = NSColor.white.withAlphaComponent(0.2).cgColor
            fillLayer.strokeColor = NSColor.clear.cgColor

            trackLayer.fillColor = NSColor.clear.cgColor
            trackLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
            trackLayer.lineWidth = 5

            progressLayer.fillColor = NSColor.clear.cgColor
            progressLayer.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
            progressLayer.lineWidth = 5
            progressLayer.lineCap = .round
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = 1
            progressLayer.transform = CATransform3DMakeRotation(-CGFloat.pi / 2, 0, 0, 1)

            layer?.addSublayer(fillLayer)
            layer?.addSublayer(trackLayer)
            layer?.addSublayer(progressLayer)

            addSubview(valueLabel)
            NSLayoutConstraint.activate([
                valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        private func updateCirclePath() {
            fillLayer.frame = bounds
            trackLayer.frame = bounds
            progressLayer.frame = bounds

            let circleRect = bounds.insetBy(dx: 6, dy: 6)
            let circlePath = CGPath(ellipseIn: circleRect, transform: nil)
            fillLayer.path = circlePath
            trackLayer.path = circlePath
            progressLayer.path = circlePath
        }

        private func tick() {
            guard let startedAt else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = max(0, duration - elapsed)
            updateDisplay(remaining: remaining)

            if remaining <= 0 {
                stop()
            }
        }

        private func updateDisplay(remaining: TimeInterval) {
            let progress = max(0, min(1, remaining / duration))
            progressLayer.strokeEnd = progress
            valueLabel.stringValue = "\(Int(ceil(remaining)))s"
        }
    }

    private final class HoverCloseButton: NSButton {
        private var tracking: NSTrackingArea?
        private var hovering = false {
            didSet { applyStyle() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking {
                removeTrackingArea(tracking)
            }

            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
        }

        private func setup() {
            isBordered = false
            title = ""
            focusRingType = .none
            wantsLayer = true
            layer?.masksToBounds = true
            applyStyle()
        }

        private func applyStyle() {
            let background = hovering ? NSColor.white : NSColor.white.withAlphaComponent(0.28)
            let foreground = hovering ? NSColor.black : NSColor.white
            let font = NSFont.systemFont(ofSize: 38, weight: .bold)

            layer?.backgroundColor = background.cgColor
            layer?.cornerRadius = 28
            attributedTitle = NSAttributedString(
                string: "\u{2715}",
                attributes: [
                    .font: font,
                    .foregroundColor: foreground
                ]
            )
        }
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "⚠️ BATTERY SOS ⚠️")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Bold", size: 72) ?? NSFont.systemFont(ofSize: 72, weight: .bold)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let paragraphSpacer: NSView = {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer.heightAnchor.constraint(equalToConstant: 56)
        ])
        return spacer
    }()

    private let bodyLabel: NSTextField = {
        let label = NSTextField(labelWithString: "I AM GOING TO DIE IF YOU DON'T PLUG ME IN NOW!")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Bold", size: 56) ?? NSFont.systemFont(ofSize: 56, weight: .bold)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let secondParagraphSpacer: NSView = {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer.heightAnchor.constraint(equalToConstant: 56)
        ])
        return spacer
    }()

    private let countdownView: CountdownCircleView = {
        let view = CountdownCircleView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 172),
            view.heightAnchor.constraint(equalToConstant: 172)
        ])
        return view
    }()

    private let systemDisplayName = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName).uppercased()

    private let vitalsLeadLabel: NSTextField = {
        let label = NSTextField(labelWithString: "II   X1   DIAGNOSTIC   NOTCH OFF")
        label.alignment = .left
        label.textColor = NSColor.green.withAlphaComponent(0.92)
        label.font = NSFont(name: "SF Mono Bold", size: 30) ?? NSFont.monospacedSystemFont(ofSize: 30, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var vitalsSystemIdLabel: NSTextField = {
        let label = NSTextField(labelWithString: systemDisplayName)
        label.alignment = .right
        label.textColor = NSColor.green.withAlphaComponent(0.95)
        label.font = NSFont(name: "SF Mono Bold", size: 36) ?? NSFont.monospacedSystemFont(ofSize: 36, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let heartRateValueLabel: NSTextField = {
        let label = NSTextField(labelWithString: "--")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Heavy", size: 148) ?? NSFont.systemFont(ofSize: 148, weight: .heavy)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let heartRateCaptionLabel: NSTextField = {
        let label = NSTextField(labelWithString: "BPM")
        label.alignment = .center
        label.textColor = NSColor.green.withAlphaComponent(0.93)
        label.font = NSFont(name: "SF Pro Display Bold", size: 28) ?? NSFont.systemFont(ofSize: 28, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let batteryPercentValueLabel: NSTextField = {
        let label = NSTextField(labelWithString: "--%")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Bold", size: 74) ?? NSFont.systemFont(ofSize: 74, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let batteryCaptionLabel: NSTextField = {
        let label = NSTextField(labelWithString: "BATTERY")
        label.alignment = .center
        label.textColor = NSColor.green.withAlphaComponent(0.9)
        label.font = NSFont(name: "SF Pro Display Bold", size: 24) ?? NSFont.systemFont(ofSize: 24, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let metricsStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "ART 1 MN.O\nART 1 DN.O\nPA2 MN.O")
        label.alignment = .left
        label.textColor = NSColor.green.withAlphaComponent(0.88)
        label.font = NSFont(name: "SF Mono Bold", size: 24) ?? NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let ekgView: EKGMonitorView = {
        let view = EKGMonitorView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 860),
            view.heightAnchor.constraint(equalToConstant: 315)
        ])
        return view
    }()

    private let respirationStripView: TelemetryStripView = {
        let view = TelemetryStripView(style: .respiration, tint: NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.62, alpha: 1.0))
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 860),
            view.heightAnchor.constraint(equalToConstant: 140)
        ])
        return view
    }()

    private let plethStripView: TelemetryStripView = {
        let view = TelemetryStripView(style: .pleth, tint: NSColor(calibratedRed: 0.60, green: 0.96, blue: 1.0, alpha: 1.0))
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 860),
            view.heightAnchor.constraint(equalToConstant: 140)
        ])
        return view
    }()

    private let oxygenValueLabel: NSTextField = {
        let label = NSTextField(labelWithString: "97%")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Bold", size: 104) ?? NSFont.systemFont(ofSize: 104, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let co2TitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "CO2")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Bold", size: 78) ?? NSFont.systemFont(ofSize: 78, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let co2StatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Not Attached")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Regular", size: 38) ?? NSFont.systemFont(ofSize: 38, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var footerLeftLabel: NSTextField = {
        let label = NSTextField(labelWithString: "System Health Monitoring \(systemDisplayName)")
        label.alignment = .left
        label.textColor = NSColor.green.withAlphaComponent(0.92)
        label.font = NSFont(name: "SF Pro Display Medium", size: 54) ?? NSFont.systemFont(ofSize: 54, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var footerNameLabel: NSTextField = {
        let label = NSTextField(labelWithString: systemDisplayName)
        label.alignment = .right
        label.textColor = NSColor.green.withAlphaComponent(0.95)
        label.font = NSFont(name: "SF Pro Display Medium", size: 56) ?? NSFont.systemFont(ofSize: 56, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let attachPowerMessageLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Attach Device to Power Immediately")
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont(name: "SF Pro Display Bold", size: 44) ?? NSFont.systemFont(ofSize: 44, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var vitalsMetricsPanel: NSStackView = {
        let stack = NSStackView(views: [heartRateValueLabel, heartRateCaptionLabel, batteryPercentValueLabel, batteryCaptionLabel, metricsStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        stack.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        stack.layer?.borderWidth = 2
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 330),
            stack.heightAnchor.constraint(equalToConstant: 315)
        ])
        return stack
    }()

    private lazy var oxygenPanel: NSStackView = {
        let stack = NSStackView(views: [oxygenValueLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        stack.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        stack.layer?.borderWidth = 2
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 330),
            stack.heightAnchor.constraint(equalToConstant: 140)
        ])
        return stack
    }()

    private lazy var co2Panel: NSStackView = {
        let stack = NSStackView(views: [co2TitleLabel, co2StatusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        stack.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        stack.layer?.borderWidth = 2
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 330),
            stack.heightAnchor.constraint(equalToConstant: 140)
        ])
        return stack
    }()

    private lazy var messageStack: NSStackView = {
        let stack = NSStackView(views: [titleLabel, paragraphSpacer, bodyLabel, secondParagraphSpacer, countdownView])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var vitalsStack: NSStackView = {
        let topSpacer = NSView()
        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [vitalsLeadLabel, topSpacer, vitalsSystemIdLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14

        let mainRow = NSStackView(views: [ekgView, vitalsMetricsPanel])
        mainRow.orientation = .horizontal
        mainRow.alignment = .top
        mainRow.spacing = 14

        let respirationRow = NSStackView(views: [respirationStripView, oxygenPanel])
        respirationRow.orientation = .horizontal
        respirationRow.alignment = .top
        respirationRow.spacing = 14

        let plethRow = NSStackView(views: [plethStripView, co2Panel])
        plethRow.orientation = .horizontal
        plethRow.alignment = .top
        plethRow.spacing = 14

        let footerRow = NSStackView(views: [footerLeftLabel])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 14

        let stack = NSStackView(views: [topRow, mainRow, respirationRow, plethRow, footerRow, attachPowerMessageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var selfDestructView: SelfDestructConsoleView = {
        let view = SelfDestructConsoleView(agentName: systemDisplayName)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var reactorMeltdownView: ReactorMeltdownView = {
        let view = ReactorMeltdownView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var starshipLifeSupportView: StarshipLifeSupportView = {
        let view = StarshipLifeSupportView(vesselName: systemDisplayName)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var matrixBinaryView: MatrixBinaryView = {
        let view = MatrixBinaryView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let closeButton: HoverCloseButton = {
        let button = HoverCloseButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.5).cgColor

        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        addSubview(messageStack)
        addSubview(vitalsStack)
        addSubview(selfDestructView)
        addSubview(reactorMeltdownView)
        addSubview(starshipLifeSupportView)
        addSubview(matrixBinaryView)
        addSubview(closeButton)

        ekgView.onBeat = { [weak self] beatIndex, bpm in
            self?.heartRateValueLabel.stringValue = "\(bpm)"
            self?.oxygenValueLabel.stringValue = "\(min(99, 58 + ((beatIndex + 1) * 2)))%"
            self?.tonePlayer.playBeat()
        }
        ekgView.onFlatline = { [weak self] in
            self?.heartRateValueLabel.stringValue = "0"
            self?.oxygenValueLabel.stringValue = "0%"
            self?.applyFlatlineVisualState()
            self?.tonePlayer.startFlatlineLoop()
        }

        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: messageStack.widthAnchor),
            bodyLabel.widthAnchor.constraint(lessThanOrEqualTo: messageStack.widthAnchor),

            vitalsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            vitalsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            vitalsStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.97),
            vitalsLeadLabel.widthAnchor.constraint(lessThanOrEqualTo: vitalsStack.widthAnchor, multiplier: 0.72),
            footerLeftLabel.widthAnchor.constraint(lessThanOrEqualTo: vitalsStack.widthAnchor, multiplier: 0.72),

            selfDestructView.centerXAnchor.constraint(equalTo: centerXAnchor),
            selfDestructView.centerYAnchor.constraint(equalTo: centerYAnchor),
            selfDestructView.widthAnchor.constraint(equalTo: widthAnchor),
            selfDestructView.heightAnchor.constraint(equalTo: heightAnchor),

            reactorMeltdownView.centerXAnchor.constraint(equalTo: centerXAnchor),
            reactorMeltdownView.centerYAnchor.constraint(equalTo: centerYAnchor),
            reactorMeltdownView.widthAnchor.constraint(equalTo: widthAnchor),
            reactorMeltdownView.heightAnchor.constraint(equalTo: heightAnchor),

            starshipLifeSupportView.centerXAnchor.constraint(equalTo: centerXAnchor),
            starshipLifeSupportView.centerYAnchor.constraint(equalTo: centerYAnchor),
            starshipLifeSupportView.widthAnchor.constraint(equalTo: widthAnchor),
            starshipLifeSupportView.heightAnchor.constraint(equalTo: heightAnchor),

            matrixBinaryView.centerXAnchor.constraint(equalTo: centerXAnchor),
            matrixBinaryView.centerYAnchor.constraint(equalTo: centerYAnchor),
            matrixBinaryView.widthAnchor.constraint(equalTo: widthAnchor),
            matrixBinaryView.heightAnchor.constraint(equalTo: heightAnchor),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            closeButton.widthAnchor.constraint(equalToConstant: 56),
            closeButton.heightAnchor.constraint(equalToConstant: 56)
        ])

        applyMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOverlayAlpha(_ alpha: CGFloat) {
        switch mode {
        case .defaultWarning:
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(alpha).cgColor
        case .vitalsMonitor:
            layer?.backgroundColor = NSColor(calibratedRed: 0.01, green: 0.08, blue: 0.04, alpha: 0.86).cgColor
        case .selfDestruct:
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        case .reactorMeltdown:
            layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.03, blue: 0.02, alpha: 0.90).cgColor
        case .starshipLifeSupport:
            layer?.backgroundColor = NSColor(calibratedRed: 0.01, green: 0.05, blue: 0.10, alpha: 0.88).cgColor
        case .matrixBinary:
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        }
    }

    func setBatteryPercent(_ percent: Int?) {
        guard let percent else {
            batteryPercentValueLabel.stringValue = "--%"
            return
        }
        batteryPercentValueLabel.stringValue = "\(percent)%"
    }

    func setSoundMuted(_ muted: Bool) {
        tonePlayer.setMuted(muted)
    }

    func startAlertAnimations() {
        switch mode {
        case .defaultWarning:
            countdownView.start()
            ekgView.stop()
            respirationStripView.stop()
            plethStripView.stop()
            selfDestructView.stop()
            reactorMeltdownView.stop()
            starshipLifeSupportView.stop()
            matrixBinaryView.stop()
            tonePlayer.startDefaultWarningLoop()
        case .vitalsMonitor:
            setOverlayAlpha(0.5)
            countdownView.stop()
            heartRateValueLabel.stringValue = "--"
            oxygenValueLabel.stringValue = "97%"
            ekgView.start()
            respirationStripView.start()
            plethStripView.start()
            selfDestructView.stop()
            reactorMeltdownView.stop()
            starshipLifeSupportView.stop()
            matrixBinaryView.stop()
            tonePlayer.stopAll()
        case .selfDestruct:
            countdownView.stop()
            ekgView.stop()
            respirationStripView.stop()
            plethStripView.stop()
            tonePlayer.stopAll()
            reactorMeltdownView.stop()
            starshipLifeSupportView.stop()
            matrixBinaryView.stop()
            selfDestructView.start()
            tonePlayer.startSelfDestructLoop()
        case .reactorMeltdown:
            countdownView.stop()
            ekgView.stop()
            respirationStripView.stop()
            plethStripView.stop()
            tonePlayer.stopAll()
            selfDestructView.stop()
            starshipLifeSupportView.stop()
            matrixBinaryView.stop()
            reactorMeltdownView.start()
            tonePlayer.startReactorLoop()
        case .starshipLifeSupport:
            countdownView.stop()
            ekgView.stop()
            respirationStripView.stop()
            plethStripView.stop()
            tonePlayer.stopAll()
            selfDestructView.stop()
            reactorMeltdownView.stop()
            matrixBinaryView.stop()
            starshipLifeSupportView.start()
            tonePlayer.startStarshipLoop()
        case .matrixBinary:
            countdownView.stop()
            ekgView.stop()
            respirationStripView.stop()
            plethStripView.stop()
            tonePlayer.stopAll()
            selfDestructView.stop()
            reactorMeltdownView.stop()
            starshipLifeSupportView.stop()
            matrixBinaryView.start()
            tonePlayer.startMatrixLoop()
        }
    }

    func stopAlertAnimations() {
        countdownView.stop()
        ekgView.stop()
        respirationStripView.stop()
        plethStripView.stop()
        selfDestructView.stop()
        reactorMeltdownView.stop()
        starshipLifeSupportView.stop()
        matrixBinaryView.stop()
        tonePlayer.stopAll()
    }

    func restartAlertAnimations() {
        stopAlertAnimations()
        startAlertAnimations()
    }

    private func applyMode() {
        messageStack.isHidden = mode != .defaultWarning
        vitalsStack.isHidden = mode != .vitalsMonitor
        selfDestructView.isHidden = mode != .selfDestruct
        reactorMeltdownView.isHidden = mode != .reactorMeltdown
        starshipLifeSupportView.isHidden = mode != .starshipLifeSupport
        matrixBinaryView.isHidden = mode != .matrixBinary
        setOverlayAlpha(0.5)
    }

    private func applyFlatlineVisualState() {
        guard mode == .vitalsMonitor else { return }
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.5).cgColor
    }

    @objc private func closeTapped() {
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        // Escape key should dismiss exactly like the close button.
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

private final class EscapeCapableOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayWindowController {
    let window: NSWindow
    let overlayView: OverlayView

    init(screen: NSScreen, onDismiss: @escaping () -> Void) {
        let frame = screen.frame
        overlayView = OverlayView(frame: frame)
        overlayView.onDismiss = onDismiss

        window = EscapeCapableOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.contentView = overlayView
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(window.screen?.frame ?? window.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.makeFirstResponder(overlayView)
        overlayView.startAlertAnimations()
    }

    func hide() {
        overlayView.stopAlertAnimations()
        window.orderOut(nil)
    }

    func setBatteryPercent(_ percent: Int?) {
        overlayView.setBatteryPercent(percent)
    }
}

private final class OverlayManager {
    var onDismiss: (() -> Void)?

    private var controllers: [OverlayWindowController] = []
    private var pulseTimer: Timer?
    private var pulsePhase: Double = 0
    private var mode: OverlayMode = .defaultWarning
    private var currentPulseAlpha: CGFloat = 0.5
    private var latestBatteryPercent: Int?
    private var soundMuted = false

    var isVisible: Bool {
        !controllers.isEmpty
    }

    func setMode(_ mode: OverlayMode) {
        self.mode = mode
        controllers.forEach { $0.overlayView.mode = mode }

        if isVisible {
            if mode == .defaultWarning {
                startPulse()
            } else {
                stopPulse()
                controllers.forEach { $0.overlayView.setOverlayAlpha(currentPulseAlpha) }
            }
            controllers.forEach { $0.overlayView.restartAlertAnimations() }
        } else {
            stopPulse()
        }
    }

    func setBatteryPercent(_ percent: Int?) {
        latestBatteryPercent = percent
        controllers.forEach { $0.setBatteryPercent(percent) }
    }

    func setSoundMuted(_ muted: Bool) {
        soundMuted = muted
        controllers.forEach { $0.overlayView.setSoundMuted(muted) }
    }

    func show() {
        guard controllers.isEmpty else {
            return
        }

        let dismiss: () -> Void = { [weak self] in
            guard let onDismiss = self?.onDismiss else {
                return
            }
            onDismiss()
        }

        controllers = NSScreen.screens.map {
            let controller = OverlayWindowController(screen: $0, onDismiss: dismiss)
            controller.overlayView.mode = mode
            controller.setBatteryPercent(latestBatteryPercent)
            controller.overlayView.setSoundMuted(soundMuted)
            return controller
        }
        controllers.forEach { $0.show() }

        if mode == .defaultWarning {
            startPulse()
        } else {
            stopPulse()
            controllers.forEach { $0.overlayView.setOverlayAlpha(currentPulseAlpha) }
        }
    }

    func hide() {
        stopPulse()
        controllers.forEach { $0.hide() }
        controllers.removeAll()
    }

    private func startPulse() {
        stopPulse()
        pulsePhase = 0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePulse()
        }
        RunLoop.main.add(pulseTimer!, forMode: .common)
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func updatePulse() {
        pulsePhase += 0.18
        let normalized = (sin(pulsePhase) + 1.0) / 2.0
        currentPulseAlpha = CGFloat(0.35 + (0.3 * normalized))
        controllers.forEach { $0.overlayView.setOverlayAlpha(currentPulseAlpha) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let thresholdDefaultsKey = "BatterySOS.warningThresholdPercent"
    private let soundMutedDefaultsKey = "BatterySOS.soundEffectsMuted"
    private let billingBaseURL = URL(string: ProcessInfo.processInfo.environment["BATTERY_SOS_BILLING_URL"] ?? "http://127.0.0.1:8787")!
    private let monetization = MonetizationManager()
    private let overlay = OverlayManager()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var batteryTimer: Timer?
    private var dismissedUntilRecover = false
    private var manualTestActive = false
    private var checkForUpdatesItem: NSMenuItem?
    private var lastKnownChargingState: Bool?
    private var thresholdPercent = 1
    private var soundEffectsMuted = false
    private var currentMode: OverlayMode = .defaultWarning
    private var statusItem: NSStatusItem?
    private var defaultWarningModeItem: NSMenuItem?
    private var vitalsModeItem: NSMenuItem?
    private var selfDestructModeItem: NSMenuItem?
    private var reactorMeltdownModeItem: NSMenuItem?
    private var starshipLifeSupportModeItem: NSMenuItem?
    private var matrixModeItem: NSMenuItem?
    private var startAtLoginItem: NSMenuItem?
    private var thresholdMenuItems: [Int: NSMenuItem] = [:]
    private var muteSoundEffectsItem: NSMenuItem?
    private var unlockProItem: NSMenuItem?
    private var licenseStatusItem: NSMenuItem?
    private var enterLicenseItem: NSMenuItem?
    private var clearLicenseItem: NSMenuItem?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadThresholdPreference()
        loadSoundPreference()
        overlay.setSoundMuted(soundEffectsMuted)

        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            if self.manualTestActive {
                self.manualTestActive = false
                self.overlay.hide()
                return
            }

            self.dismissedUntilRecover = true
            self.overlay.hide()
        }

        setupStatusMenu()
        if !canUseMode(currentMode) {
            currentMode = .defaultWarning
        }
        applyMode(currentMode)
        updateMonetizationUI()
        registerPowerStateObservers()

        evaluateBatteryState()

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.evaluateBatteryState()
        }
        if let batteryTimer {
            RunLoop.main.add(batteryTimer, forMode: .common)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        batteryTimer?.invalidate()
        unregisterPowerStateObservers()
        overlay.hide()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func startManualTest() {
        manualTestActive = true
        evaluateBatteryState()
    }

    @objc private func selectDefaultWarningMode() {
        selectModeWithGate(.defaultWarning)
    }

    @objc private func selectVitalsMode() {
        selectModeWithGate(.vitalsMonitor)
    }

    @objc private func selectSelfDestructMode() {
        selectModeWithGate(.selfDestruct)
    }

    @objc private func selectReactorMeltdownMode() {
        selectModeWithGate(.reactorMeltdown)
    }

    @objc private func selectStarshipLifeSupportMode() {
        selectModeWithGate(.starshipLifeSupport)
    }

    @objc private func selectMatrixMode() {
        selectModeWithGate(.matrixBinary)
    }

    @objc private func selectWarningThreshold(_ sender: NSMenuItem) {
        setWarningThreshold(sender.tag)
    }

    @objc private func toggleSoundEffectsMute() {
        setSoundEffectsMuted(!soundEffectsMuted)
    }

    @objc private func startProCheckout() {
        beginCheckoutFlow()
    }

    @objc private func promptForLicenseKey() {
        let alert = NSAlert()
        alert.messageText = "Enter License Key"
        alert.informativeText = "After checkout, paste your key here to unlock all Pro modes. If Cmd+V does not work, click Paste & Activate."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Paste & Activate")
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "BSOS-XXXX-XXXX-XXXX-XXXX"
        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            let normalized = clipboardText
                .uppercased()
                .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            if normalized.hasPrefix("BSOS-") {
                input.stringValue = normalized
            }
        }
        alert.accessoryView = input

        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        let rawKey: String
        if response == .alertFirstButtonReturn {
            rawKey = NSPasteboard.general.string(forType: .string) ?? input.stringValue
        } else {
            rawKey = input.stringValue
        }

        let normalizedInputKey = rawKey
            .uppercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard !normalizedInputKey.isEmpty else {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "License Key Missing"
            failure.informativeText = "Copy your key first, then use Paste & Activate."
            failure.runModal()
            return
        }

        verifyLicenseRemotely(normalizedInputKey) { [weak self] success, message, serverNormalizedKey in
            guard let self else { return }
            if success, let serverNormalizedKey {
                self.monetization.storeActivatedLicense(serverNormalizedKey)
                let successAlert = NSAlert()
                successAlert.messageText = "Battery SOS Pro Activated"
                successAlert.informativeText = "All modes are now unlocked on this Mac."
                successAlert.runModal()
            } else {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "License Verification Failed"
                failure.informativeText = message ?? "Unable to verify this key. Please try again."
                failure.runModal()
            }
            self.updateMonetizationUI()
        }
    }

    @objc private func clearLicenseKey() {
        monetization.clearLicense()
        updateMonetizationUI()
    }

    private func beginCheckoutFlow() {
        guard let url = URL(string: "/api/billing/create-checkout-session", relativeTo: billingBaseURL) else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["machineName": (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.showCheckoutError("Could not start checkout: \(error.localizedDescription)")
                    return
                }

                guard
                    let data,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let checkoutURLString = object["url"] as? String,
                    let checkoutURL = URL(string: checkoutURLString)
                else {
                    self.showCheckoutError("Checkout URL response was invalid.")
                    return
                }

                NSWorkspace.shared.open(checkoutURL)
            }
        }.resume()
    }

    private func verifyLicenseRemotely(_ licenseKey: String, completion: @escaping (Bool, String?, String?) -> Void) {
        guard let url = URL(string: "/api/billing/verify-license", relativeTo: billingBaseURL) else {
            completion(false, "Billing endpoint URL is invalid.", nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "licenseKey": licenseKey,
            "machineName": (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(false, "Unable to contact billing server: \(error.localizedDescription)", nil)
                    return
                }

                guard
                    let data,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    completion(false, "License verification response was invalid.", nil)
                    return
                }

                let valid = object["valid"] as? Bool ?? false
                let message = object["message"] as? String
                let normalizedKey = object["normalizedKey"] as? String
                completion(valid, message, normalizedKey)
            }
        }.resume()
    }

    private func showCheckoutError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Checkout Unavailable"
        alert.informativeText = message + "\n\nSet BATTERY_SOS_BILLING_URL to your deployed billing server URL."
        alert.runModal()
    }

    @objc private func toggleStartAtLogin() {
        guard #available(macOS 13.0, *) else {
            return
        }
        guard supportsStartAtLogin else {
            return
        }

        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Battery SOS: failed to toggle start at login: \(error.localizedDescription)")
        }
        updateStartAtLoginMenuState()
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let bodyRect = NSRect(x: 4.0, y: 2.0, width: 10.0, height: 12.5)
            let tipRect = NSRect(x: 7.2, y: 14.7, width: 3.6, height: 1.8)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.0, yRadius: 2.0)
            let tipPath = NSBezierPath(roundedRect: tipRect, xRadius: 0.9, yRadius: 0.9)

            NSColor.white.setFill()
            bodyPath.fill()
            tipPath.fill()

            NSColor.white.withAlphaComponent(0.95).setStroke()
            bodyPath.lineWidth = 1.1
            bodyPath.stroke()

            let warning = NSAttributedString(
                string: "!",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.0, weight: .black),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.9)
                ]
            )
            warning.draw(at: NSPoint(x: 6.85, y: 2.45))
            return true
        }
        image.isTemplate = false
        return image
    }

    private func setupStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Battery SOS"
        }

        let menu = NSMenu()
        let testItem = NSMenuItem(title: "Test SOS", action: #selector(startManualTest), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkUpdatesItem.target = updaterController
        menu.addItem(checkUpdatesItem)
        checkForUpdatesItem = checkUpdatesItem

        let modeMenuItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "Mode")
        let defaultModeItem = NSMenuItem(title: OverlayMode.defaultWarning.rawValue, action: #selector(selectDefaultWarningMode), keyEquivalent: "")
        defaultModeItem.target = self
        let vitalsModeItem = NSMenuItem(title: OverlayMode.vitalsMonitor.rawValue, action: #selector(selectVitalsMode), keyEquivalent: "")
        vitalsModeItem.target = self
        let selfDestructModeItem = NSMenuItem(title: OverlayMode.selfDestruct.rawValue, action: #selector(selectSelfDestructMode), keyEquivalent: "")
        selfDestructModeItem.target = self
        let reactorMeltdownModeItem = NSMenuItem(title: OverlayMode.reactorMeltdown.rawValue, action: #selector(selectReactorMeltdownMode), keyEquivalent: "")
        reactorMeltdownModeItem.target = self
        let starshipLifeSupportModeItem = NSMenuItem(title: OverlayMode.starshipLifeSupport.rawValue, action: #selector(selectStarshipLifeSupportMode), keyEquivalent: "")
        starshipLifeSupportModeItem.target = self
        let matrixModeItem = NSMenuItem(title: OverlayMode.matrixBinary.rawValue, action: #selector(selectMatrixMode), keyEquivalent: "")
        matrixModeItem.target = self
        modeMenu.addItem(defaultModeItem)
        modeMenu.addItem(vitalsModeItem)
        modeMenu.addItem(selfDestructModeItem)
        modeMenu.addItem(reactorMeltdownModeItem)
        modeMenu.addItem(starshipLifeSupportModeItem)
        modeMenu.addItem(matrixModeItem)
        menu.addItem(modeMenuItem)
        menu.setSubmenu(modeMenu, for: modeMenuItem)

        let settingsMenuItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Settings")
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        loginItem.target = self
        settingsMenu.addItem(loginItem)
        settingsMenu.addItem(NSMenuItem.separator())
        let muteSoundItem = NSMenuItem(title: "Mute Sound Effects", action: #selector(toggleSoundEffectsMute), keyEquivalent: "")
        muteSoundItem.target = self
        settingsMenu.addItem(muteSoundItem)
        settingsMenu.addItem(NSMenuItem.separator())
        let warningPercentMenuItem = NSMenuItem(title: "Warning Percentage", action: nil, keyEquivalent: "")
        let warningPercentMenu = NSMenu(title: "Warning Percentage")
        for percent in 1...10 {
            let warningItem = NSMenuItem(title: "\(percent)%", action: #selector(selectWarningThreshold(_:)), keyEquivalent: "")
            warningItem.target = self
            warningItem.tag = percent
            thresholdMenuItems[percent] = warningItem
            warningPercentMenu.addItem(warningItem)
        }
        settingsMenu.addItem(warningPercentMenuItem)
        settingsMenu.setSubmenu(warningPercentMenu, for: warningPercentMenuItem)

        settingsMenu.addItem(NSMenuItem.separator())
        let unlockPro = NSMenuItem(title: "Unlock Pro ($1)...", action: #selector(startProCheckout), keyEquivalent: "")
        unlockPro.target = self
        let licenseStatusMenuItem = NSMenuItem(title: "License: --", action: nil, keyEquivalent: "")
        licenseStatusMenuItem.isEnabled = false
        let enterLicense = NSMenuItem(title: "Enter License Key...", action: #selector(promptForLicenseKey), keyEquivalent: "")
        enterLicense.target = self
        let clearLicense = NSMenuItem(title: "Clear License Key", action: #selector(clearLicenseKey), keyEquivalent: "")
        clearLicense.target = self
        settingsMenu.addItem(unlockPro)
        settingsMenu.addItem(licenseStatusMenuItem)
        settingsMenu.addItem(enterLicense)
        settingsMenu.addItem(clearLicense)

        menu.addItem(settingsMenuItem)
        menu.setSubmenu(settingsMenu, for: settingsMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Battery SOS", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu

        defaultWarningModeItem = defaultModeItem
        self.vitalsModeItem = vitalsModeItem
        self.selfDestructModeItem = selfDestructModeItem
        self.reactorMeltdownModeItem = reactorMeltdownModeItem
        self.starshipLifeSupportModeItem = starshipLifeSupportModeItem
        self.matrixModeItem = matrixModeItem
        startAtLoginItem = loginItem
        muteSoundEffectsItem = muteSoundItem
        unlockProItem = unlockPro
        licenseStatusItem = licenseStatusMenuItem
        enterLicenseItem = enterLicense
        clearLicenseItem = clearLicense
        updateThresholdMenuState()
        updateSoundMenuState()
        updateStartAtLoginMenuState()
        updateMonetizationUI()
        statusItem = item
    }

    private func registerPowerStateObservers() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWillSleep()
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemDidWake()
        }
    }

    private func unregisterPowerStateObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
        }
        sleepObserver = nil
        wakeObserver = nil
    }

    private func handleSystemWillSleep() {
        manualTestActive = false
        overlay.hide()
    }

    private func handleSystemDidWake() {
        evaluateBatteryState()
    }

    private func applyMode(_ mode: OverlayMode) {
        currentMode = canUseMode(mode) ? mode : .defaultWarning
        overlay.setMode(currentMode)
        defaultWarningModeItem?.state = currentMode == .defaultWarning ? .on : .off
        vitalsModeItem?.state = currentMode == .vitalsMonitor ? .on : .off
        selfDestructModeItem?.state = currentMode == .selfDestruct ? .on : .off
        reactorMeltdownModeItem?.state = currentMode == .reactorMeltdown ? .on : .off
        starshipLifeSupportModeItem?.state = currentMode == .starshipLifeSupport ? .on : .off
        matrixModeItem?.state = currentMode == .matrixBinary ? .on : .off
    }

    private func loadThresholdPreference() {
        let stored = UserDefaults.standard.integer(forKey: thresholdDefaultsKey)
        if (1...10).contains(stored) {
            thresholdPercent = stored
        }
    }

    private func setWarningThreshold(_ value: Int) {
        guard (1...10).contains(value) else { return }
        thresholdPercent = value
        UserDefaults.standard.set(value, forKey: thresholdDefaultsKey)
        updateThresholdMenuState()
        dismissedUntilRecover = false
        evaluateBatteryState()
    }

    private func updateThresholdMenuState() {
        for percent in 1...10 {
            thresholdMenuItems[percent]?.state = percent == thresholdPercent ? .on : .off
        }
    }

    private func loadSoundPreference() {
        soundEffectsMuted = UserDefaults.standard.bool(forKey: soundMutedDefaultsKey)
    }

    private func setSoundEffectsMuted(_ muted: Bool) {
        soundEffectsMuted = muted
        UserDefaults.standard.set(muted, forKey: soundMutedDefaultsKey)
        overlay.setSoundMuted(muted)
        updateSoundMenuState()
    }

    private func updateSoundMenuState() {
        muteSoundEffectsItem?.state = soundEffectsMuted ? .on : .off
    }

    private var supportsStartAtLogin: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func updateStartAtLoginMenuState() {
        guard let startAtLoginItem else { return }

        if !supportsStartAtLogin {
            startAtLoginItem.title = "Start at Login (App Bundle Required)"
            startAtLoginItem.state = .off
            startAtLoginItem.isEnabled = false
            return
        }

        startAtLoginItem.title = "Start at Login"
        startAtLoginItem.isEnabled = true

        if #available(macOS 13.0, *) {
            startAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            startAtLoginItem.state = .off
            startAtLoginItem.isEnabled = false
        }
    }

    private func isPremiumMode(_ mode: OverlayMode) -> Bool {
        switch mode {
        case .defaultWarning:
            return false
        case .vitalsMonitor, .selfDestruct, .reactorMeltdown, .starshipLifeSupport, .matrixBinary:
            return true
        }
    }

    private func canUseMode(_ mode: OverlayMode) -> Bool {
        !isPremiumMode(mode) || monetization.hasProAccess
    }

    private func menuTitle(for mode: OverlayMode) -> String {
        guard isPremiumMode(mode), !monetization.hasProAccess else {
            return mode.rawValue
        }
        return "\(mode.rawValue) (Pro)"
    }

    private func updateModeMenuTitles() {
        defaultWarningModeItem?.title = OverlayMode.defaultWarning.rawValue
        vitalsModeItem?.title = OverlayMode.vitalsMonitor.rawValue
        selfDestructModeItem?.title = menuTitle(for: .selfDestruct)
        reactorMeltdownModeItem?.title = menuTitle(for: .reactorMeltdown)
        starshipLifeSupportModeItem?.title = menuTitle(for: .starshipLifeSupport)
        matrixModeItem?.title = menuTitle(for: .matrixBinary)
    }

    private func selectModeWithGate(_ mode: OverlayMode) {
        guard canUseMode(mode) else {
            presentProRequiredAlert(for: mode)
            return
        }
        applyMode(mode)
    }

    private func presentProRequiredAlert(for mode: OverlayMode) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(mode.rawValue) is a Pro mode"
        alert.informativeText = "Use Settings -> Unlock Pro ($1)..., then enter your license key."
        alert.runModal()
    }

    private func updateMonetizationUI() {
        updateModeMenuTitles()
        licenseStatusItem?.title = "License: \(monetization.statusSummary)"
        enterLicenseItem?.title = monetization.isProUnlocked ? "Change License Key..." : "Enter License Key..."
        clearLicenseItem?.isEnabled = monetization.isProUnlocked
        unlockProItem?.isEnabled = !monetization.isProUnlocked

        if !canUseMode(currentMode) {
            applyMode(.defaultWarning)
        }
    }

    private func evaluateBatteryState() {
        updateMonetizationUI()
        guard let state = readBatteryState() else {
            lastKnownChargingState = nil
            overlay.setBatteryPercent(nil)
            overlay.hide()
            return
        }

        let didJustPlugIn = (lastKnownChargingState == false && state.isCharging)
        lastKnownChargingState = state.isCharging

        overlay.setBatteryPercent(state.percent)

        if manualTestActive {
            if didJustPlugIn {
                manualTestActive = false
                overlay.hide()
            } else {
                overlay.show()
            }
            return
        }

        if state.isCharging {
            dismissedUntilRecover = false
            overlay.hide()
            return
        }

        let isCritical = state.percent <= thresholdPercent

        if state.percent > thresholdPercent {
            dismissedUntilRecover = false
            overlay.hide()
            return
        }

        if isCritical && !dismissedUntilRecover {
            overlay.show()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
