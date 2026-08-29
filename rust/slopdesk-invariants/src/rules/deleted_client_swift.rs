//! The PATH-1 client mux that used to be Swift, the terminal wire's byte half that G.4 found had no
//! caller left once it moved, and the faces that are all the two stages left behind.
//!
//! `deleted_host_swift` is this file's twin on the other end of the same connection: hostd stopped
//! speaking the mux in Swift at `docs/60` F.9, and `docs/63` G.3 did the same to the CLIENT. What
//! moved is not one file but a whole layer — the envelope's bytes, the streaming decoder, the
//! channel table, the three credit policies, the four admission guards, the two teardowns, the
//! sub-channel pair a pane rides on, the byte link under them and the per-host connection pool
//! above them. All of it is `rust/slopdesk-wire`'s `mux`, `rust/slopdesk-muxnet` and
//! `rust/slopdesk-clientnet` now, reached through the `docs/55` §4b handle in
//! `rust/slopdesk-ffi/src/mux_transport.rs`.
//!
//! ## Why a "stays deleted" list rather than a doc note
//!
//! Every file named below would still COMPILE if it came back, and every one of them would still
//! pass its own tests, because each was internally consistent — that is the whole reason the layer
//! was worth moving in one pass rather than file by file. A second envelope codec agrees with the
//! golden corpus right up until a type byte is added; a second credit accountant agrees with the
//! host right up until one of the two clamps low and stalls a channel forever rather than failing.
//! Neither shows up as a red anything. `CLAUDE.md`'s one-implementation rule is what forbids them,
//! and this is where that rule is spelled for the client.
//!
//! ## What did NOT go, and must not be banned by accident
//!
//! Three Swift files survive in the two directories this stage emptied, and each is a FACE:
//!
//! - `Sources/SlopDeskProtocol/Mux/MuxVocabulary.swift` — `MuxChannelClass`, `MuxCloseReason` and
//!   `MuxFlowControl`, which are vocabulary a caller names and constants it ASKS for
//!   (`slopdesk_mux_flow_constant`). The names live on; the two files that used to hold them
//!   (`MuxChannelClass.swift`, `MuxFlowControl.swift`) do not, so what is banned below is the PATH.
//! - `Sources/SlopDeskTransport/Mux/MuxClientTransport.swift` — the handle, and what crosses it is
//!   a decoded MESSAGE rather than a frame.
//! - `Sources/SlopDeskTransport/Mux/ConnectionRegistry.swift` — 316 lines of `@MainActor`
//!   bookkeeping reduced to a handle on `slopdesk_mux_pool_*`. Its `makeConnection` seam is the one
//!   piece of the old class that is banned rather than merely gone: it existed so a suite could
//!   pool a fake connection, and re-exposing it would mean a second dial path that ships.
//!
//! So the positive half of this rule is that those three still ASK. A ban list alone would be green
//! on a tree where the faces had quietly grown the layer back inside themselves under new names.
//!
//! Read `View::Code`, like every other ban in this crate: the prose above names what it forbids,
//! and two live comments elsewhere in the tree (`VideoConnectionRegistry.swift`, `main.swift`'s
//! vector generator) explain the deletion by naming the deleted type.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The vocabulary that survived the directory it lived in.
const VOCABULARY: &str = "Sources/SlopDeskProtocol/Mux/MuxVocabulary.swift";

/// The per-channel face — one handle, one channel, decoded messages out.
const TRANSPORT_FACE: &str = "Sources/SlopDeskTransport/Mux/MuxClientTransport.swift";

/// The per-host face — one handle, one pool, refcounts and eviction below the boundary.
const REGISTRY_FACE: &str = "Sources/SlopDeskTransport/Mux/ConnectionRegistry.swift";

/// The wire face that survived G.4 — a flattener between a Swift enum and the flat record, with
/// neither byte door left on it.
const WIRE_CODEC_FACE: &str = "Sources/SlopDeskProtocol/WireMessageCodec.swift";

