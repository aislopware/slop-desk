import CSlopDeskFFI
import Foundation
import SlopDeskArena

// MARK: - Verb / kind vocabulary

/// The client → host verbs multiplexed inside type 17 (`workspaceRequest`), docs/45 §5.2.
///
/// Verb-multiplexing an envelope — the `metadataRequest` (16) shape — is why the workspace document
/// costs exactly TWO type numbers no matter how many operations it grows. Every new verb after this
/// costs zero, and never shifts an unknown-type probe again (three of them pinned 17 before this
/// document claimed it).
public enum WorkspaceRequestVerb: UInt8, Sendable, CaseIterable {
    /// Also the RESYNC verb: re-sending `subscribe` is how a client recovers from a mis-based diff.
    /// There is deliberately no separate "resend" — reconnect and steady state are one code path.
    case subscribe = 0
    case ack = 1
    case presence = 2
    case intent = 3
}

/// The host → client frame kinds multiplexed inside type 37 (`workspaceEvent`), docs/45 §5.2.
public enum WorkspaceEventKind: UInt8, Sendable, CaseIterable {
    case snapshot = 0
    case diff = 1
    /// Full replace, NEVER diffed, and never touching `stateNum` — presence is not part of the
    /// document and must not make the host retire, via `assumedAcked`, a diff it never sent.
    case presence = 2
    case intentResult = 3
    /// Drop everything and resubscribe from 0. Carries the NEW epoch.
    case reset = 4
}

/// The outcome of one intent, carried by ``WorkspaceEventKind/intentResult``.
public enum WorkspaceIntentStatus: UInt8, Sendable, CaseIterable {
    case applied = 0
    case rejectedStale = 1
    case rejectedInvalid = 2
    case unknownOp = 3
    case rejectedNotFound = 4
}

/// Which kind of device is on the far end. A LABEL, not a credential: it is checked nowhere and
/// grants nothing, so the no-app-layer-auth directive is untouched.
public enum WorkspaceClientKind: UInt8, Sendable, CaseIterable {
    case macOS = 0
    case iOS = 1

    /// The kind THIS build is. The host branches on it for the size fold (an iPhone is size-passive)
    /// and the roster shows it, so it must be decided at compile time rather than guessed.
    public static var thisPlatform: Self {
        #if os(iOS)
        .iOS
        #else
        .macOS
        #endif
    }
}

// MARK: - subscribe (verb 0)

/// `[16B clientInstanceID][u8 clientKind][16B knownEpoch][i64 BE knownStateNum][u8 flags][u16 BE labelLen][label]`
public struct WorkspaceSubscribe: Equatable, Sendable {
    /// Minted per CONNECTION, not per install — two windows of one app are two identities.
    public var clientInstanceID: UUID
    public var clientKind: UInt8
    /// All-zero + `knownStateNum == 0` means "I know nothing"; a snapshot follows.
    public var knownEpoch: UUID
    public var knownStateNum: Int64
    public var flags: UInt8
    /// A human device name. Bounded at ``maxLabelBytes`` so a hostile peer cannot make the host
    /// retain an arbitrarily long string per connection.
    public var label: String

    /// b0 — this client's viewport participates in the PTY size fold (docs/45 §8.3). Read from the
    /// crate that puts the byte on the wire, like ``maxLabelBytes`` two lines down: a bit spelled
    /// here as well is a mask the two ends can stop agreeing about, and the symptom is a client that
    /// quietly stops counting toward the fold rather than a decode that fails.
    public static let flagContributesSize = UInt8(truncatingIfNeeded: slopdesk_workspace_constant(5))
    /// b1 — this client follows host focus rather than steering its own view (docs/45 §8.2).
    public static let flagFollowsFocus = UInt8(truncatingIfNeeded: slopdesk_workspace_constant(6))
    /// The label cap, read from the crate that enforces it rather than respelled here.
    public static let maxLabelBytes = Int(slopdesk_workspace_constant(0))

    public var contributesSize: Bool { flags & Self.flagContributesSize != 0 }
    public var followsFocus: Bool { flags & Self.flagFollowsFocus != 0 }

