import XCTest
@testable import SlopDeskWorkspaceModel

/// The pane liveness record — the value half of the fix for "the sidebar title degrades to `vi .`".
///
/// Three things are pinned here and each is a bug that has already happened once:
/// 1. ``PaneTitleFreshness`` rule 1 — a title with NO open command block is TRUSTED. The shipped
///    client gate demanded a command-start stamp that a hookless shell never produces.
/// 2. ``HostWorkspaceState/merge(paneLiveness:)`` CLEARS a fact that stopped being true. Writing only
///    the present fields would latch `runningCommand` forever, which is the same
///    "edge published, value retained nowhere" failure one layer up.
/// 3. `nil` (never observed) and `""` (retired) survive a round-trip as DIFFERENT things — an empty
///    type-21 is this codebase's agent-title-ownership retirement signal.
final class PaneLivenessTests: XCTestCase {
    private let paneID = UUID(uuidString: "5D05DE5C-0000-4000-8000-00000000BEEF")!

    // MARK: titleFresh — the four rules of docs/45 §4.4

    func testTitleWithNoOpenCommandBlockIsTrusted() {
        // Rule 1. This is the half of the reported bug a reattach re-assert alone does not fix:
        // Starship and every other hookless prompt emit no OSC 133, so no block ever opens.
        XCTAssertTrue(PaneTitleFreshness.isFresh(
            titleStampedAt: 100,
            commandStartedAt: nil,
            liveness: .attached,
        ))
    }

    func testTitlePredatingTheOpenCommandIsStale() {
        // Rule 2 — the title describes whatever ran BEFORE this command.
        XCTAssertFalse(PaneTitleFreshness.isFresh(
            titleStampedAt: 100,
            commandStartedAt: 200,
            liveness: .attached,
        ))
    }

    func testTitleAtOrAfterTheCommandStartIsFresh() {
        // Rule 3, including the exact-tie boundary: `>=`, not `>`. A shell that stamps the title in
        // the same millisecond it opens the block must not lose it to a strict comparison.
        XCTAssertTrue(PaneTitleFreshness.isFresh(
            titleStampedAt: 200,
            commandStartedAt: 200,
            liveness: .attached,
        ))
        XCTAssertTrue(PaneTitleFreshness.isFresh(
            titleStampedAt: 201,
            commandStartedAt: 200,
            liveness: .attached,
        ))
    }

    func testDeadPaneIsNeverFreshEvenWithNoOpenBlock() {
        // Rule 4 — the reported bug INVERTED. A pane restored from disk has no open block, so rule 1
        // would trust a title belonging to a process that no longer exists, forever: restored
        // scrollback is appended with `control: []` and bypasses `HostOutputSniffer`, so no replayed
        // escape can ever regenerate a corrective type-21.
        XCTAssertFalse(PaneTitleFreshness.isFresh(
            titleStampedAt: 100,
            commandStartedAt: nil,
            liveness: .dead,
        ))
    }

    func testNoTitleIsNotAFreshnessQuestion() {
        XCTAssertFalse(PaneTitleFreshness.isFresh(
            titleStampedAt: nil,
            commandStartedAt: nil,
            liveness: .attached,
        ))
    }

    // MARK: Round-trip

    func testFullRecordRoundTripsThroughEntries() {
        let record = PaneLiveness(
            paneID: paneID,
            liveness: .detached,
            liveTitle: "main.go - NVIM",
            titleFresh: true,
            cwd: "/Volumes/Lacie/Workspace",
            projectKey: "/Volumes/Lacie/Workspace/oss/slop-desk",
            foregroundProcess: "nvim",
            runningCommand: "swift test --filter PaneLiveness",
            agentState: .init(state: 3, kind: 0),
            agentLabel: "Running tests…",
            agentIntent: "wire up the workspace document",
            progress: .init(state: 1, percent: 62),
            commandRunning: true,
            lastExitCode: -9,
            lastDurationMS: 12345,
            grid: .init(cols: 213, rows: 51),
            completionEpoch: 7,
            lastActivityMS: 1_785_000_000_000,
        )
        let state = HostWorkspaceState(record.entries())
        XCTAssertEqual(PaneLiveness(paneID: paneID, entries: state), record)
    }

