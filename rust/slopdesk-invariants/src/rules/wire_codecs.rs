//! The three codecs, the framing, the mux, the demux rule, the git dialect and the two payload
//! channels — every wire body in this repo is laid out once, in Rust.
//!
//! Ported from the deleted `check-supervisor.sh`. The through-line is narrower than "a law lives
//! once": it is that a BYTE LAYOUT spelled twice is two layouts that agree until one field moves.
//! The bans here name the two primitives every hand-rolled codec in this repo was built out of —
//! `appendBE` and a big-endian reader — because a second wire never arrives as a codec. It arrives
//! as "just this one field".

use crate::claim::{Claim, RUST, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;
use crate::vocabulary::{Vocabulary, agrees};

const SWIFT_METADATA: &str = "Sources/SlopDeskProtocol/Metadata/MetadataCodec.swift";
const SWIFT_WS_CHANNEL: &str = "Sources/SlopDeskProtocol/WorkspaceChannelCodec.swift";

/// The CONTROL channel — the widest wire on the video path.
///
/// 28 message types, five of them carrying a list of records, and every record carrying text that
/// is decoded LOSSILY. It is also the only one whose strings cross through an ARENA rather than an
/// offset, because a lossy repair produces bytes that are not in the datagram, so the answer cannot
/// be a substring of the question.
///
/// With it gone through the shim, NO codec in `SlopDeskVideoProtocol` lays out a byte: the target's
/// whole remaining ownership of the wire is `VideoProtocolError`. So the second ban is the TARGET,
/// not a file at a time — a new codec cannot be added beside the pinned ones and spell its own
/// bytes. The hostile-datagram builders the tests still need live in
/// `Tests/SlopDeskVideoProtocolTests/VideoWireFixtureBytes.swift`, where a second speller of the
/// wire cannot become a second implementation of it.
#[must_use]
pub fn video_control_channel(tree: &Tree) -> Report {
    const SWIFT_CONTROL: &str = "Sources/SlopDeskVideoProtocol/VideoControlCodec.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_CONTROL,
            entries: &[
                "slopdesk_video_control_encode",
                "slopdesk_video_control_decode",
                "slopdesk_video_control_constant",
            ],
            message: "Sources/SlopDeskVideoProtocol/VideoControlCodec.swift no longer calls {entry} — the \
                      control wire is rust/slopdesk-video's",
        },
        // The length-prefixed-string pair a second speller would need back.
        Claim::Lacks {
            path: SWIFT_CONTROL,
            pattern: "appendVideoControlLengthPrefixed|readVideoControlLengthPrefixed",
            view: View::Code,
            message: "VideoControlCodec.swift grew a length-prefixed-string helper back — control bytes are \
                      laid out once, in Rust",
        },
        // The five budgets the host packs against. Prose may still name them; a doc comment is not
        // what the chunker reads.
        Claim::Lacks {
            path: SWIFT_CONTROL,
            pattern: r"(static let|=) *(1177|1186|120|32 \* 1024|48 \* 1024)\b",
            view: View::Code,
            message: "a control budget is spelled in Swift again — slopdesk_video_control_constant vends \
                      all five",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskVideoProtocol"],
            extensions: SWIFT,
            pattern: "appendBE|VideoByteReader",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "SlopDeskVideoProtocol lays out bytes again ({files}) — every codec in it goes through \
                      slopdesk-ffi",
        },
    ];
    check_all(tree, &claims)
}

