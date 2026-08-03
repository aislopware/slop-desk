import Foundation
import XCTest
@testable import SlopDeskHost

/// ``CodeBridgeServer``'s PURE halves — routing, command encoding, hello parsing. The socket half
/// is compiled + code-reviewed only: binding a real `AF_UNIX` listener and spawning accept threads
/// is exactly what hang-safety keeps out of the suite (``CodeServerManagerTests.FakeBridge`` stands
/// in wherever the manager needs one).
final class CodeBridgeServerTests: XCTestCase {
    // MARK: Containment

    /// Containment is by path COMPONENT — the sibling directory whose name merely starts with the
    /// root's is not inside it, and a file routed there would open in the wrong project's window.
    func testContainmentIsComponentWise() {
        XCTAssertTrue(CodeBridgeServer.contains(root: "/a/b", path: "/a/b/main.swift"))
        XCTAssertTrue(CodeBridgeServer.contains(root: "/a/b", path: "/a/b"))
        XCTAssertFalse(CodeBridgeServer.contains(root: "/a/b", path: "/a/bee/main.swift"))
        XCTAssertFalse(CodeBridgeServer.contains(root: "/a/b", path: "/a"))
    }

    /// A trailing slash on the root (a shape the extension could legitimately announce) still
    /// contains, and a window with NO folder open contains nothing at all.
    func testContainmentEdges() {
        XCTAssertTrue(CodeBridgeServer.contains(root: "/a/b/", path: "/a/b/main.swift"))
        XCTAssertTrue(CodeBridgeServer.contains(root: "/", path: "/main.swift"))
        XCTAssertFalse(CodeBridgeServer.contains(root: "", path: "/a/b/main.swift"))
    }

    // MARK: Routing

    func testRouteFindsTheWindowThatOwnsTheFile() {
        let candidates = [(fd: Int32(4), root: "/work/alpha"), (fd: Int32(5), root: "/work/beta")]

        XCTAssertEqual(CodeBridgeServer.route(target: "/work/beta/x.swift", among: candidates), 5)
    }

    /// No connected window owns the path ⇒ `nil`, NOT a nearest guess: the caller falls back to the
    /// CLI, and dropping a file into an unrelated project's window would be worse than a slow open.
    func testRouteRefusesAnUnownedPath() {
        let candidates = [(fd: Int32(4), root: "/work/alpha")]

        XCTAssertNil(CodeBridgeServer.route(target: "/elsewhere/x.swift", among: candidates))
        XCTAssertNil(CodeBridgeServer.route(target: "/work/alpha/x.swift", among: []))
    }

    /// Nested checkouts open as separate windows; the DEEPEST containing folder wins, so a file
    /// inside the inner repo lands in the inner repo's window.
    func testRoutePrefersTheDeepestRoot() {
        let candidates = [
            (fd: Int32(4), root: "/work"),
            (fd: Int32(5), root: "/work/alpha/vendor"),
            (fd: Int32(6), root: "/work/alpha"),
        ]

        XCTAssertEqual(
            CodeBridgeServer.route(target: "/work/alpha/vendor/x.swift", among: candidates), 5,
        )
        XCTAssertEqual(CodeBridgeServer.route(target: "/work/alpha/x.swift", among: candidates), 6)
        XCTAssertEqual(CodeBridgeServer.route(target: "/work/x.swift", among: candidates), 4)
    }

    /// Two windows on the SAME folder (the multi-client case) route deterministically — same
    /// connection set, same answer, so an open never lands in a coin-flip window.
    func testRouteBreaksTiesOnTheLowerDescriptor() {
        let candidates = [(fd: Int32(9), root: "/work"), (fd: Int32(3), root: "/work")]

        XCTAssertEqual(CodeBridgeServer.route(target: "/work/x.swift", among: candidates), 3)
        XCTAssertEqual(
            CodeBridgeServer.route(target: "/work/x.swift", among: candidates.reversed()), 3,
        )
    }

    // MARK: Command encoding

    private func decode(_ line: String?) throws -> [String: Any] {
        let line = try XCTUnwrap(line)
        XCTAssertTrue(line.hasSuffix("\n"), "the extension reads NDJSON — every command is one line")
        let data = Data(line.dropLast().utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOpenCommandCarriesABarePath() throws {
        let message = try decode(CodeBridgeServer.openCommand(target: "/work/a.swift"))

        XCTAssertEqual(message["t"] as? String, "open")
        XCTAssertEqual(message["path"] as? String, "/work/a.swift")
        XCTAssertNil(message["line"], "no suffix ⇒ no caret — the editor keeps its own position")
        XCTAssertNil(message["col"])
    }

    /// The `:line[:col]` suffix the hint-mode detector produces is split OFF the path and carried
    /// as numbers — the extension turns them into a selection, and a path with the suffix still
    /// attached would simply not exist on disk.
    func testOpenCommandSplitsTheLineColSuffix() throws {
        let line = try decode(CodeBridgeServer.openCommand(target: "/work/a.swift:42"))
        XCTAssertEqual(line["path"] as? String, "/work/a.swift")
        XCTAssertEqual(line["line"] as? Int, 42)
        XCTAssertNil(line["col"])

        let both = try decode(CodeBridgeServer.openCommand(target: "/work/a.swift:42:7"))
        XCTAssertEqual(both["path"] as? String, "/work/a.swift")
        XCTAssertEqual(both["line"] as? Int, 42)
        XCTAssertEqual(both["col"] as? Int, 7)
    }

    /// Host paths carry quotes and backslashes; the command goes through `JSONSerialization`, so
    /// they survive instead of handing the extension a line it silently drops.
    func testOpenCommandEscapesHostilePaths() throws {
        let hostile = #"/work/we"ird\path/a.swift"#

        let message = try decode(CodeBridgeServer.openCommand(target: hostile))

        XCTAssertEqual(message["path"] as? String, hostile)
    }

    // MARK: Hello parsing

    func testHelloRootIsRead() {
        let line = Data(#"{"t":"hello","v":1,"root":"/work/alpha"}"#.utf8)

        XCTAssertEqual(CodeBridgeServer.helloRoot(in: line), "/work/alpha")
    }

    /// Validate-then-drop: everything that is not a well-formed hello with an ABSOLUTE root leaves
    /// the connection unrouted rather than routable to a path the host cannot resolve.
    func testHelloRootRejectsEverythingElse() {
        for line in [
            #"{"t":"open","root":"/work"}"#, // another verb
            #"{"t":"hello","root":"relative"}"#, // not absolute
            #"{"t":"hello"}"#, // no root
            #"{"t":"hello","root":42}"#, // wrong type
            "not json at all",
            "",
        ] {
            XCTAssertNil(CodeBridgeServer.helloRoot(in: Data(line.utf8)), "rejected: \(line)")
        }
    }
}
