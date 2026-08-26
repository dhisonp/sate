import Foundation
import Testing

@testable import SateCore

@Suite("SystemPrompt")
struct SystemPromptTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    @Test("The date token is replaced with the supplied day")
    func substitutesDate() {
        let date = Date(timeIntervalSince1970: 1_774_483_200)  // 2026-03-25 UTC
        let resolved = SystemPrompt.resolve(
            "Today is \(SystemPrompt.currentDateToken).",
            date: date, locale: english, timeZone: utc)

        #expect(!resolved.contains(SystemPrompt.currentDateToken))
        #expect(resolved.contains("2026"))
        #expect(resolved.contains("March"))
    }

    @Test("A prompt without the token is returned unchanged")
    func leavesPlainPromptAlone() {
        let plain = "You are a terse assistant."
        #expect(SystemPrompt.resolve(plain) == plain)
    }

    @Test("An empty prompt stays empty so no system message is sent")
    func emptyStaysEmpty() {
        // ContextBuilder treats "" as "no system prompt"; resolution must not
        // turn it into a non-empty string and quietly add a system turn.
        #expect(SystemPrompt.resolve("").isEmpty)
    }

    @Test("The default prompt carries the token and resolves cleanly")
    func defaultPromptResolves() {
        #expect(SystemPrompt.researchAssistant.contains(SystemPrompt.currentDateToken))

        let resolved = SystemPrompt.resolve(
            SystemPrompt.researchAssistant,
            date: Date(timeIntervalSince1970: 1_774_483_200),
            locale: english, timeZone: utc)
        #expect(!resolved.contains(SystemPrompt.currentDateToken))
        #expect(!resolved.contains("{{"))
    }

    @Test("Fresh settings default to the research-assistant prompt")
    func settingsDefaultToResearchAssistant() {
        #expect(SateSettings().systemPrompt == SystemPrompt.researchAssistant)
    }

    @Test("A stored prompt survives a settings round-trip")
    func customPromptRoundTrips() throws {
        // The default must not overwrite a prompt the operator actually chose.
        var settings = SateSettings()
        settings.systemPrompt = "Be extremely terse."
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SateSettings.self, from: data)
        #expect(decoded.systemPrompt == "Be extremely terse.")
    }
}
