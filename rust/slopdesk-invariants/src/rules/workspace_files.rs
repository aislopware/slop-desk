//! The two files a workspace leaves behind, the solvers that read them, and the bytes their enums
//! cross as.
//!
//! Ported from the deleted `check-supervisor.sh`. Three rules that share one subject: what the app
//! writes to disk, who decides its shape, and how the four enums that ride the wire are numbered.
//!
//! The middle one is here because of a defect that no test could see. `SplitNode+Codable.swift` was
//! 273 lines of Swift beside `slopdesk-workspace`'s `persist`, which had been a finished port with
//! no caller — and the two did not merely duplicate, they DISAGREED: for a divider the file does
//! not name, Rust derives the `SplitNodeId` from the seam's position while the Swift decoder minted
//! a fresh UUID. Every launch renamed every seam, and every remembered divider position was lost.
//! Nothing crashed; the arrangement just kept resetting.

use crate::claim::{ByteMap, Claim, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The face over the state file's door.
const STATE_FACE: &str = "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift";
/// The rule and its refusal taxonomy, in one place.
const STATE_RULE: &str = "rust/slopdesk-wire/src/document/state_file.rs";

/// The face over the workspace file's door.
const FILE_FACE: &str = "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceFile.swift";
/// The store beneath it.
const FILE_STORE: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspacePersistence.swift";
/// The rule, its derivation and its taxonomy.
const FILE_RULE: &str = "rust/slopdesk-workspace/src/persist.rs";
/// The hand-written header that is the ABI.
const HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
/// Where the solvers' faces live.
const DOMAIN: &str = "Sources/SlopDeskWorkspaceModel/Domain";

/// One answer to "may this cell touch the disk"
///
/// The predicate is the filter, the two codecs are the file's bytes, and the status probe is the
/// taxonomy. Dropping any of the four doors is a decision coming back to this side: a transcribed
/// refusal byte that drifted on one arm turns a corrupt row into a mint-the-default, and the file
/// nobody kept aside is the one nobody can look at.
///
/// What a marshaller cannot have: an encoder of its own is the whole file coming back; a version
/// literal is the no-migration rule spelled twice, where the smaller number refuses files the other
/// happily writes; a base64 call is the row codec; a pane-field name is the filter itself.
///
/// No claim here reads prose: the ban is [`View::Code`] so that naming what moved stays legible,
/// and the two positive halves read `statements()` so that naming it cannot ANSWER for it — only
/// code can re-implement a boundary, and only code may say it still calls one.
///
/// BREAK-TEST: dropped `slopdesk_ws_state_file_status` from the face ⇒ FAIL "stopped asking".
/// Separately wrote `JSONEncoder()` into it ⇒ FAIL "decides something again". Separately deleted
/// `VersionMismatch(i64)` from the crate ⇒ FAIL "the rule and its taxonomy are one place". All
/// three restored from /tmp; PASS.
#[must_use]
pub fn one_answer_to_what_survives_a_restart(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Doors {
            path: STATE_FACE,
            entries: &[
                "slopdesk_ws_state_file_is_persisted",
                "slopdesk_ws_state_file_encode",
                "slopdesk_ws_state_file_decode",
                "slopdesk_ws_state_file_status",
            ],
            message: "WorkspaceStateFile stopped asking {entry} — one answer to what survives a restart \
                      (docs/55 §6)",
        },
        Claim::Lacks {
            path: STATE_FACE,
            pattern: r"JSONEncoder|JSONDecoder|base64Encoded|version *= *[0-9]|WorkspacePaneField\.|WorkspaceProjectField\.",
            view: View::Code,
            message: "WorkspaceStateFile decides something again — it marshals, and rust/slopdesk-wire's \
                      state_file rules (docs/55 §6)",
        },
        Claim::Mentions {
            path: STATE_RULE,
            names: &[
                "pub fn is_persisted",
                "pub fn persisting",
                "pub fn encode",
                "pub fn decode_bytes",
                "const fn code",
                "Malformed,",
                "VersionMismatch(i64)",
                "MalformedRow,",
            ],
            message: "rust/slopdesk-wire/src/document/state_file.rs lost {entry} — the rule and its \
                      taxonomy are one place, so the door cannot be a shim over a shim (docs/55 §6)",
        },
    ])
}