    public init(
        clientInstanceID: UUID,
        clientKind: UInt8,
        knownEpoch: UUID = WireMessage.newSessionID,
        knownStateNum: Int64 = 0,
        flags: UInt8 = 0,
        label: String = "",
    ) {
        self.clientInstanceID = clientInstanceID
        self.clientKind = clientKind
        self.knownEpoch = knownEpoch
        self.knownStateNum = knownStateNum
        self.flags = flags
        self.label = label
    }

    public func encode() -> Data {
        var pool = [UInt8]()
        let record = SlopDeskWorkspaceSubscribe(
            client_instance_id: WorkspaceChannelCodec.flat(clientInstanceID),
            known_epoch: WorkspaceChannelCodec.flat(knownEpoch),
            known_state_num: knownStateNum,
            label: WorkspaceChannelCodec.intern(label, &pool),
            client_kind: clientKind,
            flags: flags,
        )
        return WorkspaceChannelCodec.sized { out, cap in
            withUnsafePointer(to: record) { one in
                pool.withUnsafeBufferPointer { arena in
                    slopdesk_workspace_encode_subscribe(one, arena.baseAddress, arena.count, out, cap)
                }
            }
        }
    }

    public static func decode(_ payload: Data) throws -> Self {
        // The label is capped, so the arena it lands in is a fixed 64 bytes rather than a fraction
        // of the payload — the only decode here whose bound is a cap and not a length.
        try WorkspaceChannelCodec.decode(
            payload, arenaBytes: maxLabelBytes, "workspace subscribe",
            slopdesk_workspace_decode_subscribe,
        ) { record, arena in
            Self(
                clientInstanceID: WorkspaceChannelCodec.uuid(record.client_instance_id),
                clientKind: record.client_kind,
                knownEpoch: WorkspaceChannelCodec.uuid(record.known_epoch),
                knownStateNum: record.known_state_num,
                flags: record.flags,
                label: WorkspaceChannelCodec.text(arena, record.label),
            )
        }
    }
}

// MARK: - presence (verb 2)

/// `[i64 BE presenceClock][16B viewingTabID][16B viewingPaneID][u16 cols][u16 rows][u8 flags]`
public struct WorkspacePresenceUpdate: Equatable, Sendable {
    /// Per-client monotone. NEWEST WINS, with no merge — an older clock from a reconnecting client
    /// must never resurrect a view it has since left.
    public var presenceClock: Int64
    public var viewingTabID: UUID
    public var viewingPaneID: UUID
    public var cols: UInt16
    public var rows: UInt16
    public var flags: UInt8

    public var contributesSize: Bool { flags & WorkspaceSubscribe.flagContributesSize != 0 }

    public init(
        presenceClock: Int64,
        viewingTabID: UUID = WireMessage.newSessionID,
        viewingPaneID: UUID = WireMessage.newSessionID,
        cols: UInt16 = 0,
        rows: UInt16 = 0,
        flags: UInt8 = 0,
    ) {
        self.presenceClock = presenceClock
        self.viewingTabID = viewingTabID
        self.viewingPaneID = viewingPaneID
        self.cols = cols
        self.rows = rows
        self.flags = flags
    }

    public func encode() -> Data {
        let record = SlopDeskWorkspacePresence(
            presence_clock: presenceClock,
            viewing_tab_id: WorkspaceChannelCodec.flat(viewingTabID),
            viewing_pane_id: WorkspaceChannelCodec.flat(viewingPaneID),
            cols: cols,
            rows: rows,
            flags: flags,
        )
        return WorkspaceChannelCodec.sized { out, cap in
            withUnsafePointer(to: record) { slopdesk_workspace_encode_presence($0, out, cap) }
        }
    }

    public static func decode(_ payload: Data) throws -> Self {
        let entry = slopdesk_workspace_decode_presence
        return try WorkspaceChannelCodec.decode(payload, "workspace presence", entry) { record in
            Self(
                presenceClock: record.presence_clock,
                viewingTabID: WorkspaceChannelCodec.uuid(record.viewing_tab_id),
                viewingPaneID: WorkspaceChannelCodec.uuid(record.viewing_pane_id),
                cols: record.cols,
                rows: record.rows,
                flags: record.flags,
            )
        }
    }
}

// MARK: - intent (verb 3)

