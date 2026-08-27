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

use crate::claim::{Claim, Corpus, Extract, RUST, SWIFT, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// dropd's client door, in the shim.
const DROP_FFI: &str = "rust/slopdesk-ffi/src/file_transfer.rs";
/// The Swift target that is dropd's face.
const DROP_DIR: &str = "Sources/SlopDeskFileTransfer";
/// The one file in it that used to hold a layout.
const DROP_PROTOCOL_FACE: &str = "Sources/SlopDeskFileTransfer/FileTransferProtocol.swift";
/// The client half of the wire — the module that writes every request and reads every reply.
const DROP_CLIENT: &str = "rust/slopdesk-dropd/src/client.rs";
/// The daemon half — the module that decodes every request and writes every reply.
const DROP_PROTOCOL: &str = "rust/slopdesk-dropd/src/protocol.rs";
/// dropd's listener, which prints the announce line.
const DROP_SERVER: &str = "rust/slopdesk-dropd/src/server.rs";

/// The Android panel's target — three connection types, each writing its own ops.
const ANDROID_DIR: &str = "Sources/SlopDeskDevicePanels/Android";
/// The panel's device row, which decodes the daemon's field names.
const ANDROID_DEVICE: &str = "Sources/SlopDeskDevicePanels/Android/AndroidDevice.swift";
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
/// PATH 4 (`docs/53`). The client half is `rust/slopdesk-dropd`'s `client` module;
/// `Sources/SlopDeskFileTransfer` calls it through the door in
/// `rust/slopdesk-ffi/src/file_transfer.rs` and holds nothing. So the four numbers are not compared
/// across two spellings — there is one spelling, and what is pinned is that Swift still READS it.
///
/// A "just this one field" big-endian helper is how a second implementation grows back one accessor
/// at a time, and a literal cap in the face is drift starting: a cap the client believes and a cap
/// the host enforces that disagree is a bug neither side's tests can see.
///
/// BREAK-TEST: dropped `slopdesk_drop_decoder_next` from the shim ⇒ FAIL "no longer exports".
/// Separately added `func appendBE(` to a file in the target ⇒ FAIL "a byte reader/writer is back".
/// Separately wrote `256 * 1024` into the face ⇒ FAIL "respells a dropd constant". All three
/// restored from /tmp; PASS.
#[must_use]
pub fn the_drop_client_holds_no_layout(tree: &Tree) -> Report {
    /// The eight entries the door vends, each of which Swift calls.
    const DOORS: &[&str] = &[
        "slopdesk_drop_encode_request",
        "slopdesk_drop_decode_reply",
        "slopdesk_drop_constant",
        "slopdesk_drop_decoder_new",
        "slopdesk_drop_decoder_free",
        "slopdesk_drop_decoder_append",
        "slopdesk_drop_decoder_next",
        "slopdesk_drop_decoder_buffered",
    ];
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
        Claim::Lacks {
            path: DROP_PROTOCOL_FACE,
            pattern: r"16 \* 1024 \* 1024|256 \* 1024|20 \* 1024|UInt8 = [0-9]",
            view: View::Code,
            message: "FileTransferProtocol.swift respells a dropd constant — read slopdesk_drop_constant \
                      instead, because a cap the client believes and a cap the host enforces that drift \
                      apart is a bug neither side's tests can see (docs/53)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor|protocol) (FileTransferServer|FileReceiveLogic|FileDropSink|DiskFileDropSink|FileNameSanitizer|LoopbackFileTransferChannel)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift file-drop receiver is back in Sources/ — dropd owns the receiving end, and a \
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
    /// [`View::Raw`], and that is the one place in this file where it is load-bearing rather than
    /// incidental. The comment stripper treats a line whose first character is `*` as the
    /// continuation of a block comment, which is what `    *kind = 3;` looks like to it — so the
    /// code view deletes the chunk writer's byte, the one frame that carries a body and the exact
    /// type a match-only sweep would already have missed. A comment cannot begin with a digit or
    /// with `out.push(`, so reading raw costs nothing here.
    const WRITTEN: Extract =
        Extract::raw(DROP_CLIENT, r"^ *out\.push\(([0-9]+)\);$").also(&[r"^ *\*kind = ([0-9]+);$"]);
    check_all(tree, &[
        Claim::PinnedSet {
            label: "dropd request type bytes",
            from: WRITTEN,
            expect: &["1", "2", "3", "4", "5"],
        },
        Claim::Subset {
            label: "dropd request type",
            subject: WRITTEN,
            universe: Extract::raw(DROP_PROTOCOL, r"^ *([0-9]+) => \{$"),
            message: "the client encodes request type {orphans} but rust/slopdesk-dropd/src/protocol.rs has \
                      no arm decoding it — dropd would read an offer's id out of a chunk body (docs/53)",
        },
        // Both sides are Rust here; the field names are the shape's, not the languages'.
        Claim::SameSet {
            label: "dropd reply type bytes",
            swift: Extract::raw(DROP_CLIENT, r"^ *([0-9]+) => \{$")
                .within(r"pub fn decode_reply_payload", r"^\}$"),
            rust: Extract::raw(DROP_PROTOCOL, r"^ *out\.push\(([0-9]+)\);$")
                .within(r"pub fn encode_reply_payload", r"^\}$"),
        },
        Claim::Pinned {
            label: "dropd's wire version",
            from: Extract::code(DROP_PROTOCOL, r"VERSION: u8 = ([0-9]+);$"),
            expect: "1",
        },
        Claim::Pinned {
            label: "dropd's frame ceiling",
            from: Extract::code(DROP_PROTOCOL, r"MAX_FRAME_PAYLOAD: usize = (.*);$"),
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
/// The senders are a DIRECTORY. Three connection types each write their own ops, and pinning the
/// subject to whichever file holds most of them would make an ordinary split of a connection look
/// like a new verb appearing. The floor is what notices one of the three going stale — a union
/// stays non-empty while a sender falls silent.
///
/// `AndroidDevice` is deliberately absent from the ban below: the CLIENT's row type is the far end
/// of the protocol, which is exactly what the one-implementation rule allows.
///
/// BREAK-TEST: renamed the panel's `"op": "logcat"` to `"tail"` ⇒ FAIL "no arm serving it".
/// Separately renamed `"density"` in the daemon's encoder ⇒ FAIL "never encodes it". Separately
/// restored `final class AndroidToolchain` under Sources/ ⇒ FAIL "a Swift Android bridge is back".
/// All three restored from /tmp; PASS.
#[must_use]
pub fn the_android_bridge_agrees_both_ways(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::SubsetUnder {
            label: "bridge ops",
            subject: Corpus {
                root: ANDROID_DIR,
                extensions: SWIFT,
                pattern: r#""op": "([a-z]+)""#,
                view: View::Code,
            },
            universe: Extract::code(ANDROID_SERVER, r#"^ *"([a-z]+)" =>"#),
            floor: 5,
            message: "the panel sends op '{orphans}' but rust/slopdesk-androidd/src/server.rs has no arm \
                      serving it — the daemon answers `bad request` and the tab just reads as broken \
                      (docs/48)",
        },
        Claim::Subset {
            label: "bridge device field",
            subject: Extract::code(ANDROID_DEVICE, r#"^ *[a-zA-Z]*: entry\["([a-zA-Z]+)"\]"#),
            universe: Extract::code(ANDROID_PROTOCOL, r#""([a-zA-Z]+)""#),
            message: "the panel decodes device field '{orphans}' but rust/slopdesk-androidd/src/protocol.rs \
                      never encodes it — the panel renders what it finds, which is what makes a quietly \
                      emptied column silent (docs/48)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor|protocol) (AndroidBridgeServer|AndroidBridgeManager|AndroidToolchain|AndroidScrcpySession|AndroidDeviceCatalog|AndroidEmulatorConsole|AndroidSocket|AndroidListener|AndroidBridgeRequest)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift Android bridge is back in Sources/ — androidd owns adb and the pump \
                      (docs/48): {files}",
        },
    ])
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
/// What is left in Swift is the event JSON, which is a document the daemon writes and the client
/// reads — the two-ENDS shape, not one capability twice. The tags and the ceiling themselves are
/// [`the_inspector_tags_are_one_alphabet`].
///
/// `slopdesk_inspector_decoder_buffered` is the one door with no Swift caller: it is the door's own
/// assertion that a drained splitter has compacted, exercised by the crate's tests, while Swift
/// sizes its body buffer from the AGAIN verdict instead. It is pinned on the Rust side only.
///
/// BREAK-TEST: dropped `slopdesk_inspector_decoder_next` from the face ⇒ FAIL "stopped calling".
/// Separately wrote `16 * 1024 * 1024` into the face ⇒ FAIL "respells the inspector frame".
/// Separately restored `struct TranscriptParser` under Sources/ ⇒ FAIL "a Swift inspector producer
/// is back". All three restored from /tmp; PASS.
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
        Claim::Mentions {
            path: INSPECTOR_FFI,
            names: &["slopdesk_inspector_decoder_buffered"],
            message: "rust/slopdesk-ffi/src/inspector.rs no longer exports {entry} — the one door with no \
                      Swift caller is still the door's own assertion that a drained splitter compacted \
                      (docs/55)",
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
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor|protocol) (TranscriptParser|TranscriptTailer|TranscriptLine|LineAccumulator|SubagentWatcher|EventBuilder|InspectorEngine|InspectorReplayLog|InspectorSource|InspectorServer)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift inspector producer is back in Sources/ — inspectord owns the fold, and \
                      `InspectorSource` is named here because it was the HOST end of the wire \
                      (InspectorClient, InspectorViewModel and the event types are the far end, which is \
                      allowed) (docs/54): {files}",
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
            view: View::Code,
            message: "rust/slopdesk-inspectord/src/wire.rs no longer writes tag 1 for an event — an unknown \
                      tag is SKIPPED at both ends, so nothing errors and the panel just stays empty \
                      (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_KEEP_ALIVE: u8 = 2;",
            view: View::Code,
            message: "rust/slopdesk-inspectord/src/wire.rs no longer writes tag 2 for a keep-alive — an \
                      unknown tag is SKIPPED at both ends, so nothing errors and the feed just stops \
                      (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_SUBSCRIBE: u8 = 3;",
            view: View::Code,
            message: "rust/slopdesk-inspectord/src/wire.rs no longer spells the client's subscribe tag as 3 \
                      (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_EVENT => Ok\(ClientFrame::Event",
            view: View::Code,
            message: "wire.rs's decode_client no longer reads tag 1 as an event — the client end must \
                      decode exactly the two host → client tags and refuse its own (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"TAG_KEEP_ALIVE => Ok\(ClientFrame::KeepAlive\)",
            view: View::Code,
            message: "wire.rs's decode_client no longer reads tag 2 as a keep-alive — the client end must \
                      decode exactly the two host → client tags and refuse its own (docs/54)",
        },
        Claim::Matches {
            path: INSPECTOR_WIRE,
            pattern: r"MAX_FRAME_PAYLOAD: usize = 16 \* 1024 \* 1024;",
            view: View::Code,
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
                view: View::Code,
                message: text::intern(format!(
                    "{parser} no longer learns {daemon}'s announce marker from the crate that prints it — \
                     hostd would wait out its timeout, kill a healthy service and respawn it on every \
                     restart (docs/51 §6.7)"
                )),
            },
            Claim::Matches {
                path: parser,
                pattern: text::intern(format!("slopdesk_{daemon}::server::ANNOUNCE_VERSION_PREFIX")),
                view: View::Code,
                message: text::intern(format!(
                    "{parser} no longer reads {daemon}'s version marker off the crate that prints it — a \
                     parse that stopped matching reads None, which the audit reports as 'unknown' rather \
                     than failing, so it is asserted here or nowhere (docs/49)"
                )),
            },
            Claim::Matches {
                path: server,
                pattern: r"ANNOUNCE_VERSION_PREFIX\}\{\}",
                view: View::Code,
                message: text::intern(format!(
                    "rust/slopdesk-{daemon}/src/server.rs no longer announces a version after the marker — \
                     hostd would report `unknown` and go on running last week's daemon behind this week's \
                     number (docs/49)"
                )),
            },
            Claim::Matches {
                path: server,
                pattern: r#"env!\("CARGO_PKG_VERSION"\)"#,
                view: View::Code,
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
            from: Extract::code(
                SIDECARS,
                r"^    (Automatic|SelfRetiring|OperatorChoice|NotResident),$",
            ),
            expect: &["Automatic", "NotResident", "OperatorChoice", "SelfRetiring"],
        },
        Claim::Matches {
            path: SIDECARS,
            pattern: r"pub fn policy\(tool: &str\) -> RestartPolicy",
            view: View::Code,
            message: "rust/slopdesk-sidecars no longer holds the policy table — it has two callers in two \
                      languages, which is the exact shape a Swift copy skews quietly in (docs/49)",
        },
        Claim::Matches {
            path: SIDECARS_MANIFEST,
            pattern: r"pub fn plan\(",
            view: View::Code,
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
            view: View::Code,
            message: "rust/slopdesk-hostd/src/audit.rs no longer asks rust/slopdesk-sidecars for its \
                      verdict — it would be a second table, in the one binary that acts on it (docs/49)",
        },
        Claim::Matches {
            path: SIDECAR_CLI,
            pattern: r"slopdesk_sidecars::manifest::plan|manifest::plan\b|use slopdesk_sidecars",
            view: View::Code,
            message: "`slopdesk sidecars` no longer asks rust/slopdesk-sidecars for the upgrade plan — it \
                      would be a second diff of the same two manifests (docs/49)",
        },
        Claim::Matches {
            path: HOMEBREW_FORMULA,
            pattern: r#"sidecars", "--record""#,
            view: View::Code,
            message: "the formula no longer records the manifest — every upgrade would read as a first \
                      install, which is a table that never says anything (docs/49)",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

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
            (
                super::DROP_PROTOCOL_FACE,
                "enum Wire { static let kind = slopdesk_drop_constant(0) }\n",
            ),
            (
                "Sources/SlopDeskDevicePanels/Android/AndroidStreamConnection.swift",
                "let a = [\"op\": \"boot\", \"serial\": s]\nlet b = [\"op\": \"console\"]\n",
            ),
            (
                "Sources/SlopDeskDevicePanels/Android/AndroidLogConnection.swift",
                "let c = [\"op\": \"logcat\"]\nlet d = [\"op\": \"list\"]\nlet e = [\"op\": \"open\"]\n",
            ),
            (
                super::ANDROID_DEVICE,
                "struct AndroidDevice {\n    init(entry: [String: String]) {\n        serial: \
                 entry[\"serial\"]\n        model: entry[\"model\"]\n    }\n}\n",
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

    /// The eight dropd doors, as the shim and as the face that calls them.
    const DOOR_SHIM: &str =
        "pub extern \"C\" fn slopdesk_drop_encode_request() {}\npub extern \"C\" fn \
         slopdesk_drop_decode_reply() {}\npub extern \"C\" fn slopdesk_drop_constant() {}\npub extern \"C\" \
         fn slopdesk_drop_decoder_new() {}\npub extern \"C\" fn slopdesk_drop_decoder_free() {}\npub extern \
         \"C\" fn slopdesk_drop_decoder_append() {}\npub extern \"C\" fn slopdesk_drop_decoder_next() \
         {}\npub extern \"C\" fn slopdesk_drop_decoder_buffered() {}\n";
    const DROP_FACE: &str = "let a = slopdesk_drop_encode_request()\nlet b = \
                             slopdesk_drop_decode_reply()\nlet c = slopdesk_drop_constant(0)\nlet d = \
                             slopdesk_drop_decoder_new()\nlet e = slopdesk_drop_decoder_free(d)\nlet f = \
                             slopdesk_drop_decoder_append(d)\nlet g = slopdesk_drop_decoder_next(d)\nlet h \
                             = slopdesk_drop_decoder_buffered(d)\n";

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

    const INSPECTOR_SHIM: &str =
        "pub extern \"C\" fn slopdesk_inspector_encode_subscribe() {}\npub extern \"C\" fn \
         slopdesk_inspector_decode_payload() {}\npub extern \"C\" fn slopdesk_inspector_constant() {}\npub \
         extern \"C\" fn slopdesk_inspector_decoder_new() {}\npub extern \"C\" fn \
         slopdesk_inspector_decoder_free() {}\npub extern \"C\" fn slopdesk_inspector_decoder_append() \
         {}\npub extern \"C\" fn slopdesk_inspector_decoder_next() {}\npub extern \"C\" fn \
         slopdesk_inspector_decoder_buffered() {}\n";
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
    fn a_respelled_cap_in_the_face_is_red() {
        let fixture = Fixture::new("drop-cap");
        wires(&fixture);
        fixture.write(
            super::DROP_PROTOCOL_FACE,
            "enum Wire { static let cap = 16 * 1024 * 1024 }\n",
        );
        let report = super::the_drop_client_holds_no_layout(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("respells a dropd constant")),
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

    /// The senders are three files, so the op has to be found wherever it is written.
    #[test]
    fn an_op_no_arm_serves_is_red_from_any_sender() {
        let fixture = Fixture::new("android-ops");
        wires(&fixture);
        assert!(super::the_android_bridge_agrees_both_ways(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidLogConnection.swift",
            "let c = [\"op\": \"tail\"]\nlet d = [\"op\": \"list\"]\nlet e = [\"op\": \"open\"]\n",
        );
        let report = super::the_android_bridge_agrees_both_ways(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("op 'tail'")),
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

    /// The one door with no Swift caller is pinned on the Rust side only, so the face may drop it.
    #[test]
    fn the_buffered_door_is_pinned_on_the_rust_side_only() {
        let fixture = Fixture::new("inspector-buffered");
        wires(&fixture);
        assert!(super::the_inspector_frame_has_one_spelling(&fixture.tree()).is_clean());

        fixture.write(
            super::INSPECTOR_FFI,
            &INSPECTOR_SHIM.replace(
                "pub extern \"C\" fn slopdesk_inspector_decoder_buffered() {}\n",
                "",
            ),
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