/// PATH-1, the terminal wire, and the framing that wraps it.
///
/// The LAST of the three codecs to move and the one the whole product sits on: 30 message types, an
/// `.output` flood behind every keystroke. Its Swift side is now a flattener and nothing else — the
/// layout lives in `rust/slopdesk-wire`, reached through `slopdesk-ffi`.
///
/// The `appendBE`/`BigEndianReader` ban is on this FILE rather than on the module. The helpers are
/// not in `Sources/SlopDeskProtocol` at all any more — they are test fixtures under
/// `Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift`, where hand-spelling the bytes a
/// decode must accept is the point rather than a shortfall. A file-scoped ban is what says the
/// codec that went to Rust may not quietly come back by importing one.
///
/// The numbers both ends would otherwise type are the wire version and the frame ceiling, and by
/// G.4 Swift asks for NEITHER: the `SlopDesk` namespace vended them and is deleted, which is why
/// the claim below is the one that keeps it gone. The handshake's version is filled by
/// `slopdesk-clientnet` and the ceiling is enforced by `slopdesk-wire`'s framer, so the last Swift
/// reader of either was an inspector suite reaching across protocols for a number that happened to
/// match — it asks `slopdesk_inspector_constant` now. A session id's 16 bytes were the third, asked
/// for by a `UUID(dataBytes:)` initialiser nothing called. What survives is the TRANSCRIPTION ban,
/// which is the half that mattered: the version travels as a bare `1`, which no numeric pattern can
/// tell from a tag byte, so it is pinned by NAME and the width by value.
///
/// ## What `docs/63` §G.4 changed about this rule
///
/// It used to make two more claims: that `WireMessageCodec.swift` called
/// `slopdesk_wire_message_encode` and `slopdesk_wire_message_decode`, and that
/// `FrameDecoder.swift` called the five framing doors. Both faces asked Rust for BYTES, and by G.4
/// nothing wanted bytes: G.3 moved the socket into `slopdesk-clientnet`, so the live path takes the
/// FLAT RECORD through `slopdesk_mux_transport_send` and a channel's stream is framed on the Rust
/// side of the boundary. What kept the byte doors alive after that was their own test suites and
/// the golden generator — a codec whose only callers were the things checking it still worked. The
/// two doors, the five framing doors and `FrameDecoder.swift` are all deleted.
///
/// What is NOT gone is the reason the framing half of the rule existed. A second READER of a stream
/// is not a second implementation; a second BUFFER of it is, and that is how a cursor and a
/// fail-stop drift apart. So the ban is re-aimed the way `mux_layer` re-aimed its own: at the ONE
/// copy, positively, in the crate that holds it, where a second buffer would actually be written.
#[must_use]
pub fn terminal_wire(tree: &Tree) -> Report {
    const SWIFT_WIRE: &str = "Sources/SlopDeskProtocol/WireMessageCodec.swift";
    /// The buffer, the read cursor, the lazy compaction and the poisoning — one copy, and this is
    /// it.
    const RUST_FRAMING: &str = "rust/slopdesk-wire/src/framing.rs";
    /// The receive loop that drives it, and the crate that would grow a second one if one grew.
    const RUST_CLIENTNET: &str = "rust/slopdesk-clientnet/src";

    let claims = [
        Claim::Doors {
            path: SWIFT_WIRE,
            entries: &["slopdesk_wire_message_byte_count"],
            message: "Sources/SlopDeskProtocol/WireMessageCodec.swift no longer calls {entry} — it is the \
                      one number the flow control depends on, it must equal the sender's per-frame debit \
                      exactly, and a Swift count of it would be a second answer that drifts by accumulating \
                      rather than by failing",
        },
        Claim::Absent {
            path: "Sources/SlopDeskProtocol/SlopDesk.swift",
            message: "Sources/SlopDeskProtocol/SlopDesk.swift is back — the wire version and the frame \
                      ceiling are the transport's now (slopdesk-clientnet fills the handshake, \
                      slopdesk-wire's framer enforces the cap), and a Swift namespace holding them is a \
                      second place to read a number no Swift code needs (docs/63 §G.4)",
        },
        Claim::Lacks {
            path: SWIFT_WIRE,
            pattern: "appendBE|BigEndianReader",
            view: View::Code,
            message: "WireMessageCodec.swift grew a big-endian helper back — PATH-1 bytes are laid out \
                      once, in Rust",
        },
        Claim::NoneOf {
            paths: &[SWIFT_WIRE],
            pattern: r"(static let|==) *(16 \* 1024 \* 1024|16)\b",
            view: View::Code,
            message: "a wire width is spelled in Swift again ({files}) — slopdesk_wire_constant vends it",
        },
        Claim::NoneOf {
            paths: &[SWIFT_WIRE],
            pattern: r"protocolVersion[^=]*= *[0-9]",
            view: View::Code,
            message: "the wire version is spelled in Swift again ({files}) — slopdesk_wire_constant vends it",
        },
        // The positive half, so the ban below cannot go green by the one copy vanishing too.
        Claim::Mentions {
            path: RUST_FRAMING,
            names: &["struct PrefixedReader", "COMPACTION_THRESHOLD"],
            message: "rust/slopdesk-wire/src/framing.rs lost {entry} — the frame buffer, its read cursor \
                      and the lazy compaction that keeps a chunk of many small frames off O(n²) are one \
                      answer, and the terminal decoder and the mux decoder are both three lines over it \
                      (docs/20 §4)",
        },
        // The ban, aimed where a second buffer would actually be written: the receive loop. Not at
        // all of `rust/` — `PrefixedReader` itself is these names, and a walk that includes it can
        // never fail.
        Claim::NoneUnder {
            roots: &[RUST_CLIENTNET],
            extensions: &["rs"],
            pattern: r"read_offset|compact_consumed|read_prefix|COMPACTION_THRESHOLD",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a second frame buffer is growing beside PrefixedReader's ({files}) — the read cursor \
                      and its compaction schedule are one implementation, and two of them drift apart \
                      silently because each passes its own tests. The BUFFER is named rather than the \
                      poisoning: `map_err(|_poisoned| …)` on a Mutex is an ordinary lock idiom the pool \
                      uses eight times, and a ban that fires on it is one somebody exempts instead of reads \
                      (docs/20 §4)",
        },
    ];
    check_all(tree, &claims)
}