/// `[16B intentID][u8 op][u32 BE argLen][args…]`
public struct WorkspaceIntent: Equatable, Sendable {
    /// Client-minted so the host's `intentResult` can be matched to the optimistic local patch that
    /// is standing in for it.
    public var intentID: UUID
    public var op: UInt8
    public var args: Data

    public init(intentID: UUID, op: UInt8, args: Data = Data()) {
        self.intentID = intentID
        self.op = op
        self.args = args
    }

    public func encode() -> Data {
        let id = WorkspaceChannelCodec.flat(intentID)
        return WorkspaceChannelCodec.sized { out, cap in
            withUnsafePointer(to: id) { one in
                args.spanning { bytes, length in
                    slopdesk_workspace_encode_intent(
                        one, op, bytes?.assumingMemoryBound(to: UInt8.self), length, out, cap,
                    )
                }
            }
        }
    }

    public static func decode(_ payload: Data) throws -> Self {
        // The arguments are opaque here and run to the frame cap, so the decode answers WHERE they
        // sit in the payload and this is the ONE copy of them.
        let flat = try WorkspaceChannelCodec.decode(
            payload, "workspace intent", slopdesk_workspace_decode_intent,
        ) { $0 }
        let start = Int(flat.args.offset)
        let args = payload.withUnsafeBytes { bytes in
            Data(bytes[start..<start + Int(flat.args.length)])
        }
        return Self(intentID: WorkspaceChannelCodec.uuid(flat.intent_id), op: flat.op, args: args)
    }
}

// MARK: - intentResult (kind 3)

/// `[16B intentID][u8 status]`
public struct WorkspaceIntentResult: Equatable, Sendable {
    public var intentID: UUID
    public var status: UInt8

    public init(intentID: UUID, status: WorkspaceIntentStatus) {
        self.intentID = intentID
        self.status = status.rawValue
    }

    public init(intentID: UUID, statusByte: UInt8) {
        self.intentID = intentID
        status = statusByte
    }

    public func encode() -> Data {
        let record = SlopDeskWorkspaceIntentResult(
            intent_id: WorkspaceChannelCodec.flat(intentID), status: status,
        )
        return WorkspaceChannelCodec.sized { out, cap in
            withUnsafePointer(to: record) { slopdesk_workspace_encode_intent_result($0, out, cap) }
        }
    }

    public static func decode(_ payload: Data) throws -> Self {
        try WorkspaceChannelCodec.decode(
            payload, "workspace intent result", slopdesk_workspace_decode_intent_result,
        ) { record in
            Self(intentID: WorkspaceChannelCodec.uuid(record.intent_id), statusByte: record.status)
        }
    }
}

// MARK: - presence roster (kind 2)

/// One client currently on this host, as the host describes it to everyone else.
public struct WorkspaceRosterClient: Equatable, Sendable {
    public var clientInstanceID: UUID
    public var clientKind: UInt8
    public var flags: UInt8
    public var viewingTabID: UUID
    public var viewingPaneID: UUID
    public var cols: UInt16
    public var rows: UInt16
    public var label: String

    public init(
        clientInstanceID: UUID,
        clientKind: UInt8,
        flags: UInt8 = 0,
        viewingTabID: UUID = WireMessage.newSessionID,
        viewingPaneID: UUID = WireMessage.newSessionID,
        cols: UInt16 = 0,
        rows: UInt16 = 0,
        label: String = "",
    ) {
        self.clientInstanceID = clientInstanceID
        self.clientKind = clientKind
        self.flags = flags
        self.viewingTabID = viewingTabID
        self.viewingPaneID = viewingPaneID
        self.cols = cols
        self.rows = rows
        self.label = label
    }
}

/// Who is attached to one pane, and the grid the size fold resolved for it.
public struct WorkspaceRosterPane: Equatable, Sendable {
    public struct Attachment: Equatable, Sendable {
        public var clientInstanceID: UUID
        public var contributes: Bool
        public var cols: UInt16
        public var rows: UInt16

        public init(clientInstanceID: UUID, contributes: Bool, cols: UInt16, rows: UInt16) {
            self.clientInstanceID = clientInstanceID
            self.contributes = contributes
            self.cols = cols
            self.rows = rows
        }
    }

