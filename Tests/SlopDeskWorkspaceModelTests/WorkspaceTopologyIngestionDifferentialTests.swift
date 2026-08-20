import CSlopDeskFFI
import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

// MARK: - The crossing

/// What the crate made of one document.
private enum CrateIngestion {
    /// `from_document` answered nothing — there is no workspace in these cells.
    case noWorkspace
    /// The topology the crate ingested, as the cells its own projection answers.
    case cells(HostWorkspaceState)
    /// The door turned the harness's own no-op down. Never an ingestion answer — it is the report
    /// that this input stopped at the CROSSING rather than at the rule under test, so a case landing
    /// here is read as a failure and named as one.
    case refused(UInt8)
}

/// `slopdesk_wire::document::topology::from_document`, reached the only way a Swift caller can.
///
/// There is no "ingest this document" door and there deliberately is not one: the topology crosses
/// as the document's own bytes (`docs/55` §4b), so the applier is the entry that takes cells and
/// hands cells back. What that costs here is one intent that must change nothing — the disarm
/// ``TopologyCrossing/ingestion(of:noOp:armed:)`` rides on — and the marshalling below, which is
/// ``WorkspaceIntentApplier``'s minus the project keys and with RAW cells where the applier starts
/// from a ``WorkspaceTopology``. That
/// difference is the whole point: a harness that started from an ingested value could not feed the
/// crate a document Swift's own ingestion had already refused.
private enum TopologyCrossing {
    /// The crate's own status bytes, asked for by INDEX and never transcribed — which is also why the
    /// index is not the value:
    /// `slopdesk_ws_intent_status(3)` is the fourth status and answers the byte **4**. A reader who
    /// assumes the index is the byte reads a "no such object" as an "unknown op".
    static let applied = slopdesk_ws_intent_status(0)
    static let rejectedNotFound = slopdesk_ws_intent_status(3)
    static let unknownOp = slopdesk_ws_intent_status(4)

    /// A status byte in words, so a refusal in a failure message needs no lookup.
    static func name(of status: UInt8) -> String {
        switch status {
        case applied: "applied"
        case rejectedNotFound: "no such object"
        case unknownOp: "unknown op"
        default: "a status this build does not name"
        }
    }

    /// The smallest op byte no build claims.
    ///
    /// DERIVED rather than typed, for the reason every vocabulary in this file is: an op added
    /// tomorrow would turn this probe from "tell me whether there is a document" into a real intent,
    /// and the probe would keep passing while measuring something else entirely.
    static let unclaimedOp: UInt8 = {
        let claimed = Set(WorkspaceIntentOp.allCases.map(\.rawValue))
        return (UInt8.min...UInt8.max).first { !claimed.contains($0) } ?? .max
    }()

    /// The crate's reading of `document`, or why there is none.
    ///
    /// Two calls, because one status byte carries two answers. The door returns `rejectedNotFound`
    /// BEFORE it looks at the op when `from_document` is `None`, and `set_sync_input` returns the
    /// same byte for a tab that is not there — so an op byte no arm claims separates them: it can
    /// only reach `unknownOp` on a document the crate did ingest.
    static func ingestion(of document: HostWorkspaceState, noOp tab: TabID, armed: Bool) -> CrateIngestion {
        let probe = cross(document, op: unclaimedOp, args: Data()).status
        if probe == rejectedNotFound { return .noWorkspace }
        guard probe == unknownOp else { return .refused(probe) }

        let outcome = cross(
            document,
            op: WorkspaceIntentOp.setSyncInput.rawValue,
            args: WorkspaceIntentArgs.encode(id: tab.raw, flag: armed),
        )
        guard outcome.status == applied,
              let cells = try? WorkspaceStateCodec.decodeSnapshot(outcome.answer)
        else { return .refused(outcome.status) }
        return .cells(cells)
    }

    /// One call through the door, with the document's cells as the flat `(entry, blob)` pairs it
    /// takes. No project keys: the no-op is not a close, and the close rule is the only reader.
    static func cross(
        _ document: HostWorkspaceState,
        op: UInt8,
        args: Data,
    ) -> (status: UInt8, answer: Data) {
        var blob = WsBlob()
        var cells = document.sortedEntries.map { blob.entry($0) }
        let minted = (0..<slopdesk_ws_minted_ids_per_intent()).map { _ in SlopDeskWsUuid(UUID()) }
        var status = UInt8.max
        var payload = [UInt8](args)

        let answer = blob.lend { arena in
            cells.withUnsafeMutableBufferPointer { cell in
                minted.withUnsafeBufferPointer { pool in
                    payload.withUnsafeMutableBufferPointer { bytes in
                        withUnsafeMutablePointer(to: &status) { verdict in
                            wsBytes { out, cap in
                                slopdesk_ws_apply_intent(
                                    op,
                                    bytes.baseAddress,
                                    bytes.count,
                                    cell.baseAddress,
                                    cell.count,
                                    nil,
                                    0,
                                    arena.baseAddress,
                                    arena.count,
                                    pool.baseAddress,
                                    pool.count,
                                    false,
                                    verdict,
                                    out,
                                    cap,
                                )
                            }
                        }
                    }
                }
            }
        }
        return (status, answer)
    }
}

// MARK: - The suite

