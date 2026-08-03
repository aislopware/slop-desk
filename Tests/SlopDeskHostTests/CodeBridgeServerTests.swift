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

        XCTAssertEqual(CodeBridgeServer.inbound(in: line), .hello(root: "/work/alpha"))
    }

    /// Validate-then-drop: everything that is not a well-formed hello with an ABSOLUTE root leaves
    /// the connection unrouted rather than routable to a path the host cannot resolve.
    func testHelloRootRejectsEverythingElse() {
        for line in [
            #"{"t":"hello","root":"relative"}"#, // not absolute
            #"{"t":"hello"}"#, // no root
            #"{"t":"hello","root":42}"#, // wrong type
            "not json at all",
            "",
        ] {
            XCTAssertNil(CodeBridgeServer.inbound(in: Data(line.utf8)), "rejected: \(line)")
        }
    }

    // MARK: Run / cd parsing

    func testRunCarriesTheCommandAndItsProject() {
        let line = Data(
            #"{"t":"run","v":1,"id":"7","root":"/work/a","cwd":"/work/a/src","text":"npm test"}"#.utf8,
        )

        XCTAssertEqual(
            CodeBridgeServer.inbound(in: line),
            .run(
                id: "7",
                request: CodeBridgeRunRequest(
                    root: "/work/a", directory: "/work/a/src", text: "npm test",
                ),
            ),
        )
    }

    /// A `cd` names a DIRECTORY and the host writes the command line, so the shell quoting has one
    /// tested home instead of a second copy in JavaScript.
    func testChangeDirectoryIsBuiltHostSide() {
        let line = Data(#"{"t":"cd","v":1,"id":"8","root":"/work/a","path":"/work/a/it's here"}"#.utf8)

        XCTAssertEqual(
            CodeBridgeServer.inbound(in: line),
            .run(
                id: "8",
                request: CodeBridgeRunRequest(
                    root: "/work/a", directory: nil, text: #"cd '/work/a/it'\''s here'"#,
                ),
            ),
        )
    }

    /// Validate-then-drop, and the stakes are higher here than anywhere else in this file: what
    /// survives gets TYPED at a live shell prompt.
    func testRunRejectsWhatMustNotBeTyped() {
        for line in [
            #"{"t":"run","id":"1","root":"/work","text":"ls\u001b[A"}"#, // ESC is a keybinding, not text
            #"{"t":"run","id":"1","root":"/work","text":"ls\u0000rm -rf /"}"#, // NUL truncates
            #"{"t":"run","id":"1","root":"/work","text":""}"#, // nothing to run
            #"{"t":"run","id":"","root":"/work","text":"ls"}"#, // no correlation id
            #"{"t":"run","id":"1","root":"relative","text":"ls"}"#, // unroutable project
            #"{"t":"run","id":"1","root":"/work"}"#, // no text
            #"{"t":"cd","id":"1","root":"/work","path":"relative"}"#,
        ] {
            XCTAssertNil(CodeBridgeServer.inbound(in: Data(line.utf8)), "rejected: \(line)")
        }
    }

    /// Newline and tab DO survive: a multi-line selection is exactly what "run selection" means.
    func testMultiLineSelectionsAreTypeable() {
        XCTAssertTrue(CodeBridgeServer.isTypeable("cd /tmp\n\tls -la\n"))
        XCTAssertFalse(
            CodeBridgeServer.isTypeable(String(repeating: "x", count: CodeBridgeServer.maxRunTextBytes + 1)),
            "a selection this large was never meant for a prompt",
        )
    }

    /// A relative `cwd` is dropped rather than passed through — it only ranks, so losing it costs
    /// nothing, while believing it could rank on nonsense.
    func testRelativeWorkingDirectoryIsDropped() {
        let line = Data(#"{"t":"run","id":"9","root":"/work","cwd":"src","text":"ls"}"#.utf8)

        XCTAssertEqual(
            CodeBridgeServer.inbound(in: line),
            .run(id: "9", request: CodeBridgeRunRequest(root: "/work", directory: nil, text: "ls")),
        )
    }

    // MARK: Result encoding

    func testResultNamesThePaneItLandedIn() throws {
        let message = try decode(
            CodeBridgeServer.resultLine(id: "7", outcome: .landed(in: "zsh — alpha")),
        )

        XCTAssertEqual(message["t"] as? String, "result")
        XCTAssertEqual(message["id"] as? String, "7")
        XCTAssertEqual(message["ok"] as? Bool, true)
        XCTAssertEqual(message["pane"] as? String, "zsh — alpha")
        XCTAssertNil(message["message"])
    }

    func testRefusalCarriesTheSentenceTheEditorShows() throws {
        let message = try decode(
            CodeBridgeServer.resultLine(id: "7", outcome: .refused("no pane")),
        )

        XCTAssertEqual(message["ok"] as? Bool, false)
        XCTAssertEqual(message["message"] as? String, "no pane")
        XCTAssertNil(message["pane"])
    }
}
