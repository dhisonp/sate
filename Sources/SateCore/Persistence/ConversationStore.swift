import Foundation

// MARK: - Coding

/// One JSON configuration shared by the transcript, the index and the in-flight
/// sidecar so a value written by one is always readable by the others.
enum SessionCoding {
    /// ISO-8601 with fractional seconds. Chosen over the `Codable` default
    /// (seconds since 2001 as a `Double`) because a transcript is a file the
    /// operator may have to read or repair by hand; the fractional part is kept
    /// because sibling ordering compares timestamps.
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let fallbackStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(style.format(date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? style.parse(text) {
                return date
            }
            // Tolerate whole-second stamps: hand-edited files and older writers.
            return try fallbackStyle.parse(text)
        }
        return decoder
    }

    /// Reads only the line's discriminator. Used by the index rebuild so it can
    /// count messages without paying to decode their bodies.
    struct TypeProbe: Decodable {
        let type: String

        private enum CodingKeys: String, CodingKey { case type }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        }
    }
}

// MARK: - Errors

public enum ConversationStoreError: Error, Sendable, Equatable {
    case notFound(UUID)
    /// The transcript exists but carries no usable `header` line.
    case missingHeader(UUID)
}

// MARK: - Snapshot

/// An immutable view of one conversation, rebuilt from its JSONL on every load.
///
/// The whole `parent -> children` map is materialized, not just the leaf path,
/// because R2.2 requires sibling navigation ("2 of 3") at every fork.
public struct ConversationSnapshot: Sendable {
    public var header: ConversationHeader
    public var messagesByID: [UUID: Message]
    /// Children in append order; the `nil` key holds the roots.
    public var childrenByParent: [UUID?: [UUID]]
    public var leafID: UUID?

    public init(
        header: ConversationHeader,
        messagesByID: [UUID: Message],
        childrenByParent: [UUID?: [UUID]],
        leafID: UUID?
    ) {
        self.header = header
        self.messagesByID = messagesByID
        self.childrenByParent = childrenByParent
        self.leafID = leafID
    }

    /// The visible branch: from the leaf up to its root, root-first.
    public var currentBranch: [Message] {
        var reversed: [Message] = []
        // A cycle can only arise from a corrupt/hand-edited file, but walking one
        // would hang the UI thread, so the walk is explicitly bounded.
        var visited: Set<UUID> = []
        var cursor = leafID
        while let id = cursor, let message = messagesByID[id], visited.insert(id).inserted {
            reversed.append(message)
            cursor = message.parentID
        }
        return reversed.reversed()
    }

    /// Every message sharing `id`'s parent, `id` included, in append order.
    public func siblings(of id: UUID) -> [UUID] {
        guard let message = messagesByID[id] else { return [] }
        return childrenByParent[message.parentID] ?? []
    }
}

// MARK: - Store

