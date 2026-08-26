import Foundation
import Testing

@testable import SateCore

@Suite("JSONLFile")
struct JSONLFileTests {
    /// Each test gets its own directory so nothing can leak between them, and so
    /// a failing test leaves no state that changes the next run's result.
    private func withTempDirectory(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func line(_ text: String) -> Data { Data(text.utf8) }

    @Test("append creates missing parent directories")
    func createsParentDirectories() throws {
        try withTempDirectory { root in
            let url = root.appending(path: "nested/deeper/log.jsonl")
            let file = JSONLFile(url: url)
            #expect(file.exists() == false)

            try file.append(line(#"{"a":1}"#), durable: true)

            #expect(file.exists())
            let (lines, partial) = try file.readLines()
            #expect(lines == [line(#"{"a":1}"#)])
            #expect(partial == false)
        }
    }

    @Test("append round-trips multiple lines in order")
    func roundTripsLines() throws {
        try withTempDirectory { root in
            let file = JSONLFile(url: root.appending(path: "log.jsonl"))
            try file.append(line("one"), durable: false)
            try file.append(line("two"), durable: false)
            try file.append(line("three"), durable: true)

            let (lines, partial) = try file.readLines()
            #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])
            #expect(partial == false)
        }
    }

    @Test("reading a file that does not exist yields no lines")
    func readsMissingFile() throws {
        try withTempDirectory { root in
            let file = JSONLFile(url: root.appending(path: "absent.jsonl"))
            let (lines, partial) = try file.readLines()
            #expect(lines.isEmpty)
            #expect(partial == false)
        }
    }

    @Test("a trailing partial line is reported, not returned and not an error")
    func reportsPartialTail() throws {
        try withTempDirectory { root in
            let url = root.appending(path: "log.jsonl")
            let file = JSONLFile(url: url)
            try file.append(line("complete"), durable: true)

            // Simulate a crash between the write of a line's bytes and its newline.
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"type":"messa"#.utf8))
            try handle.close()

            let (lines, partial) = try file.readLines()
            #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["complete"])
            #expect(partial)
        }
    }

    @Test("truncatePartialTail drops the crashed tail and keeps later appends clean")
    func truncatesPartialTail() throws {
        try withTempDirectory { root in
            let url = root.appending(path: "log.jsonl")
            let file = JSONLFile(url: url)
            try file.append(line("first"), durable: true)

            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("garbage-no-newline".utf8))
            try handle.close()

            try file.truncatePartialTail()
            try file.append(line("second"), durable: true)

            let (lines, partial) = try file.readLines()
            #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["first", "second"])
            #expect(partial == false)
        }
    }

    @Test("truncatePartialTail empties a file that is nothing but a partial line")
    func truncatesWholeFileWhenNoNewlineExists() throws {
        try withTempDirectory { root in
            let url = root.appending(path: "log.jsonl")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("only-a-fragment".utf8).write(to: url)

            let file = JSONLFile(url: url)
            try file.truncatePartialTail()

            let (lines, partial) = try file.readLines()
            #expect(lines.isEmpty)
            #expect(partial == false)

            try file.append(line("fresh"), durable: true)
            #expect(try file.readLines().lines.map { String(decoding: $0, as: UTF8.self) } == ["fresh"])
        }
    }

    @Test("truncatePartialTail is a no-op on a well-formed or absent file")
    func truncateIsNoOpWhenClean() throws {
        try withTempDirectory { root in
            let file = JSONLFile(url: root.appending(path: "log.jsonl"))
            try file.truncatePartialTail()  // absent
            #expect(file.exists() == false)

            try file.append(line("a"), durable: true)
            try file.truncatePartialTail()  // clean
            #expect(try file.readLines().lines.count == 1)
        }
    }

    @Test("delete removes the file and is safe to repeat")
    func deletesFile() throws {
        try withTempDirectory { root in
            let file = JSONLFile(url: root.appending(path: "log.jsonl"))
            try file.append(line("a"), durable: true)
            #expect(file.exists())

            try file.delete()
            #expect(file.exists() == false)
            try file.delete()
        }
    }

    @Test("blank lines inside the file are skipped")
    func skipsBlankLines() throws {
        try withTempDirectory { root in
            let url = root.appending(path: "log.jsonl")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("a\n\nb\n".utf8).write(to: url)

            let (lines, partial) = try JSONLFile(url: url).readLines()
            #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
            #expect(partial == false)
        }
    }
}
