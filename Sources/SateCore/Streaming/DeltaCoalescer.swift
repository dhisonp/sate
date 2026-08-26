import Foundation

/// Injected so cadence is testable without sleeping and so the producer can be
/// driven by a virtual clock in tests.
public protocol CoalescerClock: Sendable {
    var now: Date { get }
}

public struct SystemCoalescerClock: CoalescerClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}

/// Accumulates text/reasoning deltas on the producer side and reports when a
/// flush should be delivered to the UI, so a 300 delta/second stream does not
/// cause 300 main-actor hops and SwiftUI invalidations.
public struct DeltaCoalescer: Sendable {
    public struct Flush: Hashable, Sendable {
        public var text: String
        public var reasoning: String

        public init(text: String = "", reasoning: String = "") {
            self.text = text
            self.reasoning = reasoning
        }

        public var isEmpty: Bool { text.isEmpty && reasoning.isEmpty }
    }

    private let minInterval: TimeInterval
    private let maxPendingCharacters: Int
    private let clock: any CoalescerClock

    private var pendingText = ""
    private var pendingReasoning = ""
    /// Maintained incrementally: `String.count` is O(n) and this is consulted on
    /// every single delta.
    private var pendingCharacters = 0
    private var lastFlush: Date?

    public init(
        minInterval: TimeInterval = 0.016,
        maxPendingCharacters: Int = 256,
        clock: any CoalescerClock = SystemCoalescerClock()
    ) {
        self.minInterval = minInterval
        self.maxPendingCharacters = maxPendingCharacters
        self.clock = clock
    }

    /// Append a delta. Returns a Flush when the cadence rule says it is time.
    public mutating func append(text: String = "", reasoning: String = "") -> Flush? {
        guard !text.isEmpty || !reasoning.isEmpty else { return nil }

        pendingText += text
        pendingReasoning += reasoning
        pendingCharacters += text.count + reasoning.count

        let now = clock.now
        guard let lastFlush else {
            // The very first token defines perceived latency, so it is never held.
            return flush(at: now)
        }
        if pendingCharacters >= maxPendingCharacters { return flush(at: now) }
        if now.timeIntervalSince(lastFlush) >= minInterval { return flush(at: now) }
        return nil
    }

    /// Returns pending content if any, regardless of cadence. Call on a trailing
    /// timer tick, and ALWAYS on stream completion/error so the tail is not lost.
    public mutating func drain() -> Flush? {
        guard hasPending else { return nil }
        return flush(at: clock.now)
    }

    public var hasPending: Bool { !pendingText.isEmpty || !pendingReasoning.isEmpty }

    private mutating func flush(at instant: Date) -> Flush {
        let flush = Flush(text: pendingText, reasoning: pendingReasoning)
        pendingText.removeAll(keepingCapacity: true)
        pendingReasoning.removeAll(keepingCapacity: true)
        pendingCharacters = 0
        lastFlush = instant
        return flush
    }
}
