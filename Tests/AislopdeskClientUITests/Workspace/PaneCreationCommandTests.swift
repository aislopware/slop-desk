import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pins the per-kind creation chords, the ⌘N/⌘T alias pair, the deterministic chord display order,
/// and ``WorkspaceStore/duplicatePane(_:)``:
///
/// - ⌘N and ⌘T both map to `.newPane(.terminal)` (⌘N is the macOS-native "new" — the File menu
///   replaces the default New-Window item; ⌘T is the muscle-memory alias carried by the Pane menu).
/// - ⇧⌘N → `.newPane(.claudeCode)`, ⌥⌘N → `.newPane(.remoteGUI)` — every prior creation path was
///   Terminal-only.
/// - ``CommandInterpreter/defaultChords(for:)`` is DETERMINISTIC (fewest modifiers, then lexicographic)
///   so menu items and palette hints can never flap with dictionary order: ⌘N is the canonical chord.
/// - `duplicatePane` copies the spec verbatim (title, kind, committed video endpoint), lands beside
///   the original at the SAME size, in the same group, focused, with a fresh id; ephemeral panes
///   don't duplicate.
@MainActor
final class PaneCreationCommandTests: XCTestCase {

    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) })
    }

    // MARK: - Bindings

    func testPerKindCreationChords() {
        let interpreter = CommandInterpreter()
        XCTAssertEqual(interpreter.feed(KeyChord(character: "n", [.command])), .newPane(.terminal))
        XCTAssertEqual(interpreter.feed(KeyChord(character: "t", [.command])), .newPane(.terminal),
                       "⌘T must survive as the terminal alias (Pane-menu item depends on it)")
        XCTAssertEqual(interpreter.feed(KeyChord(character: "n", [.command, .shift])), .newPane(.claudeCode))
        XCTAssertEqual(interpreter.feed(KeyChord(character: "n", [.command, .option])), .newPane(.remoteGUI))
        XCTAssertEqual(interpreter.feed(KeyChord(character: "d", [.command])), .duplicatePane)
        XCTAssertEqual(interpreter.feed(KeyChord(character: "d", [.command, .shift])), .tidy,
                       "⇧⌘D tidy is untouched by the ⌘D duplicate binding")
    }

    func testDefaultChordsAreDeterministicAndCanonicalFirst() {
        let chords = CommandInterpreter.defaultChords(for: .newPane(.terminal))
        XCTAssertEqual(chords.count, 2, "terminal creation carries exactly ⌘N + the ⌘T alias")
        XCTAssertEqual(chords.first, KeyChord(character: "n", [.command]),
                       "⌘N is the canonical (displayed) chord — sorted, not dictionary order")
        XCTAssertEqual(chords.last, KeyChord(character: "t", [.command]))
        // Single-chord commands keep working through the same path.
        XCTAssertEqual(CommandInterpreter.defaultChords(for: .duplicatePane),
                       [KeyChord(character: "d", [.command])])
        XCTAssertTrue(CommandInterpreter.defaultChords(for: .newGroup).count == 1)
    }

    // MARK: - apply(.newPane(kind))

    func testApplyNewPanePerKind() {
        let store = makeStore()
        apply(.newPane(.claudeCode), to: store)
        apply(.newPane(.remoteGUI), to: store)
        let kinds = store.workspace.canvas.allIDs().compactMap { store.workspace.canvas.spec(for: $0)?.kind }
        XCTAssertEqual(kinds.filter { $0 == .claudeCode }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .remoteGUI }.count, 1)
    }

    // MARK: - Duplicate

    func testDuplicateCopiesSpecSizeGroupAndFocuses() {
        let a = PaneID()
        let endpoint = VideoEndpoint(windowID: 99, title: "Xcode", appName: "Xcode")
        let item = CanvasItem(
            id: a,
            spec: PaneSpec(kind: .remoteGUI, title: "My Xcode", video: endpoint),
            frame: CGRect(x: 50, y: 50, width: 640, height: 400), z: 0
        )
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [item]), focusedPane: a))
        let gid = store.addGroup(name: "G")
        store.assignPane(a, toGroup: gid)

        let dup = store.duplicatePane(a)

        let id = try! XCTUnwrap(dup)
        XCTAssertNotEqual(id, a)
        let spec = store.workspace.canvas.spec(for: id)
        XCTAssertEqual(spec?.title, "My Xcode")
        XCTAssertEqual(spec?.kind, .remoteGUI)
        XCTAssertEqual(spec?.video, endpoint, "a committed endpoint duplicates — the copy is pre-bound")
        XCTAssertEqual(store.workspace.canvas.frame(of: id)?.size, CGSize(width: 640, height: 400),
                       "duplicate keeps the ORIGINAL's size, not the default")
        XCTAssertNotEqual(store.workspace.canvas.frame(of: id)?.origin,
                          store.workspace.canvas.frame(of: a)?.origin,
                          "cascaded beside the original, not on top of it")
        XCTAssertEqual(store.workspace.canvas.item(id)?.groupID, gid)
        XCTAssertEqual(store.focusedPane, id)
        XCTAssertNotNil(store.handle(for: id))
    }

    func testEphemeralPaneDoesNotDuplicate() {
        let store = makeStore()
        let dialogID = store.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "auth", isSecure: true)
        XCTAssertNil(store.duplicatePane(dialogID))
    }

    func testApplyDuplicateActsOnFocusedPane() {
        let store = makeStore()   // default workspace: one terminal, focused
        let before = store.workspace.canvas.items.count
        apply(.duplicatePane, to: store)
        XCTAssertEqual(store.workspace.canvas.items.count, before + 1)
    }
}
