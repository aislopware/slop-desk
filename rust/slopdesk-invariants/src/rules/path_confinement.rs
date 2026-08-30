//! One answer to "is this path inside that root", and it is lexical.
//!
//! Ported from the deleted `check-supervisor.sh`. Three Swift implementations of this predicate
//! existed at once, each spelled differently, and the two that were wrong were wrong in ways no
//! test in their own file could see. `rust/slopdesk-probe/src/path_confine.rs` is the rule now.
//! Every arm below is either "no second opinion grew back" or "the one that exists is still
//! reachable" — together they are the only durable evidence the port happened, because all three of
//! the deleted versions compiled and all three passed their own tests while disagreeing with each
//! other.

use crate::claim::{Claim, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The one file that holds the rule.
const PROBE_HOME: &str = "rust/slopdesk-probe/src/path_confine.rs";
/// The one process that enforces it — every metadata verb naming a path goes through this reducer.
const METADATA_REDUCER: &str = "rust/slopdesk-hostserver/src/metadata.rs";
/// The one file that decides what a mux type byte MEANS, and refuses the ones it does not know.
const MUX_ENVELOPE_RUST: &str = "rust/slopdesk-wire/src/mux/envelope.rs";

/// No Swift file decides about a `..` component, and none tests containment with a prefix
///
/// Two bans and a pair of tombstones, and they are one rule because they are one predicate seen
/// from four sides.
///
/// A Swift file deciding for itself whether a path contains `..` is exactly what the three deleted
/// implementations each spelled differently. `PathConfinement` is the only Swift that may hold an
/// opinion about a path component, and it holds it by asking Rust.
///
/// `CodeBridgeServer.contains` was `path.hasPrefix(root)`, which treats `/a/repo-evil` as a child
/// of `/a/repo` unless a separator guard is bolted on beside it, and which says nothing at all
/// about `..`. A containment answer that is a string comparison is a bug whose next reader will
/// assume the guard is somewhere.
///
/// `pathComponents`/`isWithin([String],root:)` were the decoder's own splitter and prefix match,
/// and a `contains(root:path:)` with a BODY is the bridge's string test coming back. The last of
/// those is a WINDOW rather than a line — the signature and the `hasPrefix` under it only mean
/// something together — which is why it is a file-level ban with a multi-line pattern.
#[must_use]
pub fn no_second_path_opinion_in_swift(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            pattern: r#"containsTraversal|contains\("\.\."\)|hasPrefix\("\.\./"\)|== "\.\."|components\(\).*"\.\.""#,
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "a Swift file is deciding about a '..' component itself ({files}) — path confinement \
                      is slopdesk_path_confine's answer alone (rust/slopdesk-probe/src/path_confine.rs)",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            pattern: r"\.hasPrefix\((root|projectRoot|cwd|folder|workspaceRoot)\b",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "a Swift file is testing containment with hasPrefix ({files}) — use \
                      PathConfinement.isWithin, which is component-wise and refuses '..'",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            pattern: r"static func (pathComponents|isWithin)\(_ ",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "MetadataResponseBuilder's own path splitter/prefix match is back ({files}) — the rule \
                      is rust/slopdesk-probe/src/path_confine.rs",
        },
        Claim::NoFileUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            // The `grep -A3` window: the signature, then the string test under it.
            pattern: r"func contains\(root:[^\n]*\n?[^\n]*\n?[^\n]*\n?[^\n]*hasPrefix",
            rescued_by: None,
            view: View::Raw,
            exempt: &[],
            message: "CodeBridgeServer.contains has a body again ({files}) — it must forward to \
                      PathConfinement.isWithin",
        },
    ])
}