/// The client's mux layer is Rust, and the Swift that spoke it stays deleted.
///
/// `docs/63` §G.3. Composed the way [`deleted_host_swift`](super::deleted_host_swift) is: a vector
/// per reason a file left, so the reason survives next to the ban rather than in a commit message.
#[must_use]
pub fn deleted_client_swift(tree: &Tree) -> Report {
    let mut claims = the_protocol_mux_stays_deleted();
    claims.extend(the_transport_mux_stays_deleted());
    claims.extend(the_mux_test_fakes_stay_deleted());
    claims.extend(the_terminal_byte_codec_stays_deleted());
    claims.extend(no_deleted_type_is_declared_again());
    claims.extend(the_three_faces_still_ask());
    check_all(tree, &claims)
}

/// `Sources/SlopDeskProtocol/Mux` — the codec, the framing, the table and the three policies.
///
/// Named as PATHS rather than as one directory ban, because the directory is not empty: it holds
/// [`VOCABULARY`], which is the half of `MuxFlowControl.swift` that had no Rust counterpart to
/// collapse into (a caller has to be able to WRITE `.pane`) plus two constants it asks for.
fn the_protocol_mux_stays_deleted() -> Vec<Claim> {
    vec![
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/MuxEnvelope.swift",
            message: "the mux envelope is being encoded in Swift again — slopdesk_wire::mux::envelope is \
                      the one codec, and the twelve muxEnvelopes vectors are golden-pinned against it, so a \
                      second encoder agrees with the corpus until the next type byte lands (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/MuxFrameDecoder.swift",
            message: "the streaming mux decoder is back in Swift — slopdesk_wire::mux::decoder holds the \
                      buffer, the length prefix and the partial-frame cursor, and a second one is a second \
                      answer to how many bytes a short read may keep (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/ChannelTable.swift",
            message: "the channel state machine is back in Swift — slopdesk_wire::mux::channels owns \
                      allocate/open/reject/close and the routing decision over them, and a table that is \
                      advanced in two languages is two tables (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/FlowCreditPolicy.swift",
            message: "send credit is being counted in Swift again — slopdesk_wire::mux::flow's \
                      FlowCreditPolicy is the one accountant, and a window clamped in two places is two \
                      windows, of which the lower one stalls a channel forever rather than failing (docs/63 \
                      §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/ReceiveWindowAccountant.swift",
            message: "the receive window is being folded in Swift again — slopdesk_wire::mux::flow's \
                      ReceiveWindowAccountant decides when a WINDOW_ADJUST is owed, and a second threshold \
                      grants a peer credit the host never accounted for (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/BoundedQueuePolicy.swift",
            message: "the outbound bound is back in Swift — slopdesk_wire::mux::flow's BoundedQueuePolicy \
                      is where full/enqueue/dequeue live, and a second capacity is a pause that one side \
                      never lifts (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/MuxChannelClass.swift",
            message: "the channel-class vocabulary is back in its own file — it is MuxVocabulary.swift's \
                      now, beside MuxCloseReason and the flow constants, because a vocabulary a caller \
                      writes is one file rather than three (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/Mux/MuxFlowControl.swift",
            message: "MuxFlowControl has its own file back — the transcribed numbers went with the layer \
                      and what remains ASKS slopdesk_mux_flow_constant from MuxVocabulary.swift, which is \
                      the file this one became (docs/63 §G.3)",
        },
    ]
}

