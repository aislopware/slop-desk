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
/// `SlopDeskProtocol` still owns `appendBE`/`BigEndianReader` for the framing and metadata layers
/// that have not moved yet, so that ban is this FILE rather than the target: the codec that went to
/// Rust may not quietly come back beside them.
///
/// The three numbers both ends would otherwise type are the wire version, a session id's width and
/// the frame ceiling. `slopdesk_wire_constant` vends all three. The version travels as a bare `1`,
/// which no numeric pattern can tell from a tag byte — so it is pinned by NAME, and the two widths
/// by value.
///
/// The framing itself is `rust/slopdesk-wire`'s `FrameDecoder`, held through a handle: the
/// buffering, the cursor that avoids a per-frame memmove and the fail-stop on a lost byte-boundary.
/// What is left in Swift is the handle and the error mapping. A second READER of the same stream is
/// not a second implementation; a second BUFFER of it is, and it is how the cursor and the
/// fail-stop drift apart.
#[must_use]
pub fn terminal_wire(tree: &Tree) -> Report {
    const SWIFT_WIRE: &str = "Sources/SlopDeskProtocol/WireMessageCodec.swift";
    const SWIFT_ROOT: &str = "Sources/SlopDeskProtocol/SlopDesk.swift";
    const SWIFT_FRAMING: &str = "Sources/SlopDeskProtocol/FrameDecoder.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_WIRE,
            entries: &[
                "slopdesk_wire_message_encode",
                "slopdesk_wire_message_decode",
                "slopdesk_wire_message_byte_count",
                "slopdesk_wire_constant",
            ],
            message: "Sources/SlopDeskProtocol/WireMessageCodec.swift no longer calls {entry} — the \
                      terminal wire is rust/slopdesk-wire's",
        },
        Claim::Lacks {
            path: SWIFT_WIRE,
            pattern: "appendBE|BigEndianReader",
            view: View::Code,
            message: "WireMessageCodec.swift grew a big-endian helper back — PATH-1 bytes are laid out \
                      once, in Rust",
        },
        Claim::NoneOf {
            paths: &[SWIFT_WIRE, SWIFT_ROOT],
            pattern: r"(static let|==) *(16 \* 1024 \* 1024|16)\b",
            view: View::Code,
            message: "a wire width is spelled in Swift again ({files}) — slopdesk_wire_constant vends it",
        },
        Claim::NoneOf {
            paths: &[SWIFT_WIRE, SWIFT_ROOT],
            pattern: r"protocolVersion[^=]*= *[0-9]",
            view: View::Code,
            message: "the wire version is spelled in Swift again ({files}) — slopdesk_wire_constant vends it",
        },
        Claim::Doors {
            path: SWIFT_FRAMING,
            entries: &[
                "slopdesk_frame_decoder_new",
                "slopdesk_frame_decoder_free",
                "slopdesk_frame_decoder_append",
                "slopdesk_frame_decoder_next",
                "slopdesk_frame_decoder_run",
            ],
            message: "Sources/SlopDeskProtocol/FrameDecoder.swift no longer calls {entry} — the terminal \
                      framing is rust/slopdesk-wire's",
        },
        Claim::Lacks {
            path: SWIFT_FRAMING,
            pattern: "readOffset|compactConsumed|readPrefix|private var buffer",
            view: View::Code,
            message: "FrameDecoder.swift grew its own buffer back — the frame buffer is Rust's, and there \
                      is one",
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
/// Eleven encode/decode pairs plus the porcelain fold the sidebar and the host status push must
/// agree on; five more pairs for the workspace channel. The Swift is the value types and the
/// flatten.
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
                "slopdesk_metadata_encode_processes",
                "slopdesk_metadata_decode_processes",
                "slopdesk_metadata_encode_ports",
                "slopdesk_metadata_decode_ports",
                "slopdesk_metadata_encode_dir_listing",
                "slopdesk_metadata_decode_dir_listing",
                "slopdesk_metadata_encode_git_status",
                "slopdesk_metadata_decode_git_status",
                "slopdesk_metadata_encode_agent_sessions",
                "slopdesk_metadata_decode_agent_sessions",
                "slopdesk_metadata_encode_clipboard_set",
                "slopdesk_metadata_decode_clipboard_set",
                "slopdesk_metadata_encode_clipboard_read_request",
                "slopdesk_metadata_decode_clipboard_read_request",
                "slopdesk_metadata_encode_clipboard_read_response",
                "slopdesk_metadata_decode_clipboard_read_response",
                "slopdesk_metadata_encode_host_vitals",
                "slopdesk_metadata_decode_host_vitals",
                "slopdesk_metadata_encode_service_endpoint",
                "slopdesk_metadata_decode_service_endpoint",
                "slopdesk_metadata_encode_agent_hook_status",
                "slopdesk_metadata_decode_agent_hook_status",
                "slopdesk_metadata_encode_code_open_disposition",
                "slopdesk_metadata_decode_code_open_disposition",
                "slopdesk_metadata_encode_code_font_spec",
                "slopdesk_metadata_decode_code_font_spec",
                "slopdesk_metadata_fold_git_codes",
                "slopdesk_metadata_constant",
            ],
            message: "MetadataCodec.swift no longer calls {entry} — the metadata payloads are \
                      rust/slopdesk-wire's",
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
                "slopdesk_workspace_decode_subscribe",
                "slopdesk_workspace_encode_presence",
                "slopdesk_workspace_decode_presence",
                "slopdesk_workspace_encode_intent",
                "slopdesk_workspace_decode_intent",
                "slopdesk_workspace_encode_intent_result",
                "slopdesk_workspace_decode_intent_result",
                "slopdesk_workspace_encode_roster",
                "slopdesk_workspace_decode_roster",
                "slopdesk_workspace_constant",
            ],
            message: "WorkspaceChannelCodec.swift no longer calls {entry} — the workspace payloads are \
                      parsed in Rust (docs/45 §5.2)",
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
