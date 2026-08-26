import Foundation

/// One row of the conversation list screen.
public struct ConversationSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var model: String
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: UUID, title: String, model: String, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.model = model
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}

/// The `index.json` sidecar (R2.6): a denormalized list so the conversation list
/// screen never parses JSONL bodies.
///
/// It is a *cache*, never a source of truth — every field can be recomputed from
/// the transcripts. That is why every read path self-heals: a missing, truncated
/// or schema-shifted `index.json` triggers a directory rescan instead of an
/// error, and a store mutation that fails to persist the index still leaves the
/// JSONL correct.
///
/// Not `Sendable`: it is a stored property of the `ConversationStore` actor and
/// never escapes that isolation.
final class ConversationIndex {
    private let directory: URL
    private let indexURL: URL
    private let encoder = SessionCoding.makeEncoder()
    private let decoder = SessionCoding.makeDecoder()

    private var byID: [UUID: ConversationSummary] = [:]
    private var isLoaded = false

    init(directory: URL) {
        self.directory = directory
        indexURL = directory.appending(path: "index.json")
    }

    /// All rows, newest activity first.
    func summaries() throws -> [ConversationSummary] {
        try loadIfNeeded()
        return byID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            // Deterministic tiebreak so list order is stable across launches when
            // several conversations share a timestamp (rebuild from mtime can).
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func summary(for id: UUID) throws -> ConversationSummary? {
        try loadIfNeeded()
        return byID[id]
    }

    func upsert(_ summary: ConversationSummary) throws {
        try loadIfNeeded()
        byID[summary.id] = summary
        try persist()
    }

    func remove(_ id: UUID) throws {
        try loadIfNeeded()
        byID.removeValue(forKey: id)
        try persist()
    }

    // MARK: - Loading

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        // `uniquingKeysWith`, never `uniqueKeysWithValues`: duplicate conversation
        // ids are exactly the state this type is supposed to self-heal from — an
        // iCloud/Files conflict copy (`<uuid> 2.jsonl`) or a restore leaves two
        // files carrying the same `header.conversationID`, and trapping here would
        // crash the conversation-list screen, i.e. the app would not boot.
        if let cached = readIndexFile() {
            byID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        } else {
            byID = try Dictionary(rebuild().map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            // Persist the repair so the next launch takes the fast path.
            try? persist()
        }
        isLoaded = true
    }

    /// Returns nil for "absent or unusable" — both mean "rebuild", so the caller
    /// never has to distinguish them.
    private func readIndexFile() -> [ConversationSummary]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? decoder.decode([ConversationSummary].self, from: data)
    }

    private func persist() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(Array(byID.values))
        // Atomic replace: a torn index.json would only cost a rescan, but an
        // atomic write makes that path unreachable in the first place.
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Rebuild (cold path)

    /// Rescans the directory. Deliberately cheap per file: it decodes the header
    /// line and the entry *discriminator* of the remaining lines, never the
    /// message bodies.
    private func rebuild() throws -> [ConversationSummary] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }

        let contents = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return contents.filter { $0.pathExtension == "jsonl" }.compactMap(summarize)
    }

    private func summarize(_ url: URL) -> ConversationSummary? {
        guard let lines = try? JSONLFile(url: url).lines else { return nil }

        var header: ConversationHeader?
        var title: String?
        var model: String?
        var messageCount = 0

        for line in lines {
            guard let probe = try? decoder.decode(SessionCoding.TypeProbe.self, from: line) else {
                continue
            }
            switch probe.type {
            case "message":
                messageCount += 1
            case "header":
                if header == nil,
                   let entry = try? decoder.decode(SessionEntry.self, from: line),
                   case let .header(decoded) = entry
                {
                    header = decoded
                }
            case "update":
                if let entry = try? decoder.decode(SessionEntry.self, from: line),
                   case let .update(newTitle, newModel, _) = entry
                {
                    if let newTitle {
                        title = newTitle
                    }
                    if let newModel {
                        model = newModel
                    }
                }
            default:
                continue
            }
        }

        guard let header else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return ConversationSummary(
            id: header.conversationID,
            title: title ?? header.title,
            model: model ?? header.model,
            updatedAt: modified ?? header.createdAt,
            messageCount: messageCount
        )
    }
}

private extension JSONLFile {
    /// Complete lines only; a crashed tail is simply not counted.
    var lines: [Data] {
        get throws { try readLines().lines }
    }
}
