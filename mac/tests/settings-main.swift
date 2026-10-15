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

        expect(DeviceIdentityHash.hash(platformUUID: "  ") == nil, "blank hardware id is not hashed")
        expect(DeviceIdentityHash.hash(platformUUID: "TEST-PLATFORM-UUID") == "c3ec442e7419c89b9765802c8b97ccc01d450e6697707a907fd0517f1ec31e9d", "stable hardware hash")
        let device = DeviceIdentityHash.hash(platformUUID: "TEST-PLATFORM-UUID")!
        let verify = LicenseRequest.verifyBody(licenseKey: "BSOS-1", machineName: "Fixture Mac", deviceId: device)
        expect(verify["deviceId"] == device && verify["machineName"] == "Fixture Mac", "activation sends the hash and the legacy name")
        expect(LicenseRequest.verifyBody(licenseKey: "BSOS-1", machineName: "Fixture Mac", deviceId: "IOPlatformUUID-raw")["deviceId"] == nil, "raw hardware id is not sent")
        expect(LicenseRequest.checkoutBody(machineName: "Fixture Mac", deviceId: "nope")["deviceId"] == nil, "checkout omits an invalid device id")
        let moved = LicenseRequest.deactivateBody(licenseKey: "BSOS-1", machineName: "Fixture Mac", deviceId: device)
        expect(moved["licenseKey"] == "BSOS-1" && moved["deviceId"] == device, "deactivation identifies this Mac")
        print("PASS hardware id hash and activation payload")

        let deactivated = BillingClientResponse.deactivation(data: data("{\"deactivated\":true,\"transfersRemaining\":2,\"message\":\"This Mac is deactivated.\"}"), statusCode: 200, error: nil)
        expect(deactivated.deactivated && deactivated.transfersRemaining == 2, "deactivation accepted")
        let refused = BillingClientResponse.deactivation(data: data("{\"deactivated\":false,\"message\":\"This Mac is not the one activated for this license.\"}"), statusCode: 200, error: nil)
        expect(!refused.deactivated && refused.message!.contains("not the one"), "wrong Mac stays activated")
        let limited = BillingClientResponse.deactivation(data: data("{\"error\":\"Too many recovery attempts. Please wait and try again.\"}"), statusCode: 429, error: nil)
        expect(!limited.deactivated && limited.transfersRemaining == nil, "failed deactivation does not unlock a transfer")
        print("PASS deactivation response parsing")

        func near(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.000001 }
        expect(!AlertComfort(calm: false).reducesMotion && near(AlertComfort(calm: false).outputGain(themeVolume: 0.5), 0.5), "standard presentation keeps theme volume")
        expect(AlertComfort(calm: true).reducesMotion && near(AlertComfort(calm: true).outputGain(themeVolume: 1), 0.4), "calm reduces motion and softens full volume")
        expect(near(AlertComfort(calm: true).outputGain(themeVolume: 0.5), 0.2), "calm scales the selected theme volume")
        expect(near(AlertComfort(calm: true).outputGain(themeVolume: .nan), 0.4), "invalid volume does not silence calm")
        let comfort = AlertComfortPreferences(defaults: defaults)
        expect(!comfort.calm && near(comfort.volume(for: .matrixBinary), 1), "calm off and full volume by default")
        comfort.calm = true
        comfort.setVolume(0.25, for: .reactorMeltdown)
        comfort.setVolume(4, for: .defaultWarning)
        let reloaded = AlertComfortPreferences(defaults: UserDefaults(suiteName: suite)!)
        expect(reloaded.calm && near(reloaded.volume(for: .reactorMeltdown), 0.25) && near(reloaded.volume(for: .defaultWarning), 1), "calm and per-theme volume persist and clamp")
        expect(near(reloaded.volume(for: .matrixBinary), 1), "unset themes stay at full volume")
        defaults.set(Data("broken".utf8), forKey: "BatterySOS.themeVolumes.v1")
        expect(near(comfort.volume(for: .matrixBinary), 1), "corrupt theme volume falls back")
        print("PASS calm presentation and per-theme volume")

        expect(FirstRunOnboarding.shouldPresent(defaults: defaults), "first launch shows onboarding")
        expect(FirstRunOnboarding.cards.count == 3, "three short welcome cards")
        expect(FirstRunOnboarding.cards.allSatisfy { !$0.headline.isEmpty && $0.line.count < 140 }, "each card is a headline and one short line")
        expect(FirstRunOnboarding.cards[0].line.contains("1%") && FirstRunOnboarding.cards[0].headline.contains("%"), "big alert defaults to 1%")
        expect(FirstRunOnboarding.cards[1].line.contains("15%") && FirstRunOnboarding.cards[1].line.contains("40%"), "Pro heads-up is 15 to 40")
        expect(FirstRunOnboarding.cards[2].line.contains("1%") && FirstRunOnboarding.cards[2].line.contains("breaks through"), "1% breaks snooze")
        expect(FirstRunOnboarding.cards[2].line.contains("only remind you"), "charge reminders are reminders only")
        expect(FirstRunOnboarding.menuBarNote.contains("menu bar") && FirstRunOnboarding.menuBarNote.contains("notch"), "welcome says where the menu bar icon lives")
        FirstRunOnboarding.markComplete(defaults: defaults)
        expect(!FirstRunOnboarding.shouldPresent(defaults: UserDefaults(suiteName: suite)!), "onboarding is shown once")
        print("PASS first-run onboarding")
        print("8 settings/response test groups passed")
    }
}
