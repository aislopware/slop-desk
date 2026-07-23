import XCTest
@testable import SlopDeskFileTransfer

final class DiskFileDropSinkTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slopdesk-filetransfer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Real `try` so SwiftFormat keeps `throws` (an @objc override of a throwing method must stay
        // throwing); `dir` is created in setUp, so the remove succeeds.
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    func testWriteAndFinalizeLandsBytes() throws {
        let sink = DiskFileDropSink(directory: dir)
        try sink.open(transferId: 1, name: "hello.txt", size: 5)
        try sink.write(transferId: 1, data: Data("he".utf8))
        try sink.write(transferId: 1, data: Data("llo".utf8))
        try sink.finalize(transferId: 1)

        let landed = dir.appendingPathComponent("hello.txt")
        XCTAssertEqual(try Data(contentsOf: landed), Data("hello".utf8))
    }

    func testCollisionGetsSuffix() throws {
        let sink = DiskFileDropSink(directory: dir)
        // Pre-existing file forces a suffix.
        try Data("old".utf8).write(to: dir.appendingPathComponent("report.pdf"))

        try sink.open(transferId: 1, name: "report.pdf", size: 3)
        try sink.write(transferId: 1, data: Data("new".utf8))
        try sink.finalize(transferId: 1)

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("report.pdf")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("report (1).pdf")), Data("new".utf8))
    }

    func testSecondCollisionIncrements() throws {
        try Data("a".utf8).write(to: dir.appendingPathComponent("x.txt"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("x (1).txt"))

        let sink = DiskFileDropSink(directory: dir)
        try sink.open(transferId: 1, name: "x.txt", size: 1)
        try sink.write(transferId: 1, data: Data("c".utf8))
        try sink.finalize(transferId: 1)

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("x (2).txt")), Data("c".utf8))
    }

    func testCollisionOnExtensionlessName() throws {
        try Data("a".utf8).write(to: dir.appendingPathComponent("LICENSE"))
        let sink = DiskFileDropSink(directory: dir)
        try sink.open(transferId: 1, name: "LICENSE", size: 1)
        try sink.write(transferId: 1, data: Data("b".utf8))
        try sink.finalize(transferId: 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("LICENSE (1)")), Data("b".utf8))
    }

    func testAbortLeavesNoFile() throws {
        let sink = DiskFileDropSink(directory: dir)
        try sink.open(transferId: 1, name: "gone.txt", size: 10)
        try sink.write(transferId: 1, data: Data("partial".utf8))
        sink.abort(transferId: 1)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(contents.contains("gone.txt"))
        // No stray temp part file either.
        XCTAssertFalse(contents.contains { $0.hasPrefix(".slopdesk-upload-") })
    }

    func testWriteWithoutOpenThrows() {
        let sink = DiskFileDropSink(directory: dir)
        XCTAssertThrowsError(try sink.write(transferId: 99, data: Data([1])))
    }

    func testCreatesDirectoryIfAbsent() throws {
        let nested = dir.appendingPathComponent("does/not/exist/yet")
        let sink = DiskFileDropSink(directory: nested)
        try sink.open(transferId: 1, name: "a.txt", size: 1)
        try sink.write(transferId: 1, data: Data("z".utf8))
        try sink.finalize(transferId: 1)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("a.txt")), Data("z".utf8))
    }
}
