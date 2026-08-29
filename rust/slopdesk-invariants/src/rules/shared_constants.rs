//! A number meaning the same in both languages is ASKED FOR or RATCHETED, never spelled twice.
//!
//! Ported from the `check-shared-constants.py` that used to sit in `scripts/`.
//!
//! Two constants with the same name and the same value on either side of the FFI boundary are one
//! constant written twice. Nothing catches that: both sides compile, every test passes, and the two
//! copies agree right up until someone tunes one of them. Then the client draws by a threshold the
//! host does not enforce, and the first symptom is a wrong-length ring or a fragmented datagram,
//! never an error.
//!
//! This repo settles it two ways, and which one is right follows from the LIFETIME of the boundary
//! (`CLAUDE.md`, "a port ships over a socket, or as a linked library"):
//!
//! * IN-PROCESS, across `CSlopDeskFFI` — Swift ASKS. The number crosses through a door and exists
//!   once: `Canvas.minItemSize`, `WorkspaceTopology.closedTabRingCap`.
//! * ACROSS A SOCKET, to a sidecar — the two spellings are RATCHETED against each other by a rule,
//!   because a separately-shipped binary cannot link the other's constant.
//!
//! A VOCABULARY is the exception both answers miss, and it gets the third: an alphabet of field
//! bytes that both ends must NAME, frozen on the wire, where an index-shaped door would only move
//! the transcription. Those pairs are ratcheted here instead, letter for letter and in both
//! directions.
//!
//! So a pair is a finding here only when it is none of the three. [`HOMONYMS`] is for names that
//! collide by accident and describe unrelated laws, where folding them would be the bug.
//!
//! ## What these rules CANNOT see, named precisely
//!
//! A ratchet that is trusted past its reach is worse than none, and every one of these has already
//! let a real pair through at least once. They are structural — each would need a different
//! instrument, not a bigger pattern — so they are written down rather than half-closed.
//!
//! * **Pairing is by normalised NAME.** Two spellings of one law that were never given the same
//!   name are invisible, and a literal with no name has nothing to pair with at all — the commonest
//!   shape a transcription takes. The ENUM pass has an escape from this ([`ENUM_ALIASES`]) and the
//!   CONST pass deliberately does not: a suffix rule was tried and it paired `MetadataStatus` with
//!   screend's `Status`, two protocols sharing one letter. A gate does not get to guess.
//! * **It fires only when the two values are EQUAL.** This is BIRTH CONTROL, not a drift check: it
//!   stops a second spelling being born and says nothing the day one of them moves. The instrument
//!   for drift is a differential test (`docs/55` §8), and this cannot become one.
//! * **The bit passes require the `1 << N` form** on both sides — `Self(rawValue: 1 << N)` in Swift
//!   and `pub const NAME: Self = Self(1 << N)` in Rust. A bit built by a function is not read.
//! * **An enum whose numbers are neither WRITTEN nor CAST is not read.** Unwritten discriminants
//!   are filled in, but only where the position is observable: `#[repr(int)]` on the Rust side, an
//!   integer raw type on the Swift side, or a hand-written `Enum::Case => n` map read as the table
//!   it is. What stays out of reach is the enum numbered by NEITHER, with a caller casting it
//!   anyway — there is nothing in the declaration to read, so the instrument would be the call
//!   site.
//! * **Strings are MOSTLY out of scope.** The one string surface big enough to have earned its own
//!   instrument is the `UserDefaults` key set, ratcheted in `rules::settings_rows`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::report::Report;
use crate::text;
use crate::tree::{Source, Tree};

/// One scope's constants, by normalised name.
type Alphabet = BTreeMap<String, f64>;
/// Every reading of one enum: where it was found, and what it said.
type Readings = Vec<(String, Alphabet)>;

/// Whether two parsed literals are the SAME literal.
///
/// Exact equality is the semantics, not an oversight. Both sides came out of [`numeric`], which
/// folds integer literals — so "within a margin" would be answering a question nobody asked, and a
/// cap of 15 728 639 really is a different cap from 15 728 640.
const fn same(mine: f64, yours: f64) -> bool {
    mine.to_bits() == yours.to_bits()
}

// ------------------------------------------------------------------------------------------- //
// The declared tables. Every one is checked for DEADNESS by `every_allowlist_entry_is_alive`.
// ------------------------------------------------------------------------------------------- //

/// Names that collide but do NOT describe the same law, each with the reason.
///
/// Keyed by (Swift file, name) rather than by the bare name, and that is not tidiness. A name-keyed
/// entry exempts EVERY pair sharing that name, in every file, forever — so ONE legitimate collision
/// buys silence for a real transcription nobody will ever be told about. `currentSchemaVersion` was
/// that entry: it named a homonym across three unrelated stores and quietly covered a FOURTH pair
/// that was the real thing, the two halves of the comparison that decides whether a saved workspace
/// loads. It has a door now (`slopdesk_ws_schema_version`) and the entry is gone.
/// Empty, and it earned that. The one entry was `TransportParameters.swift`'s
/// `keepaliveIntervalSeconds` against the video path's `KEEPALIVE_INTERVAL_SECONDS` — a kernel TCP
/// probe interval against an application UDP datagram that holds a NAT mapping open, both 5 s. The
/// collision was real, but the exemption was load-bearing for the wrong reason: it kept a number
/// SPELLED in Swift that the host's listener also spells, which is the thing this file exists to
/// refuse. Now `slopdesk_wire::transport` declares the ladder under a `TCP_` prefix, the door vends
/// it at indices 3/4/5, Swift asks — and there is no collision left to excuse.
const HOMONYMS: [(&str, &str, &str); 0] = [];

/// Swift `OptionSet`s whose members share a name with a WIRE flag set without sharing its law.
///
/// Empty, and checked for deadness like the rest. It carried `CommandInterpreter.swift` on the
/// grounds that `KeyChord.Modifiers` is a client-only `Int` whose ⇧⌃⌥⌘ layout agreeing with the
/// wire's `InputModifiers` was convention rather than contract. True, and it stopped mattering: the
/// two now agree bit for bit, so the exemption suppressed nothing. If they ever diverge the finding
/// is real — and it should be read then, not waved through by a note written before the divergence.
const HOMONYM_BIT_FILES: [&str; 0] = [];

/// Enums that share a name across the two languages without sharing a meaning.
///
/// None yet: every pair found so far is one wire alphabet. An entry here needs the reason the two
/// are unrelated.
const HOMONYM_ENUMS: [&str; 0] = [];

