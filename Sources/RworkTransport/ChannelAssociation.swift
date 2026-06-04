import Foundation
import Network
import RworkProtocol

/// The channel-association preamble that ties two physical TCP connections (DATA +
/// CONTROL) to one logical Rwork session.
///
/// ## The mechanism (documented in `docs/20-wire-protocol.md` §8)
/// Each connection sends a tiny fixed preamble **before** any length-prefixed
/// ``WireMessage`` frame. The preamble is *not* a `WireMessage` — it is raw bytes
/// the transport peels off first, so the protocol framing/message table is untouched.
///
/// ```
/// CONTROL preamble:  [ UInt8 0x01 ]                       (1 byte)
/// DATA    preamble:  [ UInt8 0x02 ][ 16 raw sessionID bytes ]  (17 bytes)
/// ```
///
/// ### Connect ordering (client side)
/// 1. Client opens the **CONTROL** connection, writes the control preamble (`0x01`),
///    then sends `hello(version, sessionID, lastReceivedSeq)`.
/// 2. Server reads the control preamble, reads `hello`, **decides** NEW vs
///    RETURNING_CLIENT, and replies `helloAck(authoritativeSessionID, resumeFromSeq,
///    returningClient)`.
/// 3. Client reads `helloAck`, learns the authoritative `sessionID`, then opens the
///    **DATA** connection and writes the data preamble (`0x02` + that sessionID).
/// 4. Server reads the data preamble and routes the DATA connection to the session it
///    minted/resumed in step 2.
///
/// This ordering is **deterministic — no race**: the data connection only opens once
/// the client knows the authoritative session id, so the server can always associate
/// it. (See ET `Connection.cpp`: the server, not the client, is authoritative over
/// session identity and the RETURNING_CLIENT decision.)
enum ChannelAssociation {
    /// Discriminator byte for the CONTROL connection.
    static let controlTag: UInt8 = 0x01
    /// Discriminator byte for the DATA connection.
    static let dataTag: UInt8 = 0x02
    /// Discriminator byte for a SHARED-MUX CONTROL connection (TCP-mux S1, behind `RWORK_TCP_MUX`).
    /// Distinct from ``controlTag`` so a host whose gate is ON selects the ``MuxFrameDecoder`` path
    /// for this connection. Both ends MUST agree on the flag (no mixed-mode handshake) — this tag is
    /// the on-wire confirmation of that agreement, not a negotiation.
    static let muxControlTag: UInt8 = 0x03
    /// Discriminator byte for a SHARED-MUX DATA connection (TCP-mux S1).
    static let muxDataTag: UInt8 = 0x04
    /// Length of a UUID on the wire (16 raw bytes), matching `RworkProtocol`.
    static let sessionIDByteCount = 16

    /// Encodes the control preamble (`[0x01]`).
    static func controlPreamble() -> Data {
        Data([controlTag])
    }

    /// Encodes the data preamble (`[0x02][16-byte sessionID]`).
    static func dataPreamble(sessionID: UUID) -> Data {
        var data = Data([dataTag])
        data.append(sessionID.associationBytes)
        return data
    }

    /// Encodes the shared-mux CONTROL preamble (`[0x03][16-byte connectionID]`). The connectionID
    /// pairs the two physical mux sockets (CONTROL + DATA) into ONE shared ``MuxNWConnection`` —
    /// there is no per-session id here because a shared connection carries MANY sessions, each
    /// minted/resumed per-channel via `channelOpen`, not at association.
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
    /// The UUID's 16 raw bytes in canonical order (same layout `RworkProtocol` uses).
    var associationBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