    public var paneID: UUID
    public var resolvedCols: UInt16
    public var resolvedRows: UInt16
    public var attachments: [Attachment]

    public init(paneID: UUID, resolvedCols: UInt16, resolvedRows: UInt16, attachments: [Attachment]) {
        self.paneID = paneID
        self.resolvedCols = resolvedCols
        self.resolvedRows = resolvedRows
        self.attachments = attachments
    }
}

/// `[u16 clientCount][clientRecord…][u16 paneCount][paneAttachRecord…]`
///
/// Presence is DERIVED, TTL-expired and never persisted, so it is broadcast whole every time rather
/// than diffed. Keeping it in the versioned document would persist dead connection UUIDs across a
/// restart and churn `stateNum` on every WireGuard flap.
///
/// A roster is panes each holding attachments, and a nest cannot cross without a pointer per pane.
/// It crosses as THREE flat arrays instead — clients, panes, attachments — with each pane naming its
/// run `(offset, count)` into the attachment array, the same trick the arena plays for text.
public struct WorkspacePresenceRoster: Equatable, Sendable {
    public var clients: [WorkspaceRosterClient]
    public var panes: [WorkspaceRosterPane]

    public init(clients: [WorkspaceRosterClient] = [], panes: [WorkspaceRosterPane] = []) {
        self.clients = clients
        self.panes = panes
    }

    /// Upper bound on each list. Real rosters are single digits; this only exists so a hostile count
    /// is rejected by arithmetic before it can drive an allocation.
    public static let maxRecords = Int(slopdesk_workspace_constant(1))

    public func encode() -> Data {
        var pool = [UInt8]()
        let flatClients = clients.map { client in
            SlopDeskWorkspaceRosterClient(
                client_instance_id: WorkspaceChannelCodec.flat(client.clientInstanceID),
                viewing_tab_id: WorkspaceChannelCodec.flat(client.viewingTabID),
                viewing_pane_id: WorkspaceChannelCodec.flat(client.viewingPaneID),
                label: WorkspaceChannelCodec.intern(client.label, &pool),
                cols: client.cols,
                rows: client.rows,
                client_kind: client.clientKind,
                flags: client.flags,
            )
        }
        var flatAttachments: [SlopDeskWorkspaceRosterAttachment] = []
        let flatPanes = panes.map { pane in
            let offset = UInt32(clamping: flatAttachments.count)
            flatAttachments.append(contentsOf: pane.attachments.map { attachment in
                SlopDeskWorkspaceRosterAttachment(
                    client_instance_id: WorkspaceChannelCodec.flat(attachment.clientInstanceID),
                    cols: attachment.cols,
                    rows: attachment.rows,
                    contributes: attachment.contributes,
                )
            })
            return SlopDeskWorkspaceRosterPane(
                pane_id: WorkspaceChannelCodec.flat(pane.paneID),
                attachments: SlopDeskWorkspaceRun(
                    offset: offset, count: UInt32(clamping: pane.attachments.count),
                ),
                resolved_cols: pane.resolvedCols,
                resolved_rows: pane.resolvedRows,
            )
        }
        return WorkspaceChannelCodec.sized { out, cap in
            flatClients.withUnsafeBufferPointer { clientList in
                flatPanes.withUnsafeBufferPointer { paneList in
                    flatAttachments.withUnsafeBufferPointer { attachmentList in
                        pool.withUnsafeBufferPointer { arena in
                            slopdesk_workspace_encode_roster(
                                clientList.baseAddress, clientList.count,
                                paneList.baseAddress, paneList.count,
                                attachmentList.baseAddress, attachmentList.count,
                                arena.baseAddress, arena.count, out, cap,
                            )
                        }
                    }
                }
            }
        }
    }

