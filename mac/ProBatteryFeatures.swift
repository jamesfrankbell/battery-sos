import Foundation

// Optional Pro tools. Defaults leave the existing SOS behavior unchanged.
struct ProBatterySettings: Codable, Equatable {
    var headsUpPercent = 0
    var chargeTargetPercent = 0
    var quietStartHour = 22
    var quietEndHour = 7
    var quietHoursEnabled = false

    var validated: Self {
        var copy = self
        if ![0, 15, 20, 30, 40].contains(copy.headsUpPercent) { copy.headsUpPercent = 0 }
        if ![0, 80, 90, 100].contains(copy.chargeTargetPercent) { copy.chargeTargetPercent = 0 }
        if !(0...23).contains(copy.quietStartHour) { copy.quietStartHour = 22 }
        if !(0...23).contains(copy.quietEndHour) { copy.quietEndHour = 7 }
        return copy
    }

    func quiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled, quietStartHour != quietEndHour else { return false }
        let hour = calendar.component(.hour, from: date)
        return quietStartHour < quietEndHour
            ? hour >= quietStartHour && hour < quietEndHour
            : hour >= quietStartHour || hour < quietEndHour
    }
}

final class ProBatteryPreferences {
    private let defaults: UserDefaults
    private let key = "BatterySOS.proBatterySettings.v1"
    init(defaults: UserDefaults) { self.defaults = defaults }
    var settings: ProBatterySettings {
        get {
            guard let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(ProBatterySettings.self, from: data) else { return .init() }
            return value.validated
        }
        set { if let data = try? JSONEncoder().encode(newValue.validated) { defaults.set(data, forKey: key) } }
    }
}

enum ProBatteryNotice: Equatable { case headsUp(Int), chargeTarget(Int) }

struct ProBatterySession {
    private(set) var snoozeUntil: Date?
    private var headsUpDelivered = false
    private var chargeDelivered = false
    private var previousHeadsUp = 0
    private var previousChargeTarget = 0

    mutating func snooze(minutes: Int, now: Date) {
        guard [5, 10, 15].contains(minutes) else { return }
        snoozeUntil = now.addingTimeInterval(Double(minutes * 60))
    }
    mutating func resume() { snoozeUntil = nil }

    mutating func isSnoozed(state: BatteryState?, now: Date, hasPro: Bool) -> Bool {
        guard hasPro, let state, !state.isCharging, (2...100).contains(state.percent),
              let until = snoozeUntil, until > now else { snoozeUntil = nil; return false }
        return true
    }

    mutating func evaluate(_ state: BatteryState?, settings: ProBatterySettings, hasPro: Bool, criticalPercent: Int) -> ProBatteryNotice? {
        guard hasPro, let state, (0...100).contains(state.percent) else {
            headsUpDelivered = false; chargeDelivered = false; snoozeUntil = nil
            return nil
        }
        if previousHeadsUp != settings.headsUpPercent { headsUpDelivered = false }
        if previousChargeTarget != settings.chargeTargetPercent { chargeDelivered = false }
        previousHeadsUp = settings.headsUpPercent
        previousChargeTarget = settings.chargeTargetPercent
        if state.isCharging || state.percent > settings.headsUpPercent { headsUpDelivered = false }
        if !state.isCharging || state.percent < settings.chargeTargetPercent - 2 { chargeDelivered = false }
        if state.isCharging, settings.chargeTargetPercent > 0,
           state.percent >= settings.chargeTargetPercent, !chargeDelivered {
            chargeDelivered = true
            return .chargeTarget(state.percent)
        }
        if !state.isCharging, settings.headsUpPercent > criticalPercent,
           state.percent <= settings.headsUpPercent, state.percent > criticalPercent, !headsUpDelivered {
            headsUpDelivered = true
            return .headsUp(state.percent)
        }
        return nil
    }
}

struct BatteryDashboard {
    let state: BatteryState?
    let estimatedMinutes: Int?
    var summary: String {
        guard let state else { return "No internal battery detected. SOS previews still work on this Mac." }
        let power = state.isCharging ? "Connected to power" : "Running on battery"
        let estimate: String
        if let minutes = estimatedMinutes, minutes > 0 { estimate = "Estimated time remaining: \(minutes / 60)h \(minutes % 60)m" }
        else { estimate = "Time remaining is unavailable or still calculating." }
        return "\(state.percent)% · \(power)\n\(estimate)"
    }
}
