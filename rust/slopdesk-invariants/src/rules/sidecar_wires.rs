//! The three sidecar wires a SHIPPED client dials, and the line each daemon announces itself on.
//!
//! Ported from the deleted `check-supervisor.sh` §§10–12c. dropd, androidd and inspectord are the
//! three two-ended protocols the client end dials DIRECTLY, which is what sets them apart from
//! superd and screend: an iOS build shipped months ago is one end and a fresh daemon is the other,
//! nothing negotiates, and every constant here is a value both sides simply have to have been born
//! with.
//!
//! All three ends are Rust now — the client halves are crate modules and the Swift files are faces
//! over FFI doors — so what these rules pin is no longer "two spellings agree". It is that there is
//! still only ONE spelling, and that the face reaches it rather than quietly reacquiring a copy.
//!
//! The bans read [`View::Code`]. Each of the three faces carries prose naming what moved and where
//! it went, and a gate that could not tell a declaration from a sentence about one would teach
//! people to delete the explanation.

use crate::claim::{ByteMap, Claim, Corpus, Extract, RUST, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// dropd's client door, in the shim.
const DROP_FFI: &str = "rust/slopdesk-ffi/src/file_transfer.rs";
/// The Swift target that is dropd's face.
const DROP_DIR: &str = "Sources/SlopDeskFileTransfer";
/// The client half of the wire — the module that writes every request and reads every reply.
const DROP_CLIENT: &str = "rust/slopdesk-dropd/src/client.rs";
/// The daemon half — the module that decodes every request and writes every reply.
const DROP_PROTOCOL: &str = "rust/slopdesk-dropd/src/protocol.rs";
/// dropd's listener, which prints the announce line.
const DROP_SERVER: &str = "rust/slopdesk-dropd/src/server.rs";

/// The Android panel's target — three connection types, each holding one socket.
const ANDROID_DIR: &str = "Sources/SlopDeskDevicePanels/Android";
/// The panel's device row — a FACE over `slopdesk_android_device_list` since the reply decode
/// descended, and the file the `JSONSerialization` ban used to have to exempt.
const ANDROID_DEVICE: &str = "Sources/SlopDeskDevicePanels/Android/AndroidDevice.swift";
/// The PANEL's half of the bridge grammar since `a9fd1833` — the op vocabulary, the request line
/// and the reply's refusal, all of which used to be Swift.
const ANDROID_BRIDGE: &str = "rust/slopdesk-devicepanel/src/android_bridge.rs";
/// The hand-written header the face's op names come from.
const ANDROID_HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
/// androidd's request switch and announce line.
const ANDROID_SERVER: &str = "rust/slopdesk-androidd/src/server.rs";
/// androidd's reply encoder, where the field names are written.
const ANDROID_PROTOCOL: &str = "rust/slopdesk-androidd/src/protocol.rs";

/// The inspector's client door, in the shim.
const INSPECTOR_FFI: &str = "rust/slopdesk-ffi/src/inspector.rs";
/// The Swift face over it.
const INSPECTOR_FACE: &str = "Sources/SlopDeskInspector/InspectorWire.swift";
/// The one spelling of the frame: the prefix, the cap, the three tags and the splitter.
const INSPECTOR_WIRE: &str = "rust/slopdesk-inspectord/src/wire.rs";
/// inspectord's listener.
const INSPECTOR_SERVER: &str = "rust/slopdesk-inspectord/src/server.rs";

/// hostd's profiles for the two survivors it ADOPTS — dropd and inspectord — where each daemon's
/// announce constants are read off the crate that prints them.
const HOSTD_SIDECARS: &str = "rust/slopdesk-hostd/src/sidecar.rs";
/// hostd's metadata-verb services, where androidd's ensure profile is built for the same reason.
const HOSTD_SERVICES: &str = "rust/slopdesk-hostd/src/services.rs";
/// hostd's startup audit, which decides what a stale sidecar permits.
const HOSTD_AUDIT: &str = "rust/slopdesk-hostd/src/audit.rs";

/// The per-sidecar restart policy table.
const SIDECARS: &str = "rust/slopdesk-sidecars/src/lib.rs";
/// The manifest diff that turns two `MANIFEST.json` files into a plan.
const SIDECARS_MANIFEST: &str = "rust/slopdesk-sidecars/src/manifest.rs";
/// `slopdesk sidecars`, which asks for the plan — Rust, so it calls the crate, not the door.
const SIDECAR_CLI: &str = "rust/slopdesk-cli/src/shell/local.rs";
/// The install side, which records what it read.
const HOMEBREW_FORMULA: &str = "packaging/homebrew/Formula/slopdesk.rb";

/// dropd's client end holds no layout of its own
///
/// PATH 4 (`docs/53`). The client half is `rust/slopdesk-dropd` — `upload` holds the SEQUENCE and
/// `client` every layout — and `Sources/SlopDeskFileTransfer` reaches all of it through the one
/// door in `rust/slopdesk-ffi/src/file_transfer.rs`. It used to be eight doors with a Swift driver
/// above them holding the socket and the order; the door is one verb now, so what this pins is that
/// the face still goes through it rather than dialling anything itself.
///
/// A "just this one field" big-endian helper is how a second implementation grows back one accessor
/// at a time, and a Swift receiver is the cross-language mirror the tree forbids outright.
///
/// BREAK-TEST: dropped `slopdesk_drop_upload` from the shim ⇒ FAIL "no longer exports".
/// Separately added `func appendBE(` to a file in the target ⇒ FAIL "a byte reader/writer is back".
/// Separately spelled `final class FileTransferServer` under `Sources/` ⇒ FAIL "a Swift file-drop
/// receiver is back". All three restored from /tmp; PASS.
#[must_use]
pub fn the_drop_client_holds_no_layout(tree: &Tree) -> Report {
    /// The one entry the door vends, which the face calls.
    const DOORS: &[&str] = &["slopdesk_drop_upload"];
    check_all(tree, &[
        Claim::Mentions {
            path: DROP_FFI,
            names: DOORS,
            message: "rust/slopdesk-ffi/src/file_transfer.rs no longer exports {entry} — PATH 4's client \
                      door has moved (docs/55)",
        },
        Claim::MentionsUnder {
            root: DROP_DIR,
            names: DOORS,
            message: "Sources/SlopDeskFileTransfer stopped calling {entry} — the client end is dropd's \
                      (docs/53, docs/55)",
        },
        Claim::NoneUnder {
            roots: &[DROP_DIR],
            extensions: SWIFT,
            pattern: r"func appendBE|struct ByteReader|BigEndianReader",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a byte reader/writer is back in Sources/SlopDeskFileTransfer — dropd's client module \
                      owns the layout, and a one-field helper is the second implementation growing back one \
                      accessor at a time: {files}",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor|protocol) (FileTransferServer|FileReceiveLogic|FileDropSink|DiskFileDropSink|FileNameSanitizer|LoopbackFileTransferChannel)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift file-drop receiver is back in Swift — dropd owns the receiving end, and a \
                      'small fallback for when dropd is missing' is the cross-language mirror the tree \
                      forbids: when dropd is absent hostd logs it and there is no file transfer, which is \
                      the whole design (docs/53): {files}",
        },
    ])
}

/// dropd's type bytes are one alphabet, read from both directions
///
/// The type BYTE is the whole discriminator, and the two ends are two modules of one crate rather
/// than two languages — which narrows the skew but does not close it, because they are still
/// written and edited apart. Skew a request byte and dropd decodes an offer's id out of a chunk
/// body; skew a reply byte and the client's decoder throws `unknownType` on a perfectly good
/// `complete` and reports a failed upload that is sitting finished on disk.
///
/// Both spellings of a written request byte are read. A chunk's type byte is written by
/// `write_chunk_payload` — the slice writer both the borrowed and the owned path go through — not
/// by the match arm, so sweeping only `encode_request_payload` would quietly stop covering type 3,
/// the one frame that carries a body. A gate that silently covers four of five types is worse than
/// none.
///
/// The request direction is a SUBSET and the reply direction an EQUALITY, and that asymmetry is the
/// wire's: the daemon may decode a request the shipped client does not yet send, but a reply the
/// daemon can send and the client cannot decode is a dropped connection mid-upload.
///
/// The five request bytes are ALSO pinned as a set, which is the shell's `-ne 5` count made exact.
/// A count cannot tell the loss of type 3 from the arrival of a type 7 written beside it.
///
/// BREAK-TEST: renamed `out.push(4)` to `out.push(7)` in the client ⇒ FAIL twice — the pinned set
/// disagrees, and 7 has no arm decoding it. Separately deleted the `9 => {` arm from
/// `encode_reply_payload` ⇒ FAIL "dropd reply type bytes". Both restored from /tmp; PASS.
#[must_use]
pub fn the_drop_type_bytes_are_one_alphabet(tree: &Tree) -> Report {
    /// Every request byte the client writes, in both spellings.
    ///
    /// Read over the whole file rather than the shell's two `awk` ranges: `Extract::also` is a
    /// whole-file pattern, and the file holds no other `out.push(<digit>)`. If one ever appears
    /// outside an encoder the pinned set below is what says so, by name.
    ///
    /// [`View::Statements`], and the reason it is not [`View::Code`] is the reason this read was
    /// [`View::Raw`] until 2026-08-30: `code()` is LINE-based, and it treats a line whose first
    /// character is `*` as the continuation of a block comment — which is what `    *kind = 3;`
    /// looks like to it. The code view therefore deletes the chunk writer's byte, the one frame
    /// that carries a body and the exact type a match-only sweep would already have missed.
    /// `statements()` is a scanner rather than a heuristic, so it keeps that line and blanks the
    /// comments the raw read was letting through.
    const WRITTEN: Extract =
        Extract::statements(DROP_CLIENT, r"^ *out\.push\(([0-9]+)\);$").also(&[r"^ *\*kind = ([0-9]+);$"]);
    check_all(tree, &[
        Claim::PinnedSet {
            label: "dropd request type bytes",
            from: WRITTEN,
            expect: &["1", "2", "3", "4", "5"],
        },
        Claim::Subset {
            label: "dropd request type",
            subject: WRITTEN,
            universe: Extract::statements(DROP_PROTOCOL, r"^ *([0-9]+) => \{$"),
            message: "the client encodes request type {orphans} but rust/slopdesk-dropd/src/protocol.rs has \
                      no arm decoding it — dropd would read an offer's id out of a chunk body (docs/53)",
        },
        // Both sides are Rust here; the field names are the shape's, not the languages'.
        Claim::SameSet {
            label: "dropd reply type bytes",
            swift: Extract::statements(DROP_CLIENT, r"^ *([0-9]+) => \{$")
                .within(r"pub fn decode_reply_payload", r"^\}$"),
            rust: Extract::statements(DROP_PROTOCOL, r"^ *out\.push\(([0-9]+)\);$")
                .within(r"pub fn encode_reply_payload", r"^\}$"),
        },
        Claim::Pinned {
            label: "dropd's wire version",
            from: Extract::statements(DROP_PROTOCOL, r"VERSION: u8 = ([0-9]+);$"),
            expect: "1",
        },
        Claim::Pinned {
            label: "dropd's frame ceiling",
            from: Extract::statements(DROP_PROTOCOL, r"MAX_FRAME_PAYLOAD: usize = (.*);$"),
            expect: "16 * 1024 * 1024",
        },
    ])
}

/// The Android bridge's ops and device fields cross both ways
///
/// The Android panel (`docs/48`). Like dropd the CLIENT dials the bridge port directly, having
/// learned it from metadata verb 22 — but unlike every other pair here the wire is line-JSON, so a
/// skew is not a misparsed length: it is a request the daemon answers `bad request` to, or a reply
/// field the panel silently renders as absent. Both read as "the Android tab is broken" with
/// nothing in either language's tests to say why.
///
/// The panel's half of that grammar is RUST now, and the rule follows it. `a9fd1833` moved the op
/// vocabulary, the request line and the reply's refusal into `slopdesk_devicepanel::android_bridge`
/// and deleted the Swift originals in the same change. What the Swift files kept is the SOCKET:
/// `NWConnection`, and the ack/stream split that has to happen inside a receive handler because the
/// reply line and the first bytes of the stream arrive in the same chunk. So the old comparison —
/// Swift `"op": "…"` literals against androidd's arms — did not go stale, it lost one side; and it
/// went on PASSING, because a corpus that reads nothing is a subset of everything.
///
/// Three links now carry an op from a Swift call site to an `adb` invocation, and the compiler
/// checks exactly one of them:
///
/// * the face's `SLOPDESK_ANDROID_BRIDGE_OP_*` names against the header. A build error, so the
///   subset direction proves nothing — it is read here for its FLOOR. Seven names is what says the
///   face is still a face, and a face that hand-rolled a request line again would read nought,
///   which is the exact state this rule was found in.
/// * the header's bytes against `BridgeOp`'s discriminants. The header is HAND-WRITTEN, so a
///   reordered enum has the near side sending the byte for `screenshot` and the door building a
///   `console` — with every test on both sides green, because each side is self-consistent.
/// * `BridgeOp::verb` against androidd's `match op`. Two crates, one line-JSON wire, and nothing
///   between them that fails to compile.
///
/// The verbs are PINNED as a set as well, which is the staleness guard a one-file subject can no
/// longer get from a directory's count: a `verb` arm that stopped matching would compare an empty
/// set against seven live arms and report agreement.
///
/// The `"op": "` literal that used to be this rule's SUBJECT is now its ban. It is the precise
/// shape of the regression — one connection type that stops asking the door and writes its own
/// line — and it costs nothing to forbid, because no Swift under the panel builds a bridge request
/// any more.
///
/// `AndroidBridgeRequest` LEFT the name ban in the same reading, and that is the one loosening
/// here. It is no longer a grammar: it is seven one-line calls to `slopdesk_android_bridge_request`
/// with the op byte as their only argument, which is the same far-end shape that has always kept
/// `AndroidDevice` — the CLIENT's row type — out of the ban. What replaces it is stricter than a
/// name: the door calls are required, the JSON encoder is forbidden in the face, and the op literal
/// is forbidden across the directory. Put the grammar back and all three fire.
///
/// `JSONSerialization` is banned under the WHOLE directory now. It used to be banned in the face
/// only, with `AndroidDevice.decodeList` exempt because it "legitimately parses the reply payload"
/// — an exemption that existed because the decode had never been ported, not because a decode
/// belongs on this side. `decode_list` is `slopdesk_devicepanel::android_bridge`'s, the Swift walks
/// the delivery, and the exemption is gone with the code that needed it.
///
/// The field cross-check moved with it, and that move is the point rather than bookkeeping: its
/// subject used to be `AndroidDevice.swift`'s `entry["…"]` reads, and after the port that corpus
/// reads NOTHING — which a subset claim reports as agreement. It now reads the Rust decode's own
/// keys, so the two ends being compared are the two ends that exist.
///
/// BREAK-TEST: eleven fixture cases, one per drift.
/// `an_op_no_arm_serves_is_red` renames `verb`'s `"logcat"` to `"tail"` ⇒ FAIL "no arm serving
/// it". `a_verb_arm_that_stopped_matching_is_red` drops the `Self::Open` arm ⇒ FAIL on the pinned
/// set rather than passing on a short one. `a_face_that_stopped_naming_the_ops_is_red` empties
/// the face ⇒ FAIL "floor 7", which is the state the live tree was in.
/// `a_header_byte_that_disagrees_with_the_enum_is_red` renumbers `_SCREENSHOT` in the header ⇒ FAIL
/// "the two languages disagree about which byte a case crosses as".
/// `a_hand_written_op_line_in_the_panel_is_red` writes `"op": "tail"` back into a connection ⇒
/// FAIL "builds a bridge request by hand". `a_face_that_stopped_calling_a_door_is_red` drops
/// `slopdesk_android_log_lines_push` ⇒ FAIL "stopped calling".
/// `a_json_encoder_back_in_the_face_is_red` restores `JSONSerialization` ⇒ FAIL "respells the
/// bridge grammar". `a_device_field_the_daemon_stopped_encoding_is_red` renames `model` in the
/// daemon's encoder ⇒ FAIL "never encodes it". And `a_swift_bridge_restored_under_sources_is_red`
/// restores `final class AndroidToolchain` ⇒ FAIL "a Swift Android bridge is back", with the face's
/// own `AndroidBridgeRequest` clean beside it.
#[must_use]
pub fn the_android_bridge_agrees_both_ways(tree: &Tree) -> Report {
    let mut claims = the_op_crosses_its_three_links();
    claims.push(Claim::Subset {
        label: "bridge device field",
        subject: Extract::statements(
            ANDROID_BRIDGE,
            r#"(?:optional_text\(entry, |optional_number\(entry, |entry\.get\()"([a-zA-Z]+)"\)"#,
        ),
        universe: Extract::statements(ANDROID_PROTOCOL, r#""([a-zA-Z]+)""#),
        message: "the panel decodes device field '{orphans}' but rust/slopdesk-androidd/src/protocol.rs \
                  never encodes it — the panel renders what it finds, which is what makes a quietly emptied \
                  column silent (docs/48)",
    });
    claims.push(Claim::Lacks {
        path: ANDROID_DEVICE,
        pattern: r"JSONSerialization|entry\[",
        view: View::Code,
        message: "AndroidDevice.swift decodes the bridge reply in Swift again — the grammar is \
                  slopdesk_devicepanel::android_bridge::decode_list's, and a second copy of the field rules \
                  is how a renamed key empties a column on one side only (docs/48)",
    });
    claims.push(Claim::Mentions {
        path: ANDROID_DEVICE,
        names: &["slopdesk_android_device_list"],
        message: "Sources/SlopDeskDevicePanels/Android/AndroidDevice.swift no longer asks {entry} — the \
                  `list` reply has one decoder",
    });
    claims.extend(the_panel_holds_no_bridge_grammar());
    check_all(tree, &claims)
}

/// The verbs the panel crate writes into `op`, read from the one `match` that spells them.
const VERBS: Extract = Extract::statements(ANDROID_BRIDGE, r#"^ *Self::[A-Za-z]+ => "([a-z]+)",$"#);

/// The op's three hops: the face's names against the header, the header's bytes against the enum's
/// discriminants, and the enum's verbs against androidd's arms — with the verbs pinned as a set so
/// a `match` that stopped matching cannot read as agreement.
fn the_op_crosses_its_three_links() -> Vec<Claim> {
    vec![
        Claim::SubsetUnder {
            label: "bridge ops",
            subject: Corpus {
                root: ANDROID_DIR,
                extensions: SWIFT,
                pattern: r"SLOPDESK_ANDROID_BRIDGE_OP_([A-Z]+)\b",
            },
            universe: Extract::statements(ANDROID_HEADER, r"^#define SLOPDESK_ANDROID_BRIDGE_OP_([A-Z]+) "),
            floor: 7,
            message: "the panel names op '{orphans}', which slopdesk_ffi.h does not define — the header is \
                      hand-written and it is the only thing that makes a door reachable from Swift \
                      (docs/48, docs/55)",
        },
        Claim::SameByteMap {
            label: "BridgeOp",
            swift: ByteMap {
                path: ANDROID_HEADER,
                marker: r"#define SLOPDESK_ANDROID_BRIDGE_OP_LIST ",
                end: r"#define SLOPDESK_ANDROID_BRIDGE_OP_OPEN ",
                pattern: r"#define SLOPDESK_ANDROID_BRIDGE_OP_([A-Z]+) ([0-9]+)u",
            },
            rust: ByteMap {
                path: ANDROID_BRIDGE,
                marker: r"pub enum BridgeOp \{",
                end: r"^\}$",
                pattern: r"^ *([A-Z][a-zA-Z]*) = ([0-9]+),",
            },
        },
        Claim::PinnedSet {
            label: "bridge op verbs",
            from: VERBS,
            expect: &[
                "list",
                "boot",
                "shutdown",
                "console",
                "screenshot",
                "logcat",
                "open",
            ],
        },
        Claim::Subset {
            label: "bridge ops",
            subject: VERBS,
            universe: Extract::statements(ANDROID_SERVER, r#"^ *"([a-z]+)" =>"#),
            message: "the panel sends op '{orphans}' but rust/slopdesk-androidd/src/server.rs has no arm \
                      serving it — the daemon answers `bad request` and the tab just reads as broken \
                      (docs/48)",
        },
    ]
}

/// What is left in Swift is the socket. These four say so from both ends: the doors are called, the
/// JSON encoder is gone from the face, no file under the panel writes a request line by hand, and
/// no host-side bridge has grown back anywhere in `Sources/`.
fn the_panel_holds_no_bridge_grammar() -> Vec<Claim> {
    /// Every door the panel reaches the bridge through. All nine have a Swift caller under
    /// [`ANDROID_DIR`] — the request/reply pair in the face, the console, screenshot and refusal
    /// readers in the client, and the log splitter's four in the log connection — so this list has
    /// no Rust-side-only entry to hold apart the way the inspector's does.
    const DOORS: &[&str] = &[
        "slopdesk_android_bridge_request",
        "slopdesk_android_bridge_reply_failure",
        "slopdesk_android_bridge_refusals",
        "slopdesk_android_bridge_console_output",
        "slopdesk_android_bridge_screenshot_bytes",
        "slopdesk_android_log_lines_new",
        "slopdesk_android_log_lines_free",
        "slopdesk_android_log_lines_push",
        "slopdesk_android_log_lines_answer",
    ];
    vec![
        Claim::MentionsUnder {
            root: ANDROID_DIR,
            names: DOORS,
            message: "Sources/SlopDeskDevicePanels/Android stopped calling {entry} — the request grammar, \
                      the refusal and the logcat splitter are the panel crate's (docs/48, docs/55)",
        },
        Claim::NoneUnder {
            roots: &[ANDROID_DIR],
            extensions: SWIFT,
            pattern: r"JSONSerialization|isValidJSONObject",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} respells the bridge grammar — the request line is \
                      slopdesk_android_bridge_request's, the refusal is \
                      slopdesk_android_bridge_reply_failure's and the device set is \
                      slopdesk_android_device_list's, because an encoder that raises rather than throws \
                      took the app down on a typo the last time this was Swift (docs/48)",
        },
        Claim::NoneUnder {
            roots: &[ANDROID_DIR],
            extensions: SWIFT,
            pattern: r#""op": *""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift file under the Android panel builds a bridge request by hand — the op \
                      vocabulary is slopdesk_devicepanel::android_bridge's, and a connection that writes \
                      its own line is the skew this rule used to be able to see and now forbids outright \
                      (docs/48): {files}",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor|protocol) (AndroidBridgeServer|AndroidBridgeManager|AndroidToolchain|AndroidScrcpySession|AndroidDeviceCatalog|AndroidEmulatorConsole|AndroidSocket|AndroidListener)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift Android bridge is back in Swift — androidd owns adb and the pump (docs/48): \
                      {files}",
        },
    ]
}

/// The inspector's frame has one spelling, and Swift reaches it
///
/// The read-only inspector (`docs/54`). The client has always dialled `terminalPort + 1` directly,
/// and this is the most silent of the five wires because both halves are tolerant BY DESIGN: an
/// unknown frame tag is skipped and an unparseable event body is skipped, precisely so one rogue
/// frame cannot end a session's feed. Skew the tags and nothing errors anywhere; the panel just
/// stays empty.
///
/// `wire.rs` owns the prefix, the cap, the three tags and the splitter, and
/// `Sources/SlopDeskInspector` is its face over the door in `rust/slopdesk-ffi/src/inspector.rs`.
/// What is left in Swift is FRAMING — which frame arrived and where its body sits. The body itself
/// crosses unread: `docs/66` moved the fold and the taxonomy to `slopdesk-inspectord`, and the
/// second claim below is what stops the taxonomy growing back. This doc used to call the event a
/// two-ENDS document, which it was not — both ends deserialised the same body. The tags and the
/// ceiling themselves are [`the_inspector_tags_are_one_alphabet`].
///
/// ⚠️ `slopdesk_inspector_decoder_buffered` DOES NOT EXIST, and this doc claimed the opposite for
/// as long as the claim below it did. It was the one door with no Swift caller — the door's own
/// assertion that a drained splitter had compacted — and it was deleted, because Swift sizes its
/// body buffer from the AGAIN verdict and never asked. The `Claim::Mentions` demanding it survived
/// the deletion by reading the TOMBSTONE that replaced it: a positive anchor read raw text until
/// 2026-08-30, so the sentence "there is no `slopdesk_inspector_decoder_buffered`" answered a claim
/// that the name be present. It is a stay-deleted claim now, over `View::Statements` for exactly
/// that reason — the tombstone must be free to say the name.
///
/// BREAK-TEST: dropped `slopdesk_inspector_decoder_next` from the face ⇒ FAIL "stopped calling".
/// Separately wrote `16 * 1024 * 1024` into the face ⇒ FAIL "respells the inspector frame".
/// Separately restored `struct TranscriptParser` under Sources/ ⇒ FAIL "a Swift inspector producer
/// is back". Separately restored `struct ToolCard` under Sources/ ⇒ FAIL "event taxonomy is back in
/// Swift". All four restored from /tmp; PASS.
#[must_use]
pub fn the_inspector_frame_has_one_spelling(tree: &Tree) -> Report {
    /// The seven entries with a caller on both sides.
    const SHARED: &[&str] = &[
        "slopdesk_inspector_encode_subscribe",
        "slopdesk_inspector_decode_payload",
        "slopdesk_inspector_constant",
        "slopdesk_inspector_decoder_new",
        "slopdesk_inspector_decoder_free",
        "slopdesk_inspector_decoder_append",
        "slopdesk_inspector_decoder_next",
    ];
    check_all(tree, &[
        Claim::Mentions {
            path: INSPECTOR_FFI,
            names: SHARED,
            message: "rust/slopdesk-ffi/src/inspector.rs no longer exports {entry} — the inspector's client \
                      door has moved (docs/55)",
        },
        Claim::Lacks {
            path: INSPECTOR_FFI,
            pattern: "slopdesk_inspector_decoder_buffered",
            view: View::Statements,
            message: "rust/slopdesk-ffi/src/inspector.rs exports slopdesk_inspector_decoder_buffered again \
                      — a door no Swift caller opens, and Swift sizes its body buffer from the AGAIN \
                      verdict instead (docs/55)",
        },
        Claim::Mentions {
            path: INSPECTOR_FACE,
            names: SHARED,
            message: "Sources/SlopDeskInspector/InspectorWire.swift stopped calling {entry} — the frame is \
                      inspectord's (docs/54, docs/55)",
        },
        Claim::Lacks {
            path: INSPECTOR_FACE,
            pattern: r"appendBE|readPrefix|readBESeq|struct ByteReader|16 \* 1024 \* 1024|UInt8 = [0-9]",
            view: View::Code,
            message: "InspectorWire.swift respells the inspector frame — read slopdesk_inspector_constant \
                      instead, because a length prefix read by hand is the second implementation growing \
                      back one line at a time (docs/54)",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor|protocol) (TranscriptParser|TranscriptTailer|TranscriptLine|LineAccumulator|SubagentWatcher|EventBuilder|InspectorEngine|InspectorReplayLog|InspectorSource|InspectorServer)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift inspector producer is back in Swift — inspectord owns the fold, and \
                      `InspectorSource` is named here because it was the HOST end of the wire \
                      (`InspectorClient` and `InspectorViewModel` are the far end, which is allowed) \
                      (docs/54): {files}",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor|protocol) (InspectorEvent|ToolCard|TodoItem|SubagentNode|MessageEvent|ThinkingMarker|WorkflowMarker|SessionInfo|PendingToolSummary|InspectorStoreRules)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the inspector's event taxonomy is back in Swift — it is declared ONCE, in \
                      `slopdesk_inspectord::event`, and `slopdesk_inspectord::store` is the only thing that \
                      decodes it. A second declaration here is not a two-ENDS document: both ends would \
                      deserialise the SAME body, and this side's `JSONDecoder` flattened every integer to a \
                      `Double` doing it. The bodies cross unread; ask a door for what a surface renders \
                      (docs/66): {files}",
        },
    ])
}

/// The inspector's three tags and its ceiling are one alphabet
///
/// `1` and `2` are what the daemon writes and the client end reads; `3` is what the client writes
/// and the daemon reads — and the client end must REFUSE it, since seeing one arrive means the
/// daemon echoed the client's own control back. That is why the decode arms are pinned as well as
/// the constants: a `decode_client` that accepted tag 3 would not fail anything, it would just
/// render the client's own subscribe as an event.
///
/// The cap is the other half. A daemon whose ceiling is LOWER refuses a large replay frame it just
/// built; a HIGHER one has the client throw `frameTooLarge`, which is the ONE unrecoverable decode
/// error on this wire, because a length prefix read past its end is framing desync.
///
/// BREAK-TEST: renumbered `TAG_SUBSCRIBE` to 4 ⇒ FAIL "no longer spells the client's subscribe tag
/// as 3". Separately halved the frame cap ⇒ FAIL "not the 16 MiB ceiling". Both restored from /tmp;
/// PASS.
#[must_use]
pub fn the_inspector_tags_are_one_alphabet(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_EVENT: u8 = 1;",
            view: View::Statements,
            message: "rust/slopdesk-inspectord/src/wire.rs no longer writes tag 1 for an event — an unknown \
                      tag is SKIPPED at both ends, so nothing errors and the panel just stays empty \
                      (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_KEEP_ALIVE: u8 = 2;",
            view: View::Statements,
            message: "rust/slopdesk-inspectord/src/wire.rs no longer writes tag 2 for a keep-alive — an \
                      unknown tag is SKIPPED at both ends, so nothing errors and the feed just stops \
                      (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_SUBSCRIBE: u8 = 3;",
            view: View::Statements,
            message: "rust/slopdesk-inspectord/src/wire.rs no longer spells the client's subscribe tag as 3 \
                      (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_EVENT => Ok\(ClientFrame::Event",
            view: View::Statements,
            message: "wire.rs's decode_client no longer reads tag 1 as an event — the client end must \
                      decode exactly the two host → client tags and refuse its own (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_KEEP_ALIVE => Ok\(ClientFrame::KeepAlive\)",
            view: View::Statements,
            message: "wire.rs's decode_client no longer reads tag 2 as a keep-alive — the client end must \
                      decode exactly the two host → client tags and refuse its own (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"MAX_FRAME_PAYLOAD: usize = 16 \* 1024 \* 1024;",
            view: View::Statements,
            message: "the inspector's frame cap is not the 16 MiB ceiling the other four paths use — a \
                      LOWER cap refuses a large replay frame the daemon just built, a HIGHER one has the \
                      client throw frameTooLarge, which is the one unrecoverable decode error (docs/54)",
        },
    ])
}

