import Foundation
@testable import SateCore
import Testing

@Suite("TokenEstimator")
struct TokenEstimatorTests {
    private let model = "anthropic/claude-opus-5"

    @Test("Uncalibrated models use the default ratio")
    func defaultRatio() {
        let estimator = TokenEstimator()
        #expect(estimator.charactersPerToken(for: model) == 3.6)
        // 360 / 3.6 == 100 exactly.
        #expect(estimator.estimate(characters: 360, model: model) == 100)
        // Partial tokens round up: a fragment still costs a token.
        #expect(estimator.estimate(characters: 361, model: model) == 101)
        #expect(estimator.estimate(characters: 0, model: model) == 0)
    }

    @Test("Estimation is deterministic")
    func deterministic() {
        let estimator = TokenEstimator()
        let messages = [Message.user(String(repeating: "a", count: 720))]
        let first = estimator.estimate(messages, systemPrompt: "system", model: model)
        let second = estimator.estimate(messages, systemPrompt: "system", model: model)
        #expect(first == second)
    }

    @Test("Per-message and system framing overhead is counted")
    func framingOverhead() {
        let estimator = TokenEstimator()
        let messages = [
            Message.user(String(repeating: "a", count: 360)),
            Message(role: .assistant, content: [.text(String(repeating: "b", count: 360))]),
        ]
        // 2 messages * (100 + 4) plus a 36-char system prompt (10 + 4).
        let expected = 2 * (100 + TokenEstimator.perMessageOverheadTokens)
            + 10 + TokenEstimator.perMessageOverheadTokens
        #expect(estimator.estimate(messages, systemPrompt: String(repeating: "s", count: 36), model: model) == expected)
    }

    @Test("Reasoning text is never counted, because it is never replayed")
    func reasoningNotCounted() {
        let estimator = TokenEstimator()
        var message = Message(role: .assistant, content: [.text("hello")])
        let withoutReasoning = estimator.estimate([message], systemPrompt: nil, model: model)
        message.reasoning = String(repeating: "r", count: 10000)
        #expect(estimator.estimate([message], systemPrompt: nil, model: model) == withoutReasoning)
    }

    @Test("Calibration moves the ratio toward the observed value")
    func calibrationMovesTowardObservation() {
        var estimator = TokenEstimator()
        // 2000 chars for 1000 tokens => 2.0 chars/token (dense code / CJK).
        estimator.calibrate(model: model, characters: 2000, promptTokens: 1000)
        let afterOne = estimator.charactersPerToken(for: model)
        #expect(afterOne < 3.6)
        #expect(afterOne > 2.0)
        #expect(abs(afterOne - (3.6 * 0.7 + 2.0 * 0.3)) < 0.000_001)

        // Repeated identical samples converge on the observation.
        for _ in 0 ..< 20 {
            estimator.calibrate(model: model, characters: 2000, promptTokens: 1000)
        }
        #expect(abs(estimator.charactersPerToken(for: model) - 2.0) < 0.01)
    }

    @Test("Calibration is per model")
    func calibrationIsPerModel() {
        var estimator = TokenEstimator()
        estimator.calibrate(model: model, characters: 2000, promptTokens: 1000)
        #expect(estimator.charactersPerToken(for: "openai/gpt-5.2") == 3.6)
        #expect(estimator.charactersPerToken(for: model) != 3.6)
    }

    @Test("Absurd calibration samples are rejected")
    func rejectsAbsurdSamples() {
        var estimator = TokenEstimator()
        let baseline = estimator.charactersPerToken(for: model)

        estimator.calibrate(model: model, characters: 1000, promptTokens: 0)
        estimator.calibrate(model: model, characters: 1000, promptTokens: -5)
        estimator.calibrate(model: model, characters: 0, promptTokens: 100)
        // 100 chars / 200 tokens = 0.5 — below any real tokenizer.
        estimator.calibrate(model: model, characters: 100, promptTokens: 200)
        // 100_000 chars / 100 tokens = 1000 — a cache hit or a mismatched request.
        estimator.calibrate(model: model, characters: 100_000, promptTokens: 100)

        #expect(estimator.charactersPerToken(for: model) == baseline)
        #expect(estimator.calibratedRatios.isEmpty)
    }

    @Test("A single bad sample cannot poison an established ratio")
    func badSampleDoesNotPoison() {
        var estimator = TokenEstimator()
        for _ in 0 ..< 20 {
            estimator.calibrate(model: model, characters: 2000, promptTokens: 1000)
        }
        let established = estimator.charactersPerToken(for: model)
        estimator.calibrate(model: model, characters: 500_000, promptTokens: 10)
        #expect(estimator.charactersPerToken(for: model) == established)
    }

    @Test("Calibrated ratios survive a Codable round trip")
    func codableRoundTrip() throws {
        var estimator = TokenEstimator(defaultCharactersPerToken: 4.0)
        estimator.calibrate(model: model, characters: 2000, promptTokens: 1000)
        let data = try JSONEncoder().encode(estimator)
        let decoded = try JSONDecoder().decode(TokenEstimator.self, from: data)
        #expect(decoded.defaultCharactersPerToken == 4.0)
        #expect(decoded.charactersPerToken(for: model) == estimator.charactersPerToken(for: model))
    }

    @Test("Decoding tolerates a blob missing every key")
    func decodesEmptyBlob() throws {
        let decoded = try JSONDecoder().decode(TokenEstimator.self, from: Data("{}".utf8))
        #expect(decoded.defaultCharactersPerToken == 3.6)
        #expect(decoded.calibratedRatios.isEmpty)
    }
}