/// One answer to "what arrangement did I leave"
///
/// The Swift half is deleted, `Codec/WorkspaceFile.swift` is the face, and both halves of that are
/// pinned: the file staying gone, and the face still being a marshaller rather than a decoder
/// growing back under a new name.
///
/// The CONFORMANCE is the re-implementation, however small the body. `Codable` on any of the tree's
/// types is a second encoder for the file by SYNTHESIS alone — and a synthesized one has no
/// derivation, so it brings the divider-renaming defect back exactly as it was. (`PaneKind`,
/// `SplitAxis` and the device-prefs template values stay `Codable` on purpose: those are
/// vocabulary, `docs/55` §8.)
///
/// The pool probe is the load-bearing door: the crate holds no entropy, so a caller that stopped
/// asking how many ids a file needs would hand it a pool that runs dry, and a dry pool REPEATS —
/// two panes with one id, which the repair then re-mints apart on every single load. That is the
/// divider defect again, wearing the pane's clothes.
///
/// `derived_split_id` is named on the far side because it is the defect's actual fix: delete it and
/// both languages agree again, on the wrong answer.
///
/// BREAK-TEST: restored `SplitNode+Codable.swift` ⇒ FAIL "is back". Separately wrote
/// `extension SplitNode: Codable` under Sources/ ⇒ FAIL "conforms to Codable again". Separately
/// dropped `slopdesk_ws_workspace_file_minted_ids` from the header ⇒ FAIL "does not declare".
/// Separately wrote `JSONEncoder()` into `WorkspacePersistence` ⇒ FAIL "decides the file's shape
/// again". All four restored from /tmp; PASS.
#[must_use]
pub fn one_answer_to_the_saved_arrangement(tree: &Tree) -> Report {
    /// The five doors the face and the header must both carry.
    const DOORS: &[&str] = &[
        "slopdesk_ws_workspace_file_minted_ids",
        "slopdesk_ws_workspace_file_encode",
        "slopdesk_ws_workspace_file_decode",
        "slopdesk_ws_workspace_file_status",
        "slopdesk_ws_workspace_file_max_panes",
    ];
    check_all(tree, &[
        Claim::Absent {
            path: "Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitNode+Codable.swift",
            message: "the workspace file's rule is rust/slopdesk-workspace's persist, and this file's \
                      decoder minted a fresh id for every unnamed divider — every launch renamed every seam \
                      (docs/55 §6)",
        },
        Claim::Exists {
            path: FILE_FACE,
            message: "the workspace file's door has no Swift face, so every ban about it stopped checking \
                      anything (docs/55 §6)",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(struct|private struct) (RawWeightedChild|SpecEntry)\b|func (decodeRaw|decodeChildren|rawNode)\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift workspace-file decoder is back in Swift — the tree's JSON lives in \
                      rust/slopdesk-workspace (docs/55 §6): {files}",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"\b(SplitNode|WeightedChild|SplitWeight|TreeWorkspace|DetachedPane|PaneSpec|VideoEndpoint|Session|Tab)\b *: *(any )?(Codable|Decodable|Encodable)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a workspace tree type conforms to Codable again — one encoder, and it is \
                      persist::encode_file; a SYNTHESIZED one has no derivation, so it brings the \
                      divider-renaming defect back exactly as it was (docs/55 §6): {files}",
        },
        Claim::Doors {
            path: FILE_FACE,
            entries: DOORS,
            message: "WorkspaceFile stopped asking {entry} — one answer to the saved arrangement (docs/55 \
                      §6)",
        },
        Claim::Mentions {
            path: HEADER,
            names: DOORS,
            message: "slopdesk_ffi.h does not declare {entry} — the header is hand-written and it is the \
                      ABI (docs/55 §2)",
        },
        Claim::Lacks {
            path: FILE_FACE,
            pattern: r"JSONEncoder|JSONDecoder|CodingKeys|schemaVersion *= *[0-9]",
            view: View::Code,
            message: "WorkspaceFile decides the file's shape again — it marshals, and \
                      rust/slopdesk-workspace's persist rules (docs/55 §6)",
        },
        Claim::Lacks {
            path: FILE_STORE,
            pattern: r"JSONEncoder|JSONDecoder|CodingKeys|schemaVersion *= *[0-9]",
            view: View::Code,
            message: "WorkspacePersistence decides the file's shape again — the store beneath the face \
                      cannot go back to it either (docs/55 §6)",
        },
        Claim::Mentions {
            path: FILE_RULE,
            names: &[
                "fn derived_split_id",
                "pub fn encode_file",
                "pub fn decode_file",
                "pub fn minted_ids_for",
                "Malformed,",
                "VersionMismatch(i64)",
                "TooManyPanes,",
            ],
            message: "rust/slopdesk-workspace/src/persist.rs lost {entry} — the file's rule and its \
                      taxonomy are one place, and the derivation is the defect's actual fix (docs/55 §6)",
        },
    ])
}