    public static func decode(_ payload: Data) throws -> Self {
        // Every buffer is bounded by the payload itself: no list can hold more records than
        // `payload.count / theSmallestSuchRecord`, and no arena can exceed the payload. So the sizes
        // come off the bytes already in hand and the call happens ONCE.
        let clientRoom = WorkspaceChannelCodec.room(payload, perRecord: 2)
        let paneRoom = WorkspaceChannelCodec.room(payload, perRecord: 3)
        let attachmentRoom = WorkspaceChannelCodec.room(payload, perRecord: 4)
        return try payload.spanning { bytes, length in
            try withUnsafeTemporaryAllocation(
                of: SlopDeskWorkspaceRosterClient.self, capacity: clientRoom,
            ) { clientSlots in
                try withUnsafeTemporaryAllocation(
                    of: SlopDeskWorkspaceRosterPane.self, capacity: paneRoom,
                ) { paneSlots in
                    try withUnsafeTemporaryAllocation(
                        of: SlopDeskWorkspaceRosterAttachment.self, capacity: attachmentRoom,
                    ) { attachmentSlots in
                        try withUnsafeTemporaryAllocation(
                            of: UInt8.self, capacity: Swift.max(payload.count, 1),
                        ) { arena in
                            var clientCount = 0
                            var paneCount = 0
                            var attachmentCount = 0
                            let verdict = slopdesk_workspace_decode_roster(
                                bytes?.assumingMemoryBound(to: UInt8.self), length,
                                clientSlots.baseAddress, clientSlots.count, &clientCount,
                                paneSlots.baseAddress, paneSlots.count, &paneCount,
                                attachmentSlots.baseAddress, attachmentSlots.count, &attachmentCount,
                                arena.baseAddress, arena.count,
                            )
                            try WorkspaceChannelCodec.throwIfFaulted(verdict, "workspace roster")
                            let pool = UnsafeRawBufferPointer(arena)
                            return Self(
                                clients: (0..<clientCount).map { built(clientSlots[$0], pool) },
                                panes: (0..<paneCount).map { built(paneSlots[$0], attachmentSlots) },
                            )
                        }
                    }
                }
            }
        }
    }

    /// One client, read out of its record and the arena its label landed in.
    private static func built(
        _ record: SlopDeskWorkspaceRosterClient,
        _ arena: UnsafeRawBufferPointer,
    ) -> WorkspaceRosterClient {
        WorkspaceRosterClient(
            clientInstanceID: WorkspaceChannelCodec.uuid(record.client_instance_id),
            clientKind: record.client_kind,
            flags: record.flags,
            viewingTabID: WorkspaceChannelCodec.uuid(record.viewing_tab_id),
            viewingPaneID: WorkspaceChannelCodec.uuid(record.viewing_pane_id),
            cols: record.cols,
            rows: record.rows,
            label: WorkspaceChannelCodec.text(arena, record.label),
        )
    }

    /// One pane, with its run of the flat attachment array read back into a nest.
    private static func built(
        _ record: SlopDeskWorkspaceRosterPane,
        _ attachments: UnsafeMutableBufferPointer<SlopDeskWorkspaceRosterAttachment>,
    ) -> WorkspaceRosterPane {
        let start = Int(record.attachments.offset)
        let end = start + Int(record.attachments.count)
        return WorkspaceRosterPane(
            paneID: WorkspaceChannelCodec.uuid(record.pane_id),
            resolvedCols: record.resolved_cols,
            resolvedRows: record.resolved_rows,
            attachments: (start..<end).map { slot in
                WorkspaceRosterPane.Attachment(
                    clientInstanceID: WorkspaceChannelCodec.uuid(attachments[slot].client_instance_id),
                    contributes: attachments[slot].contributes,
                    cols: attachments[slot].cols,
                    rows: attachments[slot].rows,
                )
            },
        )
    }
}

// MARK: - Shared helpers

/// Namespace for the bits the workspace payload codecs share. Not a codec itself — every layout,
/// clamp and validation lives in `rust/slopdesk-wire`'s `workspace` module, and the ENVELOPE is
/// ``WireMessage/workspaceRequest(requestSeq:verb:payload:)`` /
/// ``WireMessage/workspaceEvent(kind:epoch:baseStateNum:newStateNum:payload:)`` while the document
/// entries are `WorkspaceStateCodec` in the model target.
public enum WorkspaceChannelCodec {
    /// A UUID as the sixteen bytes the wire orders them in.
    static func flat(_ uuid: UUID) -> SlopDeskWsUuid {
        SlopDeskWsUuid(bytes: uuid.uuid)
    }

    /// The UUID those sixteen bytes are.
    static func uuid(_ flat: SlopDeskWsUuid) -> UUID {
        UUID(uuid: flat.bytes)
    }