/// `Sources/SlopDeskTransport` — the connection, the router, the doorman, the link and the two
/// helpers under them.
///
/// `MuxAdmission.swift` and `MuxNWConnection.swift` are the pair `hot_paths::one_frame_one_doorman`
/// used to pin from the Swift side; the four guards and the two teardowns they marshalled for are
/// `slopdesk_wire::mux::admission`, and the connection that asks all three verdicts is
/// `rust/slopdesk-muxnet/src/connection.rs`.
///
/// `PortValidation.swift` is here rather than under a transport heading because it is the same
/// deletion: it was the last Swift caller of `slopdesk_ws_listen_port`, composing that door with a
/// range predicate and a cast of its own, and the door retired with it (`docs/55` §4b). The bind is
/// `slopdesk_hostd`'s and asks `slopdesk_workspace::listen::port` in-process.
fn the_transport_mux_stays_deleted() -> Vec<Claim> {
    vec![
        Claim::Absent {
            path: "Sources/SlopDeskTransport/Mux/MuxNWConnection.swift",
            message: "the mux connection is being driven from Swift again — the read loop, the router and \
                      the send gate are rust/slopdesk-muxnet's, and NWConnection is not the transport any \
                      more (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/Mux/MuxAdmission.swift",
            message: "the doorman face is back — the four guards and the two teardowns are \
                      slopdesk_wire::mux::admission, and the PRECEDENCE between the guards is what a second \
                      copy loses first (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/Mux/MuxRoutingCore.swift",
            message: "the demux rule is back in Swift — ChannelTable::route decides beside the state its \
                      every branch reads and then writes, which is the arrangement this file was the \
                      counter-example to (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/Mux/MuxRouter.swift",
            message: "the frame router is back in Swift — routing a decoded frame to a sub-channel is \
                      rust/slopdesk-muxnet's, and the bytes no longer cross the boundary at all (docs/63 \
                      §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/Mux/MuxSubChannel.swift",
            message: "the CONTROL/DATA sub-channel pair is back in Swift — slopdesk_muxnet::subchannel \
                      holds the pair, its receive window and its end states (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/Mux/MuxByteLink.swift",
            message: "the byte-link abstraction is back — slopdesk_muxnet::link's ByteLink is the seam a \
                      test substitutes at, and a Swift protocol beside it is a second link layer that only \
                      its own suite reaches (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/Mux/NWMuxByteLink.swift",
            message: "the NWConnection byte link is back — TcpByteLink is the shipped one and it is Rust's, \
                      so a Network.framework link would be a second socket path with its own timeouts \
                      (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/ChannelAssociation.swift",
            message: "channel association is back in Swift — which session a channel id belongs to is the \
                      pool's, and a Swift map beside it is the association the reconnect path forgets to \
                      clear (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/NWConnection+Async.swift",
            message: "the NWConnection async shims are back — nothing on PATH-1 holds an NWConnection any \
                      more, so a continuation wrapper here is scaffolding for a transport that is not the \
                      one that ships (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskTransport/PortValidation.swift",
            message: "the listen-port rule has a Swift half again — the refusal and the conversion are one \
                      answer and it is slopdesk_workspace::listen::port's; slopdesk_ws_listen_port retired \
                      with this file rather than outliving its only caller (docs/63 §G.3, docs/55 §4b)",
        },
    ]
}

/// The three link fakes, which are the mirror fixture `CLAUDE.md` bans by name.
///
/// Each was a Swift implementation of the byte link written so a Swift suite could drive the Swift
/// mux without a socket. The Rust pool is tested against real loopback sockets in
/// `rust/slopdesk-clientnet/tests/`, which is both a stronger proof and a cheaper one — so a fake
/// here would not be a test helper, it would be the deleted link layer kept alive under a test
/// target where nothing else can see it drift.
fn the_mux_test_fakes_stay_deleted() -> Vec<Claim> {
    vec![
        Claim::Absent {
            path: "Tests/SlopDeskTransportTests/Support/InMemoryMuxLink.swift",
            message: "the in-memory mux link is back — a Swift fake of a Rust link is the cross-language \
                      mirror fixture the one-implementation rule bans, and the loopback tests in \
                      rust/slopdesk-clientnet/tests/ are what replaced it (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskTransportTests/Support/BlockingMuxLink.swift",
            message: "the blocking mux link is back — back-pressure is exercised against the real pool in \
                      rust/slopdesk-clientnet/tests/, and a Swift stand-in proves only that the stand-in \
                      blocks (docs/63 §G.3)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskTransportTests/Support/RecordingMuxLink.swift",
            message: "the recording mux link is back — asserting on the FRAMES a client writes means \
                      spelling the envelope in Swift to read it, which is the deleted codec returning as a \
                      test helper (docs/63 §G.3)",
        },
    ]
}

