import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pins the Command Snippets feature: the two pure parsers (`SnippetExpander` placeholder resolution,
/// `SendKeysParser` control-key token grammar), the `Snippet` model + persistence, and the store CRUD +
/// `runSnippet` fan-out (focused pane, or the broadcast group when armed). The run path is fully tested
/// via FakePaneSession.sentBytes; only the placeholder-entry sheet is GUI.
@MainActor
final class SnippetTests: XCTestCase {

    // MARK: - SnippetExpander

    func testExpandResolvesPlaceholders() {
        let r = SnippetExpander.expand("ssh {{user}}@{{host}}", values: ["user": "ada", "host": "h.local"])
        XCTAssertEqual(r.text, "ssh ada@h.local")
        XCTAssertTrue(r.missing.isEmpty)
    }

    func testExpandReportsMissingAndKeepsLiteral() {
        let r = SnippetExpander.expand("deploy {{env}} {{env}} {{region}}", values: ["region": "eu"])
        XCTAssertEqual(r.text, "deploy {{env}} {{env}} eu", "an unresolved placeholder stays literal")
        XCTAssertEqual(r.missing, ["env"], "missing reported once, in order")
    }

    func testExpandWhitespaceInsideBracesAndNoPlaceholders() {
        XCTAssertEqual(SnippetExpander.expand("x {{ a }} y", values: ["a": "1"]).text, "x 1 y")
        XCTAssertEqual(SnippetExpander.expand("plain text", values: [:]).text, "plain text")
    }

    func testPlaceholdersAreOrderedAndDeduped() {
        XCTAssertEqual(Snippet(name: "n", body: "{{b}} {{a}} {{b}} {{c}}").placeholders, ["b", "a", "c"])
        XCTAssertEqual(Snippet(name: "n", body: "no slots").placeholders, [])
    }

    // MARK: - SendKeysParser

    func testLiteralTextIsUTF8() {
        XCTAssertEqual(SendKeysParser.encode("ls"), Array("ls".utf8))
    }

    func testNamedControlTokens() {
        XCTAssertEqual(SendKeysParser.encode("<Enter>"), [0x0D])
        XCTAssertEqual(SendKeysParser.encode("<Tab>"), [0x09])
        XCTAssertEqual(SendKeysParser.encode("<Esc>"), [0x1B])
        XCTAssertEqual(SendKeysParser.encode("<BS>"), [0x7F])
        XCTAssertEqual(SendKeysParser.encode("<Up>"), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(SendKeysParser.encode("<Left>"), [0x1B, 0x5B, 0x44])
    }

    func testCtrlChordFoldsToControlByte() {
        XCTAssertEqual(SendKeysParser.encode("<C-c>"), [0x03], "Ctrl-C")
        XCTAssertEqual(SendKeysParser.encode("<C-d>"), [0x04], "Ctrl-D")
        XCTAssertEqual(SendKeysParser.encode("<c-C>"), [0x03], "token names are case-insensitive")
    }

    func testUnknownTokenAndBareAngleAreLiteral() {
        XCTAssertEqual(SendKeysParser.encode("<foo>"), Array("<foo>".utf8), "unknown token is literal")
        XCTAssertEqual(SendKeysParser.encode("a < b"), Array("a < b".utf8), "a bare '<' is literal")
        XCTAssertEqual(SendKeysParser.encode("x<"), Array("x<".utf8), "a trailing '<' is literal")
    }

    func testCombinedLiteralAndTokens() {
        XCTAssertEqual(SendKeysParser.encode("git add -A<Enter>"), Array("git add -A".utf8) + [0x0D])
        // A chained two-command macro.
        XCTAssertEqual(SendKeysParser.encode("a<Enter>b<Enter>"),
                       Array("a".utf8) + [0x0D] + Array("b".utf8) + [0x0D])
    }

    // MARK: - Store CRUD + run

    private func store(_ items: [CanvasItem], focus: PaneID) -> WorkspaceStore {
        WorkspaceStore(restoring: Workspace(canvas: Canvas(items: items), focusedPane: focus),
                       makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }
    private func term(_ x: CGFloat) -> CanvasItem {
        CanvasItem(id: PaneID(), spec: PaneSpec(kind: .terminal, title: "t"),
                   frame: CGRect(x: x, y: 0, width: 300, height: 200), z: 0)
    }
    private func bytes(_ store: WorkspaceStore, _ id: PaneID) -> [[UInt8]] {
        (store.handle(for: id) as? FakePaneSession)?.sentBytes ?? []
    }

    func testSnippetNameIsTrimmedAndBlankFallsBack() {
        let a = term(0)
        let st = store([a], focus: a.id)
        XCTAssertEqual(st.addSnippet(name: "  deploy  ", body: "x").name, "deploy", "name is trimmed")
        XCTAssertEqual(st.addSnippet(name: "   ", body: "x").name, "Snippet", "a blank name falls back (no blank palette row)")
        XCTAssertEqual(st.addSnippet(name: "", body: "x").name, "Snippet")
    }

    func testNormalizingCollectionsPreservesUniqueSnippetIdButRemintsDuplicates() {
        // load() idempotency: a clean file's snippet ids must NOT churn on every launch.
        let s = Snippet(name: "a", body: "b")
        let clean = Workspace(canvas: Canvas(items: [term(0)]), focusedPane: nil, snippets: [s])
        XCTAssertEqual(clean.normalizingCollections().snippets.first?.id, s.id, "a unique snippet id is preserved")
        // A genuine duplicate id is still re-minted (palette entry-id safety).
        let dup = Workspace(canvas: Canvas(items: [term(0)]), focusedPane: nil,
                            snippets: [Snippet(id: s.id, name: "a", body: "b"), Snippet(id: s.id, name: "c", body: "d")])
        XCTAssertEqual(Set(dup.normalizingCollections().snippets.map(\.id)).count, 2, "a duplicate snippet id is re-minted")
    }

    func testCRUDPersistsOnWorkspace() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "deploy", body: "make deploy<Enter>")
        XCTAssertEqual(st.snippets.count, 1)
        st.updateSnippet(s.id, name: "deploy-prod", body: "make deploy ENV=prod<Enter>")
        XCTAssertEqual(st.snippets.first?.name, "deploy-prod")
        XCTAssertEqual(st.snippets.first?.body, "make deploy ENV=prod<Enter>")
        st.deleteSnippet(s.id)
        XCTAssertTrue(st.snippets.isEmpty)
    }

    func testRunSnippetSendsExpandedBytesToFocusedPane() {
        let a = term(0), b = term(400)
        let st = store([a, b], focus: a.id)
        let s = st.addSnippet(name: "ssh", body: "ssh {{host}}<Enter>")
        let n = st.runSnippet(s.id, values: ["host": "h.local"])
        XCTAssertEqual(n, 1, "delivered to the focused pane")
        XCTAssertEqual(bytes(st, a.id), [Array("ssh h.local".utf8) + [0x0D]])
        XCTAssertEqual(bytes(st, b.id), [], "an unfocused pane receives nothing without broadcast")
    }

    func testRunSnippetFansToBroadcastGroupWhenArmed() {
        let a = term(0), b = term(400), c = term(800)
        let st = store([a, b, c], focus: a.id)
        st.setSelection([a.id, b.id])
        st.toggleBroadcast()
        XCTAssertTrue(st.broadcastActive)
        let s = st.addSnippet(name: "u", body: "uptime<Enter>")
        let n = st.runSnippet(s.id)
        XCTAssertEqual(n, 2, "broadcast fans to the selection")
        let expected = Array("uptime".utf8) + [0x0D]
        XCTAssertEqual(bytes(st, a.id), [expected])
        XCTAssertEqual(bytes(st, b.id), [expected])
        XCTAssertEqual(bytes(st, c.id), [])
    }

    func testRunUnknownSnippetIsNoOp() {
        let a = term(0)
        let st = store([a], focus: a.id)
        XCTAssertEqual(st.runSnippet(UUID()), 0)
        XCTAssertEqual(bytes(st, a.id), [])
    }

    func testSnippetsSurviveCodableRoundTrip() throws {
        let a = term(0)
        let st = store([a], focus: a.id)
        st.addSnippet(name: "g", body: "git status<Enter>")
        let data = try JSONEncoder().encode(st.workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.snippets.first?.name, "g")
        XCTAssertEqual(decoded.snippets.first?.body, "git status<Enter>")
    }

    // MARK: - beginRunSnippet: the placeholder-prompt gate (don't send literal {{slots}})

    func testBeginRunSnippetRunsImmediatelyWhenNoPlaceholders() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "u", body: "uptime<Enter>")
        XCTAssertEqual(st.beginRunSnippet(s.id), .ran(1), "a no-placeholder snippet runs at once")
        XCTAssertNil(st.pendingSnippetRun, "no value sheet is armed")
        XCTAssertEqual(bytes(st, a.id), [Array("uptime".utf8) + [0x0D]])
    }

    func testBeginRunSnippetArmsTheSheetForAParameterizedSnippetAndDoesNotSendLiteralSlots() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "ssh", body: "ssh {{user}}@{{host}}<Enter>")
        XCTAssertEqual(st.beginRunSnippet(s.id), .needsValues(["user", "host"]),
                       "placeholders are reported in first-appearance order")
        XCTAssertEqual(st.pendingSnippetRun, s.id, "the value sheet is armed")
        XCTAssertEqual(bytes(st, a.id), [], "NOTHING is sent until values are collected (no literal {{}})")
    }

    func testBeginRunSnippetUnknownId() {
        let a = term(0)
        let st = store([a], focus: a.id)
        XCTAssertEqual(st.beginRunSnippet(UUID()), .unknown)
        XCTAssertNil(st.pendingSnippetRun)
    }

    // MARK: - Run Last Snippet (⌥⌘R re-fire)

    func testRunLastSnippetReFiresTheMostRecentLaunch() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "u", body: "uptime<Enter>")
        XCTAssertEqual(st.runLastSnippet(), .unknown, "nothing launched yet → graceful no-op")
        XCTAssertEqual(bytes(st, a.id), [])

        st.beginRunSnippet(s.id)                       // launch records lastRanSnippetID
        XCTAssertEqual(st.lastRanSnippetID, s.id)
        XCTAssertEqual(st.runLastSnippet(), .ran(1), "⌥⌘R re-fires the last snippet")
        XCTAssertEqual(bytes(st, a.id), [Array("uptime".utf8) + [0x0D], Array("uptime".utf8) + [0x0D]],
                       "the macro was sent twice (the launch + the re-fire)")
    }

    func testRunLastSnippetRePromptsForAParameterizedSnippet() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "ssh", body: "ssh {{host}}<Enter>")
        st.beginRunSnippet(s.id)                       // arms the value sheet, records lastRan
        st.clearSnippetRunRequest()
        XCTAssertEqual(st.runLastSnippet(), .needsValues(["host"]), "re-firing a parameterized macro re-prompts")
        XCTAssertEqual(bytes(st, a.id), [], "no literal {{host}} is sent")
    }

    func testDeletingTheLastSnippetClearsTheReFireTarget() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "u", body: "uptime<Enter>")
        st.beginRunSnippet(s.id)
        st.deleteSnippet(s.id)
        XCTAssertNil(st.lastRanSnippetID, "⌥⌘R no longer points at a dead snippet")
        XCTAssertEqual(st.runLastSnippet(), .unknown, "and re-firing is a graceful no-op")
    }

    func testClearSnippetRunRequestDisarms() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "ssh", body: "ssh {{host}}<Enter>")
        _ = st.beginRunSnippet(s.id)
        XCTAssertNotNil(st.pendingSnippetRun)
        st.clearSnippetRunRequest()
        XCTAssertNil(st.pendingSnippetRun)
    }

    func testRunAfterCollectingValuesResolvesEveryPlaceholder() {
        // The sheet's run path: seed all slots (blanks for any untouched) so no literal {{}} can leak.
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "ssh", body: "ssh {{user}}@{{host}}<Enter>")
        _ = st.beginRunSnippet(s.id)
        let n = st.runSnippet(s.id, values: ["user": "root", "host": "h.local"])
        st.clearSnippetRunRequest()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(bytes(st, a.id), [Array("ssh root@h.local".utf8) + [0x0D]])
        XCTAssertNil(st.pendingSnippetRun)
    }

    // MARK: - Snippet manager (the in-app CRUD surface — previously JSON-only)

    func testManageSnippetsCommandOpensTheManager() {
        let a = term(0)
        let st = store([a], focus: a.id)
        XCTAssertFalse(st.snippetManagerPresented)
        apply(.manageSnippets, to: st)
        XCTAssertTrue(st.snippetManagerPresented, "the command opens the manager")
        st.dismissSnippetManager()
        XCTAssertFalse(st.snippetManagerPresented)
    }

    func testManageSnippetsIsNotRecentsWorthy() {
        // Opening a manager is not an action verb — it should not churn the palette recents ring.
        XCTAssertFalse(WorkspaceCommand.manageSnippets.isRecentsWorthy)
    }

    func testManageSnippetsIsInThePaletteCatalog() {
        XCTAssertTrue(CommandPaletteView.commandCatalog.contains { $0.command == .manageSnippets },
                      "Manage Snippets… is runnable from ⌘K")
    }

    func testUpdateSnippetStoresNameVerbatimSoLiveEditingDoesNotChurn() {
        // The live editor binds name straight through updateSnippet; a per-keystroke trim/substitute
        // would eat a trailing space and snap a cleared field to "Snippet". updateSnippet must NOT
        // normalize — the empty→"Snippet" fallback is display-time only.
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "x", body: "b")
        st.updateSnippet(s.id, name: "my server ", body: "b")     // trailing space kept
        XCTAssertEqual(st.snippets.first?.name, "my server ")
        st.updateSnippet(s.id, name: "", body: "b")               // cleared, not snapped to "Snippet"
        XCTAssertEqual(st.snippets.first?.name, "")
        // The display fallback still produces a non-blank label.
        XCTAssertEqual(WorkspaceStore.snippetName(st.snippets.first!.name), "Snippet")
    }

    func testRequestSnippetManagerClearsAStrandedPendingRun() {
        // Belt-and-suspenders against the stacked-sheet race: opening the manager clears any value-entry
        // flag a failed transition left armed-but-invisible.
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "ssh", body: "ssh {{host}}<Enter>")
        _ = st.beginRunSnippet(s.id)
        XCTAssertNotNil(st.pendingSnippetRun)
        st.requestSnippetManager()
        XCTAssertNil(st.pendingSnippetRun, "opening the manager clears a stranded value-entry flag")
        XCTAssertTrue(st.snippetManagerPresented)
    }

    func testManagerCRUDFlowMirrorsTheView() {
        // What the manager view does: add (seeds + selects), edit name+body, delete.
        let a = term(0)
        let st = store([a], focus: a.id)
        let created = st.addSnippet(name: "New Snippet", body: "")
        XCTAssertEqual(st.snippets.count, 1)
        st.updateSnippet(created.id, name: "deploy", body: "make deploy<Enter>")
        XCTAssertEqual(st.snippets.first?.name, "deploy")
        XCTAssertEqual(st.snippets.first?.body, "make deploy<Enter>")
        st.deleteSnippet(created.id)
        XCTAssertTrue(st.snippets.isEmpty)
    }
}