    func testNegativeExitCodeSurvivesTheRoundTrip() {
        // A signal-killed child reports a negative code. It rides as the UInt32 bit pattern precisely
        // so there is no sign convention for the two ends to disagree about.
        let record = PaneLiveness(paneID: paneID, lastExitCode: Int32.min)
        let state = HostWorkspaceState(record.entries())
        XCTAssertEqual(PaneLiveness(paneID: paneID, entries: state)?.lastExitCode, Int32.min)
    }

    func testRetiredTitleIsDistinctFromNeverObserved() {
        // `""` is the agent-title-ownership RETIREMENT signal (an empty type-21). If a zero-length
        // value collapsed to "absent", a client would fall back to the previous title and resurrect
        // the dead agent's name on every reconnect.
        let retired = PaneLiveness(paneID: paneID, liveTitle: "")
        let never = PaneLiveness(paneID: paneID, liveTitle: nil)
        XCTAssertNotEqual(retired.entries(), never.entries())
        XCTAssertEqual(
            PaneLiveness(paneID: paneID, entries: HostWorkspaceState(retired.entries()))?.liveTitle,
            "",
        )
        XCTAssertNil(
            PaneLiveness(paneID: paneID, entries: HostWorkspaceState(never.entries()))?.liveTitle,
        )
    }

    func testLivenessIsAlwaysEmittedSoThePaneObjectExists() {
        // An all-default record still produces exactly one entry: without it a live pane with nothing
        // yet observed would have zero entries and simply not be in the document.
        let record = PaneLiveness(paneID: paneID)
        XCTAssertEqual(record.entries().count, 1)
        XCTAssertEqual(record.entries().first?.key.field, WorkspacePaneField.liveness)
        XCTAssertNotNil(PaneLiveness(paneID: paneID, entries: HostWorkspaceState(record.entries())))
    }

    func testAbsentLivenessMeansNoSuchPane() {
        XCTAssertNil(PaneLiveness(paneID: paneID, entries: HostWorkspaceState()))
    }

    func testUnknownLivenessByteDegradesToDeadNotLive() {
        // Rendering a live pane as stale is cosmetic; rendering a dead pane as live is the fake-live
        // bug. A byte from a newer host degrades toward the safe side.
        var state = HostWorkspaceState()
        state.set(WorkspaceKey(.pane, paneID, WorkspacePaneField.liveness), Data([200]))
        XCTAssertEqual(PaneLiveness(paneID: paneID, entries: state)?.liveness, .dead)
    }

    func testMalformedScalarDropsOneFieldNotTheRecord() {
        // These bytes came off a socket. One bad `grid` must not blank the pane's title.
        var state = HostWorkspaceState(PaneLiveness(
            paneID: paneID,
            liveTitle: "main.go - NVIM",
            grid: .init(cols: 80, rows: 24),
        ).entries())
        state.set(WorkspaceKey(.pane, paneID, WorkspacePaneField.grid), Data([0x01, 0x02, 0x03]))
        let decoded = PaneLiveness(paneID: paneID, entries: state)
        XCTAssertNil(decoded?.grid)
        XCTAssertEqual(decoded?.liveTitle, "main.go - NVIM")
    }

    // MARK: Merge

    func testMergeClearsAFactThatStoppedBeingTrue() {
        var state = HostWorkspaceState()
        state.merge(paneLiveness: PaneLiveness(
            paneID: paneID,
            runningCommand: "sleep 300",
            commandRunning: true,
        ))
        XCTAssertNotNil(state[WorkspaceKey(.pane, paneID, WorkspacePaneField.runningCommand)])

        // The command finished. A write-over merge would latch `runningCommand` forever — the exact
        // "edge published, current value retained nowhere" failure, moved one layer up.
        state.merge(paneLiveness: PaneLiveness(paneID: paneID, lastExitCode: 0, lastDurationMS: 300_000))
        XCTAssertNil(state[WorkspaceKey(.pane, paneID, WorkspacePaneField.runningCommand)])
        XCTAssertNil(state[WorkspaceKey(.pane, paneID, WorkspacePaneField.commandRunning)])
        XCTAssertEqual(
            state[WorkspaceKey(.pane, paneID, WorkspacePaneField.lastExitCode)],
            WorkspaceStateCodec.encodeI32(0),
        )
    }

