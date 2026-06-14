import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins portable workspace export / import: the round-trip preserves the layout, the host connection is
/// stripped on export and never adopted on import, a hostile / foreign / future file is rejected with the
/// live workspace untouched, ephemeral panes never ship, and the registry==canvas invariant holds after a
/// replace. The file-picker chrome is the only GUI part; the codec + replace path are all here.
@MainActor
final class WorkspaceTransferTests: XCTestCase {
    private func store(_ items: [CanvasItem], focus: PaneID, connection: ConnectionTarget? = nil) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: items), focusedPane: focus, connection: connection),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    private func term(_ x: CGFloat, _ title: String) -> CanvasItem {
        CanvasItem(
            id: PaneID(),
            spec: PaneSpec(kind: .terminal, title: title),
            frame: CGRect(x: x, y: 0, width: 300, height: 200),
            z: 0,
        )
    }

    func testExportImportRoundTripPreservesLayout() {
        let a = term(0, "alpha"), b = term(400, "beta")
        let src = store([a, b], focus: a.id)
        let g = src.addGroup(name: "work")
        src.assignPane(a.id, toGroup: g)
        src.addSnippet(name: "deploy", body: "make deploy<Enter>")
        let data = src.exportWorkspaceData()

        // A fresh store (its own single default pane) imports the document, REPLACING its canvas.
        let dst = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
        XCTAssertTrue(dst.importWorkspace(data))

        XCTAssertEqual(
            Set(dst.workspace.canvas.allIDs().compactMap { dst.workspace.canvas.spec(for: $0)?.title }),
            ["alpha", "beta"],
            "both panes restored (by title; ids are re-minted)",
        )
        XCTAssertEqual(dst.workspace.groups.map(\.name), ["work"], "the group survives")
        XCTAssertEqual(dst.snippets.first?.name, "deploy", "snippets survive the round trip")
    }

    func testExportStripsHostConnection() {
        let a = term(0, "a")
        let src = store(
            [a],
            focus: a.id,
            connection: ConnectionTarget(
                host: "secret.host",
                port: 7420,
                mediaPort: 9000,
                cursorPort: 9001,
            ),
        )
        let decoded = WorkspaceTransfer.decode(src.exportWorkspaceData())
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.connection, "the host:port is never written into a shareable document")
    }

    func testImportKeepsLocalConnectionNotTheFiles() {
        let a = term(0, "a")
        let src = store(
            [a],
            focus: a.id,
            connection: ConnectionTarget(host: "stranger", port: 1, mediaPort: 2, cursorPort: 3),
        )
        let data = src.exportWorkspaceData()
        let local = ConnectionTarget(host: "mine", port: 7420, mediaPort: 9000, cursorPort: 9001)
        let dst = store([term(0, "x")], focus: PaneID(), connection: local)
        XCTAssertTrue(dst.importWorkspace(data))
        XCTAssertEqual(dst.workspace.connection, local, "the importer keeps its OWN host, never the file's")
    }

    func testHostileDataIsRejectedAndLeavesWorkspaceUntouched() {
        let a = term(0, "keep")
        let st = store([a], focus: a.id)
        let before = st.workspace.canvas.allIDs()
        XCTAssertFalse(st.importWorkspace(Data("not a workspace".utf8)), "garbage is rejected")
        XCTAssertFalse(st.importWorkspace(Data()), "empty data is rejected")
        XCTAssertEqual(st.workspace.canvas.allIDs(), before, "a rejected import leaves the live workspace intact")
    }

    func testWrongMagicAndFutureFormatRejected() throws {
        let ws = Workspace(canvas: Canvas(items: [term(0, "a")]), focusedPane: nil)
        // Wrong magic.
        let bad = WorkspaceTransfer.Document(format: "evil.format", formatVersion: 1, workspace: ws)
        XCTAssertNil(try WorkspaceTransfer.decode(JSONEncoder().encode(bad)))
        // Future format version this build can't promise to read.
        let future = WorkspaceTransfer.Document(format: WorkspaceTransfer.magic, formatVersion: 99, workspace: ws)
        XCTAssertNil(try WorkspaceTransfer.decode(JSONEncoder().encode(future)))
    }

    func testImportMaintainsRegistryEqualsCanvasInvariant() {
        let a = term(0, "a"), b = term(400, "b")
        let src = store([a, b], focus: a.id)
        let data = src.exportWorkspaceData()
        let dst = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
        XCTAssertTrue(dst.importWorkspace(data))
        // The load-bearing invariant: every live canvas leaf has a materialized handle, and vice versa.
        for id in dst.workspace.canvas.allIDs() {
            XCTAssertNotNil(dst.handle(for: id), "every imported leaf materialized a session")
        }
    }

    func testSameSessionReimportPreservesFocusAndBookmarkAnchors() {
        // Self-review fix: exporting the live workspace then re-importing it into the SAME session collides
        // EVERY pane id, so all are re-minted. Without an id-map, focus reset to pane-0 and bookmarks
        // dangled. The id-map must carry focus + bookmark anchors through the re-mint.
        let a = term(0, "alpha"), b = term(400, "beta")
        let st = store([a, b], focus: a.id)
        st.focus(b.id)
        st.saveBookmark(1) // bookmark 1 anchors to the focused pane (B)
        XCTAssertEqual(st.workspace.bookmarks[1]?.pane, b.id, "precondition: bookmark anchored to B")

        let data = st.exportWorkspaceData()
        XCTAssertTrue(st.importWorkspace(data), "re-import into the SAME store")

        XCTAssertEqual(
            st.workspace.focusedPane.flatMap { st.workspace.canvas.spec(for: $0)?.title },
            "beta",
            "focus follows the re-mint (it reset to pane-0 before the id-map fix)",
        )
        guard let anchor = st.workspace.bookmarks[1]?.pane else { XCTFail("bookmark anchor lost")
            return
        }
        XCTAssertTrue(st.workspace.canvas.contains(anchor), "the bookmark anchor maps to a live re-minted pane")
        XCTAssertEqual(st.workspace.canvas.spec(for: anchor)?.title, "beta", "anchor still points at beta")
    }

    func testMergeAppendAddsImportedPanesBesideExistingAndUnionsSnippets() {
        let src = store([term(0, "alpha"), term(400, "beta")], focus: PaneID())
        src.addSnippet(name: "deploy", body: "make deploy<Enter>")
        let data = src.exportWorkspaceData()

        let dst = store([term(0, "keep")], focus: PaneID())
        dst.addSnippet(name: "deploy", body: "other<Enter>") // a name collision to exercise the suffix
        XCTAssertTrue(dst.importWorkspace(data, mode: .mergeAppend))

        let titles = Set(dst.workspace.canvas.allIDs().compactMap { dst.workspace.canvas.spec(for: $0)?.title })
        XCTAssertEqual(titles, ["keep", "alpha", "beta"], "merge keeps the existing pane and adds the imported ones")
        XCTAssertEqual(
            Set(dst.snippets.map(\.name)),
            ["deploy", "deploy copy"],
            "a snippet name collision gets a ‘copy’ suffix",
        )
        for id in dst.workspace.canvas.allIDs() {
            XCTAssertNotNil(dst.handle(for: id), "registry==canvas holds after a merge (every pane materialized)")
        }
    }

    // MARK: - Hostile-document hardening (final convergence hunt)

    func testHostileMaxZIsClampedAndDoesNotCrashOnNextAddPane() throws {
        // A doc whose item carries z = Int.max survives decode if z isn't clamped, then the next maxZ+1
        // (addPane / raise) traps Swift's checked arithmetic → crash. The clamp neutralizes it.
        let hostile = CanvasItem(
            id: PaneID(),
            spec: PaneSpec(kind: .terminal, title: "z"),
            frame: CGRect(x: 0, y: 0, width: 300, height: 200),
            z: Int.max,
        )
        let data = WorkspaceTransfer.export(Workspace(canvas: Canvas(items: [hostile]), focusedPane: nil))
        guard let decoded = WorkspaceTransfer.decode(data) else { XCTFail("should decode")
            return
        }
        XCTAssertLessThan(try XCTUnwrap(decoded.canvas.items.first?.z), Int.max, "z is clamped on decode")

        let st = store([term(0, "x")], focus: PaneID())
        XCTAssertTrue(st.importWorkspace(data, mode: .replace))
        st.addPane(kind: .terminal) // computes maxZ+1 — must NOT trap
        XCTAssertGreaterThanOrEqual(st.workspace.canvas.allIDs().count, 2, "add-pane after a hostile import is safe")
    }

    func testDuplicateGroupIDIsDroppedOnDecode() {
        let g = PaneGroupID()
        let ws = Workspace(
            canvas: Canvas(items: [term(0, "a")]),
            focusedPane: nil,
            groups: [PaneGroup(id: g, name: "A"), PaneGroup(id: g, name: "B")],
        )
        guard let decoded = WorkspaceTransfer.decode(WorkspaceTransfer.export(ws)) else { XCTFail()
            return
        }
        XCTAssertEqual(
            decoded.groups.count,
            1,
            "a duplicate group id is dropped (keep first) — no ForEach id collision",
        )
    }

    func testDuplicateSnippetIDsAreRemintedOnDecode() {
        let sid = UUID()
        let ws = Workspace(
            canvas: Canvas(items: [term(0, "a")]),
            focusedPane: nil,
            snippets: [Snippet(id: sid, name: "x", body: "a"), Snippet(id: sid, name: "y", body: "b")],
        )
        guard let decoded = WorkspaceTransfer.decode(WorkspaceTransfer.export(ws)) else { XCTFail()
            return
        }
        XCTAssertEqual(
            Set(decoded.snippets.map(\.id)).count,
            2,
            "snippet ids are re-minted so palette entry ids can't collide",
        )
    }

    func testOversizedDocumentIsRejected() {
        let items = (0...WorkspaceTransfer.maxItems).map { term(CGFloat($0) * 10, "p\($0)") } // maxItems + 1
        let ws = Workspace(canvas: Canvas(items: items), focusedPane: nil)
        XCTAssertNil(
            WorkspaceTransfer.decode(WorkspaceTransfer.export(ws)),
            "a document beyond the item cap is rejected (import DoS guard)",
        )
    }

    func testOversizedBookmarksAreRejected() {
        // The bookmarks dictionary is the same untrusted-input surface as items/groups/snippets — a
        // hand-edited document with a huge bookmark map must be rejected, not iterated on the main actor.
        let bookmarks = Dictionary(uniqueKeysWithValues:
            (0...WorkspaceTransfer.maxItems)
                .map { ($0, CanvasBookmark(pane: nil, cameraOrigin: .zero, name: "b\($0)")) })
        let ws = Workspace(canvas: Canvas(items: [term(0, "a")]), focusedPane: nil, bookmarks: bookmarks)
        XCTAssertNil(
            WorkspaceTransfer.decode(WorkspaceTransfer.export(ws)),
            "a document beyond the bookmark cap is rejected (import DoS guard)",
        )
    }

    func testOutOfRangeBookmarkSlotsAreDropped() {
        // Bookmarks live in slots 1…9; a junk slot is dead weight (unreachable from ⌘1…⌘9) and is
        // filtered out on import so only reachable bookmarks survive.
        let bookmarks: [Int: CanvasBookmark] = [
            1: CanvasBookmark(pane: nil, cameraOrigin: .zero, name: "valid"),
            0: CanvasBookmark(pane: nil, cameraOrigin: .zero, name: "zero"),
            42: CanvasBookmark(pane: nil, cameraOrigin: .zero, name: "junk"),
        ]
        let ws = Workspace(canvas: Canvas(items: [term(0, "a")]), focusedPane: nil, bookmarks: bookmarks)
        guard let decoded = WorkspaceTransfer.decode(WorkspaceTransfer.export(ws)) else { XCTFail()
            return
        }
        XCTAssertEqual(Set(decoded.bookmarks.keys), [1], "only the in-range (1…9) slot survives import")
    }

    func testMergeRejectedWhenCombinedCanvasExceedsCap() {
        // A live workspace near the cap + a sizable import must not assemble a canvas past maxItems — that
        // is what reconcile() would materialize as live sessions. The merge is rejected and the live
        // workspace is left exactly as it was.
        let liveItems = (0..<(WorkspaceTransfer.maxItems - 1)).map { term(CGFloat($0), "live\($0)") }
        let dst = store(liveItems, focus: liveItems[0].id)
        let before = dst.workspace.canvas.allIDs().count

        // A small valid import (5 panes) that would push the combined total past the cap.
        let importItems = (0..<5).map { term(CGFloat($0) * 10, "imp\($0)") }
        let importData = WorkspaceTransfer.export(Workspace(canvas: Canvas(items: importItems), focusedPane: nil))

        XCTAssertFalse(
            dst.importWorkspace(importData, mode: .mergeAppend),
            "a merge that would exceed maxItems is rejected",
        )
        XCTAssertEqual(dst.workspace.canvas.allIDs().count, before, "the live canvas is untouched on a rejected merge")
    }

    func testRejectedMergeCommitsInFlightScrollPanInsteadOfDroppingIt() {
        // A rejected merge must truly leave the view "untouched" — importWorkspace runs the scroll-flush
        // BEFORE it can bail, so it must COMMIT the in-flight pan (fold it into the camera), not DISCARD it
        // (which snapped the canvas back to the pre-scroll origin).
        let liveItems = (0..<(WorkspaceTransfer.maxItems - 1)).map { term(CGFloat($0), "live\($0)") }
        let dst = store(liveItems, focus: liveItems[0].id)
        let origin0 = dst.workspace.canvas.camera.origin
        dst.scrollPan(by: CGSize(width: 120, height: 80)) // sets liveCameraOffset; debounced commit pending
        XCTAssertNotEqual(dst.liveCameraOffset, .zero, "the pan is live (uncommitted) before the import")

        let importData = WorkspaceTransfer.export(
            Workspace(canvas: Canvas(items: (0..<5).map { term(CGFloat($0) * 10, "imp\($0)") }), focusedPane: nil),
        )
        XCTAssertFalse(dst.importWorkspace(importData, mode: .mergeAppend), "the over-cap merge is rejected")

        XCTAssertEqual(dst.liveCameraOffset, .zero, "the pending pan was flushed by the import")
        XCTAssertNotEqual(
            dst.workspace.canvas.camera.origin,
            origin0,
            "the pan was COMMITTED into the camera, not discarded (no silent snap-back)",
        )
    }

    func testMergeWithinCapStillSucceeds() {
        // Positive control: the cap does not block a normal merge.
        let dst = store([term(0, "live")], focus: PaneID())
        let importData = WorkspaceTransfer.export(
            Workspace(canvas: Canvas(items: [term(100, "imp")]), focusedPane: nil),
        )
        XCTAssertTrue(dst.importWorkspace(importData, mode: .mergeAppend), "an in-cap merge succeeds")
        XCTAssertEqual(dst.workspace.canvas.allIDs().count, 2, "both panes present after a normal merge")
    }

    func testMergeAdoptsAnchoredBookmarksButDropsForeignFrameCameraBookmarks() throws {
        // A merged bookmark whose anchor pane survives the id remap is followable (recall re-derives the
        // camera from the live pane) → adopt it. A bookmark with NO surviving anchor (pane == nil, or a pane
        // absent from the import) keeps a cameraOrigin in the IMPORTED frame while the merged canvas is in the
        // live frame → recalling it would pan into the void. Drop those, mirroring switchToLayoutPreset.
        let dst = store([term(0, "live")], focus: PaneID())
        let impPane = term(100, "imp")
        let importWS = Workspace(
            canvas: Canvas(items: [impPane]), focusedPane: nil,
            bookmarks: [
                1: CanvasBookmark(pane: impPane.id, cameraOrigin: CGPoint(x: 5000, y: 5000), name: "anchored"),
                2: CanvasBookmark(pane: nil, cameraOrigin: CGPoint(x: 9999, y: 9999), name: "pure-camera"),
            ],
        )
        XCTAssertTrue(dst.importWorkspace(WorkspaceTransfer.export(importWS), mode: .mergeAppend))

        guard let adopted = dst.workspace.bookmarks[1] else { XCTFail("the anchored bookmark is adopted")
            return
        }
        XCTAssertNotNil(adopted.pane, "the adopted bookmark keeps a (remapped) anchor")
        XCTAssertTrue(try dst.workspace.canvas.contains(XCTUnwrap(adopted.pane)), "the adopted anchor is a LIVE pane")
        XCTAssertNil(dst.workspace.bookmarks[2], "the foreign-frame pure-camera bookmark is dropped, not adopted")
    }

    func testMergeRejectedWhenCombinedGroupsExceedCapElseNextLaunchWipesEverything() {
        // DATA-LOSS REGRESSION: mergeAppend used to cap ONLY the canvas, so a merge that pushed the combined
        // groups (or snippets, or presets) past maxItems produced an over-cap workspace that worked this
        // session — then load() (which guards EACH side collection <= maxItems) discarded the ENTIRE
        // workspace to the default on the next launch. The merge must reject symmetrically, leaving the live
        // workspace untouched, so what is persisted always survives a reload.
        let liveGroups = (0..<(WorkspaceTransfer.maxItems - 1)).map { PaneGroup(id: PaneGroupID(), name: "g\($0)") }
        let live = Workspace(canvas: Canvas(items: [term(0, "live")]), focusedPane: nil, groups: liveGroups)
        let dst = WorkspaceStore(restoring: live, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
        let beforeGroups = dst.workspace.groups.count

        // A small valid import (5 groups) that would push the combined group count past the cap.
        let importGroups = (0..<5).map { PaneGroup(id: PaneGroupID(), name: "imp\($0)") }
        let importData = WorkspaceTransfer.export(
            Workspace(canvas: Canvas(items: [term(100, "imp")]), focusedPane: nil, groups: importGroups),
        )

        XCTAssertFalse(
            dst.importWorkspace(importData, mode: .mergeAppend),
            "a merge that would exceed maxItems groups is rejected",
        )
        XCTAssertEqual(dst.workspace.groups.count, beforeGroups, "the live groups are untouched on a rejected merge")
        // The invariant the rejection protects: whatever the merge leaves behind must itself survive a reload
        // (i.e. obey the same per-collection cap decode() enforces).
        XCTAssertLessThanOrEqual(
            dst.workspace.groups.count,
            WorkspaceTransfer.maxItems,
            "the persisted workspace never exceeds the cap load() would reject",
        )
    }

    func testUniqueNameSuffixing() {
        XCTAssertEqual(WorkspaceStore.uniqueName(base: "work", existing: []), "work")
        XCTAssertEqual(WorkspaceStore.uniqueName(base: "work", existing: ["work"]), "work copy")
        XCTAssertEqual(WorkspaceStore.uniqueName(base: "work", existing: ["work", "work copy"]), "work copy 2")
        XCTAssertEqual(
            WorkspaceStore.uniqueName(base: "work", existing: ["work", "work copy", "work copy 2"]),
            "work copy 3",
        )
    }

    func testEphemeralPanesNeverExported() throws {
        let a = term(0, "a")
        let src = store([a], focus: a.id)
        src.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "Authenticate", isSecure: true)
        let decoded = WorkspaceTransfer.decode(src.exportWorkspaceData())
        XCTAssertNotNil(decoded)
        XCTAssertFalse(
            try XCTUnwrap(decoded?.canvas.allIDs().contains { decoded!.canvas.spec(for: $0)?.kind == .systemDialog }),
            "an ephemeral system-dialog pane is stripped from the export",
        )
    }
}
