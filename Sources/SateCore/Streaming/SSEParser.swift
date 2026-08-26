import Foundation

/// Framing half of the SSE pipeline: raw bytes in, `SSEEvent`s out. It is a
/// value type with no isolation because it is owned by the streaming `Task` —
/// handing bytes to an actor would cost a hop per chunk.
///
/// Nothing here knows about chat completions; `data` is handed on verbatim.
public struct SSEParser: Sendable {
    private let maxEventBytes: Int

    /// Bytes of the line being assembled. UTF-8 is decoded only once a full line
    /// exists, so a multi-byte scalar split across two chunks is never mangled.
    private var lineBytes: [UInt8] = []

    private var dataLines: [String] = []
    /// Distinct from `dataLines.isEmpty`: a lone `data:` with an empty value
    /// still makes the event dispatchable, while an event carrying only `id:`
    /// must be swallowed.
    private var sawDataField = false
    private var eventName: String?
    private var eventID: String?

    /// A `\r` already terminated a line, so an immediately following `\n` is its
    /// partner rather than a second terminator. This survives across `consume`
    /// calls because a CRLF pair is routinely split by the transport.
    private var pendingLF = false

    /// Bytes charged against the event currently being assembled; reset by every
    /// blank line. Guards against a provider streaming an unterminated event
    /// forever and exhausting memory.
    private var eventBytes = 0

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    private var bomMatched = 0
    private var bomResolved = false

    public init(maxEventBytes: Int = 1 << 20) {
        self.maxEventBytes = maxEventBytes
    }

    /// Feed newly received bytes. Returns every complete event that became available.
    public mutating func consume(_ bytes: some Sequence<UInt8>) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if !bomResolved {
                if byte == Self.bom[bomMatched] {
                    bomMatched += 1
                    if bomMatched == Self.bom.count {
                        bomResolved = true
                    }
                    continue
                }
                // The prefix matched but the sequence is not a BOM, so the bytes
                // we speculatively withheld are real content and must be replayed.
                let replay = Self.bom.prefix(bomMatched)
                bomMatched = 0
                bomResolved = true
                for withheld in replay {
                    try feed(withheld, into: &events)
                }
            }
            try feed(byte, into: &events)
        }
        return events
    }

    /// Call at end of stream. Per the SSE spec an unterminated trailing event is
    /// DISCARDED; return whether that happened so the caller can log it.
    public mutating func finish() -> Bool {
        // `bomMatched > 0` counts too: those bytes were withheld from an
        // unterminated first line and are being thrown away with it.
        let discarded = !lineBytes.isEmpty || sawDataField || eventName != nil || eventID != nil || bomMatched > 0
        lineBytes.removeAll()
        resetEvent()
        pendingLF = false
        bomResolved = true
        bomMatched = 0
        return discarded
    }

    private mutating func feed(_ byte: UInt8, into events: inout [SSEEvent]) throws {
        if pendingLF {
            pendingLF = false
            if byte == 0x0A {
                return
            }
        }

        eventBytes += 1
        if eventBytes > maxEventBytes {
            throw GatewayError.protocolError("SSE event exceeded \(maxEventBytes) bytes")
        }

        switch byte {
        case 0x0A:
            endLine(into: &events)
        case 0x0D:
            pendingLF = true
            endLine(into: &events)
        default:
            lineBytes.append(byte)
        }
    }

    private mutating func endLine(into events: inout [SSEEvent]) {
        defer { lineBytes.removeAll(keepingCapacity: true) }

        if lineBytes.isEmpty {
            dispatch(into: &events)
            return
        }
        // Keepalive comment.
        if lineBytes[0] == 0x3A {
            return
        }

        // Split on bytes, not Characters: the spec's colon and single space are
        // defined on the byte stream, and `String.first` would see a leading
        // space followed by a combining mark as one grapheme and refuse to strip it.
        let field: String
        let value: String
        if let colon = lineBytes.firstIndex(of: 0x3A) {
            field = decode(lineBytes[..<colon])
            var start = lineBytes.index(after: colon)
            // Exactly one space, so `data:  x` keeps its second space.
            if start < lineBytes.endIndex, lineBytes[start] == 0x20 {
                start = lineBytes.index(after: start)
            }
            value = decode(lineBytes[start...])
        } else {
            field = decode(lineBytes[...])
            value = ""
        }

        switch field {
        case "data":
            dataLines.append(value)
            sawDataField = true
        case "event":
            eventName = value
        case "id":
            // Deliberately not sticky across events: this client never resumes
            // with Last-Event-ID, so carrying an id forward would only mislabel
            // later events.
            eventID = value
        default:
            // `retry` and anything unknown: ignored per spec.
            break
        }
    }

    /// Invalid byte sequences become U+FFFD rather than an error: the spec
    /// mandates replacement, and one bad byte must not kill a live generation.
    private func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        eventBytes = 0
        defer { resetEvent() }
        guard sawDataField else { return }
        events.append(SSEEvent(name: eventName, data: dataLines.joined(separator: "\n"), id: eventID))
    }

    private mutating func resetEvent() {
        dataLines.removeAll(keepingCapacity: true)
        sawDataField = false
        eventName = nil
        eventID = nil
        eventBytes = 0
    }
}