/// One alphabet under two names, because a Swift type carries its namespace in the NAME and a Rust
/// one carries it in the module path.
///
/// `AndroidMotionAction` here is `androidd::control::MotionAction` there. The enum pass keys by
/// name, so it sees none of these — three of them in `SlopDeskDevicePanels` alone, each a byte the
/// panel writes and the daemon reads.
///
/// A declared list and not the obvious rule, and the rule was tried first: "the Swift name ENDS
/// WITH the Rust name, and they share a case". It pairs `MetadataStatus` with
/// `slopdesk_screenwire::Status` — the metadata RPC's four-letter status alphabet against screend's
/// three-letter one, sharing only `ok` and describing different protocols. A suffix is a guess
/// about where a namespace ends.
///
/// `ScreenStatus`/`Status` is deliberately NOT here: its third case is `internalError` against
/// `Internal`, so the letters do not line up and the pass would report a rename as a drift. Two
/// separate binaries share it, which is the sidecar answer — it is ratcheted by value instead.
const ENUM_ALIASES: [(&str, &str); 4] = [
    ("AndroidMotionAction", "MotionAction"),
    ("AndroidKeyAction", "KeyAction"),
    ("DeviceLogSeverity", "Severity"),
    ("AndroidBodilessMessage", "Bodiless"),
];

/// The declared alphabets, ratcheted letter for letter in both directions.
///
/// A field byte is not a law anyone may tune — it is a letter of the document's alphabet, frozen
/// the moment a golden vector carries one, and both ends must be able to NAME it
/// (`WorkspacePaneField.liveTitle`) rather than reach for it through an index that would itself be
/// the transcription. A field added to one language and not the other fails here rather than at a
/// peer of another build.
#[expect(
    clippy::type_complexity,
    reason = "the table IS the shape a reader wants: two files and the scope pairs between them"
)]
const VOCABULARIES: [(&str, &str, &[(&str, &str)]); 1] = [(
    "Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift",
    "rust/slopdesk-wire/src/document/fields.rs",
    &[
        ("WorkspaceRootField", "root"),
        ("WorkspaceSessionField", "session"),
        ("WorkspaceTabField", "tab"),
        ("WorkspacePaneField", "pane"),
        ("WorkspaceSplitNodeField", "split_node"),
        ("WorkspaceProjectField", "project"),
    ],
)];

/// Pairs a DERIVED gate already compares, keyed by the two files and by the gate's own label.
///
/// A derived gate names no constant, which is what makes it a ratchet rather than a list — and what
/// makes it invisible to the "does some other gate mention this name" test below. The label must
/// still be there: an escape hatch pointing at a gate someone deleted is a suppression, not a
/// ratchet.
/// EMPTY since `docs/60` Batch B, and empty on purpose rather than deleted.
///
/// The one entry was `ScreenProtocol.swift` against `slopdesk-screenwire`, whose reset flags
/// `reset_flags_and_ceiling` compared as a normalised SET. That gate no longer compares anything:
/// the Swift half is gone and `slopdesk-screenclient` IMPORTS the flags, so the pin became "there
/// is one copy" instead of "the two agree". The array stays because the ESCAPE HATCH is the point —
/// a derived gate names no constant, so without a row here it is invisible to the sweep below, and
/// the next one to be written needs somewhere to say so.
const DERIVED_RATCHETS: [(&str, &str, &str); 0] = [];

// ------------------------------------------------------------------------------------------- //
// The patterns. Composed through macros because `concat!` takes literals, not consts.
// ------------------------------------------------------------------------------------------- //

/// Decimal, hex or binary — a flag byte is written `0x10` on both sides and a decimal-only pattern
/// reads neither of them, which is how four `slopdesk-screenwire` flags stayed unwatched.
macro_rules! number {
    () => {
        r"(0[xX][0-9a-fA-F_]+|0b[01_]+|[0-9][0-9_]*(?:\.[0-9]+)?)"
    };
}

/// The same, as a group nothing reads — for use inside a larger capture.
macro_rules! number_only {
    () => {
        r"(?:0[xX][0-9a-fA-F_]+|0b[01_]+|[0-9][0-9_]*(?:\.[0-9]+)?)"
    };
}

/// A size is rarely written as its digits.
///
/// `256 * 1024 * 1024` is how a cap is spelled where a reader has to see the megabytes, and a
/// literal-only pattern reads neither half — so the loudest constants in the tree, the ones a
/// comment calls "the 15 MiB cap", were the ones this gate could not see at all.
macro_rules! expression {
    () => {
        concat!(
            "(",
            number_only!(),
            r"(?:[ \t]*(?:\*|\+|<<)[ \t]*",
            number_only!(),
            r")*)"
        )
    };
}

/// A module's exported alphabet. Indented, because a vocabulary declares its constants inside a
/// `mod` — anchoring at column 0 hid every field byte from this gate until 2026-08-17.
const RUST_CONST: &str = concat!(
    r"^[ \t]*pub const ([A-Z][A-Z_0-9]*): *",
    r"(?:usize|u8|u16|u32|u64|i8|i16|i32|i64|f32|f64) *= *",
    expression!(),
    r"[ \t]*;"
);

const SWIFT_CONST: &str = concat!(
    r"^\s*(?:public |private |internal |fileprivate |package )?static let ",
    r"([A-Za-z][A-Za-z0-9]*)",
    r"(?: *: *[A-Za-z][A-Za-z0-9]*)? *= *",
    expression!(),
    r"[ \t]*$"
);

const RUST_SCOPE: &str = r"^pub mod ([a-z_]+) \{$";
const SWIFT_SCOPE: &str = r"^public enum ([A-Za-z]+) \{$";

/// An enum opener, with its indent, its name and the rest of its header line.
///
/// Both allow LEADING WHITESPACE and every visibility either language spells, and neither
/// concession is cosmetic. Column-anchoring cost this pass two whole classes of pair at once: a
/// NESTED Swift enum was invisible (`MetadataCodec` declares six, each with a `slopdesk_wire` twin,
/// and all six read as ONE scope), and `package` was missing from the visibility list, which is the
/// whole of `SlopDeskDevicePanels`.
///
/// The header is captured because a Swift enum's RAW TYPE decides whether its unnumbered cases mean
/// anything.
const RUST_ENUM: &str = r"^([ \t]*)(?:pub(?:\([a-z_:]+\))? )?enum ([A-Za-z][A-Za-z0-9]*)([^\n]*)\{$";
const SWIFT_ENUM: &str = concat!(
    r"^([ \t]*)(?:(?:public|package|internal|private|fileprivate) )?(?:indirect )?",
    r"enum ([A-Za-z][A-Za-z0-9]*)([^\n]*)\{$"
);

/// One case line, with the `= n` OPTIONAL — see [`discriminants`] for when the missing half may be
/// filled in.
const RUST_CASE: &str = concat!(
    r"^[ \t]*([A-Z][A-Za-z0-9]*)[ \t]*(?:=[ \t]*",
    number!(),
    r")?[ \t]*,[ \t]*(?://.*)?$"
);
const SWIFT_CASE: &str = concat!(
    r"^[ \t]*case ([a-z][A-Za-z0-9]*)[ \t]*(?:=[ \t]*",
    number!(),
    r")?[ \t]*(?://.*)?$"
);

/// A case that CARRIES something has no discriminant to compare, and — worse — makes the implicit
/// numbering of every case after it a fiction.
const RUST_PAYLOAD: &str = r"^[ \t]*[A-Z][A-Za-z0-9]*[ \t]*[({]";
const SWIFT_PAYLOAD: &str = r"^[ \t]*(?:indirect )?case [a-z][A-Za-z0-9]*[ \t]*\(";