/// Every announce line is one string, and it names the build that is running
///
/// dropd, inspectord and androidd OUTLIVE hostd — hostd re-learns their port by replaying superd's
/// ring from offset 0 (`docs/51` §6.7), which is what the marker half of this rule is about. Reword
/// a marker on one side and hostd waits out its timeout, kills a perfectly healthy service and
/// respawns it on every restart; for androidd, whose port is ephemeral, the panel reports
/// `starting` forever instead.
///
/// HALF of this rule retired in `docs/60` F.9 rather than moving. It compared a Swift manager's
/// `announceMarker` literal against the daemon's `ANNOUNCE_PREFIX`, and a second literal in
/// `SupervisedServiceLifecycle.swift` against its `ANNOUNCE_VERSION_PREFIX`. hostd is Rust now and
/// IMPORTS both constants from the crate that prints the line, so the import IS the equality and
/// the compiler is what enforces it — a rename lands on both sides or neither.
///
/// What no compiler can see is the two halves left here. First, that hostd still ASKS the printing
/// crate rather than reacquiring a literal beside it: a `"dropd: listening on 0.0.0.0:"` typed into
/// a host crate compiles, passes every test, and reintroduces exactly the drift the import removed.
/// Second, that the line still carries a version AT ALL — `server.rs` compiles perfectly with the
/// parenthetical dropped out of its format string.
///
/// The VERSION of the build that is running rides that line, first in the parenthetical, because it
/// is the only channel that describes a child this hostd did not start (`docs/49`). A skew here is
/// the quietest failure in the file — hostd's parser finds no marker, reports `unknown`, and goes
/// on running last week's daemon behind this week's version number: green tests, working panel,
/// wrong code.
///
/// Each daemon announces its OWN compile-time version, never a number read back off disk. A daemon
/// that reported the installed version would compare equal to it forever, which is the failure
/// inverted — so `env!("CARGO_PKG_VERSION")` is pinned beside the marker.
///
/// BREAK-TEST: dropped `slopdesk_dropd::server::ANNOUNCE_PREFIX` from hostd's profile ⇒ FAIL "no
/// longer learns dropd's announce marker from the crate that prints it". Separately changed
/// androidd's version marker to `"v"` in hostd ⇒ FAIL "no longer reads androidd's version marker".
/// Separately wrote the marker as a literal into a host crate ⇒ FAIL "spells a sidecar's announce
/// marker as a literal". All three restored from /tmp; PASS.
#[must_use]
pub fn every_announce_line_is_one_string(tree: &Tree) -> Report {
    let mut report = Report::new();
    report.absorb(check_all(tree, &[Claim::NoneUnder {
        roots: HOSTD_CRATES,
        extensions: RUST,
        pattern: r#""(dropd|androidd|inspectord): listening on"#,
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "{files} spells a sidecar's announce marker as a literal — the crate that PRINTS the line \
                  owns the spelling, and a copy kept equal to it by hand is the drift linking the crate \
                  removed (docs/49, docs/51 §6.7)",
    }]));
    for (parser, server, daemon) in [
        (HOSTD_SIDECARS, DROP_SERVER, "dropd"),
        (HOSTD_SERVICES, ANDROID_SERVER, "androidd"),
        (HOSTD_SIDECARS, INSPECTOR_SERVER, "inspectord"),
    ] {
        report.absorb(check_all(tree, &[
            Claim::Matches {
                path: parser,
                pattern: text::intern(format!("slopdesk_{daemon}::server::ANNOUNCE_PREFIX")),
                view: View::Statements,
                message: text::intern(format!(
                    "{parser} no longer learns {daemon}'s announce marker from the crate that prints it — \
                     hostd would wait out its timeout, kill a healthy service and respawn it on every \
                     restart (docs/51 §6.7)"
                )),
            },
            Claim::Matches {
                path: parser,
                pattern: text::intern(format!("slopdesk_{daemon}::server::ANNOUNCE_VERSION_PREFIX")),
                view: View::Statements,
                message: text::intern(format!(
                    "{parser} no longer reads {daemon}'s version marker off the crate that prints it — a \
                     parse that stopped matching reads None, which the audit reports as 'unknown' rather \
                     than failing, so it is asserted here or nowhere (docs/49)"
                )),
            },
            Claim::Matches {
                path: server,
                pattern: r"ANNOUNCE_VERSION_PREFIX\}\{\}",
                view: View::Statements,
                message: text::intern(format!(
                    "rust/slopdesk-{daemon}/src/server.rs no longer announces a version after the marker — \
                     hostd would report `unknown` and go on running last week's daemon behind this week's \
                     number (docs/49)"
                )),
            },
            Claim::Matches {
                path: server,
                pattern: r#"env!\("CARGO_PKG_VERSION"\)"#,
                view: View::Statements,
                message: text::intern(format!(
                    "rust/slopdesk-{daemon}/src/server.rs no longer announces its OWN compile-time version \
                     — a daemon reporting the version it read off disk compares equal to it forever, which \
                     is the failure inverted (docs/49)"
                )),
            },
        ]));
    }
    report
}