/// The terminal wire's BYTE half, deleted by `docs/63` §G.4 for the reason G.3 created.
///
/// `FrameDecoder.swift` was a handle over `slopdesk_wire`'s `FrameDecoder` and `WireMessageCodec`'s
/// `encode()`/`decode(payload:)` were handles over the two byte doors. All three were already one
/// implementation; what G.4 found is that they had no CALLER. Once G.3 moved the socket into
/// `slopdesk-clientnet`, the live path took the flat record through `slopdesk_mux_transport_send`
/// and a channel's stream was framed on the Rust side — so the only things still asking for bytes
/// were the suites checking the bytes were right, and the golden generator. A codec whose callers
/// are its own tests is not a face; it is a second implementation with a witness.
///
/// The doors retired with them (`slopdesk_wire_message_encode`, `slopdesk_wire_message_decode`, the
/// five `slopdesk_frame_decoder_*`), the way `slopdesk_ws_listen_port` retired with
/// `PortValidation.swift` rather than outliving its only caller. The corpus keys those suites
/// pinned moved EMITTED → FROZEN and are replayed by `rust/slopdesk-wire/tests/golden_vectors.rs`,
/// which decodes each frame, checks its fields against the pinned values, re-encodes and asserts
/// byte-identical output — a stronger pin than an emission, which can only agree with itself.
///
/// The test paths are banned as well as the source ones. Bringing back
/// `WireMessageRoundTripTests.swift` alone would not compile, but bringing it back WITH the encoder
/// it needs is exactly how the pair grows back, and a ban on only one half is a ban on the half
/// nobody would restore first.
fn the_terminal_byte_codec_stays_deleted() -> Vec<Claim> {
    vec![
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/FrameDecoder.swift",
            message: "the terminal frame decoder is back in Swift — slopdesk_wire::framing's PrefixedReader \
                      holds the buffer, the read cursor and the fail-stop, and the client's receive loop \
                      frames on the Rust side of the boundary now, so a Swift decoder here has no stream to \
                      read (docs/63 §G.4)",
        },
        Claim::Lacks {
            path: WIRE_CODEC_FACE,
            pattern: r"func encode\(\)|static func decode\(payload",
            view: View::Code,
            message: "the terminal wire's byte half is back in WireMessageCodec.swift — nothing on the \
                      client asks for a frame, so an encode()/decode(payload:) pair here is a codec whose \
                      only callers would be its own tests (docs/63 §G.4)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskProtocolTests/WireMessageRoundTripTests.swift",
            message: "the Swift wire round-trip suite is back — round-tripping one codebase's encoder \
                      through its own decoder passes just as happily when both have drifted from the wire; \
                      rust/slopdesk-wire/tests/golden_vectors.rs checks the hex against the FIELDS (docs/63 \
                      §G.4)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskProtocolTests/FrameDecoderTests.swift",
            message: "the Swift framing suite is back — the buffer, the cursor and the poisoning are \
                      exercised in rust/slopdesk-wire, beside the one copy of them (docs/63 §G.4)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskProtocolTests/MetadataWireMessageTests.swift",
            message: "the type-16/30 envelope suite is back — its envelope half needed the deleted encoder, \
                      and its verb/status half was a hand-typed copy of what wire_vocabularies already \
                      ratchets in both directions against slopdesk_wire's table (docs/63 §G.4)",
        },
    ]
}