/// Swift numbers unwritten cases only when the enum declares an INTEGER raw type; without one there
/// is no `rawValue` at all and a position is not a number anybody can observe.
const SWIFT_RAW_TYPE: &str = r"^[ \t]*:[ \t]*(U?Int(?:8|16|32|64)?)\b";

/// Rust numbers them always — a fieldless variant's discriminant IS its position — but a position
/// nobody CASTS is not a shared law, and a gate that reported one would be reporting on the order
/// somebody wrote the variants in. `#[repr(int)]` is the marker that the ordinals are the
/// representation.
const RUST_REPR: &str = r"#\[repr\((?:u|i)(?:8|16|32|64|size)\)\]";

/// A hand-written `Enum::Case => n` arm, which is where an unnumbered Rust enum's real law lives.
///
/// `slopdesk_wire::mux::ChannelState` was the worked example: no `= n` on any variant and no
/// `#[repr]`, so reordering it changed nothing — the number the other side read was minted by hand
/// in a `const fn ordinal`, and the Swift `ChannelTable` turned it back with
/// `ChannelState(rawValue: ordinal) ?? .closed`. That `?? .closed` is why the drift was silent
/// rather than loud: an arm renumbered in the shim did not fail to decode, it decoded to a
/// DIFFERENT state, and a half-closed channel read as closed simply stopped routing. `docs/63` §G.3
/// deleted that Swift half, so the ordinal no longer crosses a language for this particular enum —
/// the SHAPE it is named for is unchanged, and this rule pairs enums dynamically rather than by a
/// list, so nothing about it moved with the file.
///
/// The right-hand side is a number OR THE NAME OF ONE, because that is how a protocol whose bytes
/// have names writes it: `Bodiless::type_byte` answers `kind::COLLAPSE_PANELS`, never `7`.
///
/// The qualifier is ONE capture and `Self` is resolved in code, which is not a tidy-up: it used to
/// be `(?:([A-Z][A-Za-z0-9]*)|Self)::`, and `[A-Z][A-Za-z0-9]*` matches the four letters of `Self`,
/// so every `Self::`-qualified map in the tree was filed under an enum literally named `Self` —
/// eighteen files' worth, pairing with nothing.
const RUST_ORDINAL_ARM: &str = concat!(
    r"^[ \t]*([A-Z][A-Za-z0-9]*)::([A-Z][A-Za-z0-9]*)[ \t]*=>[ \t]*",
    "(",
    number_only!(),
    r"|(?:[a-z][a-z_0-9]*::)*[A-Z][A-Z_0-9]*)",
    r",[ \t]*$"
);

/// A constant an ordinal arm may NAME. Visibility is optional and `pub(super)`/`pub(crate)` are in
/// scope, which is the difference from [`RUST_CONST`]: that one reads a vocabulary's exported
/// alphabet and this one reads whatever the file happens to call its own bytes.
const RUST_LOCAL_CONST: &str = concat!(
    r"^[ \t]*(?:pub(?:\([a-z_:]+\))? )?const ([A-Z][A-Z_0-9]*): *",
    r"(?:usize|u8|u16|u32|u64|i8|i16|i32|i64) *= *",
    expression!(),
    r"[ \t]*;"
);

const RUST_IMPL: &str = concat!(
    r"^impl(?:<[^>]*>)?[ \t]+(?:[A-Za-z][A-Za-z0-9_:<>, ]*[ \t]+for[ \t]+)?",
    r"([A-Za-z][A-Za-z0-9]*)"
);

/// An `OptionSet`'s bit POSITIONS are the third alphabet: `1 << 6` on both sides, spelled as an
/// expression rather than a literal, so neither of the constant patterns reads one.
const RUST_BIT: &str = r"^\s*pub const ([A-Z][A-Z_0-9]*): *Self *= *Self\(1 *<< *([0-9]+)\);";
const SWIFT_BIT: &str = concat!(
    r"^\s*(?:public |private |internal )?static let ([A-Za-z][A-Za-z0-9]*)",
    r" *(?::[^=\n]+)?= *(?:Self|[A-Za-z][A-Za-z0-9]*)\(rawValue: *1 *<< *([0-9]+)\)"
);

/// This module's own path, held out of the ratchet corpus.
///
/// The corpus is "every other gate's text", and a name found in it means some ratchet already
/// compares the pair. This file NAMES the pairs it excuses — that is what [`HOMONYMS`] is — so
/// counting itself would suppress the very pair whose exemption it then reports as dead.
const OWN_PATH: &str = "rust/slopdesk-invariants/src/rules/shared_constants.rs";

/// Where the Swift tree ENDS.
///
/// A TEST is deliberately not audited. A door called only from a test is still a door somebody
/// reaches; a NUMBER spelled in a test is usually the pin itself — the whole point of
/// `XCTAssertEqual(field, 7)` is that 7 is written down where a refactor cannot move it. Auditing
/// those would report every golden expectation in the tree as a transcription of the constant it
/// exists to hold still. So the exclusion is a `Tests` PATH COMPONENT and not the single top-level
/// root: the iOS suite lives inside `Apps/`, which this does audit.
const SWIFT_ROOTS: [&str; 3] = ["Sources", "Apps", "ThirdParty/ghostty/integration"];

// ------------------------------------------------------------------------------------------- //
// Reading numbers
// ------------------------------------------------------------------------------------------- //

/// A literal's value, in whichever of the three notations it was written.
fn literal(written: &str) -> Option<f64> {
    let plain = written.replace('_', "");
    let head = plain.get(..2).unwrap_or_default().to_ascii_lowercase();
    #[expect(
        clippy::cast_precision_loss,
        reason = "a constant wider than 2^53 is not a number either language writes as a literal"
    )]
    match head.as_str() {
        "0x" => {
            i64::from_str_radix(&plain[2..], 16)
                .ok()
                .map(|value| value as f64)
        },
        "0b" => i64::from_str_radix(&plain[2..], 2).ok().map(|value| value as f64),
        _ => plain.parse::<f64>().ok(),
    }
}