/// The MUX layer and the DEMUX rule.
///
/// The envelope's bytes, the framing, the credit arithmetic and the channel state machine are all
/// `rust/slopdesk-wire`'s. A window that is clamped in two languages is two windows, and the one
/// that drifts low stalls a channel forever rather than failing.
///
/// ## What `docs/63` §G.3 changed about this rule
///
/// It used to be six claims about Swift FACES: that `MuxEnvelope.swift` called the four envelope
/// doors, that `MuxFrameDecoder.swift` called the five framing doors, that something under
/// `Sources/SlopDeskProtocol/Mux` called each of five policy doors, and that `MuxRoutingCore.swift`
/// asked `table.route(` without spelling a table verb of its own. Every one of those files is gone
/// and so are the doors: what crosses the boundary now is a decoded MESSAGE, not a frame, so there
/// is no marshalling layer left for a door to be dropped from and the type system is what says the
/// call happened. Only `slopdesk_mux_flow_constant` survives, because two payload CAPS are numbers
/// a Swift caller still has to know, and `MuxVocabulary.swift` asks for them rather than
/// transcribing.
///
/// What is NOT gone is the reason the rule exists. Nothing in the build graph stops
/// `slopdesk-muxnet` or `slopdesk-clientnet` from growing a second credit accountant beside
/// `slopdesk_wire::mux::flow`'s, or a second framing cursor beside the decoder's — each compiles,
/// each passes its own tests, and each drifts. So the "there is one" half survives, spelled the way
/// Rust would write the drift, with the four sites that hold the one copy pinned positively so the
/// bans cannot go green by everything vanishing.
///
/// The DEMUX rule is pinned the same way. It used to be a Swift `MuxRoutingCore.route` reaching six
/// ways into a table that was ALREADY Rust — a rule living apart from the state its every branch
/// reads and then writes, which is the arrangement that lets one of them be edited alone.
/// `ChannelTable::route` decides beside its table, and `rust/slopdesk-muxnet` is the caller that
/// must keep asking rather than reading the table's verbs itself.
#[must_use]
pub fn mux_layer(tree: &Tree) -> Report {
    /// The envelope codec — one layout, and twelve golden vectors pinned against it.
    const ENVELOPE: &str = "rust/slopdesk-wire/src/mux/envelope.rs";
    /// The streaming decoder — the buffer, the length prefix and the partial-frame cursor.
    const DECODER: &str = "rust/slopdesk-wire/src/mux/decoder.rs";
    /// The channel state machine, and the demux rule beside it.
    const CHANNELS: &str = "rust/slopdesk-wire/src/mux/channels.rs";
    /// The three credit policies and the seven constants they are reasoned against.
    const FLOW: &str = "rust/slopdesk-wire/src/mux/flow.rs";
    /// The one Swift file left with a mux number in it, and it ASKS for it.
    const SWIFT_VOCABULARY: &str = "Sources/SlopDeskProtocol/Mux/MuxVocabulary.swift";
    /// The two crates that drive the layer, and would hold a second copy if one grew.
    const DRIVERS: [&str; 2] = ["rust/slopdesk-muxnet/src", "rust/slopdesk-clientnet/src"];

    let claims = [
        Claim::Doors {
            path: ENVELOPE,
            entries: &[
                "pub fn encode",
                "pub fn decode",
                "pub fn encode_with_payload_into",
                "pub fn encoded_byte_count_with_payload",
            ],
            message: "rust/slopdesk-wire/src/mux/envelope.rs lost {entry} — the mux envelope's bytes are \
                      laid out once, and the twelve muxEnvelopes vectors are golden-pinned against this \
                      file (docs/20 §4)",
        },
        Claim::Doors {
            path: DECODER,
            entries: &["pub fn append", "pub fn next_frame", "pub fn payload_bytes"],
            message: "rust/slopdesk-wire/src/mux/decoder.rs lost {entry} — the framing cursor is one answer \
                      to how many bytes a short read may keep (docs/20 §4)",
        },
        // `Mentions` rather than `Doors`: three of these are TYPES and the fourth is a constant, so
        // demanding a call parenthesis after the name would report all four as gone.
        Claim::Mentions {
            path: FLOW,
            names: &[
                "pub struct FlowCreditPolicy",
                "pub struct ReceiveWindowAccountant",
                "pub struct BoundedQueuePolicy",
                "MAX_CHANNELS_PER_CONNECTION",
            ],
            message: "rust/slopdesk-wire/src/mux/flow.rs lost {entry} — the send credit, the receive \
                      window, the outbound bound and the live-channel cap are one set of numbers both ends \
                      are reasoned against (docs/20 §4)",
        },
        Claim::Names {
            path: CHANNELS,
            needle: "pub fn route",
            message: "rust/slopdesk-wire/src/mux/channels.rs lost route — the demux rule lives beside its \
                      table, which is what stops one of the two being edited alone (docs/20 §4)",
        },
        Claim::Names {
            path: SWIFT_VOCABULARY,
            needle: "slopdesk_mux_flow_constant(",
            message: "MuxVocabulary.swift stopped asking slopdesk_mux_flow_constant — the two payload caps \
                      are the only mux numbers Swift still needs, and a transcribed one chunks input to a \
                      size the host does not bound (docs/20 §4)",
        },
        // The Swift half of the ban. `Sources/SlopDeskProtocol` and `Sources/SlopDeskTransport` are
        // where the deleted arithmetic lived and where a rebuild of it would land; the roots are those
        // two rather than all of `Sources` because `remaining -=` and `states[` are ordinary lines in
        // a workspace store and a sidebar model, and a ban that fires on those is a ban somebody
        // widens an exemption list for instead of reading.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskProtocol", "Sources/SlopDeskTransport"],
            extensions: SWIFT,
            pattern: r"pendingCredit \+=|remaining -=|outstanding \+=|states\[|terminalRing",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the client grew the mux arithmetic back in Swift ({files}) — the credit, the window \
                      and the channel states are slopdesk_wire::mux's, and what crosses the boundary is a \
                      decoded message rather than a frame (docs/20 §4, docs/63 §G.3)",
        },
        // And the Rust half, which is the one with nothing above it: the drivers may HOLD a policy,
        // never declare one.
        Claim::NoneUnder {
            roots: &DRIVERS,
            extensions: RUST,
            pattern: concat!(
                r"pub struct (FlowCreditPolicy|ReceiveWindowAccountant|BoundedQueuePolicy",
                r"|ChannelTable|MuxFrameDecoder)\b",
            ),
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} declares a second mux policy — slopdesk-muxnet and slopdesk-clientnet DRIVE \
                      slopdesk_wire::mux, and a copy beside it agrees with the host until one of the two \
                      clamps low and stalls a channel rather than failing (docs/20 §4)",
        },
        Claim::Populated {
            roots: &DRIVERS,
            extensions: RUST,
            minimum: 8,
            message: "rust/slopdesk-{muxnet,clientnet}/src read as {found} files — the crates moved, so the \
                      second-copy ban beside this stopped checking anything (docs/20 §4)",
        },
    ];
    check_all(tree, &claims)
}

