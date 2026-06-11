import XCTest
@testable import AislopdeskInspector

/// LineAccumulator (the pure tailer core) + TranscriptTailer (the file-following actor).
/// Asserts every line emitted exactly once, in order; a partial line is not emitted
/// until its newline arrives; a burst is fully drained; truncation resets cleanly.
final class TailerTests: XCTestCase {
    // MARK: - LineAccumulator (deterministic, no I/O)

    func testPartialLineHeldUntilNewline() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.append(Data("abc".utf8)), [], "no newline yet → emit nothing")
        XCTAssertGreaterThan(acc.bufferedByteCount, 0)
        XCTAssertEqual(acc.append(Data("def\n".utf8)), ["abcdef"], "newline completes the line, once")
        XCTAssertEqual(acc.bufferedByteCount, 0)
    }

    func testBurstOfManyLinesDrainsInOrderExactlyOnce() {
        var acc = LineAccumulator()
        let expected = (1...1000).map { "line-\($0)" }
        let blob = (expected.joined(separator: "\n") + "\n")
        let out = acc.append(Data(blob.utf8))
        XCTAssertEqual(out, expected)
    }

    func testByteAtATimeEmitsEachLineOnce() {
        var acc = LineAccumulator()
        var got: [String] = []
        for byte in Array("a\nbb\nccc\n".utf8) {
            got += acc.append(Data([byte]))
        }
        XCTAssertEqual(got, ["a", "bb", "ccc"])
    }

    func testCRLFStripped() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.append(Data("a\r\nb\r\n".utf8)), ["a", "b"])
    }

    func testResetDropsStaleHalfLine() {
        var acc = LineAccumulator()
        _ = acc.append(Data("partial-no-newline".utf8))
        acc.reset()
        XCTAssertEqual(acc.bufferedByteCount, 0)
        XCTAssertEqual(acc.append(Data("fresh\n".utf8)), ["fresh"])
    }

    // MARK: - TranscriptTailer (file follow)

    private func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-tailer-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Collects up to `count` lines from a tailer with a bounded timeout (deterministic).
    private func collect(
        _ tailer: TranscriptTailer,
        count: Int,
        producing: @escaping @Sendable () async -> Void,
        timeout: Duration = .seconds(5)
    ) async -> [TranscriptLine] {
        let stream = tailer.lines()

        let producer = Task { await producing() }

        // The collector owns its own array (no mutable state shared across tasks).
        let collector = Task { () -> [TranscriptLine] in
            var collected: [TranscriptLine] = []
            for await line in stream {
                collected.append(line)
                if collected.count >= count { break }
            }
            return collected
        }

        let result = await withTaskGroup(of: [TranscriptLine]?.self) { group -> [TranscriptLine] in
            group.addTask { await collector.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first ?? []
        }
        producer.cancel()
        await tailer.stop()
        return result
    }

    func testTailerEmitsAppendedLinesInOrderOnce() async throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // Pre-existing content + later appends, including a line written in two writes.
        try Self.append(#"{"type":"user","uuid":"1","message":{"role":"user","content":"first"}}"#, to: url)
        try Self.append("\n", to: url)

        let tailer = TranscriptTailer(path: url.path, pollInterval: .milliseconds(20))

        let lines = await collect(tailer, count: 3, producing: {
            try? await Task.sleep(for: .milliseconds(60))
            // A burst.
            try? Self.append(#"{"type":"user","uuid":"2","message":{"role":"user","content":"second"}}"# + "\n", to: url)
            try? await Task.sleep(for: .milliseconds(60))
            // A line written WITHOUT its newline first...
            try? Self.append(#"{"type":"user","uuid":"3","message":{"role":"user","content":"third"}}"#, to: url)
            try? await Task.sleep(for: .milliseconds(60))
            // ...then the newline arrives.
            try? Self.append("\n", to: url)
        })

        let uuids = lines.compactMap { line -> String? in
            if case let .user(u) = line { return u.identity.uuid }
            return nil
        }
        XCTAssertEqual(uuids, ["1", "2", "3"], "every line once, in order; partial held until newline")
    }

    func testTailerDetectsRotationToSameOrLargerFile() async throws {
        // Rotation where the NEW file is >= the consumed offset: a size-only check would
        // read from the stale offset into the new file and lose its prefix. Identity
        // (inode) detection must reset and read the new file from the top.
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // Old file: one short line (consumes a small offset).
        try Self.append(#"{"type":"user","uuid":"old","message":{"role":"user","content":"x"}}"# + "\n", to: url)

        let tailer = TranscriptTailer(path: url.path, pollInterval: .milliseconds(20))

        let lines = await collect(tailer, count: 3, producing: {
            try? await Task.sleep(for: .milliseconds(80))
            // Rotate: remove the old file and create a FRESH (different inode) one whose
            // first line, on its own, already exceeds the old byte count.
            try? FileManager.default.removeItem(at: url)
            let newFirst = #"{"type":"user","uuid":"new1","message":{"role":"user","content":"a longer first line of the rotated file"}}"# + "\n"
            FileManager.default.createFile(atPath: url.path, contents: Data(newFirst.utf8))
            try? await Task.sleep(for: .milliseconds(80))
            try? Self.append(#"{"type":"user","uuid":"new2","message":{"role":"user","content":"y"}}"# + "\n", to: url)
        })

        let uuids = lines.compactMap { line -> String? in
            if case let .user(u) = line { return u.identity.uuid }
            return nil
        }
        // The rotated file's PREFIX line ("new1") must not be lost.
        XCTAssertEqual(uuids, ["old", "new1", "new2"],
                       "rotation to a same-or-larger file resets via inode identity; no prefix lost")
    }

    func testTailerToleratesMissingFileThenAppears() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-late-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // File does NOT exist yet (SessionStart-before-file race, doc 16 pitfall 5).
        let tailer = TranscriptTailer(path: url.path, pollInterval: .milliseconds(20))

        let lines = await collect(tailer, count: 1, producing: {
            try? await Task.sleep(for: .milliseconds(80))
            FileManager.default.createFile(atPath: url.path, contents: Data())
            try? Self.append(#"{"type":"user","uuid":"late","message":{"role":"user","content":"hi"}}"# + "\n", to: url)
        })
        let uuids = lines.compactMap { line -> String? in
            if case let .user(u) = line { return u.identity.uuid }
            return nil
        }
        XCTAssertEqual(uuids, ["late"])
    }
}