/// What a constant's right-hand side is WORTH, or `None` when this evaluator cannot say.
///
/// Integer literals joined by `*`, `+` and `<<`, folded left to right with `*` before `+`. Not an
/// `eval`: this reads files nobody reviewed as code, and a gate that executes its input to compare
/// two numbers has traded the bug it catches for a worse one.
///
/// A `<<` mixed with either arithmetic operator answers `None` rather than a value, and that
/// refusal is the one judgement in here. Rust binds `*` and `+` TIGHTER than `<<`; Swift binds `<<`
/// tighter than both. So `1 << 2 + 3` is 32 in Rust and 7 in Swift, and any answer this function
/// gave would be right about one language and wrong about the other — which is the exact class of
/// silent disagreement it exists to report.
fn numeric(written: &str) -> Option<f64> {
    let mut values = Vec::new();
    let mut operators = Vec::new();
    let mut rest = written.trim();
    loop {
        let head = rest.find(['*', '+', '<']).unwrap_or(rest.len());
        values.push(literal(rest[..head].trim())?);
        rest = &rest[head..];
        if rest.is_empty() {
            break;
        }
        let operator = if rest.starts_with("<<") { "<<" } else { &rest[..1] };
        operators.push(operator);
        rest = rest[operator.len()..].trim_start();
    }

    let shifts = operators.iter().filter(|operator| **operator == "<<").count();
    if shifts > 0 && shifts != operators.len() {
        return None;
    }
    if shifts > 0 {
        let mut shifted = values[0];
        for places in &values[1..] {
            if shifted.fract() != 0.0 || places.fract() != 0.0 || !(0.0..64.0).contains(places) {
                return None;
            }
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_precision_loss,
                reason = "both sides are whole and the shift is range-checked on the line above"
            )]
            let stepped = ((shifted as i64) << (*places as i64)) as f64;
            shifted = stepped;
        }
        return Some(shifted);
    }
    // `*` binds tighter than `+` in both languages, so the products are folded first and summed.
    let mut terms = vec![values[0]];
    for (operator, value) in operators.iter().zip(&values[1..]) {
        if *operator == "*" {
            *terms.last_mut().expect("a term is always pushed first") *= value;
        } else {
            terms.push(*value);
        }
    }
    Some(terms.iter().sum())
}

/// A value as a reader wants to see it: whole numbers without a decimal point.
///
/// The Python printed these through `%g`, which turns the 15 MiB cap into `1.57286e+07` — a
/// rendering that makes a byte count harder to check than the source line it came from.
fn shown(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{value:.0}")
    } else {
        format!("{value}")
    }
}

/// A name with its underscores dropped and its case folded, so `FLAG_AGENT` and `flagAgent` meet.
fn normalised(name: &str) -> String {
    name.replace('_', "").to_lowercase()
}

// ------------------------------------------------------------------------------------------- //
// Reading declarations
// ------------------------------------------------------------------------------------------- //

/// Every Swift file this gate audits, tests aside.
fn swift_sources(tree: &Tree) -> Vec<(&Path, &Source)> {
    let mut out = Vec::new();
    for root in SWIFT_ROOTS {
        for (path, source) in tree.under(root) {
            let is_swift = path.extension().is_some_and(|extension| extension == "swift");
            let in_tests = path.components().any(|part| part.as_os_str() == "Tests");
            if is_swift && !in_tests {
                out.push((path, source));
            }
        }
    }
    out
}

/// Every `.rs` under `rust/`, which is where both wire crates and the FFI shims live.
fn rust_sources(tree: &Tree) -> Vec<(&Path, &Source)> {
    tree.under("rust")
        .filter(|(path, _)| path.extension().is_some_and(|extension| extension == "rs"))
        .collect()
}

/// Each `mod`/`enum` in `text`, mapped to the constants declared before the next one opens.
fn scopes(text: &str, opener: &str, constant: &str) -> BTreeMap<String, Alphabet> {
    let starts: Vec<(String, usize)> = text::cached(opener)
        .captures_iter(text)
        .map(|found| (found[1].to_owned(), found.get(0).expect("the whole match").end()))
        .collect();
    let mut out = BTreeMap::new();
    for (index, (name, at)) in starts.iter().enumerate() {
        let end = starts.get(index + 1).map_or(text.len(), |(_, next)| *next);
        let mut held = BTreeMap::new();
        for found in text::cached(constant).captures_iter(&text[*at..end]) {
            if let Some(value) = numeric(&found[2]) {
                held.insert(normalised(&found[1]), value);
            }
        }
        out.insert(name.clone(), held);
    }
    out
}

/// One enum declaration, as much of it as the discriminant reader needs.
struct Declaration {
    name: String,
    header: String,
    attributes: String,
    body: String,
}

/// Every enum in `text`.
///
/// The body ENDS, which the `mod`-shaped [`scopes`] does not need to care about and this does: a
/// nested enum's cases are not its parent's, and a parent that swallowed them would report six
/// alphabets as one. So the body runs to whichever comes first — the closing brace at the
/// declaration's own indent, or the next enum opening inside it.
///
/// `attributes` is the run of `#[…]` lines immediately above the declaration, which is where Rust
/// writes the `#[repr(u8)]` that decides whether an unnumbered variant means a number.
fn declarations(text: &str, opener: &str) -> Vec<Declaration> {
    let found: Vec<_> = text::cached(opener).captures_iter(text).collect();
    let mut out = Vec::new();
    for (index, capture) in found.iter().enumerate() {
        let whole = capture.get(0).expect("the whole match");
        let indent = &capture[1];
        let following = found
            .get(index + 1)
            .map_or(text.len(), |next| next.get(0).expect("the whole match").start());
        let closer = text::cached(&format!(r"^{}\}}", regex::escape(indent)))
            .find(&text[whole.end()..])
            .map_or(text.len(), |at| whole.end() + at.start());
        let end = following.min(closer).max(whole.end());

        let mut attributes = Vec::new();
        let mut line_start = text[..whole.start()].rfind('\n').map_or(0, |at| at + 1);
        while line_start > 0 {
            let previous = text[..line_start - 1].rfind('\n').map_or(0, |at| at + 1);
            let line = &text[previous..line_start - 1];
            if !line.trim_start().starts_with("#[") {
                break;
            }
            attributes.push(line);
            line_start = previous;
        }
        attributes.reverse();

        out.push(Declaration {
            name: capture[2].to_owned(),
            header: capture[3].to_owned(),
            attributes: attributes.join("\n"),
            body: text[whole.end()..end].to_owned(),
        });
    }
    out
}

/// One enum's discriminants, normalised for comparison across the two spellings.
///
/// An unwritten `= n` is filled in the way its own language would fill it — running from 0 and from
/// the last explicit value, which is what both compilers do — but only when the position is a
/// number somebody can actually OBSERVE. That is the whole judgement in here, and it differs by
/// language: Rust needs `#[repr(int)]` (without it, no cast exists and the order is just the order
/// somebody typed), Swift needs an integer raw type (without one there is no `rawValue`). A case
/// carrying a payload voids the numbering outright, for both.
fn discriminants(held: &Declaration, rust: bool) -> Alphabet {
    let line_case = text::cached(if rust { RUST_CASE } else { SWIFT_CASE });
    let payload = text::cached(if rust { RUST_PAYLOAD } else { SWIFT_PAYLOAD });
    let mut observable = if rust {
        text::matches(&held.attributes, RUST_REPR)
    } else {
        text::matches(&held.header, SWIFT_RAW_TYPE)
    };

    let mut written = Vec::new();
    for line in held.body.split('\n') {
        if payload.is_match(line) {
            observable = false;
            continue;
        }
        let Some(found) = line_case.captures(line) else {
            continue;
        };
        let value = found.get(2).and_then(|digits| numeric(digits.as_str()));
        written.push((normalised(&found[1]), value));
    }

    let mut out = BTreeMap::new();
    let mut following = 0.0;
    for (name, value) in written {
        let resolved = value.unwrap_or(following);
        if value.is_none() && !observable {
            following += 1.0; // count the position, so a LATER explicit case still lands right
            continue;
        }
        out.insert(name, resolved);
        following = resolved + 1.0;
    }
    out
}