    func testMergeLeavesTopologyFieldsAlone() {
        // A user-authored rename is topology and belongs to an intent, not to the process watcher.
        // A liveness recapture that clobbered it would undo the rename on the next PTY tick.
        var state = HostWorkspaceState()
        let titleKey = WorkspaceKey(.pane, paneID, WorkspacePaneField.title)
        state.set(titleKey, WorkspaceStateCodec.encodeString("deploy"))
        state.set(WorkspaceKey(.pane, paneID, WorkspacePaneField.userRenamed), WorkspaceStateCodec.encodeBool(true))
        state.merge(paneLiveness: PaneLiveness(paneID: paneID, liveTitle: "zsh"))
        XCTAssertEqual(state[titleKey], WorkspaceStateCodec.encodeString("deploy"))
        XCTAssertEqual(
            state[WorkspaceKey(.pane, paneID, WorkspacePaneField.userRenamed)],
            WorkspaceStateCodec.encodeBool(true),
        )
    }

    func testIdenticalMergeReportsNoChange() {
        // Every version bump costs every subscriber a frame. A recapture that observed nothing new
        // must not move `stateNum`, or an idle host churns versions at the poll rate forever.
        var state = HostWorkspaceState()
        let record = PaneLiveness(paneID: paneID, liveTitle: "zsh", cwd: "/tmp", grid: .init(cols: 80, rows: 24))
        XCTAssertTrue(state.merge(paneLiveness: record))
        XCTAssertFalse(state.merge(paneLiveness: record))
        XCTAssertFalse(state.merge(paneLiveness: record))
    }

    func testMergeOfOnePaneDoesNotDisturbAnother() throws {
        var state = HostWorkspaceState()
        let other = try XCTUnwrap(UUID(uuidString: "5D05DE5C-0000-4000-8000-0000000000AA"))
        state.merge(paneLiveness: PaneLiveness(paneID: other, liveTitle: "other"))
        state.merge(paneLiveness: PaneLiveness(paneID: paneID, liveTitle: "mine"))
        XCTAssertEqual(
            state[WorkspaceKey(.pane, other, WorkspacePaneField.liveTitle)],
            WorkspaceStateCodec.encodeString("other"),
        )
    }

    // MARK: Scalar codecs

    func testScalarCodecsRejectAWrongWidthValue() {
        // Strict widths are what stop a mis-numbered field from decoding into a plausible value —
        // every entry is length-prefixed, so nothing else would catch it.
        XCTAssertNil(WorkspaceStateCodec.decodeU8(Data([1, 2])))
        XCTAssertNil(WorkspaceStateCodec.decodeU8(Data()))
        XCTAssertNil(WorkspaceStateCodec.decodeU8Pair(Data([1])))
        XCTAssertNil(WorkspaceStateCodec.decodeU16Pair(Data([1, 2, 3])))
        XCTAssertNil(WorkspaceStateCodec.decodeU32(Data([1, 2, 3])))
        XCTAssertNil(WorkspaceStateCodec.decodeI64(Data([1, 2, 3, 4, 5, 6, 7])))
    }

    func testBoolFollowsTheNonZeroInteropRule() {
        XCTAssertEqual(WorkspaceStateCodec.decodeBool(Data([0])), false)
        XCTAssertEqual(WorkspaceStateCodec.decodeBool(Data([1])), true)
        XCTAssertEqual(WorkspaceStateCodec.decodeBool(Data([0xFF])), true)
    }

    func testI64RoundTripsAtTheExtremes() {
        for value in [Int64.min, -1, 0, 1, Int64.max] {
            XCTAssertEqual(WorkspaceStateCodec.decodeI64(WorkspaceStateCodec.encodeI64(value)), value)
        }
    }

    func testUUIDListRoundTripsAndRejectsAShortBuffer() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(WorkspaceStateCodec.decodeUUIDList(WorkspaceStateCodec.encodeUUIDList(ids)), ids)
        XCTAssertEqual(WorkspaceStateCodec.decodeUUIDList(WorkspaceStateCodec.encodeUUIDList([])), [])
        // Count claims 0xFFFF with no bytes behind it — bounded before any capacity is reserved.
        XCTAssertNil(WorkspaceStateCodec.decodeUUIDList(Data([0xFF, 0xFF])))
        // A trailing partial UUID is a DROP, not a truncated read.
        var short = [UInt8](WorkspaceStateCodec.encodeUUIDList(ids))
        short.removeLast()
        XCTAssertNil(WorkspaceStateCodec.decodeUUIDList(Data(short)))
    }
}
