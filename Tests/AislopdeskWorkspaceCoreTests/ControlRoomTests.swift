import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// Control Room (design-craft big-swing B): the pure grid solver + the store's overview state machine
/// + the ⌘⇧M routing.
final class ControlRoomLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testEmptyAndDegenerateProduceNoSlots() {
        XCTAssertEqual(ControlRoomLayout.slots(count: 0, in: bounds), [])
        XCTAssertEqual(ControlRoomLayout.slots(count: 3, in: .zero), [])
        XCTAssertEqual(ControlRoomLayout.slots(count: 400, in: CGRect(x: 0, y: 0, width: 40, height: 40)), [])
    }

    func testSingleTabGetsOneCentredAspectSlot() throws {
        let slots = ControlRoomLayout.slots(count: 1, in: bounds)
        XCTAssertEqual(slots.count, 1)
        let slot = try XCTUnwrap(slots.first)
        // Canvas aspect preserved (uniform scale).
        XCTAssertEqual(slot.width / slot.height, bounds.width / bounds.height, accuracy: 0.001)
        // Centred.
        XCTAssertEqual(slot.midX, bounds.midX, accuracy: 0.5)
        XCTAssertEqual(slot.midY, bounds.midY, accuracy: 0.5)
    }

    func testAllSlotsShareOneScaleAndNeverOverlap() {
        for count in [2, 3, 4, 5, 7, 9] {
            let slots = ControlRoomLayout.slots(count: count, in: bounds)
            XCTAssertEqual(slots.count, count)
            let widths = Set(slots.map { ($0.width * 100).rounded() })
            XCTAssertEqual(widths.count, 1, "uniform scale for count \(count)")
            for (i, a) in slots.enumerated() {
                XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(a), "slot \(i) inside bounds")
                for b in slots.dropFirst(i + 1) {
                    XCTAssertFalse(a.intersects(b), "slots must not overlap (count \(count))")
                }
            }
        }
    }

    func testLastRowStragglersAreCentred() throws {
        // 3 tabs in a 2-col grid: the lone straggler on row 2 sits centred, not left-packed.
        let slots = ControlRoomLayout.slots(count: 3, in: bounds)
        let straggler = try XCTUnwrap(slots.last)
        XCTAssertEqual(straggler.midX, bounds.midX, accuracy: 0.5)
    }
}

@MainActor
final class ControlRoomStoreTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    func testToggleFlipsAndRouteDrivesIt() {
        let store = makeStore()
        XCTAssertFalse(store.controlRoomActive)
        WorkspaceBindingRegistry.route(.controlRoom, to: store)
        XCTAssertTrue(store.controlRoomActive, "⌘⇧M routes to the overview toggle")
        WorkspaceBindingRegistry.route(.controlRoom, to: store)
        XCTAssertFalse(store.controlRoomActive)
    }

    func testLeaveWithoutSelectionJustExits() {
        let store = makeStore()
        let before = store.tree.activeSession?.activeTab?.id
        store.toggleControlRoom()
        store.leaveControlRoom()
        XCTAssertFalse(store.controlRoomActive)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, before, "Esc must not change the tab")
    }

    func testLeaveSelectingTabInActiveSessionSwitchesTab() throws {
        let store = makeStore()
        store.newTab(kind: .terminal)
        let tabs = try XCTUnwrap(store.tree.activeSession?.tabs)
        XCTAssertGreaterThanOrEqual(tabs.count, 2)
        let first = tabs[0].id
        XCTAssertNotEqual(store.tree.activeSession?.activeTab?.id, first)
        store.toggleControlRoom()
        store.leaveControlRoom(selecting: first)
        XCTAssertFalse(store.controlRoomActive)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, first, "card click flies into its tab")
    }

    func testLeaveSelectingRetainedOtherSessionsTabActivatesThatSession() throws {
        let store = makeStore()
        let firstSession = try XCTUnwrap(store.tree.activeSessionID)
        let firstTab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        store.newSession(name: "second", kind: .terminal)
        XCTAssertNotEqual(store.tree.activeSessionID, firstSession)
        store.toggleControlRoom()
        store.leaveControlRoom(selecting: firstTab)
        XCTAssertEqual(store.tree.activeSessionID, firstSession, "cross-session card activates its owner")
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, firstTab)
        XCTAssertFalse(store.controlRoomActive)
    }
}
