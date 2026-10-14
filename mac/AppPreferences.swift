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
}
