// Standalone assertions keep these simulations runnable with Command Line Tools.
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    guard actual == expected else { fatalError("\(file):\(line): expected \(expected), observed \(actual)") }
}
func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    expectEqual(value, false, file: file, line: line)
}

final class BatteryAlertTests {
    func testThresholdBoundariesAndRepeatedSamples() {
        for threshold in 1...10 {
            var machine = BatteryAlertStateMachine()
            machine.setThreshold(threshold)
            expectEqual(machine.evaluate(BatteryState(percent: threshold + 1, isCharging: false)), .hide)
            expectEqual(machine.evaluate(BatteryState(percent: threshold, isCharging: false)), .show)
            for _ in 0..<20 { expectEqual(machine.evaluate(BatteryState(percent: threshold - 1, isCharging: false)), .show) }
        }
    }
    func testDismissAndRecover() {
        var machine = BatteryAlertStateMachine()
        expectEqual(machine.evaluate(BatteryState(percent: 1, isCharging: false)), .show)
        machine.dismiss()
        for _ in 0..<20 { expectEqual(machine.evaluate(BatteryState(percent: 0, isCharging: false)), .hide) }
        expectEqual(machine.evaluate(BatteryState(percent: 2, isCharging: false)), .hide)
        expectEqual(machine.evaluate(BatteryState(percent: 1, isCharging: false)), .show)
    }
    func testACConnectionRearmsDismissedAlert() {
        var machine = BatteryAlertStateMachine()
        _ = machine.evaluate(BatteryState(percent: 1, isCharging: false))
        machine.dismiss()
        expectEqual(machine.evaluate(BatteryState(percent: 1, isCharging: true)), .hide)
        expectEqual(machine.evaluate(BatteryState(percent: 1, isCharging: false)), .show)
    }
    func testDesktopPreviewWithoutBattery() {
        var machine = BatteryAlertStateMachine()
        expectEqual(machine.evaluate(nil), .hide)
        machine.startPreview()
        for _ in 0..<20 { expectEqual(machine.evaluate(nil), .show) }
        machine.dismiss()
        expectFalse(machine.manualTestActive)
        expectEqual(machine.evaluate(nil), .hide)
        machine.startPreview()
        expectEqual(machine.evaluate(nil), .show)
    }
    func testPreviewWhileOnACAndPlugInTransition() {
        var machine = BatteryAlertStateMachine()
        _ = machine.evaluate(BatteryState(percent: 50, isCharging: true))
        machine.startPreview()
        expectEqual(machine.evaluate(BatteryState(percent: 50, isCharging: true)), .show)
        _ = machine.evaluate(BatteryState(percent: 50, isCharging: false))
        expectEqual(machine.evaluate(BatteryState(percent: 50, isCharging: true)), .hide)
        expectFalse(machine.manualTestActive)
    }
    func testSleepPreventsTimerFromReshowingThenWakeReevaluates() {
        var machine = BatteryAlertStateMachine()
        let low = BatteryState(percent: 1, isCharging: false)
        expectEqual(machine.evaluate(low), .show)
        machine.prepareForSleep()
        for _ in 0..<20 { expectEqual(machine.evaluate(low), .hide) }
        machine.wake()
        expectEqual(machine.evaluate(low), .show)
        machine.prepareForSleep()
        machine.wake()
        expectEqual(machine.evaluate(BatteryState(percent: 1, isCharging: true)), .hide)
    }
    func testSleepEndsPreviewAndRetainsDismissal() {
        var machine = BatteryAlertStateMachine()
        machine.startPreview()
        machine.prepareForSleep()
        expectFalse(machine.manualTestActive)
        machine.wake()
        expectEqual(machine.evaluate(nil), .hide)
        let low = BatteryState(percent: 1, isCharging: false)
        _ = machine.evaluate(low)
        machine.dismiss()
        machine.prepareForSleep()
        machine.wake()
        expectEqual(machine.evaluate(low), .hide)
    }
    func testPreviewDismissalDoesNotSuppressRealWarning() {
        var machine = BatteryAlertStateMachine()
        let low = BatteryState(percent: 1, isCharging: false)
        machine.startPreview()
        expectEqual(machine.evaluate(low), .show)
        machine.dismiss()
        expectEqual(machine.evaluate(low), .show)
        machine.dismiss()
        expectEqual(machine.evaluate(low), .hide)
    }
    func testPreferenceChangeAndSensorInterruption() {
        var machine = BatteryAlertStateMachine()
        expectEqual(machine.thresholdPercent, 1)
        for value in [0, 11, -1] { machine.setThreshold(value); expectEqual(machine.thresholdPercent, 1) }
        _ = machine.evaluate(BatteryState(percent: 1, isCharging: false))
        machine.dismiss()
        expectEqual(machine.evaluate(nil), .hide)
        expectEqual(machine.evaluate(BatteryState(percent: 1, isCharging: false)), .hide)
        machine.setThreshold(5)
        expectEqual(machine.evaluate(BatteryState(percent: 4, isCharging: false)), .show)
    }
}

let tests = BatteryAlertTests()
let cases: [(String, () -> Void)] = [
    ("threshold boundaries and repeated samples", tests.testThresholdBoundariesAndRepeatedSamples),
    ("dismiss and recover", tests.testDismissAndRecover),
    ("AC connection", tests.testACConnectionRearmsDismissedAlert),
    ("desktop preview without battery", tests.testDesktopPreviewWithoutBattery),
    ("preview AC transition", tests.testPreviewWhileOnACAndPlugInTransition),
    ("sleep timer and wake", tests.testSleepPreventsTimerFromReshowingThenWakeReevaluates),
    ("sleep preview and dismissal", tests.testSleepEndsPreviewAndRetainsDismissal),
    ("preferences and sensor interruption", tests.testPreferenceChangeAndSensorInterruption),
    ("preview dismissal preserves actual warning", tests.testPreviewDismissalDoesNotSuppressRealWarning),
]
for (name, run) in cases { run(); print("PASS \(name)") }
print("\(cases.count) simulations passed")