/// Every integer constant one Rust FILE declares, by bare name, for an ordinal arm to name.
///
/// Keyed by the bare name and not by the path an arm writes, because the arm writes the path from
/// wherever it stands — `kind::COLLAPSE_PANELS` inside the module, `COLLAPSE_PANELS` under a `use`.
/// A name declared TWICE in one file with two different values is dropped rather than guessed at.
fn local_constants(text: &str) -> Alphabet {
    let mut seen: BTreeMap<String, BTreeSet<u64>> = BTreeMap::new();
    for found in text::cached(RUST_LOCAL_CONST).captures_iter(text) {
        if let Some(value) = numeric(&found[2]) {
            seen.entry(found[1].to_owned())
                .or_default()
                .insert(value.to_bits());
        }
    }
    seen.into_iter()
        .filter(|(_, values)| values.len() == 1)
        .filter_map(|(name, values)| Some((name, f64::from_bits(*values.iter().next()?))))
        .collect()
}

/// Every hand-written `Enum::Case => n` map in one Rust file, one table per `match` block.
///
/// Per BLOCK, not per enum: a file often holds both an `ordinal` and its inverse, and a couple hold
/// two maps of the same enum for two different callers. Merging them would let one block's arm
/// quietly satisfy the other's, which is the reading that would miss a renumbering in exactly one
/// direction. Two arms belong to the same block while the text between them opens or closes
/// nothing — a `}` ends the block, and so does an arm naming a different enum.
fn ordinal_shims(text: &str) -> BTreeMap<String, Vec<Alphabet>> {
    let impls: Vec<(usize, &str)> = text::cached(RUST_IMPL)
        .captures_iter(text)
        .map(|found| {
            (
                found.get(0).expect("the whole match").start(),
                found.get(1).expect("the type").as_str(),
            )
        })
        .collect();
    let constants = local_constants(text);
    let mut out: BTreeMap<String, Vec<Alphabet>> = BTreeMap::new();
    let mut owner = String::new();
    let mut block: Alphabet = BTreeMap::new();
    let mut previous_end = 0;

    for arm in text::cached(RUST_ORDINAL_ARM).captures_iter(text) {
        let whole = arm.get(0).expect("the whole match");
        let mut named = arm[1].to_owned();
        if named == "Self" {
            // The enum is whichever `impl` block encloses the arm.
            named = impls
                .iter()
                .rev()
                .find(|(at, _)| *at < whole.start())
                .map_or_else(String::new, |(_, name)| (*name).to_owned());
        }
        let written = &arm[3];
        let value = numeric(written).or_else(|| {
            constants
                .get(written.rsplit("::").next().unwrap_or(written))
                .copied()
        });
        if named != owner || text[previous_end..whole.start()].contains('}') || value.is_none() {
            if !owner.is_empty() && !block.is_empty() {
                out.entry(owner.clone())
                    .or_default()
                    .push(std::mem::take(&mut block));
            }
            owner = named;
            block = BTreeMap::new();
        }
        if let Some(value) = value {
            block.insert(normalised(&arm[2]), value);
        }
        previous_end = whole.end();
    }
    if !owner.is_empty() && !block.is_empty() {
        out.entry(owner).or_default().push(block);
    }
    out
}

/// Every Rust enum's discriminants, by enum name, from its DECLARATION and from any shim.
///
/// Both readings are kept, and neither is preferred, because which one is the law depends on the
/// enum: `MotionAction` writes its bytes on the variants, `ChannelState` writes them in an FFI
/// `match` and nowhere else. An enum with both is compared against both, and they had better agree.
fn rust_alphabets(tree: &Tree) -> BTreeMap<String, Readings> {
    let mut out: BTreeMap<String, Readings> = BTreeMap::new();
    for (path, source) in rust_sources(tree) {
        let where_ = path.display().to_string();
        for held in declarations(&source.text, RUST_ENUM) {
            let declared = discriminants(&held, true);
            if !declared.is_empty() {
                out.entry(held.name).or_default().push((where_.clone(), declared));
            }
        }
        for (name, blocks) in ordinal_shims(&source.text) {
            for block in blocks {
                out.entry(name.clone())
                    .or_default()
                    .push((format!("{where_} (ordinal map)"), block));
            }
        }
    }
    out
}

// ------------------------------------------------------------------------------------------- //
// The rules
// ------------------------------------------------------------------------------------------- //

/// What the const pass found, and which exemption it needed to stay quiet.
struct Pairs {
    findings: Vec<String>,
    used_homonyms: BTreeSet<(String, String)>,
}

/// Every Swift constant that restates a Rust one, and the exemptions that were spent doing it.
fn shared_pairs(tree: &Tree) -> Pairs {
    let mut rust: BTreeMap<String, Vec<(String, String, f64)>> = BTreeMap::new();
    for (path, source) in rust_sources(tree) {
        for found in text::cached(RUST_CONST).captures_iter(&source.text) {
            if let Some(value) = numeric(&found[2]) {
                rust.entry(normalised(&found[1])).or_default().push((
                    path.display().to_string(),
                    found[1].to_owned(),
                    value,
                ));
            }
        }
    }

    // A name a gate already compares is ratcheted, which is the sidecar answer. The corpus is the
    // shell that still holds sections plus every rule in this crate EXCEPT this file — see
    // `OWN_PATH`.
    let mut ratcheted = tree
        .get("rust/slopdesk-invariants")
        .map(|held| held.text.clone())
        .unwrap_or_default();
    for (path, source) in tree.under("rust/slopdesk-invariants") {
        if path.extension().is_some_and(|extension| extension == "rs") && path != Path::new(OWN_PATH) {
            ratcheted.push_str(&source.text);
        }
    }

    let vocabulary: BTreeSet<&str> = VOCABULARIES.iter().map(|(swift, ..)| *swift).collect();
    let mut findings = Vec::new();
    let mut used_homonyms = BTreeSet::new();
    for (path, source) in swift_sources(tree) {
        let here = path.display().to_string();
        if vocabulary.contains(here.as_str()) {
            continue; // ratcheted letter for letter below, which is stricter than this pass
        }
        for found in text::cached(SWIFT_CONST).captures_iter(&source.text) {
            let (name, written) = (&found[1], &found[2]);
            let Some(worth) = numeric(written) else {
                continue;
            };
            for (rust_path, rust_name, rust_value) in rust.get(&name.to_lowercase()).unwrap_or(&Vec::new()) {
                if !same(worth, *rust_value) {
                    continue; // a different number is a different constant, or a gate's business
                }
                if ratcheted.contains(name) || ratcheted.contains(rust_name.as_str()) {
                    continue;
                }
                let derived = DERIVED_RATCHETS.iter().any(|(swift, rust_file, label)| {
                    *swift == here && rust_file == rust_path && ratcheted.contains(label)
                });
                if derived {
                    continue;
                }
                // LAST, not first: an entry only counts as USED when it is the sole reason a real
                // pair was let through. Checked before the ratchets it would have suppressed a pair
                // something else already covers, and then looked alive forever.
                if HOMONYMS
                    .iter()
                    .any(|(file, held, _)| *file == here && *held == name)
                {
                    used_homonyms.insert((here.clone(), name.to_owned()));
                    continue;
                }
                findings.push(format!(
                    "  {here}: `{name} = {written}` restates `{rust_name}` in {rust_path}"
                ));
            }
        }
    }
    findings.sort();
    Pairs {
        findings,
        used_homonyms,
    }
}

