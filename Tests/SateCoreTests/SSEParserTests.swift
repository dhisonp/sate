import Foundation
@testable import SateCore
import Testing

// MARK: - Helpers

private func fixtureBytes(_ name: String) throws -> [UInt8] {
    if let url = Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures") {
        return try Array(Data(contentsOf: url))
    }
    // Fallback for toolchains/IDEs that do not stage the resource bundle.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("\(name).sse")
    return try Array(Data(contentsOf: url))
}

/// Feeds `bytes` in fixed-size chunks; returns the events plus whether a
/// trailing unterminated event was discarded.
private func parse(
    _ bytes: [UInt8],
    chunkSize: Int = Int.max,
    maxEventBytes: Int = 1 << 20
) throws -> (events: [SSEEvent], discardedTail: Bool) {
    var parser = SSEParser(maxEventBytes: maxEventBytes)
    var events: [SSEEvent] = []
    var index = 0
    while index < bytes.count {
        let end = chunkSize == Int.max ? bytes.count : min(index + chunkSize, bytes.count)
        events += try parser.consume(bytes[index ..< end])
        index = end
    }
    return (events, parser.finish())
}

private func parse(_ text: String, chunkSize: Int = Int.max) throws -> [SSEEvent] {
    try parse(Array(text.utf8), chunkSize: chunkSize).events
}

// MARK: - Fixtures

@Suite("SSEParser fixtures")
struct SSEParserFixtureTests {
    @Test func openAIBasicStreamFrames() throws {
        let (events, discarded) = try parse(fixtureBytes("openai_basic"))

        #expect(events.count == 6)
        #expect(discarded == false)
        #expect(events.allSatisfy { $0.name == nil && $0.id == nil })
        #expect(events[1].data.contains(#""content":"Hello""#))
        #expect(events[3].data.contains(#""finish_reason":"stop""#))
        // The usage chunk carries empty `choices`; framing must not care.
        #expect(events[4].data.contains(#""choices":[]"#))
        #expect(events[4].data.contains(#""total_tokens":23"#))
        #expect(events[5].isTerminator)
        #expect(events.dropLast().allSatisfy { !$0.isTerminator })
    }

    @Test func everyDataPayloadIsValidJSONExceptTerminator() throws {
        let (events, _) = try parse(fixtureBytes("openai_basic"))
        for event in events.dropLast() {
            #expect(throws: Never.self) {
                _ = try JSONSerialization.jsonObject(with: Data(event.data.utf8))
            }
        }
    }

    @Test func compatStreamCarriesReasoningAndMultibyteContent() throws {
        let (events, discarded) = try parse(fixtureBytes("anthropic_via_compat"))

        #expect(events.count == 7)
        #expect(discarded == false)
        #expect(events[1].data.contains("reasoning_content"))
        #expect(events[2].data.contains("anthropic/claude-opus-5"))
        #expect(events[3].data.contains("你好"))
        #expect(events[3].data.contains("🚀"))
        #expect(events.last?.isTerminator == true)
    }

    @Test func crlfKeepalivesAndMultiLineDataFixture() throws {
        let (events, discarded) = try parse(fixtureBytes("crlf_keepalive"))

        #expect(discarded == false)
        // Three comment lines produced no events of their own.
        #expect(events.count == 4)

        let multiLine = events[1]
        #expect(multiLine.name == "chunk")
        #expect(multiLine.id == "42")
        #expect(multiLine.data.contains("\n"))
        // Only ONE space is stripped, so the continuation line keeps its indent
        // and the two `data:` lines rejoin into valid JSON.
        #expect(multiLine.data.contains("\n \"choices\""))
        let decoded = try JSONSerialization.jsonObject(with: Data(multiLine.data.utf8)) as? [String: Any]
        #expect(decoded?["id"] as? String == "chatcmpl-crlf-3312")

        #expect(events[2].data.contains(#""finish_reason":"stop""#))
        #expect(events[3].isTerminator)
    }

    @Test func midstreamErrorPayloadIsJustAnotherEvent() throws {
        let (events, discarded) = try parse(fixtureBytes("error_midstream"))

        #expect(events.count == 3)
        #expect(discarded == false)
        #expect(events[2].data.contains("overloaded_error"))
        // No `[DONE]` ever arrives on this path.
        #expect(events.contains { $0.isTerminator } == false)
    }

    @Test func truncatedTailIsDiscardedAndReported() throws {
        let (events, discarded) = try parse(fixtureBytes("truncated"))

        #expect(events.count == 2)
        #expect(discarded == true)
        #expect(events[1].data.contains("The answer is"))
    }

    @Test func finishIsCleanWhenTheStreamEndedOnABlankLine() throws {
        var parser = SSEParser()
        _ = try parser.consume(Array("data: x\n\n".utf8))
        #expect(parser.finish() == false)
    }

    @Test func finishResetsStateForReuse() throws {
        var parser = SSEParser()
        _ = try parser.consume(Array("data: partial".utf8))
        #expect(parser.finish() == true)
        #expect(parser.finish() == false)

        let events = try parser.consume(Array("data: fresh\n\n".utf8))
        #expect(events == [SSEEvent(data: "fresh")])
    }
}

