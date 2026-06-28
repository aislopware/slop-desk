import CoreGraphics
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

/// E16 WI-7 / M5 — the parameterized-snippet value-entry sheet. The ⌘⇧P palette routes a snippet through
/// `beginRunSnippet`, which arms `store.pendingSnippetRun` for a body carrying a NON-reserved `{{slot}}`,
/// expecting a UI to collect a value per slot. `SnippetValueSheet` (backed by the pure `SnippetValueForm`)
/// is that surface: it prompts ONLY the user-prompt slots — never the four reserved vars — and on Run hands
/// the collected values to `store.runSnippet`, injecting the EXPANDED body. These tests pin the headless
/// backing (`SnippetValueForm`) + the end-to-end inject, without instantiating SwiftUI.
@MainActor
final class SnippetValueSheetTests: XCTestCase {
    // MARK: - Store harness (focused terminal pane + a byte-recording session)

    /// Records every `sendBytes` so the run path is observable — the ClientUI-target analogue of the
    /// WorkspaceCore `FakePaneSession.sentBytes`. Pure in-memory; no terminal / video / window.
    private final class RecordingSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
        private(set) var id: PaneID
        let kind: PaneKind
        private(set) var isVideoActive = false
        private(set) var sentBytes: [[UInt8]] = []

        init(_ spec: PaneSpec) {
            id = PaneID()
            kind = spec.kind
        }

        func adopt(id: PaneID) { self.id = id }
        func setVideoActive(_: Bool) {}
        // Sync witnesses legally satisfy the `async` protocol requirements (like `MountTestPaneSession`) and
        // dodge the `async_without_await` strict-lint rule on these empty fake bodies.
        func pause() {}
        func resume() {}
        func teardown() {}
        func sendBytes(_ bytes: [UInt8]) { sentBytes.append(bytes) }
    }

    private func store(focusKind: PaneKind = .terminal) -> (WorkspaceStore, PaneID) {
        let id = PaneID()
        let item = CanvasItem(
            id: id,
            spec: PaneSpec(kind: focusKind, title: "t"),
            frame: CGRect(x: 0, y: 0, width: 300, height: 200),
            z: 0,
        )
        let store = WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: [item]), focusedPane: id),
            makeSession: { RecordingSession($0) },
            liveVideoCap: 5,
        )
        return (store, id)
    }

    private func bytes(_ store: WorkspaceStore, _ id: PaneID) -> [[UInt8]] {
        (store.handle(for: id) as? RecordingSession)?.sentBytes ?? []
    }

    // MARK: - SnippetValueForm (the headless backing)

    /// The form prompts ONLY the user-prompt slots, in first-appearance order, with the four reserved vars
    /// ({{date}}/{{time}}/{{clipboard}}/{{cursor}}) filtered out — and seeds every slot empty so an untouched
    /// slot resolves to "" rather than leaking a literal `{{slot}}`.
    func testFormSurfacesOnlyUserSlotsAndSeedsThemEmpty() {
        let form = SnippetValueForm(snippetID: UUID(), body: "ssh {{user}}@{{host}} on {{date}}<Enter>")
        XCTAssertEqual(form.slots, ["user", "host"], "the reserved {{date}} is excluded; order preserved")
        XCTAssertEqual(form.collectedValues, ["user": "", "host": ""], "every slot seeded empty")
    }

    /// A reserved-only body has NO user slots — so the sheet would render empty and `beginRunSnippet` never
    /// arms it (the body runs immediately instead).
    func testFormHasNoSlotsForReservedOnlyBody() {
        XCTAssertEqual(SnippetValueForm(snippetID: UUID(), body: "git checkout {{cursor}}").slots, [])
        XCTAssertEqual(SnippetValueForm(snippetID: UUID(), body: "{{date}} {{time}}").slots, [])
    }

    // MARK: - End-to-end: arm → collect → run injects the EXPANDED body

    /// (a) Selecting a parameterized snippet arms `pendingSnippetRun` and sends NOTHING yet (no literal
    /// `{{}}`); (b) the sheet's run path — collect into `SnippetValueForm`, then `runSnippet(id, values:)` +
    /// `clearSnippetRunRequest()` — injects the resolved body and disarms.
    ///
    /// REVERT-TO-CONFIRM-FAIL: without `SnippetValueForm`/`SnippetValueSheet` this file does not compile (the
    /// only consumer of the armed `pendingSnippetRun` flag), so selecting such a snippet from the palette
    /// would silently inject nothing — the bug M5 fixes.
    func testValueSheetCollectsThenInjectsExpandedBody() {
        let (st, pane) = store()
        let s = st.addSnippet(name: "ssh", body: "ssh {{user}}@{{host}}<Enter>")

        // (a) the palette path arms the sheet and sends nothing literal.
        XCTAssertEqual(st.beginRunSnippet(s.id), .needsValues(["user", "host"]))
        XCTAssertEqual(st.pendingSnippetRun, s.id, "the value sheet is armed")
        XCTAssertEqual(bytes(st, pane), [], "nothing is sent until values are collected")

        // (b) the sheet builds its form from the armed snippet's body, collects values, and runs.
        var form = SnippetValueForm(snippetID: s.id, body: s.body)
        form.values["user"] = "root"
        form.values["host"] = "h.local"
        st.runSnippet(form.snippetID, values: form.collectedValues)
        st.clearSnippetRunRequest()

        XCTAssertEqual(
            bytes(st, pane),
            [Array("ssh root@h.local".utf8) + [0x0D]],
            "the EXPANDED body is injected — no literal {{slots}}",
        )
        XCTAssertNil(st.pendingSnippetRun, "the sheet disarmed on run")
    }

    /// A reserved-only snippet must NOT arm the sheet — it runs immediately through `beginRunSnippet`.
    func testReservedOnlySnippetDoesNotArmTheSheet() {
        let (st, pane) = store()
        st.snippetReservedValues = { ReservedSnippetValues(date: "2026-06-28", time: "09:41") }
        let s = st.addSnippet(name: "timenow", body: "{{date}} {{time}}")

        XCTAssertEqual(st.beginRunSnippet(s.id), .ran(1), "a reserved-only body runs immediately")
        XCTAssertNil(st.pendingSnippetRun, "no value sheet is armed")
        XCTAssertEqual(bytes(st, pane), [Array("2026-06-28 09:41".utf8)], "the reserved vars resolved + sent")
    }
}
