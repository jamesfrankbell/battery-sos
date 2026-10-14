import CryptoKit
import Foundation

enum OverlayMode: String, CaseIterable {
    case defaultWarning = "Default Warning"
    case vitalsMonitor = "Vitals Monitor"
    case selfDestruct = "Self-Destruct"
    case reactorMeltdown = "Reactor Meltdown"
    case starshipLifeSupport = "Starship Life Support"
    case matrixBinary = "Matrix"

    var isPremium: Bool { self != .defaultWarning }
    func menuTitle(hasProAccess: Bool) -> String {
        if !isPremium { return "\(rawValue) (Free)" }
        return hasProAccess ? rawValue : "\(rawValue) (Pro)"
    }
}

struct ThemePreferences {
    let defaults: UserDefaults
    private let storageKey = "BatterySOS.overlayMode"

    func selectedMode(hasProAccess: Bool) -> OverlayMode {
        let saved = defaults.string(forKey: storageKey).flatMap(OverlayMode.init(rawValue:)) ?? .defaultWarning
        return saved.isPremium && !hasProAccess ? .defaultWarning : saved
    }

    func select(_ mode: OverlayMode, hasProAccess: Bool) -> Bool {
        guard !mode.isPremium || hasProAccess else { return false }
        defaults.set(mode.rawValue, forKey: storageKey)
        return true
    }
}

struct LicenseActivationResult {
    let valid: Bool
    let message: String?
    let normalizedKey: String?
}
struct BillingClientError: Error { let message: String }

