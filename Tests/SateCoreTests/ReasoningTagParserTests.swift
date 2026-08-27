import Foundation
@testable import SateCore
import Testing

@Suite("ReasoningTagParser")
struct ReasoningTagParserTests {
    @Test("Extracts clean text and reasoning from single string with <think>")
    func singleStringThinkTag() {
        let input = "<think>Let me reason about this question.\n2+2=4.</think>\nThe answer is 4."
        let (text, reasoning) = ReasoningTagParser.extract(from: input)
        #expect(text == "The answer is 4.")
        #expect(reasoning == "Let me reason about this question.\n2+2=4.")
    }

    @Test("Extracts clean text and reasoning from single string with <thought>")
    func singleStringThoughtTag() {
        let input = "<thought>Analyzing user intent.</thought>Hello! How can I help you today?"
        let (text, reasoning) = ReasoningTagParser.extract(from: input)
        #expect(text == "Hello! How can I help you today?")
        #expect(reasoning == "Analyzing user intent.")
    }

    @Test("Handles plain text without think tags")
    func plainTextNoTags() {
        let input = "This is a normal assistant reply with no reasoning tags."
        let (text, reasoning) = ReasoningTagParser.extract(from: input)
        #expect(text == input)
        #expect(reasoning == nil)
    }

    @Test("Streaming chunks with tags split at byte boundaries")
    func streamingSplitAcrossChunks() {
        var parser = ReasoningTagParser()
        var text = ""
        var reasoning = ""

        let chunks = [
            "<th",
            "ink>",
            "Step 1: check ",
            "data.\n",
            "Step 2: calculate",
            ".</th",
            "ink>",
            "Here is the final ",
            "computed result.",
        ]

        for chunk in chunks {
            let (t, r) = parser.process(text: chunk)
            text += t
            reasoning += r
        }
        let (tailT, tailR) = parser.finish()
        text += tailT
        reasoning += tailR

        #expect(text == "Here is the final computed result.")
        #expect(reasoning == "Step 1: check data.\nStep 2: calculate.")
    }

    @Test("Streaming interrupted mid-thought keeps reasoning and leaves text empty")
    func streamingInterruptedMidThought() {
        var parser = ReasoningTagParser()
        var text = ""
        var reasoning = ""

        let chunks = [
            "<think>Thinking process began...",
            " but the network was lost mid-thought",
        ]

        for chunk in chunks {
            let (t, r) = parser.process(text: chunk)
            text += t
            reasoning += r
        }
        let (tailT, tailR) = parser.finish()
        text += tailT
        reasoning += tailR

        #expect(text.isEmpty)
        #expect(reasoning == "Thinking process began... but the network was lost mid-thought")
    }

    @Test("Handles false positive candidate tags like <this is not a tag>")
    func falsePositiveTagPrefix() {
        var parser = ReasoningTagParser()
        var text = ""
        var reasoning = ""

        let chunks = [
            "Comparison: 3 ",
            "< ",
            "5 is true.",
        ]

        for chunk in chunks {
            let (t, r) = parser.process(text: chunk)
            text += t
            reasoning += r
        }
        let (tailT, tailR) = parser.finish()
        text += tailT
        reasoning += tailR

        #expect(text == "Comparison: 3 < 5 is true.")
        #expect(reasoning.isEmpty)
    }

    @Test("Strip helper removes think tags cleanly")
    func stripHelper() {
        let input = "<think>Secret thoughts here.</think>Public text here."
        let stripped = ReasoningTagParser.strip(from: input)
        #expect(stripped == "Public text here.")
    }
}
