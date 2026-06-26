import AislopdeskTransport
import Defaults
import XCTest
@testable import AislopdeskClient
@testable import AislopdeskWorkspaceCore

/// E12 WI-6 (ES-E12-4) — the Composer PIN is persisted PER-PANE (keyed by the stable leaf ``PaneID``, which
/// survives the persistence round-trip), NOT as a single global Bool. So a fresh launch re-pins exactly the
/// pane that was pinned, and toggling the pin in one pane never pins another. Entirely headless: the session's
/// transport factory is inert (never connected) and the only side effect is the `Defaults` pin set, which is
/// cleared around each test.
@MainActor
final class ComposerPinPersistenceTests: XCTestCase {
    /// An inert client factory (never connected — these tests drive `adopt` + the pin verbs directly).
    private static let makeUnconnectedClient: @Sendable () -> AislopdeskClient = {
        AislopdeskClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw AislopdeskTransportError.notConnected("inert test transport") },
                release: { _, _, _ in },
            )
        })
    }

    private func makeSession() -> LivePaneSession {
        LivePaneSession.make(
            PaneSpec(kind: .terminal, title: "term"),
            makeClient: Self.makeUnconnectedClient,
            makeInspector: { _ in nil },
        )
    }

    override func setUp() {
        super.setUp()
        Defaults[.composerPinnedPaneIDs] = [] // start from a clean persisted set
    }

    override func tearDown() {
        Defaults[.composerPinnedPaneIDs] = [] // never leak the pin set into other tests
        super.tearDown()
    }

    /// A persisted pin re-pins the RIGHT pane on a fresh store (the session adopts its leaf id at
    /// materialization), and a DIFFERENT pane is left unpinned — proving the persistence is per-pane, not a
    /// global flag. The restored pin also opens the bar so it visibly rides along.
    /// REVERT-TO-CONFIRM-FAIL: without the restore in `LivePaneSession.adopt`, `composer.isPinned` stays false.
    func testPersistedPinRePinsTheRightPaneOnAdopt() throws {
        let pinnedID = PaneID()
        let otherID = PaneID()
        SettingsKey.setComposerPinned(true, paneID: pinnedID)

        let pinned = makeSession()
        pinned.adopt(id: pinnedID)
        let pinnedComposer = try XCTUnwrap(pinned.composer)
        XCTAssertTrue(pinnedComposer.isPinned, "the persisted pane re-pins on materialization")
        XCTAssertTrue(pinnedComposer.isVisible, "a restored pin opens the bar so it visibly rides along")

        let other = makeSession()
        other.adopt(id: otherID)
        XCTAssertEqual(other.composer?.isPinned, false, "a different pane is NOT pinned (per-pane, not global)")
    }

    /// Toggling the pin AFTER adoption persists it for THIS pane (via the wired `onPinnedChange`), and
    /// unpinning removes the persisted entry — so the persisted set is the live source of truth across panes.
    func testTogglingPinPersistsPerPaneAndUnpinClears() throws {
        let id = PaneID()
        let session = makeSession()
        session.adopt(id: id)
        let composer = try XCTUnwrap(session.composer)
        XCTAssertFalse(SettingsKey.isComposerPinned(paneID: id), "not pinned at first")

        composer.togglePin()
        XCTAssertTrue(SettingsKey.isComposerPinned(paneID: id), "toggling the pin persists it for this pane")

        composer.togglePin()
        XCTAssertFalse(SettingsKey.isComposerPinned(paneID: id), "unpinning removes the persisted entry")
    }

    /// Closing a pane (the orphan/`teardown()` seam — `WorkspaceStore.reconcile` drops a leaf no longer in
    /// the tree) PRUNES that pane's persisted pin, so a closed pane's dead `PaneID` can't accumulate in the
    /// set unbounded. REVERT-TO-CONFIRM-FAIL: without the `setComposerPinned(false,…)` in
    /// `LivePaneSession.teardown`, the pin survives the close and this final assert fails.
    func testTeardownPrunesPersistedPinForClosedPane() async throws {
        let id = PaneID()
        SettingsKey.setComposerPinned(true, paneID: id)

        let session = makeSession()
        session.adopt(id: id)
        try XCTUnwrap(session.composer)
        XCTAssertTrue(SettingsKey.isComposerPinned(paneID: id), "pinned before close")

        await session.teardown()

        XCTAssertFalse(
            SettingsKey.isComposerPinned(paneID: id),
            "closing the pane prunes its dead PaneID from the persisted pin set",
        )
    }

    /// Restoring an unpinned pane neither pins nor re-persists: `adopt` reads the (empty) set, leaves the
    /// composer unpinned, and the wired `onPinnedChange` is the ONLY writer — so a plain materialization
    /// doesn't pollute the persisted set.
    func testAdoptOfUnpinnedPaneLeavesSetEmpty() {
        let id = PaneID()
        let session = makeSession()
        session.adopt(id: id)
        XCTAssertEqual(session.composer?.isPinned, false)
        XCTAssertTrue(Defaults[.composerPinnedPaneIDs].isEmpty, "materializing an unpinned pane writes nothing")
    }
}
