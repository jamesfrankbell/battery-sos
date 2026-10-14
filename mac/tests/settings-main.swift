import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard condition() else { fatalError("line \(line): \(message)") }
}
func data(_ text: String) -> Data { Data(text.utf8) }

@main enum SettingsTests {
    static func main() {
        if CommandLine.arguments.count == 3 {
            let stored = ThemePreferences(defaults: UserDefaults(suiteName: CommandLine.arguments[1])!)
            expect(stored.selectedMode(hasProAccess: true).rawValue == CommandLine.arguments[2], "fresh process restores theme")
            return
        }
        let suite = "BatterySOS.IsolatedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ThemePreferences(defaults: defaults)
        expect(settings.selectedMode(hasProAccess: false) == .defaultWarning, "fresh install uses free default")
        for mode in OverlayMode.allCases {
            expect(settings.select(mode, hasProAccess: true), "licensed selection accepted")
            let reopened = ThemePreferences(defaults: UserDefaults(suiteName: suite)!)
            expect(reopened.selectedMode(hasProAccess: true) == mode, "theme restored from preferences")
            expect(reopened.selectedMode(hasProAccess: false) == .defaultWarning, "locked launch uses free mode")
        }
        expect(!settings.select(.vitalsMonitor, hasProAccess: false), "unauthorized premium selection rejected")
        expect(settings.selectedMode(hasProAccess: true) == .matrixBinary, "rejected selection preserves saved theme")
        defaults.synchronize()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [suite, OverlayMode.matrixBinary.rawValue]
        try! child.run()
        child.waitUntilExit()
        expect(child.terminationStatus == 0, "theme persists across a fresh process")
        defaults.set("Unknown Theme", forKey: "BatterySOS.overlayMode")
        expect(settings.selectedMode(hasProAccess: true) == .defaultWarning, "unknown stored theme falls back")
        print("PASS theme persistence, gating and invalid preference fallback")

        for mode in OverlayMode.allCases {
            expect(mode.menuTitle(hasProAccess: false).contains(mode.isPremium ? "(Pro)" : "(Free)"), "free/pro labels match actual access")
            if mode.isPremium { expect(mode.menuTitle(hasProAccess: true) == mode.rawValue, "unlocked modes lose locked label") }
        }
        expect(OverlayMode.vitalsMonitor.menuTitle(hasProAccess: false) == "Vitals Monitor (Pro)", "Vitals consistently marked")
        print("PASS all six theme labels")

        let success = BillingClientResponse.activation(data: data("{\"valid\":true,\"normalizedKey\":\"BSOS-FIXTURE\"}"), statusCode: 200, error: nil)
        expect(success.valid && success.normalizedKey == "BSOS-FIXTURE", "successful activation accepted")
        for text in ["{\"valid\":true}", "{\"valid\":true,\"normalizedKey\":\" \"}", "invalid", "{}"] {
            let result = BillingClientResponse.activation(data: data(text), statusCode: 200, error: nil)
            expect(!result.valid && result.normalizedKey == nil, "malformed success never unlocks Pro")
        }
        let rejection = BillingClientResponse.activation(data: data("{\"valid\":false,\"message\":\"This key is already activated on another machine.\"}"), statusCode: 200, error: nil)
        expect(!rejection.valid && rejection.message!.contains("another machine"), "binding error remains readable")
        let serviceFailure = BillingClientResponse.activation(data: data("{\"valid\":true,\"normalizedKey\":\"BSOS-FIXTURE\"}"), statusCode: 503, error: nil)
        expect(!serviceFailure.valid && serviceFailure.message!.contains("temporarily"), "HTTP failure cannot unlock Pro")
        let offline = BillingClientResponse.activation(data: nil, statusCode: nil, error: NSError(domain: "isolated", code: -1009))
        expect(!offline.valid && offline.message!.contains("internet connection"), "offline explanation is actionable")
        print("PASS activation success, malformed response, HTTP rejection and offline errors")

        switch BillingClientResponse.checkout(data: data("{\"url\":\"https://checkout.stripe.com/fixture\"}"), statusCode: 200, error: nil) {
        case .success(let url): expect(url.scheme == "https", "secure checkout accepted")
        case .failure: fatalError("valid checkout rejected")
        }
        for text in ["{\"url\":\"http://example.invalid/\"}", "{\"url\":\"file:///tmp/fixture\"}", "{\"url\":\"relative\"}", "invalid"] {
            switch BillingClientResponse.checkout(data: data(text), statusCode: 200, error: nil) {
            case .success: fatalError("invalid checkout accepted")
            case .failure: break
            }
        }
        switch BillingClientResponse.checkout(data: data("{\"error\":\"Fixture service unavailable\"}"), statusCode: 503, error: nil) {
        case .failure(let error): expect(error.message.contains("temporarily"), "checkout service error explained")
        case .success: fatalError("failed HTTP checkout accepted")
        }
        print("PASS checkout URL and HTTP failure handling")
        print("4 settings/response test groups passed")
    }
}