/// And the same layer under any other filename.
///
/// The path bans above are exact, so a resurrection that renames the file slips all of them. These
/// two catch it by DECLARATION, tree-wide over every Swift root.
///
/// The name list is only the types that died. `MuxChannelClass`, `MuxCloseReason`, `MuxFlowControl`
/// and `ConnectionRegistry` are deliberately absent from it: all four are still declared, on the
/// three faces, and banning a name the port KEPT would fire on the port's own result.
fn no_deleted_type_is_declared_again() -> Vec<Claim> {
    vec![
        Claim::NoneUnder {
            roots: &["Sources", "Tests", "Apps"],
            extensions: SWIFT,
            pattern: concat!(
                r"(enum|struct|final class|class|actor|protocol) ",
                r"(MuxEnvelope|MuxEnvelopeCodec|MuxFrameDecoder|ChannelTable|FlowCreditPolicy",
                r"|ReceiveWindowAccountant|BoundedQueuePolicy|MuxNWConnection|MuxAdmission|MuxDoorman",
                r"|MuxRouter|MuxRoutingCore|MuxSubChannel|MuxByteLink|NWMuxByteLink|ChannelAssociation",
                r"|PortValidation)\b",
            ),
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} declares a client mux type docs/63 §G.3 deleted — the whole layer is \
                      slopdesk_wire::mux, slopdesk-muxnet and slopdesk-clientnet, reached through the \
                      mux_transport handle; a renamed file is the same second implementation",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskTransport"],
            extensions: SWIFT,
            pattern: r"makeConnection",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} exposes a makeConnection seam again — it existed so a suite could pool a fake \
                      connection, and a second dial path that SHIPS is the price of that; a test with no \
                      host injects at ClientTransporting, which docs/63 keeps until G.5",
        },
    ]
}