/// The rule stays LEXICAL, and it has exactly one home
///
/// Someone "fixing" the documented symlink residual with `canonicalize` is not a fix, and the
/// module says why at length: it needs the path to EXIST (so a missing file becomes a refusal
/// rather than a clean not-found), it refuses legitimate paths whose ROOT is itself a symlink
/// (`/tmp` on macOS), and it still loses to a symlink swap between the check and the open. Changing
/// this is a design decision, not a patch, and it must not arrive as a one-line diff.
///
/// Comment lines are excluded, because the module's own prose names `canonicalize` several times to
/// say why it is NOT used, and a ban that fires on its own rationale is a ban that gets deleted.
///
/// The second arm is the home. `path_confine` is reached two ways — the probe calls it directly,
/// hostd calls it through the door — and both must land on the same file, so every crate under
/// `rust/` except the probe and the shim is barred from declaring the two functions. Floored by
/// asserting the home still declares them: a ban over a renamed file passes silently, and this one
/// exists precisely because the predicate has been re-derived three times already.
#[must_use]
pub fn the_confinement_rule_is_lexical_and_singular(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::NoneUnder {
            roots: &["rust/slopdesk-probe/src/"],
            extensions: &["rs"],
            pattern: r"canonicalize",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "slopdesk-probe reached for canonicalize ({files}) — path confinement is LEXICAL on \
                      purpose; see the 'residual' section of rust/slopdesk-probe/src/path_confine.rs before \
                      changing it",
        },
        Claim::NoneUnder {
            roots: &["rust/"],
            extensions: &["rs"],
            pattern: r"fn (confine|is_confinable_absolute)\(",
            all: &[],
            unless: &[],
            view: View::Code,
            // The second entry is this crate, and it is the one exemption that is about the gate
            // rather than the rule: a break-test for this ban has to SPELL the thing banned, so
            // a tree-wide `rust/` ban that did not stand aside for the fixtures would fire on
            // its own proof. Scoped to the crate directory rather than to this file, because
            // the next such ban's fixtures will live in a sibling module.
            //
            // The shim used to be exempt beside the home, because it forwarded. `docs/60` F.9
            // deleted it: hostd was the door's only caller, and no Swift links the rule now.
            exempt: &[PROBE_HOME, "rust/slopdesk-invariants/"],
            message: "path confinement grew a second home ({files}) — it lives in \
                      rust/slopdesk-probe/src/path_confine.rs, and every caller asks it",
        },
        Claim::Matches {
            path: PROBE_HOME,
            pattern: r"fn (confine|is_confinable_absolute)\(",
            view: View::Code,
            message: "the one home no longer declares the rule — the ban beside this would then be a ban \
                      over nothing",
        },
    ])
}

/// The rule is reachable from the one process that enforces it
///
/// This used to be about the DOOR: `slopdesk-gate ffi` checks every declared symbol against every
/// slice, so all that was left for a rule was the case it cannot see — a module that exists and is
/// not exported, which fails as a LINK error in the app rather than in the gate.
///
/// `docs/60` F.9 removed the door instead. hostd was its only caller, so the shim module, its two
/// entries and the header block went with the daemon, and the confinement rule is now reached the
/// way every other one is: `rust/slopdesk-hostserver/src/metadata.rs` imports
/// `slopdesk_probe::path_confine` and every metadata verb that names a path goes through it.
///
/// What survives is the same question one level up. `slopdesk-gate ffi` cannot see this either: a
/// reducer that stopped importing the module would compile the moment somebody inlined a
/// `starts_with`, and the ban beside this rule catches the inlining only in a file that still
/// spells `confine`. So the IMPORT is pinned — it is the evidence that the arm exists at all.
#[must_use]
pub fn the_confinement_door_is_reachable(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: METADATA_REDUCER,
            pattern: r"use slopdesk_probe::path_confine",
            view: View::Code,
            message: "rust/slopdesk-hostserver/src/metadata.rs no longer imports the confinement rule — \
                      every metadata verb that names a path goes through it, and three Swift \
                      implementations of this predicate once compiled and passed while disagreeing with \
                      each other",
        },
        // The CALL, not the import: `use slopdesk_probe::path_confine::{self, Shape}` spells
        // `path_confine::` on its own line, so a bare-module pattern would stay green over a
        // reducer that kept the import and inlined a `starts_with` under it.
        Claim::Matches {
            path: METADATA_REDUCER,
            pattern: r"path_confine::(confine|is_confinable_absolute)\(",
            view: View::Code,
            message: "rust/slopdesk-hostserver/src/metadata.rs imports the confinement rule and never asks \
                      it — a live import over an inlined `starts_with` is what the three deleted Swift \
                      implementations each looked like from inside their own file",
        },
    ])
}

