import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``HostWorkspaceMirror`` — the client replica of the host-owned document (docs/45 §7.1).
///
/// The property under test throughout is that host truth and the low-latency overlay never merge
/// into one another. `entries` is only ever `apply(diffs, base)`; `fastPath` is only ever read where
/// `entries` is silent, and is erased by any host value for the same key. Without that erasure a
/// disagreement between the two producers freezes permanently — the bug class the whole document
/// exists to end.
final class WorkspaceMirrorFastPathTests: XCTestCase {
    private let pane = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let epoch = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func titleKey(_ id: UUID? = nil) -> WorkspaceKey {
        WorkspaceKey(.pane, id ?? pane, WorkspacePaneField.liveTitle)
    }

    private func snapshotPayload(_ entries: [WorkspaceEntry]) -> Data {
        WorkspaceStateCodec.encodeSnapshot(HostWorkspaceState(entries))
    }

    private func entry(_ field: UInt8, _ text: String, pane id: UUID? = nil) -> WorkspaceEntry {
        WorkspaceEntry(key: WorkspaceKey(.pane, id ?? pane, field), value: WorkspaceStateCodec.encodeString(text))
    }

    private func livenessEntry(_ state: PaneLivenessState = .attached, pane id: UUID? = nil) -> WorkspaceEntry {
        WorkspaceEntry(
            key: WorkspaceKey(.pane, id ?? pane, WorkspacePaneField.liveness),
            value: WorkspaceStateCodec.encodeU8(state.rawValue),
        )
    }