/// The git DIALECT — `main ↑2 ↓1 +3 !4 ?5 ~1 $2`.
///
/// The order, the sigil each role gets, the weight it is set at and the ladder it sheds down are
/// `slopdesk_workspace::git_line`'s. The Swift face asks and SPELLS: it puts a glyph next to a
/// number, and it supplies the branch's own text.
///
/// This one is ratcheted because it has already been got wrong once, in exactly the way a second
/// speller gets things wrong: a dead `PaneGitSummary.compactLine` spelled a conflict `=` where the
/// live renderer spelled it `~`, and both compiled until the copy was deleted (docs/56 increment
/// 45).
///
/// So no SIGIL may be minted on the Swift side. Every one below is a glyph the rule chooses; a
/// literal here is a second dialect being born, whatever it happens to agree with today.
#[must_use]
pub fn git_dialect(tree: &Tree) -> Report {
    const SWIFT_GIT_LINE: &str = "Sources/SlopDeskClientCore/Rail/SidebarGitLine.swift";

    let claims = [
        Claim::Names {
            path: SWIFT_GIT_LINE,
            needle: "slopdesk_git_line_runs",
            message: "SidebarGitLine.swift stopped asking the door — it spells the dialect, it does not \
                      choose it",
        },
        Claim::Names {
            path: "rust/slopdesk-workspace/src/git_line.rs",
            needle: "pub fn runs",
            message: "rust/slopdesk-workspace/src/git_line.rs lost runs — the dialect lives where its \
                      ladder does",
        },
        Claim::Lacks {
            path: SWIFT_GIT_LINE,
            pattern: r#""↑|"↓|"\+\\\(|"!\\\(|"\?\\\(|"~|"\$\\\("#,
            view: View::Code,
            message: "SidebarGitLine.swift minted a sigil — the glyph is the rule's, only the join is not",
        },
    ];
    check_all(tree, &claims)
}

