import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A durable append-only newline-delimited file.
///
/// This type knows nothing about conversations — it is the write-discipline
/// primitive from R2.3: one `write(2)` per line so a concurrent reader never
/// observes a half-line, `F_FULLFSYNC` for commits, and non-fatal recovery of a
/// tail that a crash left half-written.
public struct JSONLFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public enum Failure: Error, Sendable, Equatable {
        /// `open(2)` failed; carries `errno`.
        case cannotOpen(Int32)
        /// `write(2)` failed; carries `errno`.
        case writeFailed(Int32)
        /// `write(2)` returned fewer bytes than requested. We deliberately do
        /// *not* loop to finish the write: a second `write(2)` would no longer be
        /// atomic against a concurrent appender. The short line is left as a
        /// partial tail for `truncatePartialTail()` to discard.
        case shortWrite(expected: Int, actual: Int)
        /// `fcntl(F_FULLFSYNC)` failed; carries `errno`.
        case syncFailed(Int32)
        /// `ftruncate(2)` failed; carries `errno`.
        case truncateFailed(Int32)
    }

    // MARK: - Appending

    /// Appends `line` plus a trailing newline as a single `write(2)`.
    ///
    /// - Parameter durable: when true, issues `fcntl(fd, F_FULLFSYNC, 0)` before
    ///   returning. `FileHandle.synchronize()` / `fsync(2)` only flush to the
    ///   drive's write cache on APFS, which a power loss can still discard;
    ///   `F_FULLFSYNC` is the only barrier that actually reaches the platter.
    ///   Callers pass `false` for intermediate lines of a multi-line commit and
    ///   `true` once, on the last one.
    public func append(_ line: Data, durable: Bool) throws {
        try createParentDirectoryIfNeeded()

        var payload = line
        payload.append(0x0A)

        // O_APPEND makes the offset lookup and the write a single atomic step in
        // the kernel, so two writers (two scenes, two tasks) can never interleave
        // inside one line even if the actor guarantee above is ever relaxed.
        let fd = Self.openForAppend(url)
        guard fd >= 0 else { throw Failure.cannotOpen(errno) }
        defer { close(fd) }

        applyFileProtection()

        let written = payload.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return write(fd, base, buffer.count)
        }
        guard written >= 0 else { throw Failure.writeFailed(errno) }
        guard written == payload.count else {
            throw Failure.shortWrite(expected: payload.count, actual: written)
        }

        if durable {
            try Self.fullSync(fd)
        }
    }

    // MARK: - Reading

    /// Reads every complete line.
    ///
    /// A trailing line with no terminating newline is a crash artefact, not an
    /// error: it is reported through `hadPartialTail` and omitted from `lines`.
    ///
    /// v1 limitation: the whole file is read into memory once and split. Sessions
    /// are single-conversation transcripts (kilobytes to low megabytes), so this
    /// is fine; if transcripts ever grow past that, replace this with a chunked
    /// reader — the signature does not have to change.
    public func readLines() throws -> (lines: [Data], hadPartialTail: Bool) {
        guard exists() else { return ([], false) }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return ([], false) }

        var lines: [Data] = []
        let chunks = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let lastIndex = chunks.index(before: chunks.endIndex)
        var hadPartialTail = false

        for index in chunks.indices {
            let chunk = chunks[index]
            if index == lastIndex {
                // Anything after the final newline is incomplete by definition.
                hadPartialTail = !chunk.isEmpty
            } else if !chunk.isEmpty {
                lines.append(Data(chunk))
            }
        }
        return (lines, hadPartialTail)
    }

    /// Truncates the file to the end of its last complete line.
    ///
    /// Call once per file per process, before the first append: otherwise a
    /// crashed half-line would sit in the middle of the file after the next
    /// append and silently corrupt the line that follows it.
    public func truncatePartialTail() throws {
        guard exists() else { return }
        let data = try Data(contentsOf: url)
        guard let last = data.last else { return }
        guard last != 0x0A else { return }

        // Keep everything up to and including the last newline; if there is none
        // the entire file is one partial line and goes to zero.
        let keep = data.lastIndex(of: 0x0A).map { data.startIndex.distance(to: $0) + 1 } ?? 0

        let fd = Self.openForAppend(url)
        guard fd >= 0 else { throw Failure.cannotOpen(errno) }
        defer { close(fd) }

        guard ftruncate(fd, off_t(keep)) == 0 else { throw Failure.truncateFailed(errno) }
        // Durable: the repair must survive the crash that could follow it,
        // otherwise the same bad tail comes back on the next launch.
        try Self.fullSync(fd)
    }

    // MARK: - Lifecycle

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func delete() throws {
        guard exists() else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Internals

    private func createParentDirectoryIfNeeded() throws {
        let parent = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private static func openForAppend(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
    }

    private static func fullSync(_ fd: Int32) throws {
        #if canImport(Darwin)
        guard fcntl(fd, F_FULLFSYNC, 0) != -1 else { throw Failure.syncFailed(errno) }
        #else
        guard fsync(fd) == 0 else { throw Failure.syncFailed(errno) }
        #endif
    }

    /// `.completeUntilFirstUserAuthentication`, deliberately not `.complete`:
    /// with `.complete` an append issued while the device is locked — which is
    /// exactly what happens when a stream commits during a background task —
    /// fails with `EACCES` mid-write.
    ///
    /// Non-fatal by design: on macOS (where `swift test` runs) there is no data
    /// protection at all, and a failure to *tighten* protection must never lose
    /// the user's transcript.
    private func applyFileProtection() {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }
}