    /// Applies a snapshot and returns the mirror, so the diff cases start from a known base.
    private func mirrorAtSnapshot(_ entries: [WorkspaceEntry], stateNum: Int64 = 1) -> HostWorkspaceMirror {
        var mirror = HostWorkspaceMirror()
        let outcome = mirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: stateNum,
            payload: snapshotPayload(entries),
        )
        XCTAssertEqual(outcome, .applied(stateNum))
        return mirror
    }

    // MARK: - The fast path never outlives host truth

    /// The headline case from docs/45 Phase 4: write a key on the fast path, then have a diff supply
    /// a DIFFERENT value for it. The projection must follow the diff.
    func testADiffOverridesAFastPathValueForTheSameKey() {
        var mirror = mirrorAtSnapshot([livenessEntry()])
        mirror.writeFastPath(titleKey(), WorkspaceStateCodec.encodeString("vi ."))
        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "vi .")

        let diff = WorkspaceStateDiff(sets: [entry(WorkspacePaneField.liveTitle, "main.swift - NVIM")])
        let outcome = mirror.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: epoch,
            baseStateNum: 1,
            newStateNum: 2,
            payload: WorkspaceStateCodec.encodeDiff(diff),
        )

        XCTAssertEqual(outcome, .applied(2))
        XCTAssertEqual(
            mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "main.swift - NVIM",
            "host truth wins over the push overlay",
        )
        XCTAssertNil(mirror.fastPath[titleKey()], "the overlay entry is erased, not merely outranked")
    }

    /// The half that makes the first half permanent: once erased, a LATER frame that says nothing
    /// about the key must not let the stale push resurface.
    func testALaterEmptyDiffDoesNotResurrectTheFastPathValue() {
        var mirror = mirrorAtSnapshot([livenessEntry()])
        mirror.writeFastPath(titleKey(), WorkspaceStateCodec.encodeString("vi ."))
        _ = mirror.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: epoch,
            baseStateNum: 1,
            newStateNum: 2,
            payload: WorkspaceStateCodec.encodeDiff(
                WorkspaceStateDiff(sets: [entry(WorkspacePaneField.liveTitle, "main.swift - NVIM")]),
            ),
        )

        // A frame that touches an unrelated key — the steady-state case.
        let unrelated = WorkspaceStateDiff(sets: [entry(WorkspacePaneField.cwd, "/tmp")])
        XCTAssertEqual(
            mirror.apply(
                kind: WorkspaceEventKind.diff.rawValue,
                epoch: epoch,
                baseStateNum: 2,
                newStateNum: 3,
                payload: WorkspaceStateCodec.encodeDiff(unrelated),
            ),
            .applied(3),
        )

        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "main.swift - NVIM")
        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.cwd), "/tmp")
    }

    /// A DELETE supplies a fact too: "this key is now absent". If the overlay survived a delete, a
    /// retired title would reappear from the push that first set it.
    func testADeleteAlsoErasesTheFastPathValue() {
        var mirror = mirrorAtSnapshot([livenessEntry(), entry(WorkspacePaneField.liveTitle, "NVIM")])
        mirror.writeFastPath(WorkspaceKey(.pane, pane, WorkspacePaneField.cwd), WorkspaceStateCodec.encodeString("/x"))

        let diff = WorkspaceStateDiff(deletes: [
            titleKey(),
            WorkspaceKey(.pane, pane, WorkspacePaneField.cwd),
        ])
        XCTAssertEqual(
            mirror.apply(
                kind: WorkspaceEventKind.diff.rawValue,
                epoch: epoch,
                baseStateNum: 1,
                newStateNum: 2,
                payload: WorkspaceStateCodec.encodeDiff(diff),
            ),
            .applied(2),
        )

        XCTAssertNil(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "the deleted key is gone")
        XCTAssertNil(
            mirror.string(.pane, pane, WorkspacePaneField.cwd),
            "a delete erases the overlay for that key too",
        )
    }

    /// A push that races a document value must lose. Otherwise the two producers' disagreement is
    /// decided by arrival order, which is exactly what the erasure rule removes.
    func testAFastPathWriteIsIgnoredWhereHostTruthAlreadyHoldsTheKey() {
        var mirror = mirrorAtSnapshot([livenessEntry(), entry(WorkspacePaneField.liveTitle, "NVIM")])

        mirror.writeFastPath(titleKey(), WorkspaceStateCodec.encodeString("vi ."))

        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "NVIM")
        XCTAssertNil(mirror.fastPath[titleKey()], "the write is refused, not stored-and-outranked")
    }

    /// With no host truth at all the overlay drives the UI unchanged — the flag-off behaviour, and
    /// the pre-first-snapshot window of every cold connect.
    func testTheFastPathDrivesReadsBeforeAnySnapshot() {
        var mirror = HostWorkspaceMirror()
        mirror.writeFastPath(titleKey(), WorkspaceStateCodec.encodeString("vi ."))

        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "vi .")
        XCTAssertEqual(mirror.stateNum, 0)
        XCTAssertNil(mirror.epoch)
    }

    /// The overlay is not a pane. Enumeration reads the document's `liveness` marker, so a row can
    /// never be conjured out of a stray push for a pane the host does not have.
    func testFastPathEntriesDoNotConjureAPane() {
        var mirror = HostWorkspaceMirror()
        mirror.writeFastPath(titleKey(), WorkspaceStateCodec.encodeString("vi ."))

        XCTAssertTrue(mirror.paneIDs.isEmpty)
        XCTAssertNil(mirror.paneLiveness(pane), "no liveness field ⇒ not a pane this mirror knows")
    }

    func testClearingAPanesFastPathLeavesOtherPanesAlone() {
        let other = UUID()
        var mirror = HostWorkspaceMirror()
        mirror.writeFastPath(titleKey(), WorkspaceStateCodec.encodeString("mine"))
        mirror.writeFastPath(titleKey(other), WorkspaceStateCodec.encodeString("theirs"))

        mirror.clearFastPath(pane: pane)

        XCTAssertNil(mirror.string(.pane, pane, WorkspacePaneField.liveTitle))
        XCTAssertEqual(mirror.string(.pane, other, WorkspacePaneField.liveTitle), "theirs")
    }

    /// The invariant behind the precedence rule: the two layers are DISJOINT, so which one is read
    /// first can never decide a value. Refusing a write over host truth and erasing on supply are the
    /// two halves that maintain it; this drives an adversarial mix of both and checks the result.
    func testTheTwoLayersNeverHoldTheSameKey() {
        var mirror = HostWorkspaceMirror()
        let fields = [
            WorkspacePaneField.liveTitle, WorkspacePaneField.cwd,
            WorkspacePaneField.foregroundProcess, WorkspacePaneField.runningCommand,
        ]
        var version: Int64 = 0

        for step in 0..<120 {
            let field = fields[step % fields.count]
            if step.isMultiple(of: 3) {
                mirror.writeFastPath(
                    WorkspaceKey(.pane, pane, field),
                    WorkspaceStateCodec.encodeString("push-\(step)"),
                )
            } else if step.isMultiple(of: 7) {
                version += 1
                _ = mirror.apply(
                    kind: 0, epoch: epoch, baseStateNum: 0, newStateNum: version,
                    payload: snapshotPayload([livenessEntry(), entry(field, "snap-\(step)")]),
                )
            } else if mirror.epoch != nil {
                let base = version
                version += 1
                let diff = step.isMultiple(of: 5)
                    ? WorkspaceStateDiff(deletes: [WorkspaceKey(.pane, pane, field)])
                    : WorkspaceStateDiff(sets: [entry(field, "diff-\(step)")])
                _ = mirror.apply(
                    kind: 1, epoch: epoch, baseStateNum: base, newStateNum: version,
                    payload: WorkspaceStateCodec.encodeDiff(diff),
                )
            }

            for key in mirror.fastPath.keys {
                XCTAssertNil(mirror.entries[key], "step \(step): \(key.field) is in BOTH layers")
            }
        }
        XCTAssertGreaterThan(version, 0, "the sequence actually exercised host frames")
    }

    // MARK: - Snapshot

    func testASnapshotReplacesHostTruthWholesale() {
        var mirror = mirrorAtSnapshot([livenessEntry(), entry(WorkspacePaneField.liveTitle, "first")])

        let outcome = mirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: 9,
            payload: snapshotPayload([livenessEntry(), entry(WorkspacePaneField.cwd, "/second")]),
        )

        XCTAssertEqual(outcome, .applied(9))
        XCTAssertEqual(mirror.stateNum, 9)
        XCTAssertNil(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "keys absent from the snapshot are gone")
        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.cwd), "/second")
    }

    /// A snapshot is self-contained, so it needs no base and no matching epoch. That is what makes a
    /// post-restart client converge in ONE frame.
    func testASnapshotWithANewEpochIsAcceptedWithoutAReset() {
        var mirror = mirrorAtSnapshot([livenessEntry(), entry(WorkspacePaneField.liveTitle, "old host")])
        let newEpoch = UUID()

        let outcome = mirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: newEpoch,
            baseStateNum: 0,
            newStateNum: 1,
            payload: snapshotPayload([livenessEntry(), entry(WorkspacePaneField.liveTitle, "new host")]),
        )

        XCTAssertEqual(outcome, .applied(1))
        XCTAssertEqual(mirror.epoch, newEpoch)
        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "new host")
    }

    // MARK: - Diff discipline

    /// The rule that makes duplicates and reorders free: a frame the mirror has already superseded is
    /// IGNORED, never an error and never a resubscribe storm.
    func testASupersededDiffIsIgnoredRatherThanTreatedAsAFault() {
        var mirror = mirrorAtSnapshot([livenessEntry()], stateNum: 5)

        let outcome = mirror.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: epoch,
            baseStateNum: 3,
            newStateNum: 4,
            payload: WorkspaceStateCodec.encodeDiff(
                WorkspaceStateDiff(sets: [entry(WorkspacePaneField.liveTitle, "stale")]),
            ),
        )

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(mirror.stateNum, 5)
        XCTAssertNil(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "a superseded frame changes nothing")
    }

    /// A diff reaching FORWARD from a base we are not at is the unrecoverable case — applying it
    /// would land cleanly and corrupt silently.
    func testAMisBasedForwardDiffAsksForAResubscribe() {
        var mirror = mirrorAtSnapshot([livenessEntry()], stateNum: 5)

        let outcome = mirror.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: epoch,
            baseStateNum: 7,
            newStateNum: 8,
            payload: WorkspaceStateCodec.encodeDiff(
                WorkspaceStateDiff(sets: [entry(WorkspacePaneField.liveTitle, "future")]),
            ),
        )

        XCTAssertEqual(outcome, .needsResubscribe)
        XCTAssertEqual(mirror.stateNum, 5, "a rejected frame leaves the mirror untouched")
    }

    /// The epoch's entire job: a delta from a DIFFERENT document must never apply, even when its
    /// `stateNum` arithmetic lines up perfectly — which after a hostd restart it does.
    func testADiffFromAnotherEpochIsRefusedEvenWhenTheNumbersLineUp() {
        var mirror = mirrorAtSnapshot([livenessEntry()], stateNum: 4)

        let outcome = mirror.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: UUID(),
            baseStateNum: 4,
            newStateNum: 5,
            payload: WorkspaceStateCodec.encodeDiff(
                WorkspaceStateDiff(sets: [entry(WorkspacePaneField.liveTitle, "other document")]),
            ),
        )

        XCTAssertEqual(outcome, .needsResubscribe)
        XCTAssertNil(mirror.string(.pane, pane, WorkspacePaneField.liveTitle))
    }

    func testADiffBeforeAnySnapshotAsksForAResubscribe() {
        var mirror = HostWorkspaceMirror()

        let outcome = mirror.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: 1,
            payload: WorkspaceStateCodec.encodeDiff(
                WorkspaceStateDiff(sets: [entry(WorkspacePaneField.liveTitle, "x")]),
            ),
        )

        XCTAssertEqual(outcome, .needsResubscribe)
    }

    /// Convergence, the way the host actually drives it: apply the same diff twice. Because a diff
    /// ASSIGNS rather than mutates, the second is a no-op by construction.
    func testApplyingTheSameDiffTwiceIsANoOp() {
        var mirror = mirrorAtSnapshot([livenessEntry()])
        let payload = WorkspaceStateCodec.encodeDiff(
            WorkspaceStateDiff(sets: [entry(WorkspacePaneField.liveTitle, "once")]),
        )

        XCTAssertEqual(
            mirror.apply(kind: 1, epoch: epoch, baseStateNum: 1, newStateNum: 2, payload: payload), .applied(2),
        )
        let afterFirst = mirror.entries
        XCTAssertEqual(
            mirror.apply(kind: 1, epoch: epoch, baseStateNum: 1, newStateNum: 2, payload: payload), .ignored,
        )
        XCTAssertEqual(mirror.entries, afterFirst)
    }

    // MARK: - Reset

    func testAResetEmptiesHostTruthAndKeepsTheOverlayVisible() {
        var mirror = mirrorAtSnapshot([livenessEntry(), entry(WorkspacePaneField.liveTitle, "before")])
        // A push for a key host truth does NOT hold — so it is genuinely stored on the overlay.
        mirror.writeFastPath(
            WorkspaceKey(.pane, pane, WorkspacePaneField.cwd),
            WorkspaceStateCodec.encodeString("/still/painted"),
        )
        let newEpoch = UUID()

        XCTAssertEqual(mirror.apply(kind: 4, epoch: newEpoch, baseStateNum: 0, newStateNum: 0, payload: Data()), .reset)

        XCTAssertEqual(mirror.stateNum, 0)
        XCTAssertEqual(mirror.epoch, newEpoch)
        XCTAssertTrue(mirror.entries.isEmpty)
        XCTAssertNil(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "host truth is gone")
        XCTAssertEqual(
            mirror.string(.pane, pane, WorkspacePaneField.cwd), "/still/painted",
            "the pane channels are still alive — their overlay must keep painting",
        )
    }

    // MARK: - Subscribe parameters

    func testSubscribeAsksForASnapshotUntilOneHasLanded() {
        var mirror = HostWorkspaceMirror()
        XCTAssertEqual(mirror.knownEpoch, WireMessage.newSessionID)
        XCTAssertEqual(mirror.knownStateNum, 0)

        _ = mirror.apply(
            kind: 0, epoch: epoch, baseStateNum: 0, newStateNum: 12,
            payload: snapshotPayload([livenessEntry()]),
        )

        XCTAssertEqual(mirror.knownEpoch, epoch)
        XCTAssertEqual(mirror.knownStateNum, 12)
    }

    /// After a reset the mirror holds the new epoch but nothing under it. `stateNum 0` is the "I know
    /// nothing" sentinel, so the host answers with a snapshot — which is what it is about to send.
    func testSubscribeAfterAResetAsksForASnapshotUnderTheNewEpoch() {
        var mirror = mirrorAtSnapshot([livenessEntry()], stateNum: 3)
        let newEpoch = UUID()
        _ = mirror.apply(kind: 4, epoch: newEpoch, baseStateNum: 0, newStateNum: 0, payload: Data())

        XCTAssertEqual(mirror.knownEpoch, newEpoch)
        XCTAssertEqual(mirror.knownStateNum, 0)
    }

    // MARK: - Untrusted bytes

    func testAMalformedPayloadIsDroppedWithoutDisturbingTheMirror() {
        var mirror = mirrorAtSnapshot([livenessEntry(), entry(WorkspacePaneField.liveTitle, "intact")])
        let garbage = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x01])

        XCTAssertEqual(
            mirror.apply(kind: 0, epoch: epoch, baseStateNum: 0, newStateNum: 2, payload: garbage), .dropped,
        )
        XCTAssertEqual(
            mirror.apply(kind: 1, epoch: epoch, baseStateNum: 1, newStateNum: 2, payload: garbage), .dropped,
        )

        XCTAssertEqual(mirror.stateNum, 1)
        XCTAssertEqual(mirror.string(.pane, pane, WorkspacePaneField.liveTitle), "intact")
    }

    /// Forward tolerance: a kind this build does not know is one dropped frame, never a torn channel.
    /// There is no version negotiation on this wire, so this is the only correct answer.
    func testAnUnknownEventKindIsDropped() {
        var mirror = mirrorAtSnapshot([livenessEntry()])
        XCTAssertEqual(
            mirror.apply(kind: 200, epoch: epoch, baseStateNum: 0, newStateNum: 0, payload: Data()), .dropped,
        )
        XCTAssertEqual(mirror.stateNum, 1)
    }

    // MARK: - Presence and intent results

    func testAPresenceFrameReplacesTheRosterWithoutTouchingTheDocument() {
        var mirror = mirrorAtSnapshot([livenessEntry()])
        let roster = WorkspacePresenceRoster(
            clients: [WorkspaceRosterClient(
                clientInstanceID: UUID(), clientKind: WorkspaceClientKind.iOS.rawValue, flags: 0, label: "iPad",
            )],
            panes: [],
        )

        XCTAssertEqual(
            mirror.apply(kind: 2, epoch: epoch, baseStateNum: 0, newStateNum: 0, payload: roster.encode()), .presence,
        )

        XCTAssertEqual(mirror.roster?.clients.count, 1)
        XCTAssertEqual(mirror.roster?.clients.first?.label, "iPad")
        XCTAssertEqual(mirror.stateNum, 1, "presence is not versioned")
    }

    func testAnIntentResultIsSurfacedToTheCaller() {
        var mirror = mirrorAtSnapshot([livenessEntry()])
        let intentID = UUID()
        let result = WorkspaceIntentResult(intentID: intentID, status: .unknownOp)

        let outcome = mirror.apply(kind: 3, epoch: epoch, baseStateNum: 0, newStateNum: 0, payload: result.encode())

        XCTAssertEqual(outcome, .intentResult(result))
        XCTAssertEqual(mirror.stateNum, 1)
    }

    // MARK: - Pane projection

    /// The end of the reported bug, stated as an assertion: the freshness VERDICT crosses the wire,
    /// so the client no longer compares two in-memory stamps that reset on every app launch.
    func testAPaneProjectsTheHostsTitleAndItsFreshnessVerdict() {
        let record = PaneLiveness(
            paneID: pane,
            liveness: .attached,
            liveTitle: "main.swift - NVIM",
            titleFresh: true,
            cwd: "/Volumes/work",
            foregroundProcess: "nvim",
            runningCommand: "vi .",
            commandRunning: true,
        )
        let mirror = mirrorAtSnapshot(record.entries())

        let projected = mirror.paneLiveness(pane)

        XCTAssertEqual(projected, record)
        XCTAssertEqual(mirror.paneIDs, [pane])
        XCTAssertEqual(projected?.liveTitle, "main.swift - NVIM")
        XCTAssertTrue(projected?.titleFresh ?? false)
        XCTAssertEqual(projected?.runningCommand, "vi .")
        XCTAssertEqual(projected?.foregroundProcess, "nvim")
    }

    /// The projection reads through the overlay too — that is what keeps the focused pane painting
    /// sub-frame while the reconciler's tick is still in flight.
    func testAPaneProjectionReadsThroughTheFastPathWhereHostTruthIsSilent() {
        var mirror = mirrorAtSnapshot([livenessEntry()])
        mirror.writeFastPath(titleKey(), WorkspaceStateCodec.encodeString("pushed"))

        XCTAssertEqual(mirror.paneLiveness(pane)?.liveTitle, "pushed")
    }

    func testAProjectGitSummaryIsReadableAsRawBytes() {
        let project = UUID()
        let blob = Data([0x01, 0x02, 0x03])
        let mirror = mirrorAtSnapshot([
            livenessEntry(),
            WorkspaceEntry(key: WorkspaceKey(.project, project, WorkspaceProjectField.gitSummary), value: blob),
        ])

        XCTAssertEqual(mirror.projectGitSummary(project), blob)
        XCTAssertNil(mirror.projectGitSummary(UUID()))
    }

    // MARK: - Convergence under an adversarial stream

    /// The Phase-3 argument carried across the apply boundary: drop, duplicate and reorder frames at
    /// will; every mirror that ends at the same `stateNum` holds the same document.
    func testTwoMirrorsConvergeUnderDroppedAndDuplicatedFrames() {
        var truth = HostWorkspaceState([livenessEntry()])
        var perfect = mirrorAtSnapshot([livenessEntry()])
        var lossy = mirrorAtSnapshot([livenessEntry()])
        // `lossy` acks nothing for a while, so the host keeps re-diffing from ITS acked base — the
        // mosh rule. Modelled here as: every frame is recomputed from the receiver's own stateNum.
        var version: Int64 = 1

        for step in 0..<200 {
            var next = truth
            next[WorkspaceKey(.pane, pane, WorkspacePaneField.liveTitle)] =
                WorkspaceStateCodec.encodeString("title-\(step)")
            if step.isMultiple(of: 7) {
                next[WorkspaceKey(.pane, pane, WorkspacePaneField.cwd)] = WorkspaceStateCodec.encodeString("/d\(step)")
            }
            if step.isMultiple(of: 11) {
                next[WorkspaceKey(.pane, pane, WorkspacePaneField.cwd)] = nil
            }
            let base = version
            version += 1

            let payload = WorkspaceStateCodec.encodeDiff(next.diff(from: truth))
            // The perfect client applies every frame, sometimes twice.
            _ = perfect.apply(kind: 1, epoch: epoch, baseStateNum: base, newStateNum: version, payload: payload)
            if step.isMultiple(of: 5) {
                _ = perfect.apply(kind: 1, epoch: epoch, baseStateNum: base, newStateNum: version, payload: payload)
            }
            // The lossy client misses one in three — and the host recomputes from where it actually
            // is, which is the only thing that makes the miss self-healing.
            if !step.isMultiple(of: 3) {
                let catchUp = WorkspaceStateCodec.encodeDiff(next.diff(from: lossy.entries))
                _ = lossy.apply(
                    kind: 1, epoch: epoch, baseStateNum: lossy.stateNum, newStateNum: version, payload: catchUp,
                )
            }
            truth = next
        }

        // One final frame recomputed from the laggard's own base — the reconnect case.
        let finalPayload = WorkspaceStateCodec.encodeDiff(truth.diff(from: lossy.entries))
        _ = lossy.apply(
            kind: 1, epoch: epoch, baseStateNum: lossy.stateNum, newStateNum: version + 1, payload: finalPayload,
        )

        XCTAssertEqual(perfect.entries, truth, "every frame applied, some twice — still exact")
        XCTAssertEqual(lossy.entries, truth, "a client that missed a third of the stream catches up in one diff")
    }
}