/// The metadata RPC's payloads and the workspace CHANNEL's, both `rust/slopdesk-wire`'s.
///
/// The metadata face is ONE-directional now, and the claim below is two halves for that reason. The
/// client ENCODES requests and DECODES responses, so `MetadataCodec.swift` calls three encode doors
/// and ten decode ones plus the porcelain fold, the constant table and the two byte-reading doors.
/// The OPPOSITE diagonal — a response encoder and a request decoder per verb — is now BANNED by
/// name: `Sources/` had a host target once, and when `docs/63` §G.4 confirmed it was gone those
/// thirteen doors had no caller but the golden generator and the suites checking they worked. They
/// retired with the Swift, so this rule is what keeps a "just for a test fixture" encoder from
/// growing the host half back one verb at a time.
///
/// The workspace channel is the same shape and got the same treatment: the client encodes
/// subscribe/presence/intent and decodes roster/intentResult, and the four doors on the other
/// diagonal are banned by name. By name rather than by direction because of the ONE real crossing —
/// `slopdesk_workspace_encode_intent_result` is host-shaped and stays required, since
/// `LoopbackWorkspaceDocument` is a host that happens to run inside the client, answering intents
/// for a workspace that never leaves the process.
///
/// A payload validated in two languages is two validations, and the lenient one is the one a
/// hostile body finds — which is why the readers, the writers and the clamps are banned rather than
/// merely unused. The bounds are the doors' numbers for the same reason: the per-record floors are
/// what size a roster decode, so a Swift copy is a length check the two languages could stop
/// agreeing on.
#[must_use]
pub fn payload_channels(tree: &Tree) -> Report {
    let claims = [
        // By NAME, not by call: half of these cross as a function REFERENCE into a shared helper.
        Claim::Mentions {
            path: SWIFT_METADATA,
            names: &[
                "slopdesk_metadata_decode_processes",
                "slopdesk_metadata_decode_ports",
                "slopdesk_metadata_decode_dir_listing",
                "slopdesk_metadata_decode_git_status",
                "slopdesk_metadata_decode_agent_sessions",
                "slopdesk_metadata_decode_agent_hook_status",
                "slopdesk_metadata_encode_clipboard_set",
                "slopdesk_metadata_encode_clipboard_read_request",
                "slopdesk_metadata_decode_clipboard_read_response",
                "slopdesk_metadata_decode_host_vitals",
                "slopdesk_metadata_decode_service_endpoint",
                "slopdesk_metadata_decode_code_open_disposition",
                "slopdesk_metadata_encode_code_font_spec",
                "slopdesk_metadata_fold_git_codes",
                "slopdesk_metadata_memory_pressure",
                "slopdesk_metadata_service_state",
                "slopdesk_metadata_constant",
            ],
            message: "MetadataCodec.swift no longer calls {entry} — the metadata payloads are \
                      rust/slopdesk-wire's",
        },
        // The other diagonal, banned by name. Each of these is a door the client would only want in
        // order to fabricate a HOST message, and the moment one comes back the payload has two
        // encoders again — the shape docs/63 §G.4 retired. A test that needs host-shaped bytes
        // spells them, the way `BigEndianFixtureBytes.swift` does: a second speller is allowed, a
        // second implementation is not.
        Claim::Lacks {
            path: SWIFT_METADATA,
            pattern: "slopdesk_metadata_encode_(processes|ports|dir_listing|git_status|\
                      agent_sessions|agent_hook_status|clipboard_read_response|host_vitals|\
                      service_endpoint|code_open_disposition)|\
                      slopdesk_metadata_decode_(clipboard_set|clipboard_read_request|code_font_spec)",
            view: View::Code,
            message: "MetadataCodec.swift opened a host-side metadata door again — the client encodes \
                      REQUESTS and decodes RESPONSES, and the opposite diagonal retired with the Swift \
                      host target (docs/63 §G.4)",
        },
        Claim::Lacks {
            path: SWIFT_METADATA,
            pattern: "BigEndianReader|appendBE|clampedUTF8|clampedCount|readString",
            view: View::Code,
            message: "MetadataCodec.swift grew a reader, a writer or a clamp back — metadata bodies are \
                      parsed once, in Rust",
        },
        Claim::Lacks {
            path: SWIFT_METADATA,
            pattern: r"12 \* 1024 \* 1024|UInt32\.max|65535|4 \+ 4 \+ 2|2 \+ 1 \+ 2",
            view: View::Code,
            message: "MetadataCodec.swift spells a metadata constant again — slopdesk_metadata_constant \
                      vends them",
        },
        Claim::Mentions {
            path: SWIFT_WS_CHANNEL,
            names: &[
                "slopdesk_workspace_encode_subscribe",
                "slopdesk_workspace_encode_presence",
                "slopdesk_workspace_encode_intent",
                "slopdesk_workspace_encode_intent_result",
                "slopdesk_workspace_decode_intent_result",
                "slopdesk_workspace_decode_roster",
                "slopdesk_workspace_constant",
            ],
            message: "WorkspaceChannelCodec.swift no longer calls {entry} — the workspace payloads are \
                      parsed in Rust (docs/45 §5.2)",
        },
        // The host's diagonal, banned by name — the metadata ban's twin, one channel over. A client
        // encodes subscribe/presence/intent and decodes roster/intentResult; reading a request or
        // writing a roster is what a HOST does, and the four doors that did it had no caller but the
        // suites checking they worked.
        //
        // `slopdesk_workspace_encode_intent_result` is deliberately NOT here, and that is the whole
        // subtlety: it is host-shaped and LIVE, because `LoopbackWorkspaceDocument` is a host — a
        // client-local one, serving a workspace whose intents never leave the process. So this bans
        // four names rather than a direction; a pass that "finished the diagonal" would delete the
        // loopback's only way to answer.
        Claim::Lacks {
            path: SWIFT_WS_CHANNEL,
            pattern: "slopdesk_workspace_decode_(subscribe|presence|intent)\\b|\
                      slopdesk_workspace_encode_roster",
            view: View::Code,
            message: "WorkspaceChannelCodec.swift opened a host-side workspace door again — the client \
                      encodes REQUESTS and decodes EVENTS, and that diagonal retired with the Swift host \
                      target (docs/63 §G.4)",
        },
        Claim::Lacks {
            path: SWIFT_WS_CHANNEL,
            pattern: r"BigEndianReader|appendBE|clampUTF8|readUUID|readBytes\(",
            view: View::Code,
            message: "WorkspaceChannelCodec.swift grew a reader or a clamp back — workspace bodies are \
                      parsed once, in Rust",
        },
        Claim::Lacks {
            path: SWIFT_WS_CHANNEL,
            pattern: r"maxLabelBytes = [0-9]|maxRecords = [0-9]|\* 42|\* 22|\* 21",
            view: View::Code,
            message: "WorkspaceChannelCodec.swift spells a workspace bound again — \
                      slopdesk_workspace_constant vends them",
        },
        // Two env gates docs/46 records as "deleted deliberately — do not reintroduce". Multi-client
        // sync is unconditional because a client draws its layout FROM the document: a host that
        // switched the channel off would hand it a blank window and no error to explain it, which is
        // the worst shape a kill switch can take. Shipping code only — the test that spells the name
        // is the enforcement, not a violation of it.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "SLOPDESK_PANE_FANOUT|SLOPDESK_WORKSPACE_DOC",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a deleted multi-client env gate is back in shipping code ({files}) — sync is \
                      unconditional (docs/46)",
        },
    ];
    check_all(tree, &claims)
}