/// The other half: the three survivors are faces, and a face that stops asking has re-derived.
///
/// Without these, an empty `Sources` tree satisfies every ban above — and so does a tree where
/// `MuxClientTransport` quietly grew the envelope back inside itself. Each door named here is the
/// one that makes its file a marshaller rather than an implementation.
fn the_three_faces_still_ask() -> Vec<Claim> {
    vec![
        Claim::Names {
            path: VOCABULARY,
            needle: "slopdesk_mux_flow_constant(",
            message: "MuxVocabulary.swift stopped asking slopdesk_mux_flow_constant — the payload caps are \
                      slopdesk_wire::mux::flow's seven numbers, and a transcribed one is a client that \
                      chunks to a size the host does not bound (docs/63 §G.3)",
        },
        Claim::Doors {
            path: TRANSPORT_FACE,
            entries: &[
                "slopdesk_mux_transport_open",
                "slopdesk_mux_transport_free",
                "slopdesk_mux_transport_await_open_ack",
                "slopdesk_mux_transport_send",
                "slopdesk_mux_transport_send_input",
                "slopdesk_mux_transport_note_consumed",
            ],
            message: "MuxClientTransport.swift no longer calls {entry} — every one of those is a decision \
                      the layer took with it (the open handshake, the input SPLIT at the flow cap, the \
                      consumption credit), and a face that drops one has answered it itself (docs/63 §G.3)",
        },
        Claim::Doors {
            path: REGISTRY_FACE,
            entries: &[
                "slopdesk_mux_pool_new",
                "slopdesk_mux_pool_free",
                "slopdesk_mux_pool_pin",
                "slopdesk_mux_pool_unpin",
            ],
            message: "ConnectionRegistry.swift no longer calls {entry} — the refcount, the eviction of a \
                      connection that died under its holders and the pin that keeps a channel-less one \
                      alive are rust/slopdesk-clientnet's, and this file is the handle plus the endpoint \
                      spelling (docs/63 §G.3)",
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::deleted_client_swift;
    use crate::tests::Fixture;

    /// A tree with the three faces asking, and nothing the stage deleted.
    fn client(fixture: &Fixture) {
        fixture
            .write(
                super::VOCABULARY,
                "public enum MuxChannelClass: UInt8 { case pane = 0 }\npublic enum MuxFlowControl {\n  \
                 static var cap: Int { Int(slopdesk_mux_flow_constant(1)) }\n}\n",
            )
            .write(
                super::TRANSPORT_FACE,
                "slopdesk_mux_transport_open(pool)\nslopdesk_mux_transport_free(handle)\\
                 nslopdesk_mux_transport_await_open_ack(handle, \
                 ms)\nslopdesk_mux_transport_send(channel)\nslopdesk_mux_transport_send_input(channel)\\
                 nslopdesk_mux_transport_note_consumed(channel, bytes)\n",
            )
            .write(
                super::REGISTRY_FACE,
                "slopdesk_mux_pool_new(ms)\nslopdesk_mux_pool_free(pool)\nslopdesk_mux_pool_pin(pool)\\
                 nslopdesk_mux_pool_unpin(pool)\n",
            )
            // The flattener that survived G.4 — a marshaller, with neither byte door on it.
            .write(
                super::WIRE_CODEC_FACE,
                "func withFlattened(_ body: (Record) -> T) -> T { body(flatten()) }\nstatic func lent(_ flat: \
                 Record) -> WireMessage? { build(flat) }\n",
            );
    }

    /// Every path this stage emptied, with a seed that is plausible for the file rather than a
    /// marker — a resurrection arrives as working code, not as a placeholder.
    const REVIVALS: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskProtocol/Mux/MuxEnvelope.swift",
            "struct MuxFrame { func encode() -> Data { Data() } }\n",
        ),
        (
            "Sources/SlopDeskProtocol/Mux/MuxFrameDecoder.swift",
            "func next() -> MuxFrame? { nil }\n",
        ),
        (
            "Sources/SlopDeskProtocol/Mux/ChannelTable.swift",
            "func allocate() -> UInt32 { next += 2; return next }\n",
        ),
        (
            "Sources/SlopDeskProtocol/Mux/FlowCreditPolicy.swift",
            "mutating func consume(_ bytes: Int) -> Bool { remaining >= bytes }\n",
        ),
        (
            "Sources/SlopDeskProtocol/Mux/ReceiveWindowAccountant.swift",
            "mutating func consume(_ bytes: Int) -> Int? { nil }\n",
        ),
        (
            "Sources/SlopDeskProtocol/Mux/BoundedQueuePolicy.swift",
            "var isFull: Bool { outstanding >= capacity }\n",
        ),
        (
            "Sources/SlopDeskProtocol/Mux/MuxChannelClass.swift",
            "public enum MuxChannelClass: UInt8 { case pane = 0 }\n",
        ),
        (
            "Sources/SlopDeskProtocol/Mux/MuxFlowControl.swift",
            "public enum MuxFlowControl { static let initialWindow = 262_144 }\n",
        ),
        (
            "Sources/SlopDeskTransport/Mux/MuxNWConnection.swift",
            "func receiveLoop() async {}\n",
        ),
        (
            "Sources/SlopDeskTransport/Mux/MuxAdmission.swift",
            "static func admit(_ arrival: Arrival) -> Admission { .route }\n",
        ),
        (
            "Sources/SlopDeskTransport/Mux/MuxRoutingCore.swift",
            "func route(_ frame: MuxFrame) -> Decision { .drop }\n",
        ),
        (
            "Sources/SlopDeskTransport/Mux/MuxRouter.swift",
            "func deliver(_ frame: MuxFrame, to id: UInt32) {}\n",
        ),
        (
            "Sources/SlopDeskTransport/Mux/MuxSubChannel.swift",
            "func send(_ bytes: [UInt8]) throws {}\n",
        ),
        (
            "Sources/SlopDeskTransport/Mux/MuxByteLink.swift",
            "protocol ByteLink { func write(_ bytes: [UInt8]) throws }\n",
        ),
        (
            "Sources/SlopDeskTransport/Mux/NWMuxByteLink.swift",
            "func write(_ bytes: [UInt8]) throws { connection.send(bytes) }\n",
        ),
        (
            "Sources/SlopDeskTransport/ChannelAssociation.swift",
            "var sessions: [UInt32: UUID] = [:]\n",
        ),
        (
            "Sources/SlopDeskTransport/NWConnection+Async.swift",
            "extension NWConnection { func receiveAsync() async throws -> Data { Data() } }\n",
        ),
        (
            "Sources/SlopDeskTransport/PortValidation.swift",
            "static func port(_ raw: Int) -> UInt16? { (0...65535).contains(raw) ? UInt16(raw) : nil }\n",
        ),
        (
            "Tests/SlopDeskTransportTests/Support/InMemoryMuxLink.swift",
            "func write(_ bytes: [UInt8]) { pipe.append(contentsOf: bytes) }\n",
        ),
        (
            "Tests/SlopDeskTransportTests/Support/BlockingMuxLink.swift",
            "func write(_ bytes: [UInt8]) { semaphore.wait() }\n",
        ),
        (
            "Tests/SlopDeskTransportTests/Support/RecordingMuxLink.swift",
            "func write(_ bytes: [UInt8]) { written.append(bytes) }\n",
        ),
        (
            "Sources/SlopDeskProtocol/FrameDecoder.swift",
            "func nextMessage() throws -> WireMessage? { nil }\n",
        ),
        (
            "Tests/SlopDeskProtocolTests/WireMessageRoundTripTests.swift",
            "func testOutputRoundTrips() { XCTAssertEqual(try decode(m.encode()), m) }\n",
        ),
        (
            "Tests/SlopDeskProtocolTests/FrameDecoderTests.swift",
            "func testAPartialFrameIsNotAnError() { XCTAssertNil(try decoder.nextMessage()) }\n",
        ),
        (
            "Tests/SlopDeskProtocolTests/MetadataWireMessageTests.swift",
            "func testMetadataRequestRoundTrip() { XCTAssertEqual(try roundTrip(m), m) }\n",
        ),
    ];

    /// The clean tree is green, and each deleted path is red on its own.
    #[test]
    fn a_revived_client_mux_file_is_red() {
        let fixture = Fixture::new("deleted-client-swift-paths");
        client(&fixture);
        assert!(deleted_client_swift(&fixture.tree()).is_clean());

        for (path, seed) in REVIVALS {
            fixture.write(path, seed);
            assert!(
                !deleted_client_swift(&fixture.tree()).is_clean(),
                "{path}: the ban did not fire on its return"
            );
            fixture.remove(path);
            assert!(
                deleted_client_swift(&fixture.tree()).is_clean(),
                "{path}: taking it back out did not restore the clean tree"
            );
        }
    }

    /// The byte half growing back INSIDE the surviving flattener, which no path ban would see.
    ///
    /// The file stays — it is the marshalling `withFlattened`/`lent` do — so the ban has to be on
    /// what is written in it rather than on its existence.
    #[test]
    fn the_byte_pair_returning_to_the_flattener_is_red() {
        for seed in [
            "    func encode() -> Data { WireBuffer.filled(bound) { _ in } }\n",
            "    static func decode(payload: Data) throws -> WireMessage { try attempt(payload) }\n",
        ] {
            let fixture = Fixture::new("deleted-client-swift-byte-pair");
            client(&fixture);
            assert!(deleted_client_swift(&fixture.tree()).is_clean(), "{seed}");

            fixture.append(super::WIRE_CODEC_FACE, seed);
            assert!(
                !deleted_client_swift(&fixture.tree()).is_clean(),
                "{seed}: the byte half came back and the ban did not fire"
            );
        }
    }

    /// The rename that slips every path ban: the same type, in a file nobody thought to name.
    #[test]
    fn a_deleted_type_declared_under_a_new_name_is_red() {
        for name in [
            "MuxEnvelope",
            "MuxEnvelopeCodec",
            "MuxFrameDecoder",
            "ChannelTable",
            "FlowCreditPolicy",
            "ReceiveWindowAccountant",
            "BoundedQueuePolicy",
            "MuxNWConnection",
            "MuxAdmission",
            "MuxDoorman",
            "MuxRouter",
            "MuxRoutingCore",
            "MuxSubChannel",
            "MuxByteLink",
            "NWMuxByteLink",
            "ChannelAssociation",
            "PortValidation",
        ] {
            let fixture = Fixture::new(&format!("deleted-client-swift-{name}"));
            client(&fixture);
            assert!(deleted_client_swift(&fixture.tree()).is_clean(), "{name}");
            fixture.write(
                "Sources/SlopDeskTransport/Relay.swift",
                &format!("final class {name} {{\n    let x = 1\n}}\n"),
            );
            assert!(
                !deleted_client_swift(&fixture.tree()).is_clean(),
                "{name}: the declaration ban did not fire"
            );
        }
    }

    /// The four names the port KEPT. Banning one would fire on the faces themselves, which is why
    /// the list above is the types that died rather than everything the layer touched.
    #[test]
    fn a_surviving_vocabulary_name_is_not_a_revival() {
        let fixture = Fixture::new("deleted-client-swift-survivors");
        client(&fixture);
        fixture.write(
            "Sources/SlopDeskTransport/Relay.swift",
            "public enum MuxChannelClass: UInt8 { case pane = 0 }\npublic enum MuxCloseReason: UInt8 { case \
             normal = 0 }\npublic enum MuxFlowControl {}\npublic final class ConnectionRegistry {}\n",
        );
        assert!(deleted_client_swift(&fixture.tree()).is_clean());
    }

    /// And the comment that EXPLAINS the deletion by naming it, which two live files hold.
    #[test]
    fn a_comment_naming_a_deleted_type_is_not_a_revival() {
        let fixture = Fixture::new("deleted-client-swift-comment");
        client(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/Mux/VideoConnectionRegistry.swift",
            "/// counterpart of the TCP-mux `MuxNWConnection`, whose `final class MuxRouter` went with \
             it.\nlet ordinary = 1\n",
        );
        assert!(deleted_client_swift(&fixture.tree()).is_clean());
    }

    /// The half a ban list cannot state: a face that stopped asking.
    ///
    /// Each of the three is dropped in turn, because a tree where the transport re-derived the open
    /// handshake passes every absence above — nothing came BACK, the layer simply grew a second
    /// time inside the file that was supposed to be a marshaller.
    #[test]
    fn a_face_that_stops_asking_the_handle_is_red() {
        let fixture = Fixture::new("deleted-client-swift-faces");
        client(&fixture);

        fixture.write(
            super::VOCABULARY,
            "public enum MuxFlowControl { static let cap = 262_144 }\n",
        );
        assert!(!deleted_client_swift(&fixture.tree()).is_clean());

        client(&fixture);
        fixture.write(super::TRANSPORT_FACE, "slopdesk_mux_transport_open(pool)\n");
        assert!(!deleted_client_swift(&fixture.tree()).is_clean());

        client(&fixture);
        fixture.write(super::REGISTRY_FACE, "slopdesk_mux_pool_new(ms)\n");
        assert!(!deleted_client_swift(&fixture.tree()).is_clean());

        // A bare tree has no faces at all — which is what stops the ban list passing on nothing.
        let bare = Fixture::new("deleted-client-swift-bare");
        assert!(!deleted_client_swift(&bare.tree()).is_clean());
    }
}