/// A number meaning the same thing on both sides is asked for through a door, or ratcheted.
#[must_use]
pub fn a_shared_number_is_asked_for_or_ratcheted(tree: &Tree) -> Report {
    let mut report = Report::new();
    let found = shared_pairs(tree);
    if !found.findings.is_empty() {
        report.fail(format!(
            "a constant is spelled in both languages —{}\nAsk for it through a `CSlopDeskFFI` door (see \
             `slopdesk_ws_min_weight` for the shape), or — if the two ends are separate BINARIES — ratchet \
             the pair in a rule. A genuine name collision goes in HOMONYMS with the reason the two laws are \
             unrelated.",
            found.findings.join("\n")
        ));
    }
    report
}

/// Every way a declared alphabet stopped meaning the same thing letter for letter.
fn vocabulary_findings(tree: &Tree, report: &mut Report) -> Vec<String> {
    let mut out = Vec::new();
    for (swift_file, rust_file, pairs) in VOCABULARIES {
        let (Some(swift_source), Some(rust_source)) = (
            report.source(tree, swift_file, "a declared vocabulary has no other spelling"),
            report.source(tree, rust_file, "a declared vocabulary has no other spelling"),
        ) else {
            continue;
        };
        let swift = scopes(&swift_source.text, SWIFT_SCOPE, SWIFT_CONST);
        let rust = scopes(&rust_source.text, RUST_SCOPE, RUST_CONST);
        for (swift_scope, rust_scope) in pairs {
            let here = swift.get(*swift_scope).cloned().unwrap_or_default();
            let there = rust.get(*rust_scope).cloned().unwrap_or_default();
            if here.is_empty() || there.is_empty() {
                out.push(format!(
                    "  {swift_file}: `{swift_scope}` and `{rust_scope}` no longer pair up"
                ));
                continue;
            }
            let names: BTreeSet<&String> = here.keys().chain(there.keys()).collect();
            for name in names {
                let complaint = match (here.get(name), there.get(name)) {
                    (None, _) => {
                        format!(
                            "  {swift_file}: `{swift_scope}` is missing `{name}`, which {rust_scope} \
                             declares"
                        )
                    },
                    (_, None) => {
                        format!(
                            "  {rust_file}: `{rust_scope}` is missing `{name}`, which {swift_scope} declares"
                        )
                    },
                    (Some(mine), Some(yours)) if !same(*mine, *yours) => {
                        format!(
                            "  {swift_file}: `{swift_scope}.{name} = {}` against `{rust_scope}::{name} = {}`",
                            shown(*mine),
                            shown(*yours)
                        )
                    },
                    _ => continue,
                };
                out.push(complaint);
            }
        }
    }
    out
}

/// The declared field alphabets agree letter for letter, in both directions.
#[must_use]
pub fn the_field_vocabularies_agree(tree: &Tree) -> Report {
    let mut report = Report::new();
    let drifted = vocabulary_findings(tree, &mut report);
    if !drifted.is_empty() {
        report.fail(format!(
            "a shared alphabet drifted —\n{}\nA field byte is frozen on the wire and NAMED on both sides, \
             so the two spellings are ratcheted rather than folded into a door. Add the letter to both, or \
             give it the same byte on both — a mis-numbered field decodes cleanly into the wrong meaning.",
            drifted.join("\n")
        ));
    }
    report
}

/// Every wire enum whose two spellings stopped agreeing, case for case, and the aliases spent.
fn enum_findings(tree: &Tree) -> (Vec<String>, BTreeSet<String>) {
    let rust = rust_alphabets(tree);
    let mut out = BTreeSet::new();
    let mut used = BTreeSet::new();
    for (path, source) in swift_sources(tree) {
        let here_file = path.display().to_string();
        for held in declarations(&source.text, SWIFT_ENUM) {
            let here = discriminants(&held, false);
            if here.is_empty() || HOMONYM_ENUMS.contains(&held.name.as_str()) {
                continue;
            }
            let mut spelt = rust.get(&held.name).cloned().unwrap_or_default();
            let aliased = ENUM_ALIASES
                .iter()
                .find(|(swift, _)| *swift == held.name)
                .and_then(|(_, rust_name)| rust.get(*rust_name));
            if let Some(far) = aliased {
                used.insert(held.name.clone());
                spelt.extend(far.iter().cloned());
            }
            for (there_file, there) in spelt {
                if here.keys().all(|name| !there.contains_key(name)) {
                    continue; // same name, no case in common: not the same alphabet
                }
                let names: BTreeSet<&String> = here.keys().chain(there.keys()).collect();
                let name_of = &held.name;
                for case in names {
                    match (here.get(case), there.get(case)) {
                        (None, _) => {
                            out.insert(format!(
                                "  {here_file}: `{name_of}` is missing `{case}`, in {there_file}"
                            ))
                        },
                        (_, None) => {
                            out.insert(format!(
                                "  {there_file}: `{name_of}` is missing `{case}`, in {here_file}"
                            ))
                        },
                        (Some(mine), Some(yours)) if !same(*mine, *yours) => {
                            out.insert(format!(
                                "  {here_file}: `{name_of}.{case} = {}` against `{}` in {there_file}",
                                shown(*mine),
                                shown(*yours)
                            ))
                        },
                        _ => false,
                    };
                }
            }
        }
    }
    (out.into_iter().collect(), used)
}

/// A wire enum's discriminants agree in both languages, case for case.
#[must_use]
pub fn the_wire_enums_agree(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (drifted, _) = enum_findings(tree);
    if !drifted.is_empty() {
        report.fail(format!(
            "a shared alphabet drifted —\n{}\nA verb byte that moved in one language is a request the other \
             end answers as a DIFFERENT verb.",
            drifted.join("\n")
        ));
    }
    report
}

