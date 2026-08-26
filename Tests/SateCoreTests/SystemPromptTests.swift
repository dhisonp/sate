import Foundation
@testable import SateCore
import Testing

@Suite("SystemPrompt")
struct SystemPromptTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    @Test("The date token is replaced with the supplied day")
    func substitutesDate() {
        let date = Date(timeIntervalSince1970: 1_774_483_200) // 2026-03-25 UTC
        let resolved = SystemPrompt.resolve(
            "Today is \(SystemPrompt.currentDateToken).",
            date: date, locale: english, timeZone: utc
        )

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

    @Test("The default general-assistant prompt carries the token and resolves cleanly")
    func defaultPromptResolves() {
        #expect(SystemPrompt.generalAssistant.contains(SystemPrompt.currentDateToken))
        #expect(SystemPrompt.generalAssistant.contains("general assistant"))
        #expect(SystemPrompt.generalAssistant.contains("direct answer"))
        #expect(SystemPrompt.generalAssistant.contains("coding"))

        let resolved = SystemPrompt.resolve(
            SystemPrompt.generalAssistant,
            date: Date(timeIntervalSince1970: 1_774_483_200),
            locale: english, timeZone: utc
        )
        #expect(!resolved.contains(SystemPrompt.currentDateToken))
        #expect(!resolved.contains("{{"))
    }

    @Test("Fresh settings default to the general-assistant prompts")
    func settingsDefaultToGeneralAssistant() {
        #expect(SateSettings().systemPrompt == SystemPrompt.generalAssistant)
        #expect(SateSettings().systemPromptWithSearch == SystemPrompt.generalAssistantWithSearch)
    }

    @Test("The search-enabled prompt carries the token, search instructions, citations, and resolves cleanly")
    func searchPromptResolves() {
        #expect(SystemPrompt.generalAssistantWithSearch.contains(SystemPrompt.currentDateToken))
        #expect(SystemPrompt.generalAssistantWithSearch.contains("web search tool"))
        #expect(SystemPrompt.generalAssistantWithSearch.contains("[n]"))
        #expect(SystemPrompt.generalAssistantWithSearch.contains("direct answer"))

        let resolved = SystemPrompt.resolve(
            SystemPrompt.generalAssistantWithSearch,
            date: Date(timeIntervalSince1970: 1_774_483_200),
            locale: english, timeZone: utc
        )
        #expect(!resolved.contains(SystemPrompt.currentDateToken))
        #expect(!resolved.contains("{{"))
    }

    @Test("Research assistant aliases match general assistant prompts for backwards compatibility")
    func compatibilityAliasesMatch() {
        #expect(SystemPrompt.researchAssistant == SystemPrompt.generalAssistant)
        #expect(SystemPrompt.researchAssistantWithSearch == SystemPrompt.generalAssistantWithSearch)
    }
}