/// The two name tables that stay in Swift, and the byte that may not drift under them.
///
/// `MetadataVerb` and the workspace channel's four vocabularies are name tables with no arithmetic
/// — the same category as `MuxFrameType` — so they stay. What cannot drift is the BYTE: a verb
/// numbered differently at the two ends is a client asking for the clipboard and a host answering
/// with vitals, or a client subscribing and a host reading an intent.
///
/// Compared as `NAME=NUMBER` with both sides upper-cased, because the two languages capitalise
/// differently on purpose. The count floors are what make a renamed declaration fail loudly instead
/// of comparing two empty sets.
#[must_use]
pub fn wire_vocabularies(tree: &Tree) -> Report {
    let mut report = Report::new();
    agrees(tree, &mut report, &Vocabulary {
        label: "metadata verbs",
        swift: "Sources/SlopDeskProtocol/Metadata/MetadataVerb.swift",
        swift_pattern: SWIFT_ENTRY,
        rust: "rust/slopdesk-wire/src/metadata/verb.rs",
        rust_pattern: RUST_ENTRY,
        minimum: 26,
        doc: "docs/20 §7",
    });
    agrees(tree, &mut report, &Vocabulary {
        label: "workspace channel names",
        swift: SWIFT_WS_CHANNEL,
        swift_pattern: SWIFT_ENTRY,
        rust: "rust/slopdesk-wire/src/workspace.rs",
        rust_pattern: RUST_ENTRY,
        minimum: 14,
        doc: "docs/45 §5.2",
    });
    report
}

/// How each language spells one entry of a `NAME = NUMBER` table.
///
/// Named here rather than per call because both vocabularies below are the same two declarations
/// wearing different file names, and a pattern typed twice is one that can be edited once.
const SWIFT_ENTRY: &str = r"case ([a-zA-Z]+) = ([0-9]+)";
const RUST_ENTRY: &str = r"^\s+([A-Z][A-Za-z]+) = ([0-9]+),";