/// Every wire flag whose bit moved in one language and not the other, and the files spent.
fn bit_findings(tree: &Tree) -> (Vec<String>, BTreeSet<String>) {
    let mut rust: BTreeMap<String, Vec<(String, String, String)>> = BTreeMap::new();
    for (path, source) in rust_sources(tree) {
        for found in text::cached(RUST_BIT).captures_iter(&source.text) {
            rust.entry(normalised(&found[1])).or_default().push((
                path.display().to_string(),
                found[1].to_owned(),
                found[2].to_owned(),
            ));
        }
    }

    let mut out = Vec::new();
    let mut used = BTreeSet::new();
    for (path, source) in swift_sources(tree) {
        let here_file = path.display().to_string();
        for found in text::cached(SWIFT_BIT).captures_iter(&source.text) {
            let (name, bit) = (&found[1], &found[2]);
            for (there_file, there_name, there_bit) in rust.get(&name.to_lowercase()).unwrap_or(&Vec::new()) {
                if bit == there_bit {
                    continue;
                }
                if HOMONYM_BIT_FILES.contains(&here_file.as_str()) {
                    used.insert(here_file.clone());
                    continue;
                }
                out.push(format!(
                    "  {here_file}: `{name} = 1 << {bit}` against `{there_name} = 1 << {there_bit}` in \
                     {there_file}"
                ));
            }
        }
    }
    (out, used)
}

/// A wire flag's bit position agrees in both languages.
#[must_use]
pub fn the_wire_flag_bits_agree(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (drifted, _) = bit_findings(tree);
    if !drifted.is_empty() {
        report.fail(format!(
            "a shared alphabet drifted —\n{}\nA bit position is only a shared law when the byte crosses, \
             and when it does, both sides must lay it out the same way.",
            drifted.join("\n")
        ));
    }
    report
}

/// Every allowlist entry above suppressed something this run.
///
/// An exemption that stops matching is the failure this whole module is about, one level up: a
/// ledger that keeps being consulted after its subject moved. `maxDepth` was one — the split tree's
/// depth limit, exempted against "the JSON reader's recursion limit" — and when
/// `SplitNode.maxDepth` became `Int(slopdesk_ws_max_depth())` the entry stopped covering anything
/// and nothing said so. Deleting it changed no result, which is the definition of dead.
#[must_use]
pub fn every_allowlist_entry_is_alive(tree: &Tree) -> Report {
    let mut report = Report::new();
    let used_homonyms = shared_pairs(tree).used_homonyms;
    let (_, used_aliases) = enum_findings(tree);
    let (_, used_bit_files) = bit_findings(tree);

    let mut dead = Vec::new();
    for (file, name, _) in HOMONYMS {
        if !used_homonyms.contains(&(file.to_owned(), name.to_owned())) {
            dead.push(format!("  HOMONYMS: `{name}` in {file} suppressed nothing"));
        }
    }
    for file in HOMONYM_BIT_FILES {
        if !used_bit_files.contains(file) {
            dead.push(format!("  HOMONYM_BIT_FILES: `{file}` suppressed nothing"));
        }
    }
    for (swift, rust) in ENUM_ALIASES {
        if !used_aliases.contains(swift) {
            dead.push(format!("  ENUM_ALIASES: `{swift}` no longer pairs with `{rust}`"));
        }
    }

    if !dead.is_empty() {
        report.fail(format!(
            "a declared entry no longer names anything —\n{}\nEach of these lists exists to change what a \
             pass DOES about one named pair, and an entry that matched nothing this run changed nothing. \
             Delete the entry, or repoint it. If you believe the pair still exists, the belief is what is \
             out of date.",
            dead.join("\n")
        ));
    }
    report
}

/// The probe reads at least as much as the builder is willing to cap
///
/// Ported from the deleted `check-supervisor.sh`, and it is the one pair in this file whose rule is
/// an INEQUALITY rather than an equality — which is why it could not be a [`Claim`] and is written
/// out.
///
/// `slopdesk-probe`'s `MAX_OPAQUE_READ_BYTES` is how much of a `git diff` (or any opaque payload)
/// it will read off the wire; `slopdesk-hostserver`'s `MAX_OPAQUE_PAYLOAD_BYTES` is the ceiling the
/// reducer trims to. The trim only fires if the reducer is HANDED more than its cap, so the probe
/// must read at least that much for the trim to see `len > max`, cut, and set its "was truncated"
/// flag.
///
/// Lower the Rust number alone and the builder never sees an over-long payload, so it never trims
/// and never flags — the client renders a SILENTLY SHORT `git diff` as if it were the whole thing.
/// Raise it alone and a pathological diff spikes per-request memory before any cap applies. Neither
/// is a crash and neither is visible from one side.
///
/// Both sides are Rust since `docs/60` F.9, and `slopdesk-hostserver` LINKS `slopdesk-probe` — so
/// the usual discriminator would retire this rule. It does not, because the contract is not "is
/// this the same value" but "is this one at least that one", and no compiler compares two
/// constants that never meet in an expression. `docs/DECISIONS.md` recorded the arrangement as
/// Swift-only, before either side was Rust — the record went stale rather than the design going
/// wrong.
///
/// There used to be a THIRD spelling, `HostMetadataProbe.maxCaptureBytes`, deliberately outside
/// this rule: the stop condition on hostd's own `lsof` drain, the same number asking a different
/// question. It is gone — the pane census is `rust/slopdesk-panecensus` and its port scan rides
/// `slopdesk_probe::run::capture`, so the drain that had its own ceiling now shares this one.
///
/// [`Claim`]: crate::claim::Claim
#[must_use]
pub fn the_opaque_cap_carries_its_inequality(tree: &Tree) -> Report {
    /// Where the probe declares how much it will read.
    const PROBE: (&str, &str) = (
        "rust/slopdesk-probe/src/run.rs",
        r"MAX_OPAQUE_READ_BYTES: usize = ([0-9 *+]+);",
    );
    /// Where the host declares what it trims to.
    const REDUCER: (&str, &str) = (
        "rust/slopdesk-hostserver/src/metadata.rs",
        r"MAX_OPAQUE_PAYLOAD_BYTES: usize = ([0-9 *+]+);",
    );

    let mut report = Report::new();
    // Both sides are read even when the first is unreadable, so the diagnostic names every side
    // that has gone quiet rather than the first one.
    let read = |(path, pattern): (&'static str, &'static str), report: &mut Report| {
        report
            .source(tree, path, "one side of the opaque cap lives there")
            .and_then(|source| text::capture_first(&source.text, pattern))
            .and_then(|written| numeric(&written).map(|value| (written, value)))
    };
    let probe = read(PROBE, &mut report);
    let reducer = read(REDUCER, &mut report);
    let (Some((probe_written, probe_value)), Some((builder_written, builder_value))) = (probe, reducer)
    else {
        report.fail(
            "the opaque cap could not be read from both sides — this rule stopped checking anything \
             (docs/55 §8)"
                .to_owned(),
        );
        return report;
    };

    report.fail_if(
        probe_value < builder_value,
        format!(
            "slopdesk-probe reads {probe_written} ({}) but slopdesk-hostserver's metadata reducer caps at \
             {builder_written} ({}) — the probe must read at least the cap, or the truncation flag never \
             fires and the client renders a silently short payload as the whole thing (docs/55 §8)",
            shown(probe_value),
            shown(builder_value)
        ),
    );
    report
}
#[cfg(test)]
mod tests {
    use super::{Declaration, declarations, discriminants, numeric, ordinal_shims, shown};
    use crate::tests::Fixture;