// MARK: - Framing rules

@Suite("SSEParser framing")
struct SSEParserFramingTests {
    @Test func loneCarriageReturnTerminatesALine() throws {
        let events = try parse("data: a\rdata: b\r\r")
        #expect(events == [SSEEvent(data: "a\nb")])
    }

    @Test func mixedTerminatorsProduceIdenticalEvents() throws {
        let lf = try parse("data: a\n\ndata: b\n\n")
        let crlf = try parse("data: a\r\n\r\ndata: b\r\n\r\n")
        let cr = try parse("data: a\r\rdata: b\r\r")
        #expect(lf == crlf)
        #expect(lf == cr)
        #expect(lf == [SSEEvent(data: "a"), SSEEvent(data: "b")])
    }

    @Test func crlfSplitAcrossChunkBoundaryIsNotTwoTerminators() throws {
        var parser = SSEParser()
        var events = try parser.consume(Array("data: hi\r".utf8))
        events += try parser.consume(Array("\ndata: there\r\n\r\n".utf8))

        // Mis-handling the split pair would dispatch after "hi" and yield two events.
        #expect(events == [SSEEvent(data: "hi\nthere")])
        #expect(parser.finish() == false)
    }

    @Test func chunkBoundaryBetweenCRAndBlankLineStillDispatchesOnce() throws {
        var parser = SSEParser()
        var events = try parser.consume(Array("data: hi\r\n\r".utf8))
        events += try parser.consume(Array("\n".utf8))
        #expect(events == [SSEEvent(data: "hi")])
    }

    @Test func eventWithoutDataFieldIsNotDispatched() throws {
        let events = try parse("id: 7\nevent: ping\nretry: 500\n\ndata: real\n\n")
        // The id/event-only block is swallowed, and its fields must not leak
        // into the next event.
        #expect(events == [SSEEvent(data: "real")])
    }

    @Test func emptyDataValueStillDispatches() throws {
        #expect(try parse("data:\n\n") == [SSEEvent(data: "")])
        #expect(try parse("data: \n\n") == [SSEEvent(data: "")])
        // A field line with no colon is a field with an empty value.
        #expect(try parse("data\n\n") == [SSEEvent(data: "")])
    }

    @Test func exactlyOneLeadingSpaceIsStripped() throws {
        #expect(try parse("data:x\n\n") == [SSEEvent(data: "x")])
        #expect(try parse("data: x\n\n") == [SSEEvent(data: "x")])
        #expect(try parse("data:  x\n\n") == [SSEEvent(data: " x")])
        #expect(try parse("data:\tx\n\n") == [SSEEvent(data: "\tx")])
    }