/// Owns every write to every conversation transcript.
///
/// Actor-isolated for the reason in R2.5: two tasks — or two iPad scenes bound to
/// the same conversation — must not interleave a commit's message line and leaf
/// line, and the in-flight sidecar must be deleted in the *same* turn as the
/// commit that supersedes it.
public actor ConversationStore {
    private let directory: URL
    private let index: ConversationIndex
    private let encoder = SessionCoding.makeEncoder()
    private let decoder = SessionCoding.makeDecoder()

    /// Files already repaired in this process. A crashed partial tail can only
    /// exist from a *previous* process, so one truncation check per file per
    /// launch is both necessary and sufficient — and it keeps the hot append path
    /// free of an extra full read.
    private var repaired: Set<UUID> = []

    public init(directory: URL) {
        self.directory = directory
        index = ConversationIndex(directory: directory)
    }

    // MARK: Locations

    private func transcriptURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).jsonl")
    }

    private func inflightURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).inflight")
    }

    private func file(_ id: UUID) -> JSONLFile {
        JSONLFile(url: transcriptURL(id))
    }

    // MARK: Lifecycle

    public func create(title: String, model: String) throws -> ConversationHeader {
        let header = ConversationHeader(title: title, model: model)
        let target = file(header.conversationID)
        // The header line carries no user text; durability is provided by the
        // first message append. Skipping F_FULLFSYNC here removes the largest
        // source of latency when opening a new conversation.
        try append(.header(header), to: target, id: header.conversationID, durable: false)
        // A brand-new file has no history, so nothing can need repair.
        repaired.insert(header.conversationID)

        try index.upsert(ConversationSummary(
            id: header.conversationID,
            title: header.title,
            model: header.model,
            updatedAt: header.createdAt,
            messageCount: 0
        ))
        return header
    }

    public func list() throws -> [ConversationSummary] {
        try index.summaries()
    }

    public func delete(_ id: UUID) throws {
        try file(id).delete()
        let sidecar = inflightURL(id)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
        repaired.remove(id)
        try index.remove(id)
    }

    // MARK: Loading

    public func load(_ id: UUID) throws -> ConversationSnapshot {
        let target = file(id)
        guard target.exists() else { throw ConversationStoreError.notFound(id) }

        let (lines, _) = try target.readLines()

        var header: ConversationHeader?
        var titleOverride: String?
        var modelOverride: String?
        var messagesByID: [UUID: Message] = [:]
        var childrenByParent: [UUID?: [UUID]] = [:]
        var appendOrder: [UUID: Int] = [:]
        var leafID: UUID?

        for line in lines {
            // Forward compatibility (R2.1): a line this build cannot decode — a
            // newer schema, a hand-edit, a byte-level scribble — is dropped, never
            // fatal. `SessionEntry` already folds unknown `type`s into `.unknown`,
            // so `try?` here only catches structurally broken JSON.
            guard let entry = try? decoder.decode(SessionEntry.self, from: line) else { continue }
            switch entry {
            case let .header(decoded):
                if header == nil {
                    header = decoded
                }
            case let .message(message):
                if messagesByID.updateValue(message, forKey: message.id) == nil {
                    appendOrder[message.id] = appendOrder.count
                    childrenByParent[message.parentID, default: []].append(message.id)
                }
            case let .leaf(id, _):
                leafID = id // last one wins
            case let .update(title, model, _):
                if let title {
                    titleOverride = title
                }
                if let model {
                    modelOverride = model
                }
            case .unknown:
                continue
            }
        }

        guard var header else { throw ConversationStoreError.missingHeader(id) }
        if let titleOverride {
            header.title = titleOverride
        }
        if let modelOverride {
            header.model = modelOverride
        }

        for (parent, children) in childrenByParent {
            childrenByParent[parent] = children.sorted { lhs, rhs in
                let left = messagesByID[lhs], right = messagesByID[rhs]
                if let l = left?.timestamp, let r = right?.timestamp, l != r {
                    return l < r
                }
                // Equal timestamps happen within a millisecond; falling back to
                // append order keeps "2 of 3" labels stable across loads.
                return (appendOrder[lhs] ?? 0) < (appendOrder[rhs] ?? 0)
            }
        }

        // A transcript whose leaf line was lost still has to render something.
        if leafID.flatMap({ messagesByID[$0] }) == nil {
            leafID = appendOrder.max { $0.value < $1.value }?.key
        }

        return ConversationSnapshot(
            header: header,
            messagesByID: messagesByID,
            childrenByParent: childrenByParent,
            leafID: leafID
        )
    }

    // MARK: Mutation

    /// Commits one message and advances the leaf to it.
    ///
    /// Exactly one `F_FULLFSYNC`, and it is on the MESSAGE line, not the leaf.
    /// The sidecar is dropped the instant that line is on the platter, because
    /// the two failure modes are not symmetric:
    ///
    ///   * leaf line lost (crash, or an ENOSPC / `F_FULLFSYNC` failure on the
    ///     second append) → a message with a stale leaf, which `load` already
    ///     renders correctly by falling back to the last appended message;
    ///   * sidecar outliving a landed message line → `recoverCheckpoints()` on
    ///     the next launch mints a SECOND message with the same text and a fresh
    ///     UUID. Dedup is by `message.id`, so nothing catches it and the answer
    ///     is simply there twice, forever.
    ///
    /// So the discard goes between the two appends (still the same actor turn as
    /// the commit, per R2.4), and the durable barrier moves to the line whose
    /// loss would be unrecoverable.
    public func append(_ message: Message, to id: UUID) throws {
        let target = file(id)
        guard target.exists() else { throw ConversationStoreError.notFound(id) }

        try repairIfNeeded(id, target)
        var summary = try currentSummary(id)

        try append(.message(message), to: target, id: id, durable: true)
        discardCheckpointFile(id)
        try append(
            .leaf(id: message.id, timestamp: message.timestamp),
            to: target, id: id, durable: false
        )

        summary.messageCount += 1
        summary.updatedAt = message.timestamp
        try index.upsert(summary)
    }

    /// Switches the visible branch. Append-only: nothing is deleted, so the
    /// abandoned branch stays reachable through `siblings(of:)`.
    public func setLeaf(_ messageID: UUID, in id: UUID) throws {
        let target = file(id)
        guard target.exists() else { throw ConversationStoreError.notFound(id) }

        try repairIfNeeded(id, target)
        var summary = try currentSummary(id)

        let now = Date()
        try append(.leaf(id: messageID, timestamp: now), to: target, id: id, durable: true)

        summary.updatedAt = now
        try index.upsert(summary)
    }

    public func update(title: String?, model: String?, for id: UUID) throws {
        guard title != nil || model != nil else { return }
        let target = file(id)
        guard target.exists() else { throw ConversationStoreError.notFound(id) }

        try repairIfNeeded(id, target)
        var summary = try currentSummary(id)

        let now = Date()
        try append(
            .update(title: title, model: model, timestamp: now), to: target, id: id, durable: true
        )

        if let title {
            summary.title = title
        }
        if let model {
            summary.model = model
        }
        summary.updatedAt = now
        try index.upsert(summary)
    }

    // MARK: In-flight checkpoints

    /// Persists the draft of a generation that has not finished yet (R2.4).
    ///
    /// Not durably synced: this runs every couple of seconds for the whole length
    /// of a response, and an `F_FULLFSYNC` at that cadence would stall the stream.
    /// Atomic rename is enough — the worst case is losing the last couple of
    /// seconds of tokens, not a corrupt sidecar.
    public func checkpoint(
        conversationID: UUID,
        parentID: UUID?,
        text: String,
        reasoning: String,
        model: String
    ) throws {
        let record = InflightCheckpoint(
            conversationID: conversationID,
            parentID: parentID,
            text: text,
            reasoning: reasoning,
            model: model,
            updatedAt: Date()
        )
        try createDirectoryIfNeeded()
        try encoder.encode(record).write(to: inflightURL(conversationID), options: .atomic)
    }

    /// Drops a checkpoint without committing it — used when a generation is
    /// abandoned with nothing worth keeping.
    public func clearCheckpoint(_ id: UUID) throws {
        let sidecar = inflightURL(id)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        try FileManager.default.removeItem(at: sidecar)
    }

    /// Cheap check so bootstrap can skip the heavy recovery path on a normal launch.
    public func hasCheckpoints() throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return false }

        let contents = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return contents.contains { $0.pathExtension == "inflight" }
    }

    /// Turns every surviving sidecar into an interrupted assistant message.
    ///
    /// A sidecar that is still on disk at launch means the process died while a
    /// response was streaming. The user already paid for those tokens, so they are
    /// committed rather than discarded, flagged `interrupted` with
    /// `finishReason: .truncated` so the UI can offer "Continue".
    ///
    /// - Returns: the conversation ids that gained a recovered message.
    @discardableResult
    public func recoverCheckpoints() throws -> [UUID] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }

        let contents = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )

        var recovered: [UUID] = []
        for url in contents where url.pathExtension == "inflight" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(InflightCheckpoint.self, from: data)
            else {
                // Unreadable sidecar: nothing to recover, and leaving it would make
                // every future launch retry the same failure.
                try? manager.removeItem(at: url)
                continue
            }
            guard file(record.conversationID).exists() else {
                // The conversation was deleted while the sidecar was in flight.
                try? manager.removeItem(at: url)
                continue
            }

            let message = Message(
                parentID: record.parentID,
                role: .assistant,
                content: [.text(record.text)],
                timestamp: record.updatedAt,
                reasoning: record.reasoning.isEmpty ? nil : record.reasoning,
                model: record.model,
                finishReason: .truncated,
                interrupted: true
            )

            // `append` deletes the sidecar itself, in its own turn.
            try append(message, to: record.conversationID)
            recovered.append(record.conversationID)
        }
        return recovered
    }

    // MARK: Internals

    /// Encodes and appends one entry, re-arming this conversation's tail repair if
    /// the write fails.
    ///
    /// `JSONLFile` rolls a short write back off the end of the file, but a write
    /// that fails for any other reason may still have left something at EOF, and
    /// `repairIfNeeded` only fires once per file per process. Re-arming costs one
    /// extra read on the next write to this conversation and removes the
    /// fused-line failure mode entirely.
    private func append(
        _ entry: SessionEntry, to target: JSONLFile, id: UUID, durable: Bool
    ) throws {
        do {
            try target.append(encoder.encode(entry), durable: durable)
        } catch {
            repaired.remove(id)
            throw error
        }
    }

    private func repairIfNeeded(_ id: UUID, _ target: JSONLFile) throws {
        guard !repaired.contains(id) else { return }
        try target.truncatePartialTail()
        repaired.insert(id)
    }

    /// The index row for `id`, reconstructed from the transcript if the index has
    /// never seen this conversation (a file dropped into the directory by a
    /// restore, or an index rebuild that raced a delete).
    private func currentSummary(_ id: UUID) throws -> ConversationSummary {
        if let existing = try index.summary(for: id) {
            return existing
        }
        let snapshot = try load(id)
        return ConversationSummary(
            id: id,
            title: snapshot.header.title,
            model: snapshot.header.model,
            updatedAt: snapshot.header.createdAt,
            messageCount: snapshot.messagesByID.count
        )
    }

    private func discardCheckpointFile(_ id: UUID) {
        try? FileManager.default.removeItem(at: inflightURL(id))
    }

    private func createDirectoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// The on-disk shape of a `<uuid>.inflight` sidecar.
struct InflightCheckpoint: Codable, Sendable {
    var conversationID: UUID
    var parentID: UUID?
    var text: String
    var reasoning: String
    var model: String
    var updatedAt: Date
}