/// The solvers live in Rust, and nothing scans or compares beside them
///
/// Six faces, each of which must still reach the crate. The scanners and comparators a
/// re-implementation would need are banned across the whole domain directory, because the defect
/// they describe does not need a whole solver to come back — one `func sweptHit` beside a face is
/// two answers to where a drag landed.
///
/// `localizedStandardCompare` is on the list because it is the ONE behaviour the port deliberately
/// narrowed: the crate's `natural_compare` does not fold diacritics, so a reappearance here would
/// be a second answer to the sidebar's order rather than a refinement of it. The ban reads
/// [`View::Code`] for that reason — naming the retired collator in a doc comment is how the
/// narrowing stays legible.
///
/// BREAK-TEST: deleted `import CSlopDeskFFI` from `SplitLayoutSolver` ⇒ FAIL "no longer calls the
/// Rust crate". Separately wrote `func depenetrate(` into a file under Domain/ ⇒ FAIL "grew it
/// back". Both restored from /tmp; PASS.
#[must_use]
pub fn the_solvers_live_in_rust(tree: &Tree) -> Report {
    let mut report = Report::new();
    for solver in [
        "Domain/SendKeysParser",
        "Domain/FocusResolver",
        "Domain/Tree/TabOrdering",
        "Domain/Tree/SplitLayoutSolver",
        "Domain/Tree/SplitNode+Ops",
        "Domain/Tree/WorkspaceTreeOps",
    ] {
        let path = crate::text::intern(format!("Sources/SlopDeskWorkspaceModel/{solver}.swift"));
        report.absorb(check_all(tree, &[Claim::Matches {
            path,
            pattern: r"import CSlopDeskFFI",
            view: View::Statements,
            message: crate::text::intern(format!(
                "{path} no longer calls the Rust crate — the port was undone (docs/55 §6)"
            )),
        }]));
    }
    report.absorb(check_all(
        tree,
        &[Claim::NoneUnder {
            roots: &[DOMAIN],
            extensions: SWIFT,
            pattern: r"localizedStandardCompare|func directionalNeighbor|func crossAxisOverlap|func findClose|private static let esc|func moveCandidates|func resolveAxis|struct AxisValues|func depenetrate|func intentArmed|func sweptHit|func splitImpl|func removeImpl|func mergingSameAxis|func shiftWeight|func enclosingSplitImpl|func insertBesideImpl|func evenPair|squareRoot\(\)|sumSizes|positionByID|func flatSplit|func evenChild|private static func tiled",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "Sources/SlopDeskWorkspaceModel grew a solver back — they live in \
                      rust/slopdesk-workspace, and one scanner beside a face is two answers to the \
                      same question (docs/55 §6): {files}",
        }],
    ));
    report
}