/// The document INGESTION, held against the other implementation of it.
///
/// **The repo's third differential suite, and the second written for a pair that is still DOUBLE.**
/// ``WorkspaceTopology/init(entries:)`` and `slopdesk_wire::document::topology::from_document` read
/// the same cells into the same shape in two languages, which `CLAUDE.md` forbids — and this one
/// genuinely cannot be collapsed. `entries()`/`init(entries:)` ARE the marshalling for the doors
/// that already exist, so deleting them deletes the crossing itself; and `WorkspaceStore.tree`
/// re-ingests on every divider-drag frame, where ``WorkspaceMarshalBenchTests`` measures ~2.8 ms for
/// a realistic workspace and ~12.6 ms at 1,042 entries. An extra crossing per frame is a MEASURED
/// veto, which `CLAUDE.md` says is the only kind that counts. `docs/55` §7 step 6 names exactly this
/// case and says what is owed instead: **pin it.**
///
/// The WELL-FORMED half is already pinned — ``WorkspaceTopologyTests``'
/// `testTheWholeTopologyCrossesToTheCrateAndBack` drives a rich fixture out through the applier and
/// back and asserts every field survives. What was unpinned until this file is the MALFORMED half,
/// and `docs/55` §8's sharpest finding says that is the whole risk: *a parser and a repairer agree
/// on every well-formed input and disagree on every malformed one*, which is the input class no test
/// covers and every hand-edited or truncated document eventually produces. So nothing here is
/// well-formed except as a control.
///
/// Three things worth knowing before reading a case:
///
/// - **Both sides answer in CELLS, and the cells are what is compared.** Swift's ingestion is
///   projected back with ``WorkspaceTopology/entries()``; the crate's answer already IS its own
///   projection. Comparing documents rather than values is what lets the assertion be written
///   without either side's type vocabulary, and it is strictly stronger than comparing a handful of
///   fields: a dropped tab, a repaired weight and a re-pointed focus all land as a differing cell.
/// - **The corpus is walked, not listed, wherever a door will vend the vocabulary.** Every cell the
///   projection writes is corrupted four ways; every pane field
///   ``PaneLiveness/topologyFields()`` names is corrupted whether the fixture wrote it or not; every
///   field ``PaneLiveness/livenessFields()`` names is corrupted and must change NOTHING. A ratchet
///   stated as a count or a name list goes green about the wrong thing the day its subject moves.
/// - **There are two codecs under this, not one.** Swift's field decoders are
///   `slopdesk_workspace::state_codec` through the scalar doors; the crate's ingestion reads
///   `slopdesk_wire::document::codec`. `rust/slopdesk-ffi/tests/snapshot_codec_parity.rs` pins the
///   SNAPSHOT frame across those two crates and nothing pinned the field values, so a malformed
///   `layoutStructure`, weight cell or detached-pane record is a differential over the codecs too.
final class WorkspaceTopologyIngestionDifferentialTests: XCTestCase {
    // MARK: - Identities, readable from their bytes