    /// The inequality is DIRECTIONAL, so the break-test has to seed the skew that is silent rather
    /// than any skew: the reducer's cap raised above what the probe will ever hand it, which stops
    /// the trim from ever seeing an over-long payload and so stops the truncation flag from firing.
    #[test]
    fn a_reducer_capping_above_what_the_probe_reads_is_red() {
        let fixture = Fixture::new("opaque-cap-inequality");
        fixture
            .write(
                "rust/slopdesk-probe/src/run.rs",
                "pub const MAX_OPAQUE_READ_BYTES: usize = 15 * 1024 * 1024;\n",
            )
            .write(
                "rust/slopdesk-hostserver/src/metadata.rs",
                "pub const MAX_OPAQUE_PAYLOAD_BYTES: usize = 15 * 1024 * 1024;\n",
            );
        assert!(super::the_opaque_cap_carries_its_inequality(&fixture.tree()).is_clean());

        // Reading MORE than the cap is the safe direction and stays green — the trim fires, which
        // is the whole point of the slack.
        fixture.write(
            "rust/slopdesk-probe/src/run.rs",
            "pub const MAX_OPAQUE_READ_BYTES: usize = 32 * 1024 * 1024;\n",
        );
        assert!(super::the_opaque_cap_carries_its_inequality(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostserver/src/metadata.rs",
            "pub const MAX_OPAQUE_PAYLOAD_BYTES: usize = 64 * 1024 * 1024;\n",
        );
        let report = super::the_opaque_cap_carries_its_inequality(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("must read at least the cap")),
            "{report:?}"
        );
    }

    /// A side that stops being readable must FAIL, not pass vacuously — the failure mode of every
    /// gate keyed to a path is that the path moves and the comparison quietly stops happening.
    #[test]
    fn a_cap_that_cannot_be_read_from_both_sides_is_red() {
        let fixture = Fixture::new("opaque-cap-unreadable");
        fixture.write(
            "rust/slopdesk-probe/src/run.rs",
            "pub const MAX_OPAQUE_READ_BYTES: usize = 15 * 1024 * 1024;\n",
        );
        let report = super::the_opaque_cap_carries_its_inequality(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("stopped checking anything")),
            "{report:?}"
        );
    }

    /// The one judgement in the evaluator: `<<` mixed with arithmetic means two different numbers
    /// in the two languages, so it means none here.
    #[test]
    fn a_shift_mixed_with_arithmetic_refuses_to_answer() {
        assert_eq!(numeric("15 * 1024 * 1024"), Some(15_728_640.0));
        assert_eq!(numeric("1 << 20"), Some(1_048_576.0));
        assert_eq!(numeric("2 * 3 + 4"), Some(10.0));
        assert_eq!(numeric("0x10"), Some(16.0));
        assert_eq!(numeric("0b1010"), Some(10.0));
        assert_eq!(numeric("1 << 2 + 3"), None);
    }

    #[test]
    fn a_byte_count_prints_as_a_byte_count() {
        assert_eq!(shown(15_728_640.0), "15728640");
        assert_eq!(shown(0.5), "0.5");
    }

    /// A nested enum's cases are not its parent's — the failure that read six alphabets as one.
    #[test]
    fn a_nested_enum_keeps_its_own_cases() {
        let text = "public enum Outer {\n    public enum Inner: UInt8 {\n        case a = 1\n        case b \
                    = 2\n    }\n}\n";
        let found = declarations(text, super::SWIFT_ENUM);
        assert_eq!(found.len(), 2);
        assert!(discriminants(&found[0], false).is_empty());
        assert_eq!(discriminants(&found[1], false).len(), 2);
    }

    /// Without an integer raw type there is no `rawValue`, so a position is not a number anybody
    /// can observe — and a gate reporting one would be reporting on typing order.
    #[test]
    fn an_unnumbered_swift_enum_is_read_only_when_it_has_a_raw_type() {
        let numbered = "enum A: UInt8 {\n    case one\n    case two\n}\n";
        let bare = "enum A {\n    case one\n    case two\n}\n";
        assert_eq!(
            discriminants(&declarations(numbered, super::SWIFT_ENUM)[0], false).len(),
            2
        );
        assert!(discriminants(&declarations(bare, super::SWIFT_ENUM)[0], false).is_empty());
    }

    /// A payload voids the numbering outright: every position after it is a fiction.
    #[test]
    fn a_payload_case_voids_the_numbering() {
        let text = "enum A: UInt8 {\n    case one\n    case two(String)\n}\n";
        assert!(discriminants(&declarations(text, super::SWIFT_ENUM)[0], false).is_empty());
    }

    /// `Self::` used to file every shim in the tree under an enum literally named `Self`.
    #[test]
    fn a_self_qualified_shim_is_filed_under_its_impl() {
        let text =
            "impl ChannelState {\n    const fn ordinal(self) -> u8 {\n        match self {\n\x20           \
             Self::Idle => 0,\n            Self::Open => 1,\n        }\n    }\n}\n";
        let found = ordinal_shims(text);
        assert!(found.contains_key("ChannelState"), "{found:?}");
        assert_eq!(found["ChannelState"][0].len(), 2);
    }

    /// An arm may NAME its byte, which is how a protocol whose bytes have names writes it.
    #[test]
    fn an_arm_may_name_its_byte_through_a_local_constant() {
        let text = "pub(super) const COLLAPSE_PANELS: u8 = 7;\nimpl Bodiless {\n    fn type_byte(self) \
                    -> u8 {\n        match self {\n            Self::Collapse => kind::COLLAPSE_PANELS,\n\
                    \x20       }\n    }\n}\n";
        let found = ordinal_shims(text);
        assert!(super::same(found["Bodiless"][0]["collapse"], 7.0));
    }

    /// A `}` between two arms ends the block, so one map's arm cannot satisfy the other's.
    #[test]
    fn a_brace_between_two_arms_starts_a_second_block() {
        let text = "impl A {\n    fn to(self) -> u8 {\n        match self {\n            Self::X => \
                    1,\n\x20       }\n    }\n    fn from(v: u8) -> Self {\n        match v {\n            \
                    Self::Y => 2,\n        }\n    }\n}\n";
        assert_eq!(ordinal_shims(text)["A"].len(), 2);
    }

    #[test]
    fn a_repr_is_what_makes_an_unnumbered_rust_enum_readable() {
        let held = Declaration {
            name: "A".to_owned(),
            header: String::new(),
            attributes: "#[repr(u8)]".to_owned(),
            body: "\n    One,\n    Two,\n".to_owned(),
        };
        assert_eq!(discriminants(&held, true).len(), 2);
        let bare = Declaration {
            attributes: String::new(),
            ..held
        };
        assert!(discriminants(&bare, true).is_empty());
    }
}