/// Every ABI enum maps the same case to the same byte in both languages
///
/// Four of these cross as a BARE DISCRIMINANT, so a case that means 4 on one side and 5 on the
/// other sends focus the wrong way, aligns to the wrong edge or re-tiles into the wrong layout —
/// with every test green, because each side is self-consistent. The other four are wire type bytes,
/// where the same skew is not a decode error at all: it is a frame that decodes cleanly as the
/// WRONG message.
///
/// This compared the COUNT of cases for a long time, which cannot see either failure. A count is
/// blind to a reorder, and blind to a case added correctly to both enums and forgotten in the
/// shim's decoder. The Rust half is checked by the compiler and by a round-trip test per enum
/// (`ALL[i].index() == i`); what NEITHER can reach is Swift's `ffiByte` switch, which is where the
/// number is written for the third time.
///
/// `PaneKind`'s Rust marker is a DOC LINE rather than a signature, because `session.rs` holds two
/// `as_byte` bodies with identical signatures — `PaneKind`'s and `NewTabPosition`'s. That is why
/// the marker's uniqueness is checked rather than assumed: the unlucky version of a duplicated
/// marker was live on 2026-08-22, where the sibling body is `self as u8` and contributes no rows,
/// so the gate stayed green while covering nothing.
///
/// It is ALSO why a [`ByteMap`] takes no view. Every map here used to read raw, which the prose
/// marker seemed to force — and that let a `// Self::Desktop => 1, retired` answer for a wire byte
/// on both sides at once. The anchors and the rows want opposite views, so the range is located on
/// the raw text and read out of `statements()`; the marker may be prose, and a row may not.
///
/// BREAK-TEST: renumbered `case .centerHorizontal` in `WorkspaceTreeOps` ⇒ FAIL "disagree about
/// which byte". Separately spelled `pub const fn ffi_byte(self) -> u8` a second time in
/// `tree_ops.rs` ⇒ FAIL "matches 2 times, not once". Both restored from /tmp; PASS.
#[must_use]
pub fn every_abi_enum_crosses_as_one_byte(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::SameByteMap {
            label: "FocusDirection",
            swift: swift_map(BRIDGE, r"extension FocusDirection"),
            rust: rust_map(
                "rust/slopdesk-tree/src/focus.rs",
                r"pub const fn index\(self\) -> u8",
            ),
        },
        Claim::SameByteMap {
            label: "PaneKind",
            swift: swift_map(BRIDGE, r"extension PaneKind"),
            rust: rust_map(
                "rust/slopdesk-tree/src/session.rs",
                r"The on-wire byte, and the byte a client",
            ),
        },
        Claim::SameByteMap {
            label: "LayoutPreset/TileLayout",
            swift: swift_map(TREE_OPS, r"var ffiByte: UInt8"),
            rust: rust_map(
                "rust/slopdesk-tree/src/tree_ops.rs",
                r"pub const fn index\(self\) -> u8",
            ),
        },
        Claim::SameByteMap {
            label: "RepairPass",
            swift: swift_map(
                "Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift",
                r"var ffiByte: UInt8",
            ),
            rust: rust_map(
                "rust/slopdesk-tree/src/tree_ops.rs",
                r"pub const fn ffi_byte\(self\) -> u8",
            ),
        },
        Claim::SameByteMap {
            label: "WireMessage type byte",
            swift: swift_map(
                "Sources/SlopDeskProtocol/WireMessage.swift",
                r"var messageType: UInt8",
            ),
            rust: rust_map(
                "rust/slopdesk-wire/src/message.rs",
                r"pub const fn message_type\(&self\) -> u8",
            ),
        },
        Claim::SameByteMap {
            label: "VideoControl type byte",
            swift: swift_map(
                "Sources/SlopDeskVideoProtocol/VideoControlCodec.swift",
                r"public var messageType: UInt8",
            ),
            rust: rust_map(
                "rust/slopdesk-video/src/video_control.rs",
                r"pub const fn message_type\(&self\) -> u8",
            ),
        },
        Claim::SameByteMap {
            label: "RecoverySignaling type byte",
            swift: swift_map(
                "Sources/SlopDeskVideoProtocol/RecoverySignaling.swift",
                r"public var messageType: UInt8",
            ),
            rust: rust_map(
                "rust/slopdesk-video/src/recovery.rs",
                r"pub const fn message_type\(&self\) -> u8",
            ),
        },
        Claim::SameByteMap {
            label: "WindowGeometry type byte",
            swift: swift_map(
                "Sources/SlopDeskVideoProtocol/WindowGeometryCodec.swift",
                r"public var messageType: UInt8",
            ),
            rust: rust_map(
                "rust/slopdesk-video/src/window_geometry.rs",
                r"pub const fn message_type\(&self\) -> u8",
            ),
        },
    ])
}

