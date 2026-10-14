import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
let now = Date(timeIntervalSince1970: 1_700_000_000)
let low = BatteryState(percent: 19, isCharging: false)
var settings = ProBatterySettings()
check(settings.headsUpPercent == 0 && settings.chargeTargetPercent == 0 && !settings.quietHoursEnabled, "defaults changed")
settings.headsUpPercent = 20; settings.chargeTargetPercent = 80
var session = ProBatterySession()
check(session.evaluate(low, settings: settings, hasPro: false, criticalPercent: 1) == nil, "free notice")
check(session.evaluate(low, settings: settings, hasPro: true, criticalPercent: 1) == .headsUp(19), "early warning")
check(session.evaluate(low, settings: settings, hasPro: true, criticalPercent: 1) == nil, "repeated early warning")
_ = session.evaluate(BatteryState(percent: 21, isCharging: false), settings: settings, hasPro: true, criticalPercent: 1)
check(session.evaluate(low, settings: settings, hasPro: true, criticalPercent: 1) == .headsUp(19), "rearm early")
check(session.evaluate(BatteryState(percent: 1, isCharging: false), settings: settings, hasPro: true, criticalPercent: 1) == nil, "notice over SOS")
check(session.evaluate(BatteryState(percent: 80, isCharging: true), settings: settings, hasPro: true, criticalPercent: 1) == .chargeTarget(80), "charge reminder")
check(session.evaluate(BatteryState(percent: 79, isCharging: true), settings: settings, hasPro: true, criticalPercent: 1) == nil, "charge chatter")
check(session.evaluate(BatteryState(percent: 80, isCharging: true), settings: settings, hasPro: true, criticalPercent: 1) == nil, "repeat charge")
_ = session.evaluate(BatteryState(percent: 77, isCharging: true), settings: settings, hasPro: true, criticalPercent: 1)
check(session.evaluate(BatteryState(percent: 90, isCharging: true), settings: settings, hasPro: true, criticalPercent: 1) == .chargeTarget(90), "charge rearm")
check(session.evaluate(BatteryState(percent: 101, isCharging: true), settings: settings, hasPro: true, criticalPercent: 1) == nil, "invalid reading")
print("PASS: early warning, charge target, rearming, entitlement and invalid readings")

session.snooze(minutes: 5, now: now)
check(session.isSnoozed(state: low, now: now.addingTimeInterval(299), hasPro: true), "early expiry")
check(!session.isSnoozed(state: low, now: now.addingTimeInterval(300), hasPro: true), "late expiry")
for state in [BatteryState(percent: 1, isCharging: false), BatteryState(percent: 80, isCharging: true)] {
    session.snooze(minutes: 5, now: now)
    check(!session.isSnoozed(state: state, now: now, hasPro: true) && session.snoozeUntil == nil, "snooze override")
}
session.snooze(minutes: 5, now: now)
check(!session.isSnoozed(state: low, now: now, hasPro: false), "free snooze")
session.snooze(minutes: 100, now: now); check(session.snoozeUntil == nil, "invalid duration")
session.snooze(minutes: 10, now: now); session.resume(); check(session.snoozeUntil == nil, "resume")
print("PASS: snooze expiry, power, critical floor, entitlement, validation and resume")

var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
func date(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: hour))! }
settings.quietHoursEnabled = true
for hour in 0...23 { check(settings.quiet(at: date(hour), calendar: calendar) == (hour >= 22 || hour < 7), "overnight boundary") }
settings.quietStartHour = 9; settings.quietEndHour = 17
for hour in 0...23 { check(settings.quiet(at: date(hour), calendar: calendar) == (hour >= 9 && hour < 17), "day boundary") }
settings.quietStartHour = 17; check(!settings.quiet(at: date(17), calendar: calendar), "equal hours")
settings.quietHoursEnabled = false; check(!settings.quiet(at: date(23), calendar: calendar), "disabled")
print("PASS: quiet-hours boundary and overnight schedules")

let suite = "BatterySOS.Pro.Test.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let prefs = ProBatteryPreferences(defaults: defaults)
prefs.settings = settings
check(ProBatteryPreferences(defaults: defaults).settings == settings, "persistence")
var invalid = settings; invalid.headsUpPercent = 900; invalid.chargeTargetPercent = -10; invalid.quietStartHour = 99
prefs.settings = invalid
check(prefs.settings.headsUpPercent == 0 && prefs.settings.chargeTargetPercent == 0 && prefs.settings.quietStartHour == 22, "stored validation")
defaults.set(Data("broken".utf8), forKey: "BatterySOS.proBatterySettings.v1")
check(prefs.settings == ProBatterySettings(), "corrupt preferences")
print("PASS: preference roundtrip, validation and corrupt-data recovery")
check(BatteryDashboard(state: nil, estimatedMinutes: nil).summary.contains("No internal battery"), "desktop")
check(BatteryDashboard(state: low, estimatedMinutes: 125).summary.contains("2h 5m"), "estimate")
check(BatteryDashboard(state: low, estimatedMinutes: -1).summary.contains("unavailable"), "unknown")
print("PASS: dashboard unavailable and macOS estimate formatting")

var sos = BatteryAlertStateMachine()
sos.setThreshold(10)
let critical = BatteryState(percent: 5, isCharging: false)
check(sos.evaluate(critical) == .show, "SOS setup")
sos.dismiss()
check(sos.evaluate(critical) == .hide, "dismiss setup")
sos.resumeWarnings()
session.snooze(minutes: 5, now: now)
check(sos.evaluate(critical) == .show && session.isSnoozed(state: critical, now: now, hasPro: true), "snooze fresh alert")
check(!session.isSnoozed(state: critical, now: now.addingTimeInterval(300), hasPro: true) && sos.evaluate(critical) == .show, "SOS resumes on expiry")
print("PASS: integrated dismissed SOS, explicit snooze and alert resumption")
