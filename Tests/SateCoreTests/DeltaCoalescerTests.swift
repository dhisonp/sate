import Foundation
@testable import SateCore
import Testing

/// A hand-advanced clock: cadence must be provable without sleeping.
private final class TestClock: CoalescerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        instant = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        instant += seconds
    }
}

@Suite("DeltaCoalescer cadence")
struct DeltaCoalescerTests {
    @Test func firstAppendFlushesImmediately() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(clock: clock)

        let flush = coalescer.append(text: "H")
        #expect(flush == DeltaCoalescer.Flush(text: "H", reasoning: ""))
        #expect(coalescer.hasPending == false)
    }

    @Test func appendsInsideTheIntervalAccumulateSilently() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(clock: clock)
        _ = coalescer.append(text: "a")

        clock.advance(0.004)
        #expect(coalescer.append(text: "b") == nil)
        clock.advance(0.004)
        #expect(coalescer.append(text: "c") == nil)
        #expect(coalescer.hasPending)
    }

    @Test func crossingMinIntervalFlushesTheAccumulation() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 0.016, clock: clock)
        _ = coalescer.append(text: "a")

        clock.advance(0.005)
        #expect(coalescer.append(text: "b") == nil)
        clock.advance(0.011)
        #expect(coalescer.append(text: "c") == DeltaCoalescer.Flush(text: "bc"))
        #expect(coalescer.hasPending == false)

        // The window restarts from the flush, not from the first append.
        clock.advance(0.005)
        #expect(coalescer.append(text: "d") == nil)
    }

    @Test func exactlyAtMinIntervalFlushes() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 0.016, clock: clock)
        _ = coalescer.append(text: "a")

        clock.advance(0.016)
        #expect(coalescer.append(text: "b") == DeltaCoalescer.Flush(text: "b"))
    }

    @Test func crossingMaxPendingCharactersFlushesInsideTheInterval() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 10, maxPendingCharacters: 8, clock: clock)
        _ = coalescer.append(text: "start")

        // The clock never moves, so only the size rule can fire.
        #expect(coalescer.append(text: "1234") == nil)
        #expect(coalescer.append(text: "5678") == DeltaCoalescer.Flush(text: "12345678"))
        #expect(coalescer.hasPending == false)
    }

    @Test func aSingleOversizedDeltaFlushesOnItsOwn() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 10, maxPendingCharacters: 8, clock: clock)
        _ = coalescer.append(text: "start")

        let big = String(repeating: "z", count: 100)
        #expect(coalescer.append(text: big) == DeltaCoalescer.Flush(text: big))
    }

    @Test func textAndReasoningAccumulateIndependently() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 10, clock: clock)
        _ = coalescer.append(text: "seed")

        #expect(coalescer.append(reasoning: "think ") == nil)
        #expect(coalescer.append(text: "out") == nil)
        #expect(coalescer.append(reasoning: "more") == nil)
        #expect(coalescer.append(text: "put") == nil)

        #expect(coalescer.drain() == DeltaCoalescer.Flush(text: "output", reasoning: "think more"))
    }

    @Test func reasoningOnlyStreamStillFlushesFirstDeltaImmediately() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(clock: clock)
        #expect(coalescer.append(reasoning: "hmm") == DeltaCoalescer.Flush(text: "", reasoning: "hmm"))
    }

    @Test func reasoningCountsTowardTheSizeThreshold() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 10, maxPendingCharacters: 6, clock: clock)
        _ = coalescer.append(text: "seed")

        #expect(coalescer.append(reasoning: "abc") == nil)
        #expect(coalescer.append(text: "xyz") == DeltaCoalescer.Flush(text: "xyz", reasoning: "abc"))
    }
}

@Suite("DeltaCoalescer drain")
struct DeltaCoalescerDrainTests {
    @Test func drainReturnsTheTailAndLeavesNothingPending() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 10, clock: clock)
        _ = coalescer.append(text: "first")
        _ = coalescer.append(text: " tail")

        #expect(coalescer.hasPending)
        #expect(coalescer.drain() == DeltaCoalescer.Flush(text: " tail"))
        #expect(coalescer.hasPending == false)
        #expect(coalescer.drain() == nil)
    }

    @Test func drainOnAnUntouchedCoalescerReturnsNil() {
        var coalescer = DeltaCoalescer(clock: TestClock())
        #expect(coalescer.drain() == nil)
        #expect(coalescer.hasPending == false)
    }

    @Test func drainRestartsTheCadenceWindow() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 0.016, clock: clock)
        _ = coalescer.append(text: "a")
        clock.advance(0.005)
        _ = coalescer.append(text: "b")
        clock.advance(0.100)
        _ = coalescer.drain()

        // Without the drain resetting `lastFlush`, this would flush immediately
        // and defeat the coalescing right after a trailing-edge tick.
        #expect(coalescer.append(text: "c") == nil)
    }

    @Test func emptyAppendsAreNoOps() {
        var coalescer = DeltaCoalescer(clock: TestClock())
        #expect(coalescer.append() == nil)
        #expect(coalescer.append(text: "", reasoning: "") == nil)
        #expect(coalescer.hasPending == false)
        // The first *real* delta is still treated as the first one.
        #expect(coalescer.append(text: "x") == DeltaCoalescer.Flush(text: "x"))
    }

    @Test func flushIsEmptyReportsCorrectly() {
        #expect(DeltaCoalescer.Flush().isEmpty)
        #expect(DeltaCoalescer.Flush(text: "x").isEmpty == false)
        #expect(DeltaCoalescer.Flush(reasoning: "x").isEmpty == false)
    }

    @Test func aHighRateStreamProducesFarFewerFlushesThanDeltas() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 0.016, maxPendingCharacters: 256, clock: clock)

        // 300 deltas/second for one second, three characters each.
        var flushes = 0
        for _ in 0 ..< 300 {
            if coalescer.append(text: "abc") != nil {
                flushes += 1
            }
            clock.advance(1.0 / 300.0)
        }
        if coalescer.drain() != nil {
            flushes += 1
        }

        #expect(flushes <= 64, "expected roughly one flush per frame, got \(flushes)")
        #expect(flushes >= 2)
    }

    @Test func noCharacterIsLostAcrossAWholeStream() {
        let clock = TestClock()
        var coalescer = DeltaCoalescer(minInterval: 0.016, maxPendingCharacters: 32, clock: clock)

        var expected = ""
        var received = ""
        for index in 0 ..< 500 {
            let delta = "token\(index) "
            expected += delta
            if let flush = coalescer.append(text: delta) {
                received += flush.text
            }
            clock.advance(0.003)
        }
        if let tail = coalescer.drain() {
            received += tail.text
        }

        #expect(received == expected)
    }
}
