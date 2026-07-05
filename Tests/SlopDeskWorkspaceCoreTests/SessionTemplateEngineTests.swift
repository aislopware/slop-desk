import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The pure session-template model + expansion/capture: a template → a fresh ``Session`` (split tree +
/// seeded specs + ordered launch list), the inverse capture of a live session's geometry → a template
/// (the SHAPE round-trips), and the per-pane launch bytes (reusing the safe ``LaunchPresetEngine`` cd
/// path). No store, no transport.
final class SessionTemplateEngineTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { String(bytes: bytes, encoding: .utf8) ?? "" }

    /// A structural fingerprint of a ``SplitNode`` / ``TemplateNode`` that ignores PaneIDs / SplitNodeIDs —
    /// used for the round-trip SHAPE comparison (axes + nesting + leaf count, not identity).
    private enum Shape: Equatable {
        case leaf
        case split(SplitAxis, [Self])
    }

    private func shape(of node: SplitNode) -> Shape {
        switch node {
        case .leaf: .leaf
        case let .split(_, axis, children): .split(axis, children.map { shape(of: $0.node) })
        }
    }

    private func shape(of node: TemplateNode) -> Shape {
        switch node {
        case .pane: .leaf
        case let .split(axis, children): .split(axis, children.map { shape(of: $0) })
        }
    }

    // MARK: makeSession — structure + invariants

    func testMakeSessionBuildsSplitTreeAndSeedsSpecs() {
        let template = SessionTemplate(
            name: "ET",
            layout: .split(axis: .horizontal, children: [
                .pane(TemplatePane(title: "Editor")),
                .pane(TemplatePane(title: "Terminal")),
            ]),
        )
        let (session, launches) = SessionTemplateEngine.makeSession(from: template, name: "S1")
        XCTAssertEqual(session.name, "S1")
        XCTAssertEqual(session.tabs.count, 1)
        // Two leaves, two specs (the specs == leafIDs invariant holds at birth).
        XCTAssertEqual(session.tabs[0].root.leafCount, 2)
        XCTAssertEqual(session.specs.count, 2)
        XCTAssertEqual(Set(session.specs.keys), session.leafIDSet())
        // The launch list is in DFS pane order, one entry per leaf.
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches.map(\.1.title), ["Editor", "Terminal"])
        // The active pane is the FIRST leaf in DFS order.
        XCTAssertEqual(session.activeTab?.activePane, session.tabs[0].root.allPaneIDs().first)
        // Equal flex weights on the split children.
        if case let .split(_, _, children) = session.tabs[0].root {
            XCTAssertEqual(children.map(\.weight), [.flex(1), .flex(1)])
        } else {
            XCTFail("expected a split root")
        }
    }

    func testMakeSessionNestedLayoutPreservesSpecsKindsAndCount() {
        let (session, launches) = SessionTemplateEngine.makeSession(
            from: SessionTemplate.builtIns[1], name: "S",
        ) // "Editor · Server · Git" — 3 leaves, nested vertical split
        XCTAssertEqual(session.tabs[0].root.leafCount, 3)
        XCTAssertEqual(session.specs.count, 3)
        XCTAssertEqual(Set(session.specs.keys), session.leafIDSet())
        XCTAssertEqual(launches.count, 3)
        // Every seeded spec is a terminal carrying the template title.
        XCTAssertTrue(session.specs.values.allSatisfy { $0.kind == .terminal })
        XCTAssertEqual(Set(session.specs.values.map(\.title)), ["Editor", "Server", "Git"])
        // The Git pane carries its command in the launch list.
        XCTAssertEqual(launches.first { $0.1.title == "Git" }?.1.command, "git status")
    }

    // MARK: captureTemplate + round-trip property

    func testCaptureTemplateWalksActiveTabAndDropsCwdCommand() {
        // Build a session with a known split via the engine, then capture it back.
        let template = SessionTemplate(
            name: "X",
            layout: .split(axis: .vertical, children: [
                .pane(TemplatePane(title: "A", command: "should-not-survive")),
                .pane(TemplatePane(title: "B")),
            ]),
        )
        let (session, _) = SessionTemplateEngine.makeSession(from: template, name: "S")
        let captured = SessionTemplateEngine.captureTemplate(from: session, name: "Cap", symbol: "star")
        XCTAssertEqual(captured.name, "Cap")
        XCTAssertEqual(captured.symbol, "star")
        XCTAssertFalse(captured.isBuiltIn)
        // cwd/command are NOT in the tree, so the capture drops them (they live in the PTY).
        if case let .split(axis, children) = captured.layout {
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(children.count, 2)
            for child in children {
                if case let .pane(pane) = child {
                    XCTAssertNil(pane.cwd)
                    XCTAssertNil(pane.command)
                } else { XCTFail("expected pane children") }
            }
        } else { XCTFail("expected a split layout") }
    }

    /// REQUIRED round-trip: makeSession(from: captureTemplate(from: s)).0 has the SAME tree SHAPE as s's
    /// active tab (axes / leaf-count / structure), ignoring PaneIDs.
    func testRoundTripPreservesTreeShape() {
        for template in SessionTemplate.builtIns {
            let (session, _) = SessionTemplateEngine.makeSession(from: template, name: "S")
            let originalShape = shape(of: session.tabs[0].root)
            let captured = SessionTemplateEngine.captureTemplate(from: session, name: "Cap", symbol: "x")
            let (rebuilt, _) = SessionTemplateEngine.makeSession(from: captured, name: "S2")
            XCTAssertEqual(
                shape(of: rebuilt.tabs[0].root), originalShape,
                "round-trip must preserve axes + leaf-count + structure for \(template.name)",
            )
            // The captured TEMPLATE shape also matches the source tree shape.
            XCTAssertEqual(shape(of: captured.layout), originalShape)
        }
    }

    func testCaptureSingleLeafSession() {
        let session = Session.singlePane(name: "L", spec: PaneSpec(kind: .terminal, title: "Solo"))
        let captured = SessionTemplateEngine.captureTemplate(from: session, name: "Cap", symbol: "x")
        XCTAssertEqual(captured.layout, .pane(TemplatePane(kind: .terminal, title: "Solo")))
    }

    /// `captureTemplate` must PRESERVE a non-terminal pane kind (not hardcode `.terminal`): a `.remoteGUI`
    /// leaf's spec round-trips into a `.remoteGUI` ``TemplatePane``. Without this, hardcoding the capture's
    /// `kind:` to `.terminal` (SessionTemplateEngine.swift:83) would pass the rest of the suite.
    func testCaptureNonTerminalKindIsPreserved() {
        let session = Session.singlePane(name: "G", spec: PaneSpec(kind: .remoteGUI, title: "GUI"))
        let captured = SessionTemplateEngine.captureTemplate(from: session, name: "Cap", symbol: "x")
        XCTAssertEqual(captured.layout, .pane(TemplatePane(kind: .remoteGUI, title: "GUI")))
    }

    /// `makeSession` must PRESERVE a non-terminal template-pane kind when seeding the spec (not hardcode
    /// `.terminal`): a `.remoteGUI` ``TemplatePane`` seeds a `.remoteGUI` ``PaneSpec``. Without this,
    /// hardcoding the build's `kind:` to `.terminal` (SessionTemplateEngine.swift:44) would pass the suite.
    func testMakeSessionNonTerminalKindIsPreserved() {
        let template = SessionTemplate(
            name: "Mixed",
            layout: .split(axis: .horizontal, children: [
                .pane(TemplatePane(kind: .remoteGUI, title: "GUI")),
                .pane(TemplatePane(kind: .terminal, title: "Term")),
            ]),
        )
        let (session, _) = SessionTemplateEngine.makeSession(from: template, name: "S")
        let kindByTitle = Dictionary(
            uniqueKeysWithValues: session.specs.values.map { ($0.title, $0.kind) },
        )
        XCTAssertEqual(kindByTitle["GUI"], .remoteGUI)
        XCTAssertEqual(kindByTitle["Term"], .terminal)
    }

    // MARK: launchBytes — the safe cd/command path (reuses LaunchPresetEngine)

    func testLaunchBytesEmptyIsNil() {
        XCTAssertNil(SessionTemplateEngine.launchBytes(cwd: nil, command: nil))
        XCTAssertNil(SessionTemplateEngine.launchBytes(cwd: "", command: ""))
        XCTAssertNil(SessionTemplateEngine.launchBytes(cwd: "  ", command: " \n "))
    }

    func testLaunchBytesCwdOnlyEmitsSafeCdLine() throws {
        let bytes = try XCTUnwrap(SessionTemplateEngine.launchBytes(cwd: "/Users/me/proj", command: nil))
        XCTAssertEqual(text(bytes), "cd '/Users/me/proj'\n")
    }

    func testLaunchBytesCommandOnly() throws {
        let bytes = try XCTUnwrap(SessionTemplateEngine.launchBytes(cwd: nil, command: "claude"))
        XCTAssertEqual(text(bytes), "claude\n")
    }

    func testLaunchBytesBoth() throws {
        let bytes = try XCTUnwrap(SessionTemplateEngine.launchBytes(cwd: "/proj", command: "make"))
        XCTAssertEqual(text(bytes), "cd '/proj'\nmake\n")
    }

    /// SECURITY: a cwd containing a `SendKeysParser` token like `<Enter>` (or a quote) stays LITERAL inside
    /// the single-quoted `cd` path — no injected newline that would break out of `cd '…'` and run a second
    /// command. Inherited from the reused ``LaunchPresetEngine`` cd-as-literal path.
    func testLaunchBytesCwdInjectionIsLiteral() throws {
        let bytes = try XCTUnwrap(SessionTemplateEngine.launchBytes(
            cwd: "/tmp/proj<Enter>rm -rf important", command: "ls",
        ))
        let firstNL = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        let cdLine = Array(bytes[bytes.startIndex..<firstNL])
        XCTAssertFalse(cdLine.contains(0x0D), "no CR injected inside the cd path")
        XCTAssertFalse(cdLine.contains(0x0A), "no LF injected inside the cd path")
        XCTAssertEqual(text(cdLine), "cd '/tmp/proj<Enter>rm -rf important'")
        XCTAssertEqual(bytes.count(where: { $0 == 0x0A }), 2) // exactly cd + command, no injected 3rd line
    }

    func testLaunchBytesCwdWithQuoteIsEscaped() throws {
        let bytes = try XCTUnwrap(SessionTemplateEngine.launchBytes(cwd: "/it's/here", command: nil))
        XCTAssertEqual(text(bytes), "cd '/it'\\''s/here'\n")
    }

    // MARK: Built-ins

    func testBuiltInsAreStableAndShaped() {
        XCTAssertEqual(
            SessionTemplate.builtIns.map(\.name),
            ["Editor + Terminal", "Editor · Server · Git", "Claude + Terminal"],
        )
        XCTAssertTrue(SessionTemplate.builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(
            SessionTemplate.builtIns.map { $0.id.uuidString.lowercased() },
            [
                "22222222-0000-4000-8000-000000000001",
                "22222222-0000-4000-8000-000000000002",
                "22222222-0000-4000-8000-000000000003",
            ],
            "built-in session-template UUIDs are frozen for idempotent re-seed",
        )
        XCTAssertEqual(SessionTemplate.builtIns.map(\.layout.paneCount), [2, 3, 2])
    }
}
