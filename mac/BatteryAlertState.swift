// Battery decisions are independent of AppKit, audio, preferences and hardware.
struct BatteryState {
    let percent: Int
    let isCharging: Bool
}

enum BatteryAlertAction: Equatable { case show, hide }

struct BatteryAlertStateMachine {
    private(set) var thresholdPercent = 1
    private(set) var manualTestActive = false
    private var dismissedUntilRecover = false
    private var lastKnownChargingState: Bool?
    private var isSleeping = false

    mutating func setThreshold(_ value: Int) {
        guard (1...10).contains(value) else { return }
        thresholdPercent = value
        dismissedUntilRecover = false
    }

    mutating func resumeWarnings() { dismissedUntilRecover = false }

    mutating func startPreview() { manualTestActive = true }

    mutating func dismiss() {
        if manualTestActive { manualTestActive = false }
        else { dismissedUntilRecover = true }
    }

    mutating func prepareForSleep() {
        isSleeping = true
        manualTestActive = false
    }

    mutating func wake() { isSleeping = false }

    mutating func evaluate(_ state: BatteryState?) -> BatteryAlertAction {
        guard !isSleeping else { return .hide }
        let didJustPlugIn = lastKnownChargingState == false && state?.isCharging == true
        lastKnownChargingState = state?.isCharging
        if state?.isCharging == true { dismissedUntilRecover = false }

        // Explicit preview is useful on desktops with no battery, too.
        if manualTestActive {
            if didJustPlugIn {
                manualTestActive = false
                return .hide
            }
            return .show
        }
        guard let state else { return .hide }
        if state.isCharging { return .hide }
        if state.percent > thresholdPercent {
            dismissedUntilRecover = false
            return .hide
        }
        return dismissedUntilRecover ? .hide : .show
    }
}