    @Test func spaceStrippingIsByteWiseNotGraphemeWise() throws {
        // " " + U+FE0F is a single Character, so a grapheme-based check would
        // fail to see the leading space and leave it in the payload.
        let bytes = Array("data: ".utf8) + [0xEF, 0xB8, 0x8F] + Array("\n\n".utf8)
        let (events, _) = try parse(bytes)
        #expect(events == [SSEEvent(data: "\u{FE0F}")])
    }

    @Test func commentsAreIgnored() throws {
        let events = try parse(": keepalive\n:\n:data: not-real\ndata: real\n\n")
        #expect(events == [SSEEvent(data: "real")])
    }

    @Test func unknownFieldsAndRetryAreIgnored() throws {
        let events = try parse("retry: 3000\nfoo: bar\nbaz\ndata: x\n\n")
        #expect(events == [SSEEvent(data: "x")])
    }

    @Test func eventNameAndIDAreCarriedAndResetPerEvent() throws {
        let events = try parse("event: delta\nid: 1\ndata: a\n\ndata: b\n\n")
        #expect(events[0] == SSEEvent(name: "delta", data: "a", id: "1"))
        // Not sticky: this client never resumes with Last-Event-ID.
        #expect(events[1] == SSEEvent(name: nil, data: "b", id: nil))
    }

    @Test func multipleDataLinesJoinWithNewline() throws {
        let events = try parse("data: one\ndata: two\ndata:\ndata: four\n\n")
        #expect(events == [SSEEvent(data: "one\ntwo\n\nfour")])
    }

    @Test func consecutiveBlankLinesDoNotEmitEmptyEvents() throws {
        let events = try parse("\n\n\ndata: x\n\n\n\n")
        #expect(events == [SSEEvent(data: "x")])
    }
}

// MARK: - BOM

@Suite("SSEParser BOM handling")
struct SSEParserBOMTests {
    private let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    @Test func bomAtStreamStartIsStripped() throws {
        let bytes = bom + Array("data: x\n\n".utf8)
        let (events, _) = try parse(bytes)
        #expect(events == [SSEEvent(data: "x")])
    }

    @Test func bomSplitAcrossThreeChunksIsStillStripped() throws {
        let bytes = bom + Array("data: x\n\n".utf8)
        let (events, _) = try parse(bytes, chunkSize: 1)
        #expect(events == [SSEEvent(data: "x")])
    }

    @Test func bomLaterInStreamIsContent() throws {
        let bytes = Array("data: a\n\ndata: ".utf8) + bom + Array("b\n\n".utf8)
        let (events, _) = try parse(bytes)
        #expect(events == [SSEEvent(data: "a"), SSEEvent(data: "\u{FEFF}b")])
    }

    @Test func partialBOMPrefixIsReplayedAsContent() throws {
        // EF BB is two thirds of a BOM, so both bytes are speculatively
        // withheld — and both are real content that must come back. Dropping
        // them would leave a clean "data: x" line and wrongly emit an event.
        let bytes: [UInt8] = [0xEF, 0xBB] + Array("data: x\n\n".utf8)

        for chunkSize in [Int.max, 1, 2, 3] {
            let (events, _) = try parse(bytes, chunkSize: chunkSize)
            #expect(events.isEmpty, "chunk size \(chunkSize)")
        }
    }

    @Test func aNonBOMThreeByteScalarAtStreamStartIsNotStripped() throws {
        // U+FE0F is EF B8 8F: it shares only the BOM's first byte.
        let bytes: [UInt8] = [0xEF, 0xB8, 0x8F] + Array("\ndata: x\n\n".utf8)
        let (events, _) = try parse(bytes)
        #expect(events == [SSEEvent(data: "x")])
        let (byteAtATime, _) = try parse(bytes, chunkSize: 1)
        #expect(byteAtATime == events)
    }

    @Test func aTruncatedBOMIsTheWholeStream() throws {
        let (events, discarded) = try parse([0xEF, 0xBB])
        #expect(events.isEmpty)
        #expect(discarded == true)
    }
}

// MARK: - Chunking fuzz

private let chunkingFixtures = ["openai_basic", "anthropic_via_compat", "crlf_keepalive", "error_midstream", "truncated"]

