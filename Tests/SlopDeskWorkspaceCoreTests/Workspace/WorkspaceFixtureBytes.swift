import Foundation

// Hand-spelled workspace-CHANNEL bodies, for the client tests on both sides of that channel.
//
// `WorkspaceChannelCodec` faces ONE way, the client's: a client ENCODES subscribe, presence and
// intent and DECODES the roster, so the opposite diagonal — a roster ENCODER and a request DECODER —
// had no caller left but the tests, and belongs to `rust/slopdesk-wire` alone now. What replaces it
// here is a second SPELLER of those bodies, never a second implementation: flat literal bytes with
// the layout written over each helper, no clamp, no validation, no shared writer that could grow
// into one. `Tests/SlopDeskWorkspaceCoreTests/Metadata/MetadataFixtureBytes.swift` is the same
// fixture for the same reason, one channel over, and `VideoWireFixtureBytes` set the precedent for
// the READER half.
//
// The two halves are here for different reasons. The roster is WRITTEN because a test needs a host
// body as input to the live decode path. The requests are READ rather than compared byte for byte,
// because a client mints its own instance UUIDs and presence clocks: pinning whole bodies would
// over-specify values the test does not control, so the reader lets each site assert on the FIELDS
// it means.
//
// Every layout below is pinned against `rust/slopdesk-wire/src/workspace.rs` — `encode_into` for the
// roster, `decode` for the three requests. Two traps that spelling out avoids: the roster's
// attachments sit INLINE behind their pane on the wire (the `(offset, count)` run is the FFI
// crossing's shape, not the wire's), and the `SlopDeskWorkspaceRosterClient` FFI record's field
// order is not the wire's either.
//
// ALL multi-byte integers are big-endian ("network byte order"), assembled and read one byte at a
// time so the spelling stays explicit rather than alignment- or endian-dependent.

/// Workspace-channel payloads, spelled byte by byte. Shared by every suite in this target.
enum WorkspaceFixtureBytes {
    /// The all-zero UUID, which this wire spells "unset" with — the same sixteen bytes
    /// `WireMessage.newSessionID` is, respelled so this fixture stays Foundation-only.
    static let unsetID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    // MARK: - Roster (kind 2) — the WRITER half

    /// One client in a roster body. A mirror of the wire's fields, NOT of
    /// `WorkspaceRosterClient` — the decode side answers in that type, and a fixture that took it as
    /// input would be `encode()` respelled with the same shape rather than a body spelled by hand.
    struct RosterClient {
        var clientInstanceID: UUID
        var clientKind: UInt8 = 0
        var flags: UInt8 = 0
        var viewingTabID: UUID = WorkspaceFixtureBytes.unsetID
        var viewingPaneID: UUID = WorkspaceFixtureBytes.unsetID
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        var label: String = ""
    }

    /// One client's attachment to a pane, inline behind that pane on the wire.
    struct RosterAttachment {
        var clientInstanceID: UUID
        var contributes: Bool
        var cols: UInt16
        var rows: UInt16
    }

    /// One pane in a roster body, with its attachments.
    struct RosterPane {
        var paneID: UUID
        var resolvedCols: UInt16
        var resolvedRows: UInt16
        var attachments: [RosterAttachment] = []
    }

    /// A `presence` roster body (event kind 2):
    ///
    /// ```text
    /// [u16 clientCount]
    ///   per client: [16B clientInstanceID][u8 clientKind][u8 flags][16B viewingTabID]
    ///               [16B viewingPaneID][u16 cols][u16 rows][u16 labelLen][label UTF-8]
    /// [u16 paneCount]
    ///   per pane:   [16B paneID][u16 resolvedCols][u16 resolvedRows][u16 attachmentCount]
    ///     per attachment: [16B clientInstanceID][u8 contributes][u16 cols][u16 rows]
    /// ```
    ///
    /// Both counts and every length are written verbatim. The encoder's `MAX_RECORDS` and label
    /// clamps are not repeated here: re-deriving them would make the body agree with the encoder by
    /// construction, which asserts nothing, and it would take away this fixture's ability to hand
    /// the decoder a count no encoder would produce.
    static func roster(clients: [RosterClient] = [], panes: [RosterPane] = []) -> Data {
        var bytes = Data(be16(UInt16(clients.count)))
        for client in clients {
            bytes.append(contentsOf: rawBytes(client.clientInstanceID))
            bytes.append(client.clientKind)
            bytes.append(client.flags)
            bytes.append(contentsOf: rawBytes(client.viewingTabID))
            bytes.append(contentsOf: rawBytes(client.viewingPaneID))
            bytes.append(contentsOf: be16(client.cols))
            bytes.append(contentsOf: be16(client.rows))
            bytes.append(contentsOf: lengthPrefixed(client.label))
        }
        bytes.append(contentsOf: be16(UInt16(panes.count)))
        for pane in panes {
            bytes.append(contentsOf: rawBytes(pane.paneID))
            bytes.append(contentsOf: be16(pane.resolvedCols))
            bytes.append(contentsOf: be16(pane.resolvedRows))
            bytes.append(contentsOf: be16(UInt16(pane.attachments.count)))
            for attachment in pane.attachments {
                bytes.append(contentsOf: rawBytes(attachment.clientInstanceID))
                bytes.append(attachment.contributes ? 1 : 0)
                bytes.append(contentsOf: be16(attachment.cols))
                bytes.append(contentsOf: be16(attachment.rows))
            }
        }
        return bytes
    }

    // MARK: - Requests — the READER half