/// The mux-type VOCABULARY is asked once, and a byte outside it is REFUSED
///
/// A `default:` arm answering a frame for a type byte nobody accepted used to answer
/// `.windowAdjust`, which is flow-control CREDIT: had the two type lists stopped agreeing, an
/// unrecognised byte would have granted a peer a send window out of a struct field nothing filled.
///
/// ## The mirror is gone; the refusal is not
///
/// This rule used to be a PAIR — `MuxEnvelope.swift` doing a `MuxFrameType(rawValue:
/// flat.mux_type)` lookup with a refusal behind it, mirroring `unpack` in `slopdesk-ffi`'s
/// `mux_envelope.rs`. `docs/63` §G.3 deleted both: the near-side rebuild went with the Swift client
/// mux, and the FFI module went with it because what crosses the boundary is a decoded MESSAGE
/// rather than a frame, so no `mux_type` reaches Swift at all. The decision moved WHOLE into
/// `slopdesk_wire::mux::envelope`, which is where it was always made.
///
/// So both anchors move to that file, and both halves of the refusal are pinned separately:
/// `MuxFrameType::from_byte` answering `None` for a byte outside the list, and the decoder actually
/// ROUTING through it rather than reading the byte itself. The second is the one a rewrite loses —
/// a `match type_byte { 4 => …, _ => … }` inlined at the decode site is the `default:` arm coming
/// back one language over, and it type-checks.
///
/// Pinned POSITIVELY, because banning a wildcard arm in the file would also ban the legitimate ones
/// and a pattern ban can see a shape but never an intent. The Swift half is not re-aimed here:
/// there is no Swift left that could answer, and `deleted_client_swift` is what keeps it that way.
#[must_use]
pub fn an_unknown_mux_type_is_refused(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: MUX_ENVELOPE_RUST,
            pattern: r"_ => None",
            view: View::Raw,
            message: "MuxFrameType::from_byte stopped refusing an unknown type — a byte outside the list \
                      that decodes to SOMETHING is a peer choosing which arm this host runs (docs/20 §4)",
        },
        Claim::Matches {
            path: MUX_ENVELOPE_RUST,
            pattern: r"MuxFrameType::from_byte\(type_byte\)",
            view: View::Raw,
            message: "the mux decoder stopped asking from_byte for the type — a match on the raw byte at \
                      the decode site is the refused-arm question answered a second time, in the one place \
                      that can act on the answer (docs/20 §4)",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    #[test]
    fn a_second_swift_path_opinion_is_red() {
        let fixture = Fixture::new("confine-swift");
        fixture
            .write(
                "Sources/SlopDeskHost/CodeBridgeServer.swift",
                "    static func contains(root: String, path: String) -> Bool {\n\x20       \
                 PathConfinement.isWithin(root: root, path: path)\n\x20   }\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Metadata/MetadataResponseBuilder.swift",
                "let ok = PathConfinement.isWithin(root: root, path: path)\n",
            );
        assert!(super::no_second_path_opinion_in_swift(&fixture.tree()).is_clean());

        // The predicate re-derived, which is what all three deleted versions did.
        fixture.write(
            "Sources/SlopDeskClientCore/Metadata/MetadataResponseBuilder.swift",
            "let ok = !path.contains(\"..\")\n",
        );
        assert!(!super::no_second_path_opinion_in_swift(&fixture.tree()).is_clean());

        // A containment answer that is a string comparison: `/a/repo-evil` is not in `/a/repo`.
        fixture.write(
            "Sources/SlopDeskClientCore/Metadata/MetadataResponseBuilder.swift",
            "let ok = path.hasPrefix(root)\n",
        );
        assert!(!super::no_second_path_opinion_in_swift(&fixture.tree()).is_clean());

        // And the bridge's body coming back — the signature and the test under it, together.
        fixture.write(
            "Sources/SlopDeskClientCore/Metadata/MetadataResponseBuilder.swift",
            "let ok = PathConfinement.isWithin(root: root, path: path)\n",
        );
        fixture.write(
            "Sources/SlopDeskHost/CodeBridgeServer.swift",
            "    static func contains(root: String, path: String) -> Bool {\n\x20       path.hasPrefix(root \
             + \"/\")\n\x20   }\n",
        );
        assert!(!super::no_second_path_opinion_in_swift(&fixture.tree()).is_clean());
    }

    /// The one home.
    fn homes(fixture: &Fixture) {
        fixture.write(
            super::PROBE_HOME,
            "// `canonicalize` is NOT used: it needs the path to exist.\npub fn confine(root: &Path, path: \
             &Path) -> Option<PathBuf> { None }\npub fn is_confinable_absolute(path: &Path) -> bool { true \
             }\n",
        );
    }

    #[test]
    fn a_second_confinement_home_is_red() {
        let fixture = Fixture::new("confine-home");
        homes(&fixture);
        // The module's prose names `canonicalize` to say why it is not used.
        assert!(super::the_confinement_rule_is_lexical_and_singular(&fixture.tree()).is_clean());

        fixture.write(
            super::PROBE_HOME,
            "pub fn confine(root: &Path, path: &Path) -> Option<PathBuf> { path.canonicalize().ok() }\npub \
             fn is_confinable_absolute(path: &Path) -> bool { true }\n",
        );
        assert!(!super::the_confinement_rule_is_lexical_and_singular(&fixture.tree()).is_clean());

        // A third crate growing its own.
        homes(&fixture);
        fixture.write(
            "rust/slopdesk-dropd/src/paths.rs",
            "fn confine(root: &Path, path: &Path) -> Option<PathBuf> { None }\n",
        );
        assert!(!super::the_confinement_rule_is_lexical_and_singular(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_home_that_stopped_declaring_the_rule_is_red() {
        // A ban over a renamed home passes silently, so the home is floored; its own fixture,
        // because writes accumulate.
        let fixture = Fixture::new("confine-home-gone");
        fixture.write(super::PROBE_HOME, "// the rule moved somewhere\n");
        assert!(!super::the_confinement_rule_is_lexical_and_singular(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_reducer_that_stopped_reaching_the_rule_is_red() {
        let fixture = Fixture::new("confine-reach");
        fixture.write(
            super::METADATA_REDUCER,
            "use slopdesk_probe::path_confine::{self, Shape};\nfn open(path: &str) -> Option<PathBuf> {\n \
             path_confine::confine(&self.root, Path::new(path))\n}\n",
        );
        assert!(super::the_confinement_door_is_reachable(&fixture.tree()).is_clean());

        // A `starts_with` inlined where the call was. The ban above sees a file that spells
        // `confine`; this sees the file that stopped.
        fixture.write(
            super::METADATA_REDUCER,
            "fn open(path: &str) -> Option<PathBuf> {\n    path.starts_with(&self.root).then(...)\n}\n",
        );
        assert!(!super::the_confinement_door_is_reachable(&fixture.tree()).is_clean());

        // And the half a stale import would leave green: the module named, never asked.
        fixture.write(
            super::METADATA_REDUCER,
            "use slopdesk_probe::path_confine::{self, Shape};\nfn open(path: &str) -> Option<PathBuf> {\n \
             path.starts_with(&self.root).then(...)\n}\n",
        );
        assert!(!super::the_confinement_door_is_reachable(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_unrecognised_mux_byte_that_is_answered_is_red() {
        let fixture = Fixture::new("confine-mux");
        let refuses = "pub const fn from_byte(byte: u8) -> Option<Self> { match byte { 1 => \
                       Some(Self::Data), _ => None } }\nlet Some(mux_type) = \
                       MuxFrameType::from_byte(type_byte) else { return Err(()) };\n";
        fixture.write(super::MUX_ENVELOPE_RUST, refuses);
        assert!(super::an_unknown_mux_type_is_refused(&fixture.tree()).is_clean());

        // The vocabulary answering rather than refusing — the shape that granted a send window out
        // of a struct field nothing filled.
        fixture.write(
            super::MUX_ENVELOPE_RUST,
            "pub const fn from_byte(byte: u8) -> Self { match byte { 1 => Self::Data, _ => \
             Self::WindowAdjust } }\nlet mux_type = MuxFrameType::from_byte(type_byte);\n",
        );
        assert!(!super::an_unknown_mux_type_is_refused(&fixture.tree()).is_clean());

        // And the decode site reading the raw byte itself, with the vocabulary left intact beside
        // it — the `default:` arm coming back one language over, in the one place that can
        // act on it.
        fixture.write(
            super::MUX_ENVELOPE_RUST,
            "pub const fn from_byte(byte: u8) -> Option<Self> { match byte { 1 => Some(Self::Data), _ => \
             None } }\nlet mux_type = match type_byte { 1 => Data, _ => WindowAdjust };\n",
        );
        assert!(!super::an_unknown_mux_type_is_refused(&fixture.tree()).is_clean());
    }
}
