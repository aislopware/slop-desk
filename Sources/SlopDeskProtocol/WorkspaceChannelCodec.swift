import Foundation

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

    /// b0 — this client's viewport participates in the PTY size fold (docs/45 §8.3).
    public static let flagContributesSize: UInt8 = 1 << 0
    /// b1 — this client follows host focus rather than steering its own view (docs/45 §8.2).
    public static let flagFollowsFocus: UInt8 = 1 << 1
    public static let maxLabelBytes = 64

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
        var out = Data()
        out.append(clientInstanceID.dataBytes)
        out.append(clientKind)
        out.append(knownEpoch.dataBytes)
        out.appendBE(knownStateNum)
        out.append(flags)
        let labelBytes = WorkspaceChannelCodec.clampUTF8(label, maxBytes: Self.maxLabelBytes)
        out.appendBE(UInt16(labelBytes.count))
        out.append(labelBytes)
        return out
    }

    public static func decode(_ payload: Data) throws -> Self {
        var reader = BigEndianReader(payload)
        let clientInstanceID = try WorkspaceChannelCodec.readUUID(&reader)
        let clientKind = try reader.readUInt8()
        let knownEpoch = try WorkspaceChannelCodec.readUUID(&reader)
        let knownStateNum = try reader.readInt64()
        let flags = try reader.readUInt8()
        let labelLen = try Int(reader.readUInt16())
        // Bound the DECLARED length against both the cap and the bytes actually present, before any
        // allocation. An over-long label is malformed, not clamped: silently truncating a field a
        // peer over-declared hides a framing bug behind a plausible value.
        guard labelLen <= maxLabelBytes else {
            throw SlopDeskError.malformedBody("workspace subscribe: label \(labelLen) > \(maxLabelBytes)")
        }
        let labelBytes = try reader.readBytes(labelLen)
        guard let label = String(data: labelBytes, encoding: .utf8) else {
            throw SlopDeskError.malformedBody("workspace subscribe: label is not valid UTF-8")
        }
        return Self(
            clientInstanceID: clientInstanceID,
            clientKind: clientKind,
            knownEpoch: knownEpoch,
            knownStateNum: knownStateNum,
            flags: flags,
            label: label,
        )
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
        var out = Data()
        out.appendBE(presenceClock)
        out.append(viewingTabID.dataBytes)
        out.append(viewingPaneID.dataBytes)
        out.appendBE(cols)
        out.appendBE(rows)
        out.append(flags)
        return out
    }

    public static func decode(_ payload: Data) throws -> Self {
        var reader = BigEndianReader(payload)
        return try Self(
            presenceClock: reader.readInt64(),
            viewingTabID: WorkspaceChannelCodec.readUUID(&reader),
            viewingPaneID: WorkspaceChannelCodec.readUUID(&reader),
            cols: reader.readUInt16(),
            rows: reader.readUInt16(),
            flags: reader.readUInt8(),
        )
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
        var out = Data()
        out.append(intentID.dataBytes)
        out.append(op)
        out.appendBE(UInt32(args.count))
        out.append(args)
        return out
    }

    public static func decode(_ payload: Data) throws -> Self {
        var reader = BigEndianReader(payload)
        let intentID = try WorkspaceChannelCodec.readUUID(&reader)
        let op = try reader.readUInt8()
        let argLen = try reader.readUInt32()
        // A hostile `UInt32.max` must cost nothing: check against the bytes ACTUALLY left first.
        guard argLen <= UInt32(Int32.max), reader.bytesRemaining >= Int(argLen) else {
            throw SlopDeskError.truncated
        }
        return try Self(intentID: intentID, op: op, args: reader.readBytes(Int(argLen)))
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
        var out = Data()
        out.append(intentID.dataBytes)
        out.append(status)
        return out
    }

    public static func decode(_ payload: Data) throws -> Self {
        var reader = BigEndianReader(payload)
        return try Self(intentID: WorkspaceChannelCodec.readUUID(&reader), statusByte: reader.readUInt8())
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
public struct WorkspacePresenceRoster: Equatable, Sendable {
    public var clients: [WorkspaceRosterClient]
    public var panes: [WorkspaceRosterPane]

    public init(clients: [WorkspaceRosterClient] = [], panes: [WorkspaceRosterPane] = []) {
        self.clients = clients
        self.panes = panes
    }

    /// Upper bound on each list. Real rosters are single digits; this only exists so a hostile count
    /// is rejected by arithmetic before it can drive an allocation.
    public static let maxRecords = 4096

    public func encode() -> Data {
        var out = Data()
        out.appendBE(UInt16(truncatingIfNeeded: min(clients.count, Self.maxRecords)))
        for client in clients.prefix(Self.maxRecords) {
            out.append(client.clientInstanceID.dataBytes)
            out.append(client.clientKind)
            out.append(client.flags)
            out.append(client.viewingTabID.dataBytes)
            out.append(client.viewingPaneID.dataBytes)
            out.appendBE(client.cols)
            out.appendBE(client.rows)
            let labelBytes = WorkspaceChannelCodec.clampUTF8(
                client.label,
                maxBytes: WorkspaceSubscribe.maxLabelBytes,
            )
            out.appendBE(UInt16(labelBytes.count))
            out.append(labelBytes)
        }
        out.appendBE(UInt16(truncatingIfNeeded: min(panes.count, Self.maxRecords)))
        for pane in panes.prefix(Self.maxRecords) {
            out.append(pane.paneID.dataBytes)
            out.appendBE(pane.resolvedCols)
            out.appendBE(pane.resolvedRows)
            out.appendBE(UInt16(truncatingIfNeeded: min(pane.attachments.count, Self.maxRecords)))
            for attachment in pane.attachments.prefix(Self.maxRecords) {
                out.append(attachment.clientInstanceID.dataBytes)
                out.append(attachment.contributes ? 1 : 0)
                out.appendBE(attachment.cols)
                out.appendBE(attachment.rows)
            }
        }
        return out
    }

    public static func decode(_ payload: Data) throws -> Self {
        var reader = BigEndianReader(payload)
        let clientCount = try Int(reader.readUInt16())
        // Cheapest client record: two UUIDs + kind + flags + cols + rows + a zero label length.
        guard reader.bytesRemaining >= clientCount * 42 else { throw SlopDeskError.truncated }
        var clients: [WorkspaceRosterClient] = []
        clients.reserveCapacity(clientCount)
        for _ in 0..<clientCount {
            let id = try WorkspaceChannelCodec.readUUID(&reader)
            let kind = try reader.readUInt8()
            let flags = try reader.readUInt8()
            let tab = try WorkspaceChannelCodec.readUUID(&reader)
            let pane = try WorkspaceChannelCodec.readUUID(&reader)
            let cols = try reader.readUInt16()
            let rows = try reader.readUInt16()
            let labelLen = try Int(reader.readUInt16())
            guard labelLen <= WorkspaceSubscribe.maxLabelBytes else {
                throw SlopDeskError.malformedBody("workspace roster: label \(labelLen) over cap")
            }
            let labelBytes = try reader.readBytes(labelLen)
            guard let label = String(data: labelBytes, encoding: .utf8) else {
                throw SlopDeskError.malformedBody("workspace roster: label is not valid UTF-8")
            }
            clients.append(WorkspaceRosterClient(
                clientInstanceID: id,
                clientKind: kind,
                flags: flags,
                viewingTabID: tab,
                viewingPaneID: pane,
                cols: cols,
                rows: rows,
                label: label,
            ))
        }
        let paneCount = try Int(reader.readUInt16())
        // Cheapest pane record: paneID + resolved grid + a zero attachment count.
        guard reader.bytesRemaining >= paneCount * 22 else { throw SlopDeskError.truncated }
        var panes: [WorkspaceRosterPane] = []
        panes.reserveCapacity(paneCount)
        for _ in 0..<paneCount {
            let paneID = try WorkspaceChannelCodec.readUUID(&reader)
            let cols = try reader.readUInt16()
            let rows = try reader.readUInt16()
            let count = try Int(reader.readUInt16())
            guard reader.bytesRemaining >= count * 21 else { throw SlopDeskError.truncated }
            var attachments: [WorkspaceRosterPane.Attachment] = []
            attachments.reserveCapacity(count)
            for _ in 0..<count {
                try attachments.append(WorkspaceRosterPane.Attachment(
                    clientInstanceID: WorkspaceChannelCodec.readUUID(&reader),
                    // C-style bool: any non-zero is `true`.
                    contributes: reader.readUInt8() != 0,
                    cols: reader.readUInt16(),
                    rows: reader.readUInt16(),
                ))
            }
            panes.append(WorkspaceRosterPane(
                paneID: paneID,
                resolvedCols: cols,
                resolvedRows: rows,
                attachments: attachments,
            ))
        }
        return Self(clients: clients, panes: panes)
    }
}

// MARK: - Shared helpers

/// Namespace for the bits the workspace payload codecs share. Not a codec itself — the ENVELOPE is
/// ``WireMessage/workspaceRequest(requestSeq:verb:payload:)`` /
/// ``WireMessage/workspaceEvent(kind:epoch:baseStateNum:newStateNum:payload:)`` and the document
/// entries are `WorkspaceStateCodec` in the model target.
public enum WorkspaceChannelCodec {
    static func readUUID(_ reader: inout BigEndianReader) throws -> UUID {
        let bytes = try reader.readBytes(16)
        guard let uuid = UUID(dataBytes: bytes) else { throw SlopDeskError.truncated }
        return uuid
    }

    /// UTF-8 bytes clamped at a Unicode SCALAR boundary, so a clamped value is still valid UTF-8
    /// (the type-35 idiom). Applied on ENCODE only — a decoder rejects an over-long declared length
    /// rather than trimming it.
    static func clampUTF8(_ text: String, maxBytes: Int) -> Data {
        var out = text
        while out.utf8.count > maxBytes { out.unicodeScalars.removeLast() }
        return Data(out.utf8)
    }
}