    private func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (
            byte, byte, byte, byte, byte, byte, byte, byte,
            byte, byte, byte, byte, byte, byte, byte, byte,
        ))
    }

    /// The session every case keeps intact, and the tab the no-op names.
    ///
    /// It exists because the crossing needs a target that both sides can still find: the applier is
    /// the only door that takes cells, and every one of its ops refers to something. Keeping one
    /// sound session out of the blast radius is what lets the REST of the document be as broken as
    /// the corpus wants without the harness losing its footing.
    private var anchorSession: SessionID { SessionID(raw: uuid(0x11)) }
    private var anchorTab: TabID { TabID(raw: uuid(0x12)) }
    private var anchorPane: PaneID { PaneID(raw: uuid(0x13)) }

    /// The three objects the harness itself rides on, addressed as the cells name them.
    ///
    /// The walks below corrupt every cell in the document EXCEPT these. A document with no anchor tab
    /// stops at the crossing — the door answers `rejectedNotFound` before any ingestion is visible —
    /// so such a case would report on the harness, not on the two readings. Nothing leaves the walk
    /// by being skipped here, and ``testTheAnchorHoldsNoFieldTheRestOfTheDocumentDoesNot`` is what
    /// says so rather than this comment.
    private var anchorObjects: Set<UUID> { [anchorSession.raw, anchorTab.raw, anchorPane.raw] }

    private var victimSession: SessionID { SessionID(raw: uuid(0x21)) }
    private var victimTab: TabID { TabID(raw: uuid(0x22)) }
    private var victimSplit: SplitNodeID { SplitNodeID(raw: uuid(0x23)) }
    private var leftPane: PaneID { PaneID(raw: uuid(0x24)) }
    private var rightPane: PaneID { PaneID(raw: uuid(0x25)) }
    private var satellite: PaneID { PaneID(raw: uuid(0x26)) }

    private var closedTab: TabID { TabID(raw: uuid(0x31)) }
    private var closedPane: PaneID { PaneID(raw: uuid(0x32)) }

    /// A pane, tab and session no document ever contains — what a dangling reference names.
    private var ghostPane: PaneID { PaneID(raw: uuid(0x91)) }
    private var ghostTab: TabID { TabID(raw: uuid(0x92)) }
    private var ghostSession: SessionID { SessionID(raw: uuid(0x93)) }

    // MARK: - The base document

    /// A workspace carrying every field the projection knows how to write.
    ///
    /// Rich on purpose: a corruption is only worth applying to a cell that was there, and the
    /// vocabulary walks below corrupt what this produces. The anchor tab is deliberately NOT in
    /// `syncInputTabs` — see ``testTheNoOpTheHarnessRidesOnIsActuallyANoOp``.
    private func fixture() -> WorkspaceTopology {
        let anchor = Session(
            id: anchorSession,
            name: "anchor",
            tabs: [Tab(id: anchorTab, title: "one", root: .leaf(anchorPane), activePane: anchorPane)],
            activeTabIndex: 0,
            specs: [anchorPane: PaneSpec(kind: .terminal, title: "shell")],
        )
        let victim = Session(
            id: victimSession,
            name: "victim",
            tabs: [Tab(
                id: victimTab,
                title: "work",
                root: .split(id: victimSplit, axis: .horizontal, children: [
                    WeightedChild(weight: .flex(2), node: .leaf(leftPane)),
                    WeightedChild(weight: .fixed(220), node: .leaf(rightPane)),
                ]),
                activePane: leftPane,
                zoomedPane: rightPane,
            )],
            activeTabIndex: 0,
            specs: [
                leftPane: PaneSpec(kind: .terminal, title: "nvim", userRenamed: true),
                rightPane: PaneSpec(kind: .terminal, title: "logs"),
                satellite: PaneSpec(
                    kind: .desktop,
                    title: "Display 1",
                    video: VideoEndpoint(windowID: 0, title: "Display 1", appName: "", displayID: 1),
                ),
            ],
            detached: [DetachedPane(pane: satellite, originTab: victimTab)],
        )
        return WorkspaceTopology(
            tree: TreeWorkspace(sessions: [anchor, victim], activeSessionID: victimSession),
            syncInputTabs: [victimTab],
            focusMRU: [victimSession: [victimTab]],
            closedTabs: [WorkspaceTopology.ClosedTab(
                sessionID: victimSession,
                tab: Tab(id: closedTab, title: "gone", root: .leaf(closedPane), activePane: closedPane),
                specs: [closedPane: PaneSpec(kind: .terminal, title: "was here")],
            )],
            unattachedSessionID: anchorSession,
            hostDisplayName: "mac-studio",
            spawnCwd: [leftPane: "/tmp/work"],
        )
    }

    private func base() -> HostWorkspaceState { HostWorkspaceState(fixture().entries()) }

    // MARK: - The differential itself

    /// This side's ingestion, projected back so the two answers are the same kind of thing.
    private func here(_ document: HostWorkspaceState) -> HostWorkspaceState? {
        WorkspaceTopology(entries: document).map { HostWorkspaceState($0.entries()) }
    }

    private func there(_ document: HostWorkspaceState) -> CrateIngestion {
        TopologyCrossing.ingestion(of: document, noOp: anchorTab, armed: false)
    }

    /// Both ingestions on one document, asserted to land on the same cells.
    ///
    /// The name is the failure message, so a divergence points at the shape rather than at an index.
    @discardableResult
    private func assertConverges(
        _ document: HostWorkspaceState,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> HostWorkspaceState? {
        let mine = here(document)
        switch (mine, there(document)) {
        case (nil, .noWorkspace):
            return nil
        case let (.some(mine), .cells(crate)):
            assertSameCells(mine, crate, name, file: file, line: line)
            return mine
        case (nil, .cells):
            XCTFail("this side found no workspace in \(name) and the crate found one", file: file, line: line)
        case (.some, .noWorkspace):
            XCTFail("the crate found no workspace in \(name) and this side found one", file: file, line: line)
        case let (_, .refused(status)):
            XCTFail(
                "the crossing refused \(name): \(TopologyCrossing.name(of: status))",
                file: file,
                line: line,
            )
        }
        return nil
    }

    /// Cell by cell rather than whole-value, so a failure names the key that differs.
    ///
    /// A whole-document `XCTAssertEqual` prints two dictionaries of forty entries and leaves the
    /// reader to diff them, which is exactly the work this suite exists to do for them.
    private func assertSameCells(
        _ mine: HostWorkspaceState,
        _ crate: HostWorkspaceState,
        _ name: String,
        file: StaticString,
        line: UInt,
    ) {
        for key in Set(mine.entries.keys).union(crate.entries.keys).sorted() {
            let ours = mine[key], theirs = crate[key]
            guard ours != theirs else { continue }
            XCTFail(
                """
                the two ingestions disagree about \(name): \
                kind \(key.kind) field \(key.field) of \(key.objectID) \
                is \(describe(ours)) here and \(describe(theirs)) there
                """,
                file: file,
                line: line,
            )
        }
    }

    private func describe(_ value: Data?) -> String {
        guard let value else { return "absent" }
        return "\(value.count) bytes \(Array(value).map { String(format: "%02x", $0) }.joined())"
    }

    // MARK: - The control, and the harness's own honesty

    func testTheWellFormedDocumentIsTheOneCaseBothSidesAgreeOnByAssumption() throws {
        // The control. Every other case below compares two answers that may both be wrong in the
        // same way; this one says the crossing carries the document at all, so a corpus-wide
        // agreement is not two sides failing to read the same bytes.
        let document = base()
        let mine = try XCTUnwrap(assertConverges(document, "the well-formed fixture"))
        XCTAssertEqual(mine, document, "the projection is not the inverse of the ingestion")
    }

    func testTheNoOpTheHarnessRidesOnIsActuallyANoOp() {
        // The one property the whole suite rests on: `setSyncInput(armed: false)` on a tab that was
        // never armed changes nothing on either side. If the anchor tab ever gained a
        // `syncInputArmed` cell, every case above would be comparing this side's ingestion against
        // the crate's ingestion MINUS an armed bit, and would keep passing until the day the two
        // disagreed about that bit specifically — which is the one thing it could no longer see.
        let armed = WorkspaceKey(.tab, anchorTab.raw, WorkspaceTabField.syncInputArmed)
        XCTAssertNil(base()[armed], "the anchor tab is armed, so the harness's no-op is not one")
        XCTAssertNil(
            here(base())?[armed],
            "the anchor tab comes back armed, so the no-op would disarm it on the crate's side only",
        )
    }

    func testTheProbeSeparatesNoDocumentFromNoSuchTab() {
        // Both answer `rejectedNotFound`, and telling them apart is what makes `.noWorkspace` a real
        // answer rather than a guess. Asserted directly, because a probe that silently stopped
        // discriminating would turn every "the crate found nothing" case into a pass.
        let sound = base()
        XCTAssertEqual(
            TopologyCrossing.cross(sound, op: TopologyCrossing.unclaimedOp, args: Data()).status,
            TopologyCrossing.unknownOp,
            "an op no arm claims did not reach the applier over a document the crate can read",
        )
        XCTAssertEqual(
            TopologyCrossing.cross(HostWorkspaceState(), op: TopologyCrossing.unclaimedOp, args: Data()).status,
            TopologyCrossing.rejectedNotFound,
            "an empty document did not answer before the op was read",
        )
        XCTAssertEqual(
            TopologyCrossing.cross(
                sound,
                op: WorkspaceIntentOp.setSyncInput.rawValue,
                args: WorkspaceIntentArgs.encode(id: ghostTab.raw, flag: false),
            ).status,
            TopologyCrossing.rejectedNotFound,
            "a tab that is not there was not refused",
        )
    }

    // MARK: - Every cell the projection writes, corrupted four ways

    /// The shape ratchet, and the reason this suite does not list the document's fields.
    ///
    /// The corpus is derived from ``WorkspaceTopology/entries()`` itself, so a field added to the
    /// projection tomorrow joins it that day. A test naming `layoutStructure`, `weight` and
    /// `activePaneID` would still be green while a fifth cell nobody thought about was being read
    /// two different ways.
    ///
    /// Four corruptions, each a different failure a real document produces: a cell the writer never
    /// got to, a cell RETIRED to zero length (which is a first-class value on this wire, not an
    /// absence), a byte that will not parse as anything, and a value too long for its own grammar.
    func testEveryCellTheProjectionWritesIsReadTheSameWayWhenItIsBroken() {
        let document = base()
        let corruptions: [(String, Data?)] = [
            ("missing", nil),
            ("retired to zero length", Data()),
            ("one byte that parses as nothing", Data([0xFF])),
            ("forty bytes of noise", Data(repeating: 0xAB, count: 40)),
        ]
        for key in document.entries.keys.sorted() where !anchorObjects.contains(key.objectID) {
            for (how, value) in corruptions {
                var broken = document
                broken[key] = value
                assertConverges(
                    broken,
                    "kind \(key.kind) field \(key.field) of \(key.objectID), \(how)",
                )
            }
        }
    }

    /// The walk above skips the anchor's own cells. This is the assertion that the skip costs nothing.
    ///
    /// It compares VOCABULARIES, not counts: every `(kind, field)` the anchor holds must also be held
    /// by an object the walk does reach, so the corruption of that field is applied somewhere. A
    /// count would go green the day the anchor grew a field the victim has never carried.
    func testTheAnchorHoldsNoFieldTheRestOfTheDocumentDoesNot() {
        let keys = base().entries.keys
        // The identity is what makes two cells different cells; drop it and what is left is the
        // field vocabulary, which is the thing that has to be covered.
        func vocabulary(_ keys: [WorkspaceKey]) -> Set<WorkspaceKey> {
            Set(keys.map {
                WorkspaceKey(kind: $0.kind, objectID: WorkspaceObjectKind.rootObjectID, field: $0.field)
            })
        }
        let skipped = vocabulary(keys.filter { anchorObjects.contains($0.objectID) })
        let walked = vocabulary(keys.filter { !anchorObjects.contains($0.objectID) })
        XCTAssertTrue(
            skipped.isSubset(of: walked),
            "the anchor carries \(skipped.subtracting(walked)), which no corrupted cell covers",
        )
    }

    /// The same walk one step further: a cell TRUNCATED to every prefix of itself.
    ///
    /// A truncation is what a half-written file and a clipped frame both look like, and it is the
    /// input that separates a length-prefixed reader that checks its remaining bytes from one that
    /// does not. Kept to the structural cells rather than every cell in the document, because the
    /// point is the readers with counts in them and the run time is quadratic in the value's size.
    func testEveryStructuralCellIsReadTheSameWayAtEveryTruncation() {
        let document = base()
        let structural = [
            WorkspaceKey.root(WorkspaceRootField.sessionOrder),
            WorkspaceKey.root(WorkspaceRootField.closedTabRing),
            WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.tabOrder),
            WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.detachedPanes),
            WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.focusMRU),
            WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
            WorkspaceKey(.splitNode, victimSplit.raw, WorkspaceSplitNodeField.weight),
            WorkspaceKey(.pane, satellite.raw, WorkspacePaneField.videoTarget),
        ]
        for key in structural {
            guard let whole = document[key] else {
                XCTFail("the fixture stopped writing kind \(key.kind) field \(key.field)")
                continue
            }
            for length in 0..<whole.count {
                var broken = document
                broken[key] = whole.prefix(length)
                assertConverges(broken, "kind \(key.kind) field \(key.field) truncated to \(length) bytes")
            }
            var extended = document
            extended[key] = whole + Data([0])
            assertConverges(extended, "kind \(key.kind) field \(key.field) with a trailing byte")
        }
    }

    // MARK: - The pane vocabulary, walked through the door that owns it

    /// Every field the crate calls TOPOLOGY, corrupted on a pane that has one — whether the fixture
    /// wrote that field or not.
    ///
    /// The walk above only reaches cells the projection produced, and the projection is conditional:
    /// `videoTarget`, `spawnCwd` and `userRenamed` are written only when they are set, so a pane
    /// that has none of them leaves three fields uncovered. `slopdesk_ws_pane_fields(1, …)` names
    /// the whole half regardless, so a field added there is corrupted here on the day it is added
    /// rather than on the day someone remembers to write a case for it.
    func testEveryPaneFieldTheCrateCallsTopologyIsReadTheSameWayWhenItIsBroken() {
        let fields = PaneLiveness.topologyFields()
        XCTAssertFalse(fields.isEmpty, "the crate reports no topology fields at all")
        let values: [(String, Data)] = [
            ("a byte that parses as nothing", Data([0xFF])),
            ("an empty value", Data()),
            ("a value from another grammar", Data(repeating: 0x7F, count: 33)),
        ]
        for field in fields {
            for pane in [anchorPane, leftPane, satellite, closedPane] {
                for (how, value) in values {
                    var broken = base()
                    broken.set(WorkspaceKey(.pane, pane.raw, field), value)
                    assertConverges(broken, "pane field \(field) on \(pane.raw) carrying \(how)")
                }
                var missing = base()
                missing[WorkspaceKey(.pane, pane.raw, field)] = nil
                assertConverges(missing, "pane field \(field) missing from \(pane.raw)")
            }
        }
    }

    /// The other half of the partition: a liveness field must change the topology projection on
    /// NEITHER side, however broken it is.
    ///
    /// This is the assertion that would fire the day a field crossed the line in one language only.
    /// It is deliberately stronger than convergence — the two sides agreeing to read a liveness cell
    /// into the topology would be a converged wrong answer — so the corrupted document is compared
    /// against the UNTOUCHED one rather than against the other side.
    func testNoLivenessFieldReachesTheTopologyOnEitherSide() {
        let fields = PaneLiveness.livenessFields()
        XCTAssertFalse(fields.isEmpty, "the crate reports no liveness fields at all")
        let untouched = here(base())
        for field in fields {
            var broken = base()
            for pane in [anchorPane, leftPane, satellite, closedPane] {
                broken.set(WorkspaceKey(.pane, pane.raw, field), Data(repeating: 0xFF, count: 5))
            }
            let mine = assertConverges(broken, "liveness field \(field) filled with noise")
            XCTAssertEqual(mine, untouched, "liveness field \(field) reached the topology projection")
        }
    }

    /// The reserved root fields, which are the sharpest case of the same rule: an ingestion that
    /// read one would be reading config that deliberately does not cross, and a projection that
    /// wrote one would REAP whatever a future build put there.
    func testNoReservedRootFieldReachesTheTopologyOnEitherSide() {
        let reserved = WorkspaceTopologyOmissions.reservedRootFields
        XCTAssertFalse(reserved.isEmpty, "the crate reserves no root fields at all")
        let untouched = here(base())
        for field in reserved.sorted() {
            var broken = base()
            broken.set(.root(field), Data([0x01, 0x02, 0x03]))
            let mine = assertConverges(broken, "reserved root field \(field) carrying a future build's bytes")
            XCTAssertEqual(mine, untouched, "reserved root field \(field) reached the topology projection")
            XCTAssertNil(mine?[.root(field)], "the projection would reap a field it does not own")
        }
    }

    // MARK: - The named shapes, each a way a real document goes wrong

    func testTheDegenerateCorpusIsReadTheSameWayOnBothSidesOfTheBoundary() {
        for (name, document) in corpus() {
            assertConverges(document, name)
        }
    }

    /// Every shape worth disagreeing about that the mechanical walks above cannot reach, because
    /// each one is a claim the document makes about ANOTHER cell rather than a broken cell.
    ///
    /// Grouped by the cell that carries the claim, and the groups are separate functions only
    /// because one list of sixty is past the body-length gate — read them as one corpus.
    private func corpus() -> [(String, HostWorkspaceState)] {
        tabCases() + layoutCases() + weightCases() + focusCases() + ringCases() + detachedCases() + rootCases()
    }

    /// One case: the sound document with one edit, named by what the edit makes it.
    private func broken(_ name: String, _ edit: (inout HostWorkspaceState) -> Void) -> (String, HostWorkspaceState) {
        var document = base()
        edit(&document)
        return (name, document)
    }

    /// The tab, and the session that depends on having one.
    private func tabCases() -> [(String, HostWorkspaceState)] {
        [
            broken("a tab named in tabOrder with no layoutStructure") {
                $0[WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure)] = nil
            },
            broken("a session whose every tab is unusable") {
                $0[WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure)] = nil
                $0[WorkspaceKey(.tab, closedTab.raw, WorkspaceTabField.layoutStructure)] = nil
            },
            broken("a tabOrder naming a tab no cell describes") {
                $0.set(
                    WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.tabOrder),
                    WorkspaceStateCodec.encodeUUIDList([victimTab.raw, ghostTab.raw]),
                )
            },
            broken("a tab listed in two sessions' tabOrder") {
                $0.set(
                    WorkspaceKey(.session, anchorSession.raw, WorkspaceSessionField.tabOrder),
                    WorkspaceStateCodec.encodeUUIDList([anchorTab.raw, victimTab.raw]),
                )
            },
            broken("a tabOrder listing one tab twice") {
                $0.set(
                    WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.tabOrder),
                    WorkspaceStateCodec.encodeUUIDList([victimTab.raw, victimTab.raw]),
                )
            },
        ]
    }

    /// The layout blob itself, which two independent decoders read.
    private func layoutCases() -> [(String, HostWorkspaceState)] {
        [
            broken("a layout that is a split with no children") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
                    splitBytes(victimSplit.raw, axis: 0, children: []),
                )
            },
            broken("a layout that is a split with one child") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
                    splitBytes(victimSplit.raw, axis: 0, children: [leafBytes(leftPane.raw)]),
                )
            },
            broken("a layout claiming more children than it carries") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
                    splitBytes(victimSplit.raw, axis: 0, children: [leafBytes(leftPane.raw)], claiming: 4),
                )
            },
            broken("a layout naming a node tag no build knows") {
                $0.set(WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure), Data([7]))
            },
            broken("a layout whose axis byte is neither 0 nor 1") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
                    splitBytes(victimSplit.raw, axis: 200, children: [
                        leafBytes(leftPane.raw), leafBytes(rightPane.raw),
                    ]),
                )
            },
            broken("a layout naming the same pane twice") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
                    splitBytes(victimSplit.raw, axis: 0, children: [
                        leafBytes(leftPane.raw), leafBytes(leftPane.raw),
                    ]),
                )
            },
            broken("a layout naming a pane the tab has no spec for") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
                    splitBytes(victimSplit.raw, axis: 0, children: [
                        leafBytes(leftPane.raw), leafBytes(ghostPane.raw),
                    ]),
                )
            },
            broken("a layout whose splits carry the same id") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
                    splitBytes(victimSplit.raw, axis: 0, children: [
                        leafBytes(leftPane.raw),
                        splitBytes(victimSplit.raw, axis: 1, children: [
                            leafBytes(rightPane.raw), leafBytes(ghostPane.raw),
                        ]),
                    ]),
                )
            },
        ]
    }

    /// The weights, which ride in their own cell precisely so they can be lost alone.
    private func weightCases() -> [(String, HostWorkspaceState)] {
        let weight = WorkspaceKey(.splitNode, victimSplit.raw, WorkspaceSplitNodeField.weight)
        return [
            broken("a weight cell of a smaller arity than its split") {
                $0.set(weight, WorkspaceStateCodec.encodeWeights([.flex(9)]))
            },
            broken("a weight cell of a larger arity than its split") {
                $0.set(weight, WorkspaceStateCodec.encodeWeights([.flex(1), .flex(2), .flex(3)]))
            },
            broken("a starving weight beside a NaN one") {
                $0.set(weight, WorkspaceStateCodec.encodeWeights([.flex(0), .flex(.nan)]))
            },
            broken("a negative flex beside an infinite one") {
                $0.set(weight, WorkspaceStateCodec.encodeWeights([.flex(-5), .flex(.infinity)]))
            },
            broken("a fixed extent that is negative beside one that is NaN") {
                $0.set(weight, WorkspaceStateCodec.encodeWeights([.fixed(-1), .fixed(.nan)]))
            },
            broken("a weight cell naming a split that is not in any tab") {
                $0.set(
                    WorkspaceKey(.splitNode, ghostPane.raw, WorkspaceSplitNodeField.weight),
                    WorkspaceStateCodec.encodeWeights([.flex(4), .flex(4)]),
                )
            },
        ]
    }

    /// Focus and zoom, which name a pane and may name the wrong one.
    private func focusCases() -> [(String, HostWorkspaceState)] {
        let active = WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.activePaneID)
        let activeTab = WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.activeTabID)
        return [
            broken("an activePaneID naming a pane the tab does not contain") {
                $0.set(active, WorkspaceStateCodec.encodeUUID(ghostPane.raw))
            },
            broken("a zoomedPaneID naming a pane the tab does not contain") {
                $0.set(
                    WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.zoomedPaneID),
                    WorkspaceStateCodec.encodeUUID(ghostPane.raw),
                )
            },
            broken("an activePaneID naming a pane in the OTHER session's tab") {
                $0.set(active, WorkspaceStateCodec.encodeUUID(anchorPane.raw))
            },
            broken("an activePaneID naming the session's own DETACHED pane") {
                $0.set(active, WorkspaceStateCodec.encodeUUID(satellite.raw))
            },
            broken("an activeTabID naming a tab that was dropped") {
                $0[WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure)] = nil
                $0.set(activeTab, WorkspaceStateCodec.encodeUUID(victimTab.raw))
            },
            broken("an activeTabID naming a tab of another session") {
                $0.set(activeTab, WorkspaceStateCodec.encodeUUID(anchorTab.raw))
            },
        ]
    }

    /// The two rings.
    private func ringCases() -> [(String, HostWorkspaceState)] {
        [
            broken("a closedTabRing entry that is still live") {
                $0.set(
                    .root(WorkspaceRootField.closedTabRing),
                    WorkspaceStateCodec.encodeUUIDList([closedTab.raw, victimTab.raw]),
                )
            },
            broken("a closedTabRing naming one tab twice") {
                $0.set(
                    .root(WorkspaceRootField.closedTabRing),
                    WorkspaceStateCodec.encodeUUIDList([closedTab.raw, closedTab.raw]),
                )
            },
            broken("a closedTabRing naming a tab no cell describes") {
                $0.set(
                    .root(WorkspaceRootField.closedTabRing),
                    WorkspaceStateCodec.encodeUUIDList([ghostTab.raw]),
                )
            },
            broken("a closed tab with no back-pointer") {
                $0[WorkspaceKey(.tab, closedTab.raw, WorkspaceTabField.sessionID)] = nil
            },
            broken("a closed tab whose back-pointer names a session that is gone") {
                $0.set(
                    WorkspaceKey(.tab, closedTab.raw, WorkspaceTabField.sessionID),
                    WorkspaceStateCodec.encodeUUID(ghostSession.raw),
                )
            },
            broken("a closed tab with no layoutStructure") {
                $0[WorkspaceKey(.tab, closedTab.raw, WorkspaceTabField.layoutStructure)] = nil
            },
            broken("a closed tab whose pane is also a live tree leaf") {
                $0.set(
                    WorkspaceKey(.tab, closedTab.raw, WorkspaceTabField.layoutStructure),
                    leafBytes(leftPane.raw),
                )
            },
            broken("a focusMRU naming tabs that are gone") {
                $0.set(
                    WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.focusMRU),
                    WorkspaceStateCodec.encodeUUIDList([ghostTab.raw, victimTab.raw]),
                )
            },
            broken("an empty focusMRU") {
                $0.set(
                    WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.focusMRU),
                    WorkspaceStateCodec.encodeUUIDList([]),
                )
            },
            broken("a focusMRU on a session that was dropped") {
                $0[WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure)] = nil
                $0.set(
                    WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.focusMRU),
                    WorkspaceStateCodec.encodeUUIDList([victimTab.raw]),
                )
            },
        ]
    }

    /// The detached set, where tree membership is the tie-break.
    private func detachedCases() -> [(String, HostWorkspaceState)] {
        let key = WorkspaceKey(.session, victimSession.raw, WorkspaceSessionField.detachedPanes)
        return [
            broken("a detached pane shadowed by a tree leaf") {
                $0.set(key, WorkspaceStateCodec.encodeDetachedPanes([(leftPane.raw, nil)]))
            },
            broken("a detached pane listed twice") {
                $0.set(key, WorkspaceStateCodec.encodeDetachedPanes([
                    (satellite.raw, victimTab.raw), (satellite.raw, nil),
                ]))
            },
            broken("a detached pane whose origin tab is gone") {
                $0.set(key, WorkspaceStateCodec.encodeDetachedPanes([(satellite.raw, ghostTab.raw)]))
            },
            broken("a detached pane no cell describes") {
                $0.set(key, WorkspaceStateCodec.encodeDetachedPanes([(ghostPane.raw, nil)]))
            },
            broken("a detached record naming the OTHER session's leaf") {
                $0.set(key, WorkspaceStateCodec.encodeDetachedPanes([(anchorPane.raw, nil)]))
            },
        ]
    }

    /// The root, which decides whether there is a document at all.
    private func rootCases() -> [(String, HostWorkspaceState)] {
        [
            broken("a sessionOrder naming a session no cell describes") {
                $0.set(
                    .root(WorkspaceRootField.sessionOrder),
                    WorkspaceStateCodec.encodeUUIDList([anchorSession.raw, ghostSession.raw]),
                )
            },
            broken("a sessionOrder listing one session twice") {
                $0.set(
                    .root(WorkspaceRootField.sessionOrder),
                    WorkspaceStateCodec.encodeUUIDList([anchorSession.raw, anchorSession.raw]),
                )
            },
            broken("a sessionOrder that names nobody") {
                $0.set(.root(WorkspaceRootField.sessionOrder), WorkspaceStateCodec.encodeUUIDList([]))
            },
            broken("an activeSessionID naming a session that is not there") {
                $0.set(
                    .root(WorkspaceRootField.activeSessionID),
                    WorkspaceStateCodec.encodeUUID(ghostSession.raw),
                )
            },
            broken("an unattachedSessionID naming a session that is not there") {
                $0.set(
                    .root(WorkspaceRootField.unattachedSessionID),
                    WorkspaceStateCodec.encodeUUID(ghostSession.raw),
                )
            },
            broken("a hostDisplayName that is not UTF-8") {
                $0.set(.root(WorkspaceRootField.hostDisplayName), Data([0xC3, 0x28]))
            },
            broken("a document holding nothing but pane liveness") { document in
                document = HostWorkspaceState()
                document.merge(paneLiveness: PaneLiveness(paneID: leftPane.raw, liveness: .attached))
            },
        ]
    }

    // MARK: - The two layout decoders, at the depth where they part company

    /// Swift's `decodeLayout` is `slopdesk_workspace::state_codec`, iterative with an explicit
    /// frame stack; the crate's ingestion reads `slopdesk_wire::document::codec`, which recurses
    /// with a depth argument. Two readers of one grammar, counting depth two different ways, and
    /// nothing in the tree compares them — `snapshot_codec_parity.rs` pins the snapshot FRAME across
    /// those two crates and stops there.
    ///
    /// So the level is found rather than assumed: walk out from a lone leaf until this side refuses,
    /// and assert the crate refuses the same tab at the same level and keeps it at every level
    /// below. A cap moved on one side only fails here.
    func testTheTwoLayoutDecodersRefuseTheSameNestingAtTheSameLevel() throws {
        var refusedAt: Int?
        for levels in 0...20 {
            let bytes = chainBytes(levels)
            var document = base()
            document.set(WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure), bytes)
            let readable = (try? WorkspaceStateCodec.decodeLayout(bytes)) != nil
            if !readable, refusedAt == nil { refusedAt = levels }
            // Past the point where a tab is merely deep, the applier's own acceptance gate refuses
            // the whole document rather than the tab — a different rule, tested on its own below —
            // so the convergence assertion stops where the ingestion stops being the last word.
            guard levels <= Int(slopdesk_ws_max_depth()) - 1 || !readable else { continue }
            let survives = here(document)?.entries[
                WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure),
            ] != nil
            XCTAssertEqual(survives, readable, "this side kept a tab whose layout it could not read")
            assertConverges(document, "a layout nested \(levels) splits deep")
        }
        let cap = try XCTUnwrap(refusedAt, "no nesting in 0...20 was refused — the depth cap has gone")
        XCTAssertGreaterThan(cap, Int(slopdesk_ws_max_depth()), "the layout cap is below the tree's own")
    }

    /// The one shape both ingestions read identically and no intent can then touch.
    ///
    /// A tab whose tree is deeper than `slopdesk_ws_max_depth()` still decodes — the layout cap sits
    /// above the tree cap — so both sides ingest it whole, and then `apply`'s acceptance gate
    /// refuses every op over it. Recorded rather than repaired, because it is a real property of a
    /// hand-edited document: it renders, and it cannot be gestured on.
    func testADocumentNestedPastTheTreeCapIngestsOnBothSidesAndAcceptsNoIntent() {
        let deep = Int(slopdesk_ws_max_depth())
        var document = base()
        document.set(WorkspaceKey(.tab, victimTab.raw, WorkspaceTabField.layoutStructure), chainBytes(deep))
        XCTAssertNotNil(here(document), "this side refused a layout the decoder accepted")
        XCTAssertEqual(
            TopologyCrossing.cross(document, op: TopologyCrossing.unclaimedOp, args: Data()).status,
            TopologyCrossing.unknownOp,
            "the crate refused to ingest a document its own decoder accepted",
        )
        XCTAssertEqual(
            TopologyCrossing.cross(
                document,
                op: WorkspaceIntentOp.setSyncInput.rawValue,
                args: WorkspaceIntentArgs.encode(id: anchorTab.raw, flag: false),
            ).status,
            slopdesk_ws_intent_status(2),
            "a tree past the tree cap was gestured on rather than frozen",
        )
    }

    // MARK: - The two string clamps, at the boundary they must not split

    /// Both projections clamp a string to `slopdesk_ws_max_string_bytes()`, and they are two
    /// implementations of the clamp: `slopdesk_wire::bytes::clamp_utf8` walks `char_indices`
    /// forward, `slopdesk_workspace::state_codec::encode_string` walks the boundary backward. They
    /// can only differ where a multi-byte scalar STRADDLES the limit, so that is the case.
    func testAStringClampedAtAScalarBoundaryComesBackTheSameLengthOnBothSides() {
        let cap = WorkspaceStateCodec.maxStringBytes
        // One three-byte scalar with its first byte inside the limit and its last outside it.
        let straddling = String(repeating: "a", count: cap - 1) + "€" + "tail"
        var document = base()
        document.set(.root(WorkspaceRootField.hostDisplayName), Data(straddling.utf8))
        let mine = assertConverges(document, "a host name whose clamp falls inside a scalar")
        let kept = mine?[.root(WorkspaceRootField.hostDisplayName)] ?? Data()
        XCTAssertEqual(kept.count, cap - 1, "the clamp kept a partial scalar or dropped a whole one too many")
        XCTAssertNotNil(String(data: kept, encoding: .utf8), "the clamp cut a scalar in half")
    }

    // MARK: - Layout bytes, hand-built so a shape no encoder emits can still be fed

    private func uuidBytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    private func leafBytes(_ pane: UUID) -> Data {
        Data([0]) + uuidBytes(pane)
    }

    /// `[1][16B id][u8 axis][u8 n]` then the children. `claiming` lies about `n` where a case wants
    /// a split that promises children it does not carry.
    private func splitBytes(_ id: UUID, axis: UInt8, children: [Data], claiming: UInt8? = nil) -> Data {
        var out = Data([1])
        out.append(uuidBytes(id))
        out.append(axis)
        out.append(claiming ?? UInt8(truncatingIfNeeded: children.count))
        for child in children { out.append(child) }
        return out
    }

    /// `levels` nested splits ending in one leaf. `levels == 0` is the bare leaf.
    private func chainBytes(_ levels: Int) -> Data {
        var node = leafBytes(leftPane.raw)
        for level in 0..<levels {
            node = splitBytes(uuid(UInt8(truncatingIfNeeded: 0xA0 + level)), axis: 0, children: [node])
        }
        return node
    }
}
