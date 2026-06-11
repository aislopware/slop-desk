import Foundation
import Network
import AislopdeskProtocol

/// The shared-mux channel-association preamble that pairs two physical TCP connections (DATA +
/// CONTROL) into one shared ``MuxNWConnection`` carrying MANY logical channels.
///
/// ## The mechanism (documented in `docs/20-wire-protocol.md` §8)
/// Each connection sends a tiny fixed preamble **before** any framed mux envelope. The preamble is
/// *not* a ``AislopdeskProtocol/MuxFrame`` — it is raw bytes the transport peels off first.
///
/// ```
/// MUX CONTROL preamble:  [ UInt8 0x03 ][ 16 raw connectionID bytes ]  (17 bytes)
/// MUX DATA    preamble:  [ UInt8 0x04 ][ 16 raw connectionID bytes ]  (17 bytes)
/// ```
///
/// The `connectionID` pairs the two physical sockets into ONE shared connection on the host. There
/// is no per-session id at association: a shared connection carries MANY sessions, each
/// minted/resumed per-channel via `channelOpen`, not at association.
enum ChannelAssociation {
    /// Discriminator byte for a SHARED-MUX CONTROL connection.
    static let muxControlTag: UInt8 = 0x03
    /// Discriminator byte for a SHARED-MUX DATA connection.
    static let muxDataTag: UInt8 = 0x04
    /// Length of a UUID on the wire (16 raw bytes), matching `AislopdeskProtocol`.
    static let sessionIDByteCount = 16

    /// Encodes the shared-mux CONTROL preamble (`[0x03][16-byte connectionID]`). The connectionID
    /// pairs the two physical mux sockets (CONTROL + DATA) into ONE shared ``MuxNWConnection``.
    static func muxControlPreamble(connectionID: UUID) -> Data {
        var data = Data([muxControlTag])
        data.append(connectionID.associationBytes)
        return data
    }

    /// Encodes the shared-mux DATA preamble (`[0x04][16-byte connectionID]`), pairing it to the
    /// CONTROL socket that carried the same connectionID.
    static func muxDataPreamble(connectionID: UUID) -> Data {
        var data = Data([muxDataTag])
        data.append(connectionID.associationBytes)
        return data
    }
}

private extension UUID {
    /// The UUID's 16 raw bytes in canonical order (same layout `AislopdeskProtocol` uses).
    var associationBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