enum BillingClientResponse {
    private static func object(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func failure(statusCode: Int?, payload: [String: Any]?, action: String) -> String {
        if let statusCode, statusCode >= 500 {
            return "\(action) is temporarily unavailable. Please try again shortly."
        }
        return (payload?["message"] as? String) ?? (payload?["error"] as? String) ?? "\(action) could not be completed. Please try again."
    }
    static func activation(data: Data?, statusCode: Int?, error: Error?) -> LicenseActivationResult {
        if error != nil {
            return LicenseActivationResult(valid: false, message: "Unable to connect. Check your internet connection and try again.", normalizedKey: nil)
        }
        let payload = object(data)
        guard let statusCode, (200..<300).contains(statusCode) else {
            return LicenseActivationResult(valid: false, message: failure(statusCode: statusCode, payload: payload, action: "Activation"), normalizedKey: nil)
        }
        guard let payload, let valid = payload["valid"] as? Bool else {
            return LicenseActivationResult(valid: false, message: "The activation service returned an unreadable response. Please try again.", normalizedKey: nil)
        }
        let key = (payload["normalizedKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if valid, let key, !key.isEmpty {
            return LicenseActivationResult(valid: true, message: payload["message"] as? String, normalizedKey: key)
        }
        return LicenseActivationResult(valid: false, message: (payload["message"] as? String) ?? "This license could not be activated. Check the key and try again.", normalizedKey: nil)
    }
    static func checkout(data: Data?, statusCode: Int?, error: Error?) -> Result<URL, BillingClientError> {
        if error != nil {
            return .failure(BillingClientError(message: "Unable to connect. Check your internet connection and try again."))
        }
        let payload = object(data)
        guard let statusCode, (200..<300).contains(statusCode) else {
            return .failure(BillingClientError(message: failure(statusCode: statusCode, payload: payload, action: "Checkout")))
        }
        guard let text = payload?["url"] as? String, let url = URL(string: text), url.scheme == "https", url.host != nil else {
            return .failure(BillingClientError(message: "The checkout service returned an invalid link. Please try again."))
        }
        return .success(url)
    }

    static func deactivation(data: Data?, statusCode: Int?, error: Error?) -> LicenseDeactivationResult {
        if error != nil {
            return LicenseDeactivationResult(deactivated: false, message: "Unable to connect. Check your internet connection and try again.", transfersRemaining: nil)
        }
        let payload = object(data)
        guard let statusCode, (200..<300).contains(statusCode) else {
            return LicenseDeactivationResult(deactivated: false, message: failure(statusCode: statusCode, payload: payload, action: "Deactivation"), transfersRemaining: nil)
        }
        guard let payload, let deactivated = payload["deactivated"] as? Bool else {
            return LicenseDeactivationResult(deactivated: false, message: "The activation service returned an unreadable response. Please try again.", transfersRemaining: nil)
        }
        let remaining = payload["transfersRemaining"] as? Int
        if deactivated {
            return LicenseDeactivationResult(deactivated: true, message: payload["message"] as? String, transfersRemaining: remaining)
        }
        return LicenseDeactivationResult(deactivated: false, message: (payload["message"] as? String) ?? "This Mac could not be deactivated.", transfersRemaining: remaining)
    }
}

struct LicenseDeactivationResult {
    let deactivated: Bool
    let message: String?
    let transfersRemaining: Int?
}

enum DeviceIdentityHash {
    // SHA-256 of the trimmed hardware UUID. The raw UUID never leaves the Mac.
    static func hash(platformUUID: String) -> String? {
        let trimmed = platformUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LicenseRequest {
    static func verifyBody(licenseKey: String, machineName: String, deviceId: String) -> [String: String] {
        var body = ["licenseKey": licenseKey, "machineName": machineName]
        if let id = normalizedDeviceId(deviceId) { body["deviceId"] = id }
        return body
    }

    static func checkoutBody(machineName: String, deviceId: String) -> [String: String] {
        var body = ["machineName": machineName]
        if let id = normalizedDeviceId(deviceId) { body["deviceId"] = id }
        return body
    }

    static func deactivateBody(licenseKey: String, machineName: String, deviceId: String) -> [String: String] {
        verifyBody(licenseKey: licenseKey, machineName: machineName, deviceId: deviceId)
    }

    static func normalizedDeviceId(_ deviceId: String) -> String? {
        let id = deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return id
    }
}

struct ThemeVolumeStep: Equatable {
    let value: Double
    let title: String
}

struct ThemeVolumeSettings: Codable, Equatable {
    static let steps: [ThemeVolumeStep] = [
        .init(value: 0, title: "Off"),
        .init(value: 0.25, title: "25%"),
        .init(value: 0.5, title: "50%"),
        .init(value: 0.75, title: "75%"),
        .init(value: 1, title: "100%"),
    ]
    var levels: [String: Double] = [:]

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }

    var sanitized: Self {
        var copy = self
        for (key, value) in copy.levels { copy.levels[key] = Self.clamp(value) }
        return copy
    }

    func volume(for mode: OverlayMode) -> Double {
        guard let stored = levels[mode.rawValue] else { return 1 }
        return Self.clamp(stored)
    }

    mutating func set(_ value: Double, for mode: OverlayMode) {
        levels[mode.rawValue] = Self.clamp(value)
    }
}

struct AlertComfort: Equatable {
    var calm: Bool
    static let calmGainScale = 0.4
    var reducesMotion: Bool { calm }
    func outputGain(themeVolume: Double) -> Double {
        let volume = ThemeVolumeSettings.clamp(themeVolume)
        return ThemeVolumeSettings.clamp(calm ? volume * Self.calmGainScale : volume)
    }
}

enum AlertMotionPolicy {
    // The running app mirrors the Calm preference here before an alert is shown.
    static var reduced = false
}

final class AlertComfortPreferences {
    private let defaults: UserDefaults
    private let calmKey = "BatterySOS.calmAlerts"
    private let volumeKey = "BatterySOS.themeVolumes.v1"
    init(defaults: UserDefaults) { self.defaults = defaults }
    var calm: Bool {
        get { defaults.bool(forKey: calmKey) }
        set { defaults.set(newValue, forKey: calmKey) }
    }
    var volumes: ThemeVolumeSettings {
        get {
            guard let data = defaults.data(forKey: volumeKey),
                  let value = try? JSONDecoder().decode(ThemeVolumeSettings.self, from: data) else { return .init() }
            return value.sanitized
        }
        set { if let data = try? JSONEncoder().encode(newValue.sanitized) { defaults.set(data, forKey: volumeKey) } }
    }
    func volume(for mode: OverlayMode) -> Double { volumes.volume(for: mode) }
    func setVolume(_ value: Double, for mode: OverlayMode) {
        var copy = volumes
        copy.set(value, for: mode)
        volumes = copy
    }
}

enum FirstRunOnboarding {
    static let storageKey = "BatterySOS.onboardingCompleted.v1"
    static let title = "How Battery SOS warnings work"
    static let emergencyVersusHeadsUp = "The emergency threshold is the full-screen SOS. It defaults to 1% and can be set from 1% to 10%. Pro early heads-up is a separate earlier notice at 15%, 20%, 30%, or 40%. It does not replace the emergency threshold."
    static let snoozeOverride = "Snooze can pause the full-screen SOS for 5, 10, or 15 minutes while the battery is above 1%. At 1%, that pause is overridden and the emergency warning shows until you connect power or dismiss it."
    static let chargeReminders = "Charge reminders are reminders only. They do not start, stop, or limit charging."
    static var body: String { [emergencyVersusHeadsUp, snoozeOverride, chargeReminders].joined(separator: "\n\n") }
    static func shouldPresent(defaults: UserDefaults) -> Bool { defaults.bool(forKey: storageKey) == false }
    static func markComplete(defaults: UserDefaults) { defaults.set(true, forKey: storageKey) }
}