/// The two Swift files that hold more than one of these switches.
const BRIDGE: &str = "Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift";
/// The tree operations, which hold `LayoutPreset`'s.
const TREE_OPS: &str = "Sources/SlopDeskWorkspaceModel/Domain/Tree/WorkspaceTreeOps.swift";

/// `case .centerHorizontal: 4` — the Swift spelling of one row.
const fn swift_map(path: &'static str, marker: &'static str) -> ByteMap {
    ByteMap {
        path,
        marker,
        end: r"^ *\}",
        pattern: r"case \.([a-zA-Z]+): *([0-9]+)",
    }
}

/// `Self::CenterHorizontal => 4` — the same row, allowing for a struct or tuple payload between the
/// name and the arrow.
const fn rust_map(path: &'static str, marker: &'static str) -> ByteMap {
    ByteMap {
        path,
        marker,
        end: r"^ *\}",
        pattern: r"Self::([A-Za-z]+) *(?:\{[^}]*\}|\([^)]*\))? *=> *([0-9]+)",
    }
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// Two switches that agree, in the two spellings.
    fn enums(fixture: &Fixture, swift: &str, rust: &str) {
        fixture
            .write(super::BRIDGE, swift)
            .write("rust/slopdesk-tree/src/focus.rs", rust);
    }

    const SWIFT_SWITCH: &str = "extension FocusDirection {\n    var ffiByte: UInt8 {\n        switch self \
                                {\n        case .left: 0\n        case .right: 1\n        case \
                                .centerHorizontal: 4\n        }\n    }\n}\n";
    const RUST_SWITCH: &str =
        "impl FocusDirection {\n    pub const fn index(self) -> u8 {\n        match self {\n            \
         Self::Left => 0,\n            Self::Right => 1,\n            Self::CenterHorizontal => 4,\n        \
         }\n    }\n}\n";

    /// The claim a case COUNT is blind to: same number of cases, one of them renumbered.
    #[test]
    fn a_renumbered_case_is_red_even_at_the_same_count() {
        let fixture = Fixture::new("abi-renumber");
        enums(&fixture, SWIFT_SWITCH, RUST_SWITCH);
        let claims = [crate::claim::Claim::SameByteMap {
            label: "FocusDirection",
            swift: super::swift_map(super::BRIDGE, r"extension FocusDirection"),
            rust: super::rust_map(
                "rust/slopdesk-tree/src/focus.rs",
                r"pub const fn index\(self\) -> u8",
            ),
        }];
        assert!(crate::claim::check_all(&fixture.tree(), &claims).is_clean());

        fixture.write(
            super::BRIDGE,
            &SWIFT_SWITCH.replace("case .centerHorizontal: 4", "case .centerHorizontal: 5"),
        );
        let report = crate::claim::check_all(&fixture.tree(), &claims);
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("centerhorizontal=5")),
            "{report:?}"
        );
    }

    /// A marker that matches twice APPENDS the second enum's rows, which is the failure that stays
    /// green when the second body contributes no rows at all.
    #[test]
    fn a_marker_that_lost_its_uniqueness_is_red() {
        let fixture = Fixture::new("abi-marker");
        enums(
            &fixture,
            SWIFT_SWITCH,
            &format!(
                "{RUST_SWITCH}impl NewTabPosition {{\n    pub const fn index(self) -> u8 {{\n        self \
                 as u8\n    }}\n}}\n"
            ),
        );
        let claims = [crate::claim::Claim::SameByteMap {
            label: "FocusDirection",
            swift: super::swift_map(super::BRIDGE, r"extension FocusDirection"),
            rust: super::rust_map(
                "rust/slopdesk-tree/src/focus.rs",
                r"pub const fn index\(self\) -> u8",
            ),
        }];
        let report = crate::claim::check_all(&fixture.tree(), &claims);
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("matches 2 times, not once")),
            "{report:?}"
        );
    }

    /// The conformance is the re-implementation, however small the body.
    #[test]
    fn a_revived_codable_conformance_is_red() {
        let fixture = Fixture::new("ws-codable");
        arrangement(&fixture);
        assert!(super::one_answer_to_the_saved_arrangement(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskWorkspaceModel/Domain/Tree/Tidy.swift",
            "extension SplitNode: Codable {}\n",
        );
        let report = super::one_answer_to_the_saved_arrangement(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("conforms to Codable again")),
            "{report:?}"
        );
    }

    /// The store beneath the face cannot go back to a `JSONEncoder` either.
    #[test]
    fn a_store_that_decides_the_files_shape_is_red() {
        let fixture = Fixture::new("ws-store");
        arrangement(&fixture);
        fixture.write(
            super::FILE_STORE,
            "func save() {\n    let data = try JSONEncoder().encode(tree)\n}\n",
        );
        let report = super::one_answer_to_the_saved_arrangement(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("decides the file's shape again")),
            "{report:?}"
        );
    }

    /// A face that stopped asking the pool probe would hand the crate a pool that runs dry.
    #[test]
    fn a_face_that_stopped_asking_for_minted_ids_is_red() {
        let fixture = Fixture::new("ws-pool");
        arrangement(&fixture);
        fixture.write(
            super::FILE_FACE,
            "func load() {\n    slopdesk_ws_workspace_file_encode(p)\n    \
             slopdesk_ws_workspace_file_decode(p)\n    slopdesk_ws_workspace_file_status(p)\n    \
             slopdesk_ws_workspace_file_max_panes()\n}\n",
        );
        let report = super::one_answer_to_the_saved_arrangement(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("minted_ids")),
            "{report:?}"
        );
    }

    /// Everything the saved-arrangement rule stands on.
    fn arrangement(fixture: &Fixture) {
        fixture
            .write(
                super::FILE_FACE,
                "func load() {\n    slopdesk_ws_workspace_file_minted_ids(p)\n    \
                 slopdesk_ws_workspace_file_encode(p)\n    slopdesk_ws_workspace_file_decode(p)\n    \
                 slopdesk_ws_workspace_file_status(p)\n    slopdesk_ws_workspace_file_max_panes()\n}\n",
            )
            .write(super::FILE_STORE, "func save() {\n    face.write(bytes)\n}\n")
            .write(
                super::HEADER,
                "size_t slopdesk_ws_workspace_file_minted_ids(const uint8_t *p);\nsize_t \
                 slopdesk_ws_workspace_file_encode(const uint8_t *p);\nsize_t \
                 slopdesk_ws_workspace_file_decode(const uint8_t *p);\nsize_t \
                 slopdesk_ws_workspace_file_status(const uint8_t *p);\nsize_t \
                 slopdesk_ws_workspace_file_max_panes(void);\n",
            )
            .write(
                super::FILE_RULE,
                "fn derived_split_id(seam: Seam) -> SplitNodeId {}\npub fn encode_file() {}\npub fn \
                 decode_file() {}\npub fn minted_ids_for() {}\npub enum Refusal {\n    Malformed,\n    \
                 VersionMismatch(i64),\n    TooManyPanes,\n}\n",
            );
    }
}