@Suite("SSEParser chunk-boundary fuzz")
struct SSEParserChunkingTests {
    @Test(arguments: chunkingFixtures)
    func fixedChunkSizesParseIdentically(_ name: String) throws {
        let bytes = try fixtureBytes(name)
        let baseline = try parse(bytes)

        for size in [1, 2, 3, 5, 7, 13, 64, 4096] {
            let result = try parse(bytes, chunkSize: size)
            #expect(result.events == baseline.events, "chunk size \(size) diverged for \(name)")
            #expect(result.discardedTail == baseline.discardedTail, "chunk size \(size) diverged for \(name)")
        }
    }

    @Test(arguments: chunkingFixtures)
    func deterministicRandomChunkingParsesIdentically(_ name: String) throws {
        let bytes = try fixtureBytes(name)
        let baseline = try parse(bytes)

        // Seeded LCG so a failure is reproducible.
        for seed in [UInt64(1), 0x2545_F491_4F6C_DD1D, 0xDEAD_BEEF_CAFE_F00D] {
            var random = LCG(seed: seed)
            var parser = SSEParser()
            var events: [SSEEvent] = []
            var index = 0
            while index < bytes.count {
                let size = Int(random.next() % 37) + 1
                let end = min(index + size, bytes.count)
                events += try parser.consume(bytes[index ..< end])
                index = end
            }
            #expect(events == baseline.events, "seed \(seed) diverged for \(name)")
            #expect(parser.finish() == baseline.discardedTail, "seed \(seed) diverged for \(name)")
        }
    }

    @Test func multibyteScalarsSurviveByteAtATimeFeeding() throws {
        let payload = "data: 你好、世界 🚀🇯🇵 é\ndata: 漢字テスト\n\n"
        let events = try parse(payload, chunkSize: 1)
        #expect(events == [SSEEvent(data: "你好、世界 🚀🇯🇵 é\n漢字テスト")])
    }

    @Test func invalidUTF8BecomesReplacementCharacterInsteadOfThrowing() throws {
        // A truncated 3-byte sequence must not kill a live generation.
        let bytes = Array("data: a".utf8) + [0xE4, 0xBD] + Array("b\n\n".utf8)
        let (events, _) = try parse(bytes)
        #expect(events.count == 1)
        #expect(events[0].data.contains("\u{FFFD}"))
    }
}

private struct LCG {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 17
    }
}

// MARK: - Limits

@Suite("SSEParser limits")
struct SSEParserLimitTests {
    @Test func oversizedEventThrowsProtocolError() throws {
        var parser = SSEParser(maxEventBytes: 64)
        let payload = Array(("data: " + String(repeating: "x", count: 200) + "\n\n").utf8)

        do {
            _ = try parser.consume(payload)
            Issue.record("expected a protocolError")
        } catch let error as GatewayError {
            guard case let .protocolError(message) = error else {
                Issue.record("expected protocolError, got \(error)")
                return
            }
            #expect(message.contains("64"))
        }
    }

    @Test func theCapIsPerEventNotPerStream() throws {
        var parser = SSEParser(maxEventBytes: 64)
        var events: [SSEEvent] = []
        for _ in 0 ..< 50 {
            events += try parser.consume(Array("data: small\n\n".utf8))
        }
        #expect(events.count == 50)
    }

    @Test func oversizeIsDetectedEvenWhenSplitAcrossChunks() throws {
        var parser = SSEParser(maxEventBytes: 32)
        let payload = Array(("data: " + String(repeating: "y", count: 100) + "\n\n").utf8)

        #expect(throws: GatewayError.self) {
            for byte in payload {
                _ = try parser.consume(CollectionOfOne(byte))
            }
        }
    }

    @Test func manyDataLinesInOneEventCountTowardTheCap() throws {
        var parser = SSEParser(maxEventBytes: 40)
        #expect(throws: GatewayError.self) {
            _ = try parser.consume(Array(String(repeating: "data: ab\n", count: 20).utf8))
        }
    }
}