    /// A `subscribe` body (verb 0), read back field by field.
    struct Subscribe {
        var clientInstanceID: UUID
        var clientKind: UInt8
        var knownEpoch: UUID
        var knownStateNum: Int64
        var flags: UInt8
        var label: String
    }

    /// A `presence` body (verb 2), read back field by field.
    struct Presence {
        var presenceClock: Int64
        var viewingTabID: UUID
        var viewingPaneID: UUID
        var cols: UInt16
        var rows: UInt16
        var flags: UInt8
    }

    /// An `intent` body (verb 3), read back field by field.
    struct Intent {
        var intentID: UUID
        var op: UInt8
        var args: Data
    }

    /// Reads a `subscribe` body:
    /// `[16B clientInstanceID][u8 clientKind][16B knownEpoch][i64 knownStateNum][u8 flags]`
    /// `[u16 labelLen][label UTF-8]`.
    ///
    /// `nil` for a body too short to hold one — the shape the call sites' `compactMap` wants. The
    /// label's declared length is NOT checked against the encoder's cap: what these tests read is
    /// what this client just wrote, and a fixture that re-decided the cap would be asserting about
    /// itself.
    static func readSubscribe(_ payload: Data) -> Subscribe? {
        var reader = WorkspaceByteReader(payload)
        guard let clientInstanceID = reader.readUUID(),
              let clientKind = reader.readUInt8(),
              let knownEpoch = reader.readUUID(),
              let knownStateNum = reader.readInt64(),
              let flags = reader.readUInt8(),
              let label = reader.readLengthPrefixedString()
        else { return nil }
        return Subscribe(
            clientInstanceID: clientInstanceID,
            clientKind: clientKind,
            knownEpoch: knownEpoch,
            knownStateNum: knownStateNum,
            flags: flags,
            label: label,
        )
    }

    /// Reads a `presence` body:
    /// `[i64 presenceClock][16B viewingTabID][16B viewingPaneID][u16 cols][u16 rows][u8 flags]` —
    /// fixed width, 45 bytes. `nil` for anything shorter.
    static func readPresence(_ payload: Data) -> Presence? {
        var reader = WorkspaceByteReader(payload)
        guard let presenceClock = reader.readInt64(),
              let viewingTabID = reader.readUUID(),
              let viewingPaneID = reader.readUUID(),
              let cols = reader.readUInt16(),
              let rows = reader.readUInt16(),
              let flags = reader.readUInt8()
        else { return nil }
        return Presence(
            presenceClock: presenceClock,
            viewingTabID: viewingTabID,
            viewingPaneID: viewingPaneID,
            cols: cols,
            rows: rows,
            flags: flags,
        )
    }

    /// Reads an `intent` body: `[16B intentID][u8 op][u32 argLen][args…]`.
    ///
    /// The arguments are opaque here and run to the frame cap, so the declared length is taken as
    /// written and the bytes are whatever is actually there behind it. `nil` for a body too short to
    /// hold the header.
    static func readIntent(_ payload: Data) -> Intent? {
        var reader = WorkspaceByteReader(payload)
        guard let intentID = reader.readUUID(),
              let op = reader.readUInt8(),
              let argLength = reader.readUInt32(),
              let args = reader.readBytes(Int(argLength))
        else { return nil }
        return Intent(intentID: intentID, op: op, args: args)
    }

    // MARK: - Byte spelling

    /// A big-endian `UInt16`, most significant byte first.
    private static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// A UUID's sixteen bytes, in the canonical order the wire carries them in.
    private static func rawBytes(_ id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { [UInt8]($0) }
    }

    /// A string field: `[u16 BE byte count][UTF-8 bytes]`. The length is the string's own UTF-8 byte
    /// count, written verbatim — the encoder's over-long clamp is not repeated here.
    private static func lengthPrefixed(_ value: String) -> [UInt8] {
        let utf8 = Array(value.utf8)
        return be16(UInt16(utf8.count)) + utf8
    }
}

/// A forward-only big-endian reader over one payload, for the fixture's request half.
///
/// Every read answers `nil` rather than throwing when the bytes are not there: the call sites are
/// `compactMap`s over what a client put on the wire, and a body that is not there at all is the same
/// non-answer as one that is short.
private struct WorkspaceByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func readUInt8() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard let high = readUInt8(), let low = readUInt8() else { return nil }
        return (UInt16(high) << 8) | UInt16(low)
    }

    mutating func readUInt32() -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = readUInt8() else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    /// A big-endian `i64`, read as its two's-complement bit pattern.
    mutating func readInt64() -> Int64? {
        var value: UInt64 = 0
        for _ in 0..<8 {
            guard let byte = readUInt8() else { return nil }
            value = (value << 8) | UInt64(byte)
        }
        return Int64(bitPattern: value)
    }

    /// Sixteen raw bytes as the UUID they are.
    mutating func readUUID() -> UUID? {
        guard let bytes = readBytes(16) else { return nil }
        let b = [UInt8](bytes)
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
        ))
    }

    /// A `[u16 BE byte count][UTF-8 bytes]` field, refused rather than repaired when the bytes are
    /// not UTF-8. What these tests read is what this client just wrote, so a replacement character
    /// would be an encoder bug wearing a valid `String` — and the whole reader already answers `nil`
    /// for "that is not the body you said it was".
    mutating func readLengthPrefixedString() -> String? {
        guard let length = readUInt16(), let bytes = readBytes(Int(length)) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The next `count` bytes, or `nil` when fewer than that remain.
    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, data.count - offset >= count else { return nil }
        let start = data.startIndex + offset
        offset += count
        return data[start..<(start + count)]
    }
}
