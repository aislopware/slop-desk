import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins broadcast / synchronized input (tmux `synchronize-panes`): the target resolver (multi-selection /
/// focused group / focused-alone, restricted to text-capable kinds), the fan-out that types one string
/// into every target exactly once with the video panes skipped, the arm toggle + apply() routing, and the
/// ⇧⌘B chord. The on-device feel (N libghostty echoes) is HW; the routing/targeting core is all here.
@MainActor
final class BroadcastInputTests: XCTestCase {
    private func store(_ items: [CanvasItem], focus: PaneID) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: items), focusedPane: focus),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    private func term(_ x: CGFloat) -> CanvasItem {
        CanvasItem(
            id: PaneID(),
            spec: PaneSpec(kind: .terminal, title: "t"),
            frame: CGRect(x: x, y: 0, width: 300, height: 200),
            z: 0,
        )
    }

    private func sent(_ store: WorkspaceStore, _ id: PaneID) -> [String] {
        (store.handle(for: id) as? FakePaneSession)?.sentText ?? []
    }

    func testBroadcastTextFansToEverySelectedTerminalExactlyOnce() {
        let a = term(0), b = term(400), c = term(800)
        let st = store([a, b, c], focus: a.id)
        st.setSelection([a.id, b.id]) // ≥2 selected → the selection is the target set
        let n = st.broadcastText("uptime\r")
        XCTAssertEqual(n, 2)
        XCTAssertEqual(sent(st, a.id), ["uptime\r"])
        XCTAssertEqual(sent(st, b.id), ["uptime\r"])
        XCTAssertEqual(sent(st, c.id), [], "an unselected pane receives nothing")
    }

    func testBroadcastSkipsVideoPanesWithNoTextFunnel() {
        let a = term(0)
        let v = CanvasItem(
            id: PaneID(),
            spec: PaneSpec(
                kind: .remoteGUI,
                title: "v",
                video: VideoEndpoint(windowID: 1, title: "v", appName: ""),
            ),
            frame: CGRect(x: 400, y: 0, width: 300, height: 200),
            z: 1,
        )
        let st = store([a, v], focus: a.id)
        st.setSelection([a.id, v.id])
        let n = st.broadcastText("ls\r")
        XCTAssertEqual(n, 1, "only the text-capable pane is a target")
        XCTAssertEqual(sent(st, a.id), ["ls\r"])
        XCTAssertEqual(sent(st, v.id), [], "a video pane has no text funnel")
    }

    func testTargetsAreTheFocusedPanesWholeGroupWhenNothingSelected() {
        let a = term(0), b = term(400), c = term(800), d = term(1200)
        let st = store([a, b, c, d], focus: a.id)
        let g = st.addGroup(name: "G")
        st.assignPane(a.id, toGroup: g)
        st.assignPane(b.id, toGroup: g)
        st.assignPane(c.id, toGroup: g)
        st.focus(a.id) // a grouped member is focused, no multi-selection
        XCTAssertEqual(
            Set(st.broadcastTargets()),
            Set([a.id, b.id, c.id]),
            "the focused pane's whole group is the target set",
        )
        XCTAssertFalse(st.broadcastTargets().contains(d.id), "a pane outside the group is excluded")
    }

    func testTargetsFallBackToTheFocusedPaneAloneWhenUngroupedAndUnselected() {
        let a = term(0), b = term(400)
        let st = store([a, b], focus: a.id)
        XCTAssertEqual(st.broadcastTargets(), [a.id])
    }

    func testToggleBroadcastFlipsAndApplyRoutesIt() {
        let a = term(0)
        let st = store([a], focus: a.id)
        XCTAssertFalse(st.broadcastActive, "disarmed by default (never persisted)")
        st.toggleBroadcast()
        XCTAssertTrue(st.broadcastActive)
        apply(.toggleBroadcast, to: st) // the menu / keyboard / palette chokepoint
        XCTAssertFalse(st.broadcastActive, "apply(.toggleBroadcast) routes to toggleBroadcast()")
    }

    func testBroadcastChordIsBound() {
        let interp = CommandInterpreter()
        XCTAssertEqual(interp.feed(KeyChord(character: "b", [.command, .shift])), .toggleBroadcast)
    }

    // MARK: - Live fan-out tap (fanBroadcastInput): the keystroke-mirroring path

    private func bytes(_ store: WorkspaceStore, _ id: PaneID) -> [[UInt8]] {
        (store.handle(for: id) as? FakePaneSession)?.sentBytes ?? []
    }

    func testFanMirrorsSourceKeystrokesToEverySiblingButNotTheSource() {
        let a = term(0), b = term(400), c = term(800)
        let st = store([a, b, c], focus: a.id)
        st.setSelection([a.id, b.id, c.id])
        st.setBroadcast(true)
        // Pane `a` is the source (where the surface keystroke was typed + already delivered locally).
        let reached = st.fanBroadcastInput(from: a.id, Data("x".utf8))
        XCTAssertEqual(reached, 2, "two siblings reached")
        XCTAssertEqual(bytes(st, a.id), [], "the source is NOT re-sent (its own sendInput delivered it)")
        XCTAssertEqual(bytes(st, b.id), [Array("x".utf8)])
        XCTAssertEqual(bytes(st, c.id), [Array("x".utf8)])
    }

    func testFanIsInertWhenDisarmed() {
        let a = term(0), b = term(400)
        let st = store([a, b], focus: a.id)
        st.setSelection([a.id, b.id])
        // broadcast NOT armed
        XCTAssertEqual(st.fanBroadcastInput(from: a.id, Data("x".utf8)), 0)
        XCTAssertEqual(bytes(st, b.id), [])
    }

    func testFanIsInertWhenSourceIsNotATarget() {
        // ≥2 selected → the SELECTION is the target set; a focused-but-unselected pane typing must not fan.
        let a = term(0), b = term(400), c = term(800)
        let st = store([a, b, c], focus: c.id)
        st.setSelection([a.id, b.id]) // c is the source but not a target
        st.setBroadcast(true)
        XCTAssertEqual(
            st.fanBroadcastInput(from: c.id, Data("x".utf8)),
            0,
            "typing in a pane outside the broadcast group does not fan",
        )
        XCTAssertEqual(bytes(st, a.id), [])
        XCTAssertEqual(bytes(st, b.id), [])
    }

    func testFanIsInertForASingleTargetAndForEmptyData() {
        let a = term(0)
        let st = store([a], focus: a.id)
        st.setBroadcast(true)
        XCTAssertEqual(st.fanBroadcastInput(from: a.id, Data("x".utf8)), 0, "one target has no siblings")
        let a2 = term(0), b2 = term(400)
        let st2 = store([a2, b2], focus: a2.id)
        st2.setSelection([a2.id, b2.id])
        st2.setBroadcast(true)
        XCTAssertEqual(st2.fanBroadcastInput(from: a2.id, Data()), 0, "empty data is a no-op")
        XCTAssertEqual(bytes(st2, b2.id), [])
    }

    func testReentrancyGuardPreventsCrossFanStorm() {
        // The production loop: mirroring into a sibling re-enters that sibling's sendInput → broadcastTap →
        // fanBroadcastInput. Without the guard, every keystroke would cross-multiply across the group.
        let a = term(0), b = term(400), c = term(800)
        let st = store([a, b, c], focus: a.id)
        st.setSelection([a.id, b.id, c.id])
        st.setBroadcast(true)
        // Make every sibling RE-FAN the moment it receives bytes (what a live sibling's tap would attempt).
        for id in [a.id, b.id, c.id] {
            (st.handle(for: id) as? FakePaneSession)?.onSendBytes = { [weak st] who, payload in
                _ = st?.fanBroadcastInput(from: who.id, Data(payload))
            }
        }
        let reached = st.fanBroadcastInput(from: a.id, Data("x".utf8))
        XCTAssertEqual(reached, 2, "the outer fan reaches exactly the two siblings")
        // Each sibling received the keystroke EXACTLY once — the guard collapsed the re-entrant re-fans.
        XCTAssertEqual(bytes(st, b.id), [Array("x".utf8)])
        XCTAssertEqual(bytes(st, c.id), [Array("x".utf8)])
    }
}
