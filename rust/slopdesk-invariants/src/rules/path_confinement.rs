//! One answer to "is this path inside that root", and it is lexical.
//!
//! Ported from the deleted `check-supervisor.sh`. Three Swift implementations of this predicate
//! existed at once, each spelled differently, and the two that were wrong were wrong in ways no
//! test in their own file could see. `rust/slopdesk-probe/src/path_confine.rs` is the rule now.
//! Every arm below is either "no second opinion grew back" or "the one that exists is still
//! reachable" — together they are the only durable evidence the port happened, because all three of
//! the deleted versions compiled and all three passed their own tests while disagreeing with each
//! other.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The one file that holds the rule.
const PROBE_HOME: &str = "rust/slopdesk-probe/src/path_confine.rs";
/// The shim that carries it to Swift.
const FFI_HOME: &str = "rust/slopdesk-ffi/src/path_confine.rs";
/// The header Swift links against.
const FFI_HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
/// The shim's own module list.
const FFI_LIB: &str = "rust/slopdesk-ffi/src/lib.rs";
/// The near-side rebuild that must refuse a type byte the door never accepted.
const MUX_ENVELOPE_SWIFT: &str = "Sources/SlopDeskProtocol/Mux/MuxEnvelope.swift";
/// The door it mirrors.
const MUX_ENVELOPE_RUST: &str = "rust/slopdesk-ffi/src/mux_envelope.rs";

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
            roots: &["Sources/"],
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
            roots: &["Sources/"],
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
            roots: &["Sources/"],
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
            roots: &["Sources/"],
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
            // The third entry is this crate, and it is the one exemption that is about the gate
            // rather than the rule: a break-test for this ban has to SPELL the thing banned, so
            // a tree-wide `rust/` ban that did not stand aside for the fixtures would fire on
            // its own proof. Scoped to the crate directory rather than to this file, because
            // the next such ban's fixtures will live in a sibling module.
            exempt: &[PROBE_HOME, FFI_HOME, "rust/slopdesk-invariants/"],
            message: "path confinement grew a second home ({files}) — it lives in \
                      rust/slopdesk-probe/src/path_confine.rs, and the shim only forwards",
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

/// The door is declared where Swift can reach it
///
/// `slopdesk-gate ffi` already checks every declared symbol against every slice, so this only has
/// to catch the case it cannot: a module that exists and is not exported, which fails as a LINK
/// error in the app rather than in the gate. The `pub mod`/header/module trio is what drifts.
#[must_use]
pub fn the_confinement_door_is_reachable(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Mentions {
            path: FFI_HEADER,
            names: &["slopdesk_path_confine", "slopdesk_path_is_confinable_absolute"],
            message: "{entry} is missing from slopdesk_ffi.h — Swift cannot link the confinement rule",
        },
        Claim::Matches {
            path: FFI_LIB,
            pattern: r"^pub mod path_confine;",
            view: View::Raw,
            message: "the shim does not export path_confine — the header promises a symbol the library will \
                      not carry",
        },
    ])
}

/// The mux-type VOCABULARY is asked once, and a byte outside it is REFUSED
///
/// A `default:` arm in the near-side rebuild answers a frame for a type byte the door never
/// accepted. It used to answer `.windowAdjust`, which is flow-control CREDIT: had the two type
/// lists stopped agreeing, an unrecognised byte would have granted a peer a send window out of a
/// struct field nothing filled. `unpack` in `mux_envelope.rs` answers `None` for that input, and
/// the face must answer the same.
///
/// Pinned POSITIVELY — as a `MuxFrameType(rawValue:)` lookup with a refusal behind it — because
/// banning `default:` in the file would also ban the one legitimate `default:` in the verdict
/// switch, and a pattern ban can see a shape but never an intent.
#[must_use]
pub fn an_unknown_mux_type_is_refused(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: MUX_ENVELOPE_SWIFT,
            pattern: r"MuxFrameType\(rawValue: flat\.mux_type\)",
            view: View::Raw,
            message: "the near-side rebuild stopped refusing an unknown mux type — the type list is Rust's",
        },
        Claim::Matches {
            path: MUX_ENVELOPE_RUST,
            pattern: r"_ => None",
            view: View::Raw,
            message: "the mux door stopped refusing an unknown type — the face mirrors it",
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

    /// The one home, and the shim that forwards to it.
    fn homes(fixture: &Fixture) {
        fixture
            .write(
                super::PROBE_HOME,
                "// `canonicalize` is NOT used: it needs the path to exist.\npub fn confine(root: &Path, \
                 path: &Path) -> Option<PathBuf> { None }\npub fn is_confinable_absolute(path: &Path) -> \
                 bool { true }\n",
            )
            .write(
                super::FFI_HOME,
                "pub fn confine(root: &Path, path: &Path) -> Option<PathBuf> { \
                 slopdesk_probe::path_confine::confine(root, path) }\n",
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
    fn a_door_swift_cannot_link_is_red() {
        let fixture = Fixture::new("confine-door");
        fixture
            .write(
                super::FFI_HEADER,
                "bool slopdesk_path_confine(const char *root, const char *path);\nbool \
                 slopdesk_path_is_confinable_absolute(const char *path);\n",
            )
            .write(super::FFI_LIB, "pub mod path_confine;\n");
        assert!(super::the_confinement_door_is_reachable(&fixture.tree()).is_clean());

        // A module that exists and is not exported fails as a LINK error in the app, not here —
        // which is the one case slopdesk-gate ffi cannot catch.
        fixture.write(super::FFI_LIB, "pub mod mux_envelope;\n");
        assert!(!super::the_confinement_door_is_reachable(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_unrecognised_mux_byte_that_is_answered_is_red() {
        let fixture = Fixture::new("confine-mux");
        fixture
            .write(
                super::MUX_ENVELOPE_SWIFT,
                "guard let type = MuxFrameType(rawValue: flat.mux_type) else { return nil }\n",
            )
            .write(
                super::MUX_ENVELOPE_RUST,
                "match byte { 1 => Some(Data), _ => None }\n",
            );
        assert!(super::an_unknown_mux_type_is_refused(&fixture.tree()).is_clean());

        // The lookup dropped for a switch with a `default:` — the shape that granted a send window
        // out of a struct field nothing filled.
        fixture.write(
            super::MUX_ENVELOPE_SWIFT,
            "switch flat.mux_type { case 1: return .data\ndefault: return .windowAdjust }\n",
        );
        assert!(!super::an_unknown_mux_type_is_refused(&fixture.tree()).is_clean());

        // And the door itself answering rather than refusing.
        fixture.write(
            super::MUX_ENVELOPE_SWIFT,
            "guard let type = MuxFrameType(rawValue: flat.mux_type) else { return nil }\n",
        );
        fixture.write(
            super::MUX_ENVELOPE_RUST,
            "match byte { 1 => Some(Data), _ => Some(WindowAdjust) }\n",
        );
        assert!(!super::an_unknown_mux_type_is_refused(&fixture.tree()).is_clean());
    }
}