/// The per-sidecar version policy is one table, in Rust
///
/// What may be DONE about a stale sidecar has two callers in two BINARIES: hostd's startup audit
/// and `slopdesk sidecars`, over two `MANIFEST.json` files. `docs/60` F.9 made both of them Rust,
/// which took the FFI doors and the Swift decode with it — but not the rule, because nothing links
/// hostd to the CLI. Two copies of the table would still disagree about screend the first time
/// somebody changed its idle-exit and updated one of them, and every suite would stay green.
///
/// So the table lives in `rust/slopdesk-sidecars` and both callers ask it. A `match` over tool
/// names on the near side is the second implementation, and an arm added there alone answers
/// `OperatorChoice` — "your call" about a daemon that should have been restarted.
///
/// The ban reads a match ARM rather than the names themselves, because `audit.rs` spells every one
/// of the five as DATA — the `tool` field of a subject, the key `MANIFEST.json` is read by — and a
/// ban on the names would fire on the table's own callers.
///
/// The install side must keep BOTH halves: the plan it prints, and the record that makes the NEXT
/// plan about one tool rather than all twelve. A formula whose `post_install` stopped recording
/// leaves every upgrade reading as a first install, which is a table that never says anything.
/// Ruby has no compiler either, which is why it is asserted here.
///
/// BREAK-TEST: renamed `SelfRetiring` in the crate ⇒ FAIL "no longer names". Separately wrote
/// `"slopdesk-dropd" => RestartPolicy::Automatic,` into the audit ⇒ FAIL "decides about a tool by
/// NAME again". Separately dropped `--record` from the formula ⇒ FAIL "no longer records the
/// manifest". All three restored from /tmp; PASS.
#[must_use]
pub fn the_sidecar_version_policy_is_one_table(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::PinnedSet {
            label: "sidecar restart policies",
            from: Extract::statements(
                SIDECARS,
                r"^    (Automatic|SelfRetiring|OperatorChoice|NotResident),$",
            ),
            expect: &["Automatic", "NotResident", "OperatorChoice", "SelfRetiring"],
        },
        Claim::Matches {
            path: SIDECARS,
            pattern: r"pub fn policy\(tool: &str\) -> RestartPolicy",
            view: View::Statements,
            message: "rust/slopdesk-sidecars no longer holds the policy table — it has two callers in two \
                      languages, which is the exact shape a Swift copy skews quietly in (docs/49)",
        },
        Claim::Matches {
            path: SIDECARS_MANIFEST,
            pattern: r"pub fn plan\(",
            view: View::Statements,
            message: "rust/slopdesk-sidecars/src/manifest.rs no longer holds the manifest diff (docs/49)",
        },
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r#""slopdesk-[a-z]+" *=>"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} decides about a tool by NAME again — the table is rust/slopdesk-sidecars, and \
                      an arm added here alone answers OperatorChoice and reports 'your call' about a daemon \
                      that should have been restarted (docs/49)",
        },
        Claim::Matches {
            path: HOSTD_AUDIT,
            pattern: r"use slopdesk_sidecars::",
            view: View::Statements,
            message: "rust/slopdesk-hostd/src/audit.rs no longer asks rust/slopdesk-sidecars for its \
                      verdict — it would be a second table, in the one binary that acts on it (docs/49)",
        },
        Claim::Matches {
            path: SIDECAR_CLI,
            pattern: r"slopdesk_sidecars::manifest::plan|manifest::plan\b|use slopdesk_sidecars",
            view: View::Statements,
            message: "`slopdesk sidecars` no longer asks rust/slopdesk-sidecars for the upgrade plan — it \
                      would be a second diff of the same two manifests (docs/49)",
        },
        Claim::Matches {
            path: HOMEBREW_FORMULA,
            pattern: r#"sidecars", "--record""#,
            view: View::Statements,
            message: "the formula no longer records the manifest — every upgrade would read as a first \
                      install, which is a table that never says anything (docs/49)",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The face over the bridge's doors: the socket, and the ack/stream split, and nothing else.
    /// A fixture path only — every claim that used to name it now covers the whole directory.
    const ANDROID_FACE: &str = "Sources/SlopDeskDevicePanels/Android/AndroidBridgeSocket.swift";

    /// A tree where all five rules pass, so a case can break exactly one thing.
    fn wires(fixture: &Fixture) {
        for (path, body) in [
            (super::DROP_FFI, DOOR_SHIM),
            (super::DROP_CLIENT, DROP_CLIENT_BODY),
            (super::DROP_PROTOCOL, DROP_PROTOCOL_BODY),
            (super::ANDROID_PROTOCOL, ANDROID_PROTOCOL_BODY),
            (super::INSPECTOR_FFI, INSPECTOR_SHIM),
            (super::INSPECTOR_WIRE, INSPECTOR_WIRE_BODY),
            (super::INSPECTOR_FACE, INSPECTOR_FACE_BODY),
            ("Sources/SlopDeskFileTransfer/FileTransferClient.swift", DROP_FACE),
            (super::ANDROID_HEADER, ANDROID_HEADER_BODY),
            (super::ANDROID_BRIDGE, ANDROID_BRIDGE_BODY),
            (ANDROID_FACE, ANDROID_FACE_BODY),
            (
                "Sources/SlopDeskDevicePanels/Android/AndroidBridgeClient.swift",
                "let a = slopdesk_android_bridge_console_output(b, n)\nlet c = \
                 slopdesk_android_bridge_screenshot_bytes(b, n)\nlet d = \
                 slopdesk_android_bridge_refusals(out, cap)\n",
            ),
            (
                "Sources/SlopDeskDevicePanels/Android/AndroidLogConnection.swift",
                "let h = slopdesk_android_log_lines_new()\nslopdesk_android_log_lines_free(h)\nlet n = \
                 slopdesk_android_log_lines_push(h, b, n)\nlet m = slopdesk_android_log_lines_answer(h, o, \
                 c)\n",
            ),
            (
                super::ANDROID_DEVICE,
                "struct AndroidDevice {\n    static func decodeList(_ data: Data) -> [Self]? {\n        \
                 slopdesk_android_device_list(bytes, count, out, cap)\n    }\n}\n",
            ),
        ] {
            fixture.write(path, body);
        }
        for (path, prefix) in [
            (super::DROP_SERVER, DROP_LINE),
            (super::INSPECTOR_SERVER, INSPECTOR_LINE),
        ] {
            fixture.write(path, &announcing(prefix));
        }
        fixture.write(super::ANDROID_SERVER, &android_server());
        fixture.write(super::HOSTD_SIDECARS, &parsing(&["dropd", "inspectord"]));
        fixture.write(super::HOSTD_SERVICES, &parsing(&["androidd"]));
    }

    /// The three announce prefixes, each spelled once here and read from both ends.
    const DROP_LINE: &str = "dropd: listening on 0.0.0.0:";
    const ANDROID_LINE: &str = "androidd: listening on 0.0.0.0:";
    const INSPECTOR_LINE: &str = "inspectord: listening on 0.0.0.0:";

    /// The one dropd door, as the shim and as the face that calls it.
    const DOOR_SHIM: &str = "pub extern \"C\" fn slopdesk_drop_upload() {}\n";
    const DROP_FACE: &str = "let n = slopdesk_drop_upload(h, l, p, b, c, t, x, f)\n";

    /// Five request bytes across the two writers, four reply arms.
    const DROP_CLIENT_BODY: &str = "fn write_chunk_payload(kind: &mut u8) {\n    *kind = 3;\n}\n\
                                    pub fn encode_request_payload(out: &mut Vec<u8>) {\n    \
                                    out.push(1);\n    out.push(2);\n    out.push(4);\n    \
                                    out.push(5);\n}\n\
                                    pub fn decode_reply_payload(tag: u8) {\n    match tag {\n        \
                                    6 => {\n        }\n        7 => {\n        }\n        8 => {\n        \
                                    }\n        9 => {\n        }\n    }\n}\n";
    const DROP_PROTOCOL_BODY: &str = "pub const VERSION: u8 = 1;\n\
                                      pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;\n\
                                      pub fn decode_request(tag: u8) {\n    match tag {\n        \
                                      1 => {\n        }\n        2 => {\n        }\n        3 => {\n        \
                                      }\n        4 => {\n        }\n        5 => {\n        }\n    }\n}\n\
                                      pub fn encode_reply_payload(out: &mut Vec<u8>) {\n    \
                                      out.push(6);\n    out.push(7);\n    out.push(8);\n    \
                                      out.push(9);\n}\n";

    const ANDROID_PROTOCOL_BODY: &str =
        "pub fn encode(d: &Device) -> String {\n    json!({\"serial\": d.serial, \"model\": d.model})\n}\n";

    /// The hand-written header's op block: seven names, seven bytes.
    const ANDROID_HEADER_BODY: &str =
        "#define SLOPDESK_ANDROID_BRIDGE_OP_LIST 0u\n#define SLOPDESK_ANDROID_BRIDGE_OP_BOOT 1u\n#define \
         SLOPDESK_ANDROID_BRIDGE_OP_SHUTDOWN 2u\n#define SLOPDESK_ANDROID_BRIDGE_OP_CONSOLE 3u\n#define \
         SLOPDESK_ANDROID_BRIDGE_OP_SCREENSHOT 4u\n#define SLOPDESK_ANDROID_BRIDGE_OP_LOGCAT 5u\n#define \
         SLOPDESK_ANDROID_BRIDGE_OP_OPEN 6u\n";

    /// The panel crate's half: the enum the header numbers, and the verbs the daemon matches.
    const ANDROID_BRIDGE_BODY: &str =
        "#[repr(u8)]\npub enum BridgeOp {\n    List = 0,\n    Boot = 1,\n    Shutdown = 2,\n    Console = \
         3,\n    Screenshot = 4,\n    Logcat = 5,\n    Open = 6,\n}\nimpl BridgeOp {\n    pub const fn \
         verb(self) -> &'static str {\n        match self {\n            Self::List => \"list\",\n           \
         Self::Boot => \"boot\",\n            Self::Shutdown => \"shutdown\",\n            Self::Console => \
         \"console\",\n            Self::Screenshot => \"screenshot\",\n            Self::Logcat => \
         \"logcat\",\n            Self::Open => \"open\",\n        }\n    }\n}\nfn decode_device(entry: \
         &Value) -> Option<Device> {\n    let key = entry.get(\"serial\")?;\n    Some(Device { model: \
         optional_text(entry, \"model\") })\n}\n";

    /// The face: the seven op names, and the two doors it calls.
    const ANDROID_FACE_BODY: &str =
        "let a = slopdesk_android_bridge_request(SLOPDESK_ANDROID_BRIDGE_OP_LIST)\nlet b = \
         slopdesk_android_bridge_request(SLOPDESK_ANDROID_BRIDGE_OP_BOOT)\nlet c = \
         slopdesk_android_bridge_request(SLOPDESK_ANDROID_BRIDGE_OP_SHUTDOWN)\nlet d = \
         slopdesk_android_bridge_request(SLOPDESK_ANDROID_BRIDGE_OP_CONSOLE)\nlet e = \
         slopdesk_android_bridge_request(SLOPDESK_ANDROID_BRIDGE_OP_SCREENSHOT)\nlet f = \
         slopdesk_android_bridge_request(SLOPDESK_ANDROID_BRIDGE_OP_LOGCAT)\nlet g = \
         slopdesk_android_bridge_request(SLOPDESK_ANDROID_BRIDGE_OP_OPEN)\nlet h = \
         slopdesk_android_bridge_reply_failure(line, n)\n";

    const INSPECTOR_SHIM: &str =
        "pub extern \"C\" fn slopdesk_inspector_encode_subscribe() {}\npub extern \"C\" fn \
         slopdesk_inspector_decode_payload() {}\npub extern \"C\" fn slopdesk_inspector_constant() {}\npub \
         extern \"C\" fn slopdesk_inspector_decoder_new() {}\npub extern \"C\" fn \
         slopdesk_inspector_decoder_free() {}\npub extern \"C\" fn slopdesk_inspector_decoder_append() \
         {}\npub extern \"C\" fn slopdesk_inspector_decoder_next() {}\n";
    const INSPECTOR_FACE_BODY: &str =
        "let a = slopdesk_inspector_encode_subscribe()\nlet b = slopdesk_inspector_decode_payload()\nlet c \
         = slopdesk_inspector_constant(0)\nlet d = slopdesk_inspector_decoder_new()\nlet e = \
         slopdesk_inspector_decoder_free(d)\nlet f = slopdesk_inspector_decoder_append(d)\nlet g = \
         slopdesk_inspector_decoder_next(d)\n";
    const INSPECTOR_WIRE_BODY: &str =
        "pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;\nconst TAG_EVENT: u8 = 1;\nconst \
         TAG_KEEP_ALIVE: u8 = 2;\nconst TAG_SUBSCRIBE: u8 = 3;\npub fn decode_client(tag: u8) -> \
         Result<ClientFrame> {\n    match tag {\n        TAG_EVENT => Ok(ClientFrame::Event(0..1)),\n        \
         TAG_KEEP_ALIVE => Ok(ClientFrame::KeepAlive),\n        _ => Err(()),\n    }\n}\n";

    /// A daemon's announce line, marker and compile-time version both.
    fn announcing(prefix: &str) -> String {
        format!(
            "pub const ANNOUNCE_PREFIX: &str = \"{prefix}\";\npub const ANNOUNCE_VERSION_PREFIX: &str = \
             \"(v\";\nfn announce(port: u16) {{\n    println!(\n        \"{{ANNOUNCE_PREFIX}}{{port}} \
             {{ANNOUNCE_VERSION_PREFIX}}{{}})\",\n        env!(\"CARGO_PKG_VERSION\"),\n    );\n}}\n"
        )
    }

    /// androidd's listener: the announce line, then the seven arms the panel's ops need.
    fn android_server() -> String {
        format!(
            "{}pub fn serve(op: &str) {{\n    match op {{\n        \"list\" => a(),\n        \"boot\" => \
             b(),\n        \"shutdown\" => c(),\n        \"console\" => d(),\n        \"screenshot\" => \
             e(),\n        \"logcat\" => f(),\n        \"open\" => g(),\n        _ => bad(),\n    }}\n}}\n",
            announcing(ANDROID_LINE)
        )
    }

    /// hostd's side of each announce line: the port and the version, both read off the constants
    /// the printing crate owns rather than off a literal typed beside them.
    fn parsing(daemons: &[&str]) -> String {
        daemons.iter().fold(String::new(), |mut body, daemon| {
            use std::fmt::Write as _;
            let _ = write!(
                body,
                "fn parse_{daemon}_port(line: &str) -> Option<u16> {{\n    \
                 port_directly_after(slopdesk_{daemon}::server::ANNOUNCE_PREFIX, line)\n}}\nfn \
                 parse_{daemon}_version(line: &str) -> Option<&str> {{\n    announced_version(\n     \
                 slopdesk_{daemon}::server::ANNOUNCE_PREFIX,\n        \
                 slopdesk_{daemon}::server::ANNOUNCE_VERSION_PREFIX,\n        line,\n    )\n}}\n"
            );
            body
        })
    }

    #[test]
    fn a_hand_rolled_byte_reader_in_the_face_is_red() {
        let fixture = Fixture::new("drop-reader");
        wires(&fixture);
        assert!(super::the_drop_client_holds_no_layout(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskFileTransfer/ByteReader.swift",
            "struct ByteReader {\n    var offset = 0\n}\n",
        );
        let report = super::the_drop_client_holds_no_layout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("a byte reader/writer is back")),
            "{report:?}"
        );
    }

    #[test]
    fn a_swift_receiving_end_is_red() {
        let fixture = Fixture::new("drop-receiver");
        wires(&fixture);
        assert!(super::the_drop_client_holds_no_layout(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskFileTransfer/FileTransferServer.swift",
            "final class FileTransferServer {\n    func serve() {}\n}\n",
        );
        let report = super::the_drop_client_holds_no_layout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("a Swift file-drop receiver is back")),
            "{report:?}"
        );
    }

    /// The chunk writer's byte is the one a match-only sweep would silently stop covering.
    #[test]
    fn a_request_byte_with_no_arm_is_red_in_both_spellings() {
        let fixture = Fixture::new("drop-types");
        wires(&fixture);
        assert!(super::the_drop_type_bytes_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::DROP_CLIENT,
            &DROP_CLIENT_BODY.replace("*kind = 3;", "*kind = 7;"),
        );
        let report = super::the_drop_type_bytes_are_one_alphabet(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("request type 7")),
            "{report:?}"
        );
    }

    #[test]
    fn a_reply_byte_the_client_cannot_decode_is_red() {
        let fixture = Fixture::new("drop-replies");
        wires(&fixture);
        fixture.write(
            super::DROP_PROTOCOL,
            &DROP_PROTOCOL_BODY.replace("out.push(9);", "out.push(10);"),
        );
        let report = super::the_drop_type_bytes_are_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("dropd reply type bytes")),
            "{report:?}"
        );
    }

    /// The sender is the panel CRATE now: a verb it writes that no arm serves.
    #[test]
    fn an_op_no_arm_serves_is_red() {
        let fixture = Fixture::new("android-ops");
        wires(&fixture);
        assert!(super::the_android_bridge_agrees_both_ways(&fixture.tree()).is_clean());

        fixture.write(
            super::ANDROID_BRIDGE,
            &ANDROID_BRIDGE_BODY.replace("Self::Logcat => \"logcat\"", "Self::Logcat => \"tail\""),
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("op 'tail'")),
            "{report:?}"
        );
    }

    /// The staleness guard the one-file subject needs: an arm that stopped matching reads as a
    /// SHORTER set, which a subset alone would accept.
    #[test]
    fn a_verb_arm_that_stopped_matching_is_red() {
        let fixture = Fixture::new("android-verbs");
        wires(&fixture);
        fixture.write(
            super::ANDROID_BRIDGE,
            &ANDROID_BRIDGE_BODY.replace("            Self::Open => \"open\",\n", ""),
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("bridge op verbs")),
            "{report:?}"
        );
    }

    /// The state the live tree was found in: the face stops naming the ops and the corpus reads
    /// nought, which a subset reports as agreement.
    #[test]
    fn a_face_that_stopped_naming_the_ops_is_red() {
        let fixture = Fixture::new("android-face-ops");
        wires(&fixture);
        fixture.write(
            ANDROID_FACE,
            "let a = slopdesk_android_bridge_request(op)\nlet h = \
             slopdesk_android_bridge_reply_failure(line, n)\n",
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("floor 7")),
            "{report:?}"
        );
    }

    /// The header is hand-written, so its bytes are a second spelling of the enum's discriminants.
    #[test]
    fn a_header_byte_that_disagrees_with_the_enum_is_red() {
        let fixture = Fixture::new("android-bytes");
        wires(&fixture);
        fixture.write(
            super::ANDROID_HEADER,
            &ANDROID_HEADER_BODY.replace("SCREENSHOT 4u", "SCREENSHOT 7u"),
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("BridgeOp")),
            "{report:?}"
        );
    }

    /// The old comparison's subject is the new ban: a connection that writes its own request line.
    #[test]
    fn a_hand_written_op_line_in_the_panel_is_red() {
        let fixture = Fixture::new("android-op-literal");
        wires(&fixture);
        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidStreamConnection.swift",
            "let a = [\"op\": \"tail\", \"serial\": s]\n",
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("builds a bridge request by hand")),
            "{report:?}"
        );
    }

    /// The splitter's four doors live in the log connection, not the face — the root is the target.
    #[test]
    fn a_face_that_stopped_calling_a_door_is_red() {
        let fixture = Fixture::new("android-doors");
        wires(&fixture);
        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidLogConnection.swift",
            "let h = slopdesk_android_log_lines_new()\nslopdesk_android_log_lines_free(h)\nlet m = \
             slopdesk_android_log_lines_answer(h, o, c)\n",
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_android_log_lines_push")),
            "{report:?}"
        );
    }

    /// The encoder that raised rather than threw, growing back anywhere under the panel. The ban is
    /// directory-wide now that the reply decode has descended, so the face is only where it is
    /// likeliest rather than where it is uniquely forbidden.
    #[test]
    fn a_json_encoder_back_in_the_face_is_red() {
        let fixture = Fixture::new("android-json");
        wires(&fixture);
        fixture.append(
            ANDROID_FACE,
            "let line = try? JSONSerialization.data(withJSONObject: request)\n",
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("respells the bridge grammar")),
            "{report:?}"
        );
    }

    /// The name ban still fires — and `AndroidBridgeRequest`, which left it, is clean beside it.
    #[test]
    fn a_swift_bridge_restored_under_sources_is_red() {
        let fixture = Fixture::new("android-ban");
        wires(&fixture);
        fixture.append(ANDROID_FACE, "package enum AndroidBridgeRequest {}\n");
        assert!(super::the_android_bridge_agrees_both_ways(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidToolchain.swift",
            "final class AndroidToolchain {}\n",
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("a Swift Android bridge is back")),
            "{report:?}"
        );
    }

    #[test]
    fn a_device_field_the_daemon_stopped_encoding_is_red() {
        let fixture = Fixture::new("android-fields");
        wires(&fixture);
        fixture.write(
            super::ANDROID_PROTOCOL,
            "pub fn encode(d: &Device) -> String {\n    json!({\"serial\": d.serial})\n}\n",
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("field 'model'")),
            "{report:?}"
        );
    }

    /// The exemption that is gone: a Swift row type that starts reading the reply's keys again.
    #[test]
    fn a_reply_decode_back_in_the_device_row_is_red() {
        let fixture = Fixture::new("android-device-decode");
        wires(&fixture);
        fixture.append(super::ANDROID_DEVICE, "let s = entry[\"serial\"] as? String\n");
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("decodes the bridge reply in Swift again")),
            "{report:?}"
        );
    }

    /// And the other direction: the row stops asking the door at all, which is the shape a
    /// rewritten decode would leave behind after the ban above was worked around.
    #[test]
    fn a_device_row_that_stopped_asking_the_door_is_red() {
        let fixture = Fixture::new("android-device-door");
        wires(&fixture);
        fixture.write(super::ANDROID_DEVICE, "struct AndroidDevice {}\n");
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_android_device_list")),
            "{report:?}"
        );
    }

    #[test]
    fn a_renumbered_subscribe_tag_is_red() {
        let fixture = Fixture::new("inspector-tags");
        wires(&fixture);
        assert!(super::the_inspector_tags_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::INSPECTOR_WIRE,
            &INSPECTOR_WIRE_BODY.replace("TAG_SUBSCRIBE: u8 = 3;", "TAG_SUBSCRIBE: u8 = 4;"),
        );
        let report = super::the_inspector_tags_are_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("subscribe tag as 3")),
            "{report:?}"
        );
    }

    /// The door with no Swift caller stays DELETED, and a tombstone naming it is not a revival.
    ///
    /// The claim ran the other way round until 2026-08-30 — it demanded the door be present, and
    /// the deletion satisfied it by leaving a comment that spelled the name. Both halves are pinned
    /// here now: the comment is green, the declaration is red.
    #[test]
    fn the_buffered_door_stays_deleted_and_its_tombstone_is_not_a_revival() {
        let fixture = Fixture::new("inspector-buffered");
        wires(&fixture);
        assert!(super::the_inspector_frame_has_one_spelling(&fixture.tree()).is_clean());

        fixture.write(
            super::INSPECTOR_FFI,
            &format!(
                "// There is no slopdesk_inspector_decoder_buffered: Swift sizes its body buffer from the \
                 AGAIN verdict.\n{INSPECTOR_SHIM}"
            ),
        );
        assert!(
            super::the_inspector_frame_has_one_spelling(&fixture.tree()).is_clean(),
            "the tombstone must be free to say the name"
        );

        fixture.write(
            super::INSPECTOR_FFI,
            &format!("{INSPECTOR_SHIM}pub extern \"C\" fn slopdesk_inspector_decoder_buffered() {{}}\n"),
        );
        let report = super::the_inspector_frame_has_one_spelling(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_inspector_decoder_buffered")),
            "{report:?}"
        );
    }

    /// A second declaration of the event taxonomy is the failure that goes green: both ends decode,
    /// both compile, and the two answers differ only where a `Double` cannot hold an integer.
    #[test]
    fn the_event_taxonomy_redeclared_in_swift_is_red() {
        let fixture = Fixture::new("inspector-taxonomy");
        wires(&fixture);
        assert!(super::the_inspector_frame_has_one_spelling(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskInspector/InspectorEvent.swift",
            "public struct ToolCard: Codable {\n    public let id: String\n}\n",
        );
        let report = super::the_inspector_frame_has_one_spelling(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("event taxonomy is back in Swift")),
            "{report:?}"
        );
    }

    /// hostd reacquiring the marker: the literal compiles, every test stays green, and the copy is
    /// kept equal to `server.rs` by hand — which is the drift linking the crate removed.
    #[test]
    fn a_marker_respelled_as_a_literal_in_a_host_crate_is_red() {
        let fixture = Fixture::new("announce-literal");
        wires(&fixture);
        assert!(super::every_announce_line_is_one_string(&fixture.tree()).is_clean());

        fixture.append(
            super::HOSTD_SERVICES,
            "const MARKER: &str = \"androidd: listening on 0.0.0.0:\";\n",
        );
        let report = super::every_announce_line_is_one_string(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("announce marker as a literal")),
            "{report:?}"
        );
    }

    /// The other direction: hostd stops asking the printing crate at all.
    #[test]
    fn a_parser_that_stopped_asking_the_printing_crate_is_red() {
        let fixture = Fixture::new("announce-marker");
        wires(&fixture);
        fixture.write(
            super::HOSTD_SIDECARS,
            &parsing(&["dropd", "inspectord"])
                .replace("slopdesk_dropd::server::ANNOUNCE_PREFIX", "\"dropd: bound to \""),
        );
        let report = super::every_announce_line_is_one_string(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer learns dropd's announce marker")),
            "{report:?}"
        );
    }

    /// A daemon reporting the version it read off disk compares equal to it forever.
    #[test]
    fn a_daemon_that_does_not_announce_its_own_version_is_red() {
        let fixture = Fixture::new("announce-version");
        wires(&fixture);
        fixture.write(
            super::DROP_SERVER,
            &announcing(DROP_LINE).replace("env!(\"CARGO_PKG_VERSION\")", "installed_version()"),
        );
        let report = super::every_announce_line_is_one_string(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer announces its OWN")),
            "{report:?}"
        );
    }

    /// A parse that stopped matching reads `None`, which the audit reports as 'unknown' rather than
    /// failing — so the version half is asserted here or nowhere.
    #[test]
    fn a_parser_that_stopped_reading_the_version_marker_is_red() {
        let fixture = Fixture::new("announce-reader");
        wires(&fixture);
        fixture.write(
            super::HOSTD_SIDECARS,
            &parsing(&["dropd", "inspectord"])
                .replace("slopdesk_inspectord::server::ANNOUNCE_VERSION_PREFIX", "\"v\""),
        );
        let report = super::every_announce_line_is_one_string(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer reads inspectord's version marker")),
            "{report:?}"
        );
    }

    /// The whole point of the table: a decision made by tool NAME on the near side.
    #[test]
    fn a_match_over_tool_names_is_red() {
        let fixture = Fixture::new("sidecar-policy");
        policy(&fixture, AUDIT_CALLER);
        assert!(super::the_sidecar_version_policy_is_one_table(&fixture.tree()).is_clean());

        fixture.append(
            super::HOSTD_AUDIT,
            "fn verdict(tool: &str) -> RestartPolicy {\n    match tool {\n        \"slopdesk-dropd\" => \
             RestartPolicy::Automatic,\n        _ => slopdesk_sidecars::policy(tool),\n    }\n}\n",
        );
        let report = super::the_sidecar_version_policy_is_one_table(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("decides about a tool by NAME")),
            "{report:?}"
        );
    }

    /// The names alone must NOT fire: the audit spells all five as data — the `tool` field of a
    /// subject, the key `MANIFEST.json` is read by — and a ban on the names would fire on the
    /// table's own callers.
    #[test]
    fn the_audits_own_subjects_are_not_caught() {
        let fixture = Fixture::new("sidecar-subjects");
        policy(&fixture, AUDIT_CALLER);
        fixture.append(
            super::HOSTD_AUDIT,
            "let subjects = [Subject { tool: \"slopdesk-superd\" }, Subject { tool: \"slopdesk-dropd\" }];\n",
        );
        assert!(super::the_sidecar_version_policy_is_one_table(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_formula_that_stopped_recording_is_red() {
        let fixture = Fixture::new("sidecar-record");
        policy(&fixture, AUDIT_CALLER);
        fixture.write(
            super::HOMEBREW_FORMULA,
            "class Slopdesk < Formula\n  def post_install\n    system bin/\"slopdesk\", \"sidecars\"\n  \
             end\nend\n",
        );
        let report = super::the_sidecar_version_policy_is_one_table(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer records the manifest")),
            "{report:?}"
        );
    }

    const AUDIT_CALLER: &str = "use slopdesk_sidecars::{Report, parse_version_banner};\nfn verdict(tool: \
                                &str) -> RestartPolicy {\n    slopdesk_sidecars::policy(tool)\n}\n";

    /// The table, its two callers and the formula.
    fn policy(fixture: &Fixture, audit: &str) {
        fixture
            .write(
                super::SIDECARS,
                "pub enum RestartPolicy {\n    Automatic,\n    SelfRetiring,\n    OperatorChoice,\n    \
                 NotResident,\n}\npub fn policy(tool: &str) -> RestartPolicy {\n    \
                 RestartPolicy::Automatic\n}\n",
            )
            .write(
                super::SIDECARS_MANIFEST,
                "pub fn plan(previous: &Manifest, next: &Manifest) -> Plan {\n    Plan::default()\n}\n",
            )
            .write(super::HOSTD_AUDIT, audit)
            .write(
                super::SIDECAR_CLI,
                "use slopdesk_sidecars::manifest;\nfn plan() {\n    manifest::plan(&previous,                  &next)\n}\n",
            )
            .write(
                super::HOMEBREW_FORMULA,
                "class Slopdesk < Formula\n  def post_install\n    system bin/\"slopdesk\", \"sidecars\", \
                 \"--record\"\n  end\nend\n",
            );
    }
}