    /// Appends `string`'s UTF-8 to the arena and answers where it landed.
    ///
    /// The pool is `[UInt8]` rather than `Data` because `Data.append` per text field measured 3–4×
    /// the cost of `Array.append(contentsOf:)` at list sizes this wire really carries.
    static func intern(_ string: String, _ pool: inout [UInt8]) -> SlopDeskWorkspaceText {
        let offset = UInt32(clamping: pool.count)
        pool.append(contentsOf: string.utf8)
        return SlopDeskWorkspaceText(offset: offset, length: UInt32(clamping: pool.count) - offset)
    }

    /// Reads a text field out of the arena a decode filled.
    ///
    /// This face answered `""` for a byte sequence that is not UTF-8 where the crate's own reader
    /// repairs it; it now agrees with the crate. The branch is unreachable — the arena was filled by
    /// a Rust `String` in the same call — which is why the disagreement survived unseen.
    static func text(_ arena: UnsafeRawBufferPointer, _ field: SlopDeskWorkspaceText) -> String {
        ArenaText.text(arena, field.offset, field.length)
    }

    /// How many records of a kind the payload could possibly hold.
    ///
    /// `perRecord` is the ``slopdesk_workspace_constant(_:)`` INDEX of that kind's smallest size, not
    /// the size — the number itself stays in the crate that enforces it.
    static func room(_ payload: Data, perRecord: UInt32) -> Int {
        let smallest = Int(slopdesk_workspace_constant(perRecord))
        return Swift.max(payload.count / Swift.max(smallest, 1), 1)
    }

    /// Encodes by the §4 convention: ask for the size, then fill exactly that.
    static func sized(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data {
        let needed = call(nil, 0)
        return WireBuffer.filled(needed) { out in
            let written = call(out?.assumingMemoryBound(to: UInt8.self), needed)
            precondition(
                written == needed, "the workspace codec sized a payload differently than it wrote it",
            )
        }
    }

    /// Decodes a fixed-size payload — one record, no arena.
    static func decode<Record, Item>(
        _ payload: Data,
        _ context: String,
        _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Record>?) -> UInt32,
        _ build: (Record) -> Item,
    ) throws -> Item {
        try withUnsafeTemporaryAllocation(of: Record.self, capacity: 1) { record in
            let verdict = payload.spanning { bytes, length in
                call(bytes?.assumingMemoryBound(to: UInt8.self), length, record.baseAddress)
            }
            try throwIfFaulted(verdict, context)
            return build(record[0])
        }
    }

    /// Decodes a payload that is one record plus an arena its text lands in.
    static func decode<Record, Item>(
        _ payload: Data,
        arenaBytes: Int,
        _ context: String,
        _ call: (
            UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Record>?, UnsafeMutablePointer<UInt8>?, Int,
        ) -> UInt32,
        _ build: (Record, UnsafeRawBufferPointer) -> Item,
    ) throws -> Item {
        try withUnsafeTemporaryAllocation(of: Record.self, capacity: 1) { record in
            try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Swift.max(arenaBytes, 1)) { arena in
                let verdict = payload.spanning { bytes, length in
                    call(
                        bytes?.assumingMemoryBound(to: UInt8.self), length,
                        record.baseAddress, arena.baseAddress, arena.count,
                    )
                }
                try throwIfFaulted(verdict, context)
                return build(record[0], UnsafeRawBufferPointer(arena))
            }
        }
    }

    /// Throws the error a non-OK verdict names.
    ///
    /// `AGAIN` cannot reach a caller here: every buffer is sized off the payload or the cap that
    /// bounds it, so a short one would be a boundary bug rather than a hostile body — and is trapped
    /// as one.
    static func throwIfFaulted(_ verdict: UInt32, _ context: String) throws {
        switch verdict {
        case SLOPDESK_WIRE_DECODE_OK: return
        case SLOPDESK_WIRE_DECODE_TRUNCATED: throw SlopDeskError.truncated
        case SLOPDESK_WIRE_DECODE_AGAIN:
            preconditionFailure("\(context): a payload out-grew the buffers it bounds")
        default: throw SlopDeskError.malformedBody("\(context): rejected by the workspace codec")
        }
    }
}