/// The last hand-rolled big-endian helper left `Sources/` when its final production caller did.
///
/// Every wire body is now written and read in Rust, and `appendBE`/`BigEndianReader` live on only
/// as a TEST fixture (`Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift`), where
/// hand-spelled bytes are the POINT — a fixture that agreed with the encoder by construction would
/// assert nothing.
///
/// Back under `Sources/` they are the seed of a second implementation of a wire, which always
/// arrives as "just this one field" rather than as a codec. The fixture's continued EXISTENCE is
/// pinned with it: deleting it would satisfy the ban and take the evidence with it.
#[must_use]
pub fn big_endian_helpers(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(func|var) appendBE|(struct|enum|final class|class) BigEndianReader",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a big-endian helper is back in {files} — wire bodies are Rust's, the helper is a test \
                      fixture",
        },
        Claim::Exists {
            path: "Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift",
            message: "the fixture bytes must stay hand-spelled",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A tree where the mux layer is laid out once, in the four files that hold it, and the one
    /// Swift caller left asks for its two numbers.
    ///
    /// Seeded the way RUST would write the drift, because that is the language every remaining half
    /// of this rule is in: a Swift pattern translated by hand would match none of the drivers and
    /// the rule would pass while guarding nothing.
    fn mux(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-wire/src/mux/envelope.rs",
                "pub fn encode(&self) -> Vec<u8> { vec![] }\npub fn decode(inner: &[u8]) -> Result<Self> { \
                 Err(()) }\npub fn encode_with_payload_into(&self) -> usize { 0 }\npub fn \
                 encoded_byte_count_with_payload(&self) -> usize { 0 }\n",
            )
            .write(
                "rust/slopdesk-wire/src/mux/decoder.rs",
                "pub fn append(&mut self, data: &[u8]) {}\npub fn next_frame(&mut self) {}\npub fn \
                 payload_bytes(&self) {}\n",
            )
            .write(
                "rust/slopdesk-wire/src/mux/channels.rs",
                "pub fn route(&mut self) -> RoutingDecision { RoutingDecision::Drop }\n",
            )
            .write(
                "rust/slopdesk-wire/src/mux/flow.rs",
                "pub struct FlowCreditPolicy;\npub struct ReceiveWindowAccountant;\npub struct \
                 BoundedQueuePolicy;\npub const MAX_CHANNELS_PER_CONNECTION: usize = 256;\n",
            )
            .write(
                "Sources/SlopDeskProtocol/Mux/MuxVocabulary.swift",
                "static var cap: Int { Int(slopdesk_mux_flow_constant(1)) }\n",
            );
        // The file floor the two Rust bans stand on: eight sources across the two driver crates.
        for (crate_name, module) in [
            ("muxnet", "connection"),
            ("muxnet", "subchannel"),
            ("muxnet", "link"),
            ("muxnet", "preamble"),
            ("muxnet", "params"),
            ("clientnet", "dial"),
            ("clientnet", "registry"),
            ("clientnet", "transport"),
        ] {
            fixture.write(
                &format!("rust/slopdesk-{crate_name}/src/{module}.rs"),
                "use slopdesk_wire::mux;\n",
            );
        }
    }

    /// The mux layer is pinned on the side it lives on, and both second copies are red.
    ///
    /// This rule carried no break-test at all while it was six claims about Swift faces — the gap
    /// `docs/63` §G.3 closed along with the faces.
    #[test]
    fn a_second_copy_of_the_mux_layer_is_caught_on_either_side() {
        let fixture = Fixture::new("mux-layer");
        mux(&fixture);
        assert!(super::mux_layer(&fixture.tree()).is_clean());

        // The demux rule, edited away from the table it reads and writes.
        fixture.write(
            "rust/slopdesk-wire/src/mux/channels.rs",
            "pub fn allocate(&mut self) {}\n",
        );
        assert!(!super::mux_layer(&fixture.tree()).is_clean());

        // A policy dropped out of the one file that holds all three.
        mux(&fixture);
        fixture.write(
            "rust/slopdesk-wire/src/mux/flow.rs",
            "pub struct FlowCreditPolicy;\npub const MAX_CHANNELS_PER_CONNECTION: usize = 256;\n",
        );
        assert!(!super::mux_layer(&fixture.tree()).is_clean());

        // The face that stopped asking for the two caps it still has to know.
        mux(&fixture);
        fixture.write(
            "Sources/SlopDeskProtocol/Mux/MuxVocabulary.swift",
            "static var cap: Int { 262_144 }\n",
        );
        assert!(!super::mux_layer(&fixture.tree()).is_clean());

        // The arithmetic, back in the two Swift targets it left.
        mux(&fixture);
        fixture.write(
            "Sources/SlopDeskTransport/Mux/MuxClientTransport.swift",
            "pendingCredit += granted\n",
        );
        assert!(!super::mux_layer(&fixture.tree()).is_clean());

        // And a second policy declared beside the one that ships, which is the half with nothing
        // above it — no door goes missing, no test fails, the two simply disagree.
        mux(&fixture);
        fixture.write(
            "rust/slopdesk-muxnet/src/subchannel.rs",
            "pub struct ReceiveWindowAccountant { pending: i64 }\n",
        );
        let report = super::mux_layer(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("subchannel.rs")),
            "{report:?}"
        );

        // A bare tree has neither the four files nor the floor under the bans.
        let bare = Fixture::new("mux-layer-bare");
        assert!(!super::mux_layer(&bare.tree()).is_clean());
    }

    /// The failure the git dialect has ALREADY had: a second speller that agreed with the live
    /// renderer everywhere except one sigil, and compiled.
    #[test]
    fn a_sigil_minted_in_swift_is_caught() {
        let fixture = Fixture::new("git-sigil");
        fixture
            .write(
                "Sources/SlopDeskClientCore/Rail/SidebarGitLine.swift",
                "let runs = slopdesk_git_line_runs(handle)\n",
            )
            .write("rust/slopdesk-workspace/src/git_line.rs", "pub fn runs() {}\n");
        assert!(super::git_dialect(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskClientCore/Rail/SidebarGitLine.swift",
            "let runs = slopdesk_git_line_runs(handle)\nlet ahead = \"↑\\(n)\"\n",
        );
        let report = super::git_dialect(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("minted a sigil")),
            "{report:?}"
        );
    }

    /// Every name `payload_channels` requires of the two codec faces, in one string each, so a
    /// break-test can seed exactly the drift it is about and nothing else.
    fn metadata_face() -> String {
        [
            "slopdesk_metadata_decode_processes",
            "slopdesk_metadata_decode_ports",
            "slopdesk_metadata_decode_dir_listing",
            "slopdesk_metadata_decode_git_status",
            "slopdesk_metadata_decode_agent_sessions",
            "slopdesk_metadata_decode_agent_hook_status",
            "slopdesk_metadata_encode_clipboard_set",
            "slopdesk_metadata_encode_clipboard_read_request",
            "slopdesk_metadata_decode_clipboard_read_response",
            "slopdesk_metadata_decode_host_vitals",
            "slopdesk_metadata_decode_service_endpoint",
            "slopdesk_metadata_decode_code_open_disposition",
            "slopdesk_metadata_encode_code_font_spec",
            "slopdesk_metadata_fold_git_codes",
            "slopdesk_metadata_memory_pressure",
            "slopdesk_metadata_service_state",
            "slopdesk_metadata_constant",
        ]
        .map(|name| format!("_ = {name}\n"))
        .concat()
    }

    fn workspace_face() -> String {
        [
            "slopdesk_workspace_encode_subscribe",
            "slopdesk_workspace_encode_presence",
            "slopdesk_workspace_encode_intent",
            "slopdesk_workspace_encode_intent_result",
            "slopdesk_workspace_decode_intent_result",
            "slopdesk_workspace_decode_roster",
            "slopdesk_workspace_constant",
        ]
        .map(|name| format!("_ = {name}\n"))
        .concat()
    }

    /// The metadata face points ONE way after `docs/63` §G.4: the client encodes requests and
    /// decodes responses. A response ENCODER coming back is the Swift host half regrowing — most
    /// plausibly to fabricate bytes for a test — so the ban is by name and the seed is the single
    /// most tempting one.
    #[test]
    fn a_host_side_metadata_encoder_coming_back_is_caught() {
        let fixture = Fixture::new("metadata-host-diagonal");
        fixture
            .write(super::SWIFT_METADATA, &metadata_face())
            .write(super::SWIFT_WS_CHANNEL, &workspace_face());
        assert!(super::payload_channels(&fixture.tree()).is_clean());

        fixture.write(
            super::SWIFT_METADATA,
            &format!("{}_ = slopdesk_metadata_encode_host_vitals\n", metadata_face()),
        );
        let report = super::payload_channels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("host-side metadata door")),
            "{report:?}"
        );
    }

    /// And the request decoders are the same ban from the other end — `decodeClipboardSet` reads a
    /// message only a host receives.
    #[test]
    fn a_host_side_metadata_decoder_coming_back_is_caught() {
        let fixture = Fixture::new("metadata-host-decoder");
        fixture
            .write(super::SWIFT_METADATA, &metadata_face())
            .write(super::SWIFT_WS_CHANNEL, &workspace_face());
        assert!(super::payload_channels(&fixture.tree()).is_clean());

        fixture.write(
            super::SWIFT_METADATA,
            &format!("{}_ = slopdesk_metadata_decode_clipboard_set\n", metadata_face()),
        );
        let report = super::payload_channels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("host-side metadata door")),
            "{report:?}"
        );
    }

    /// The workspace channel points one way too — the client encodes subscribe/presence/intent and
    /// decodes roster/intentResult. Reading a REQUEST is the host's half, and `decode_subscribe` is
    /// the tempting one: a test wanting to know what the client sent would reach for it first.
    #[test]
    fn a_host_side_workspace_door_coming_back_is_caught() {
        let fixture = Fixture::new("workspace-host-diagonal");
        fixture
            .write(super::SWIFT_METADATA, &metadata_face())
            .write(super::SWIFT_WS_CHANNEL, &workspace_face());
        assert!(super::payload_channels(&fixture.tree()).is_clean());

        fixture.write(
            super::SWIFT_WS_CHANNEL,
            &format!("{}_ = slopdesk_workspace_decode_subscribe\n", workspace_face()),
        );
        let report = super::payload_channels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("host-side workspace door")),
            "{report:?}"
        );
    }

    /// And the roster ENCODER from the other end — writing one is what a host does. This also holds
    /// the ban's one exception honest: the clean fixture calls
    /// `slopdesk_workspace_encode_intent_result`, which is host-shaped and LIVE because the
    /// loopback document is a client-local host, so a ban stated as a direction rather than
    /// four names would fail this assertion before the seed ever ran.
    #[test]
    fn a_host_side_workspace_encoder_coming_back_is_caught() {
        let fixture = Fixture::new("workspace-host-encoder");
        fixture
            .write(super::SWIFT_METADATA, &metadata_face())
            .write(super::SWIFT_WS_CHANNEL, &workspace_face());
        assert!(super::payload_channels(&fixture.tree()).is_clean());

        fixture.write(
            super::SWIFT_WS_CHANNEL,
            &format!("{}_ = slopdesk_workspace_encode_roster\n", workspace_face()),
        );
        let report = super::payload_channels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("host-side workspace door")),
            "{report:?}"
        );
    }

    /// A verb numbered differently at the two ends is a client asking for the clipboard and a host
    /// answering with vitals. The capitalisation conventions must cancel; only the byte is
    /// compared.
    #[test]
    fn a_metadata_verb_renumbered_on_one_side_is_caught() {
        let fixture = Fixture::new("metadata-verbs");
        let swift = numbered_swift(26);
        fixture
            .write("Sources/SlopDeskProtocol/Metadata/MetadataVerb.swift", &swift)
            .write("rust/slopdesk-wire/src/metadata/verb.rs", &numbered_rust(26))
            .write(super::SWIFT_WS_CHANNEL, &numbered_swift(14))
            .write("rust/slopdesk-wire/src/workspace.rs", &numbered_rust(14));
        assert!(super::wire_vocabularies(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-wire/src/metadata/verb.rs",
            &numbered_rust(26).replace("    Verbx = 0,", "    Verbx = 99,"),
        );
        let report = super::wire_vocabularies(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("disagree")),
            "{report:?}"
        );
    }

    /// And a table that was renamed out of the extraction's reach fails LOUDLY, rather than
    /// comparing two empty sets and calling them equal.
    #[test]
    fn a_vocabulary_that_stopped_extracting_says_so() {
        let fixture = Fixture::new("vocab-stale");
        fixture
            .write(
                "Sources/SlopDeskProtocol/Metadata/MetadataVerb.swift",
                &numbered_swift(3),
            )
            .write("rust/slopdesk-wire/src/metadata/verb.rs", &numbered_rust(3))
            .write(super::SWIFT_WS_CHANNEL, &numbered_swift(14))
            .write("rust/slopdesk-wire/src/workspace.rs", &numbered_rust(14));
        let report = super::wire_vocabularies(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("gone stale")),
            "{report:?}"
        );
    }

    /// Deleting the fixture would satisfy the ban and take the evidence with it, so the fixture's
    /// existence is pinned beside the ban.
    #[test]
    fn deleting_the_hand_spelled_fixture_does_not_satisfy_the_ban() {
        let fixture = Fixture::new("bigendian-fixture");
        fixture.write("Sources/A.swift", "let x = 1\n").write(
            "Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift",
            "func appendBE() {}\n",
        );
        assert!(super::big_endian_helpers(&fixture.tree()).is_clean());

        let gone = Fixture::new("bigendian-gone");
        gone.write("Sources/A.swift", "let x = 1\n");
        let report = super::big_endian_helpers(&gone.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("hand-spelled")),
            "{report:?}"
        );
    }

    /// Names are letters only, because the extraction's are: both sides read `[A-Za-z]+`, so a
    /// fixture spelling `verb0` would extract NOTHING and prove only that two empty sets are equal.
    fn name_of(index: usize) -> String {
        format!("verb{}", "x".repeat(index + 1))
    }

    fn numbered_swift(count: usize) -> String {
        (0..count).fold(String::new(), |mut out, n| {
            use std::fmt::Write as _;
            let _ = writeln!(out, "    case {} = {n}", name_of(n));
            out
        })
    }

    fn numbered_rust(count: usize) -> String {
        (0..count).fold(String::new(), |mut out, n| {
            use std::fmt::Write as _;
            let _ = writeln!(out, "    Verb{} = {n},", "x".repeat(n + 1));
            out
        })
    }
}
