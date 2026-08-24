//! The workspace document: its field numbers, its intent verbs, its two reaping rules, and the
//! codec that is a face over `rust/slopdesk-workspace` rather than a second copy of it.
//!
//! Ported from the deleted `check-supervisor.sh`. The SOLVERS moved to Rust and the document's
//! value types stayed Swift on purpose — 262 files import them — so the line is INSIDE the module
//! rather than around it, and every rule here is a per-file question.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;
use crate::vocabulary::{SectionedVocabulary, Vocabulary, agrees, sections_agree};

const SWIFT_TOPOLOGY: &str = "Sources/SlopDeskWorkspaceModel/State/WorkspaceTopology.swift";
const SWIFT_LIVENESS: &str = "Sources/SlopDeskWorkspaceModel/State/PaneLiveness.swift";
const SWIFT_CODEC: &str = "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateCodec.swift";
const SWIFT_INTENT: &str = "Sources/SlopDeskWorkspaceModel/State/WorkspaceIntent.swift";

/// The document's FIELD VOCABULARY, pinned across the two languages.
///
/// `rust/slopdesk-wire/src/document/fields.rs` says it itself: nothing in the codec maps through
/// these constants, every value is length-prefixed, and an unknown byte is kept verbatim. So a
/// field number invented independently on the two ends decodes perfectly cleanly into the WRONG
/// MEANING, and there is no decoder anywhere that would notice. The host writes them and the client
/// reads them; this rule is the only thing standing between those two facts.
#[must_use]
pub fn field_vocabulary(tree: &Tree) -> Report {
    const FIELDS: SectionedVocabulary = SectionedVocabulary {
        label: "the document field vocabulary",
        swift: "Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift",
        swift_section: r"^public enum Workspace([A-Za-z]+)Field \{",
        swift_entry: r"static let ([A-Za-z]+): UInt8 = ([0-9]+)",
        rust: "rust/slopdesk-wire/src/document/fields.rs",
        rust_section: r"^pub mod ([a-z_]+) \{",
        rust_entry: r"pub const ([A-Z_0-9]+): u8 = ([0-9]+);",
        minimum: 40,
        doc: "docs/45 §5.3",
    };

    let mut report = Report::new();
    sections_agree(tree, &mut report, &FIELDS);
    report
}

/// The INTENT verbs, pinned the same way and for the same reason.
///
/// An op byte is the whole of what one end asks the other to do; two ends numbering them
/// differently is a client asking for a rename and a host performing a close.
#[must_use]
pub fn intent_verbs(tree: &Tree) -> Report {
    const INTENT: Vocabulary = Vocabulary {
        label: "intent verbs",
        swift: SWIFT_INTENT,
        swift_pattern: r"case ([a-zA-Z]+) = ([0-9]+)",
        rust: "rust/slopdesk-wire/src/document/intent.rs",
        rust_pattern: r"^\s+([A-Z][A-Za-z]+) = ([0-9]+),",
        minimum: 25,
        doc: "docs/45 §5.3",
    };

    let mut report = Report::new();
    agrees(tree, &mut report, &INTENT);
    // A `u16` in front of a blob must name the bytes that follow it. Both call sites once declared
    // a WRAPPED length and then appended every byte, so a payload past 64 KiB produced a frame that
    // mis-splits at the decoder — `intent::put_blob` clamps and cuts, and its doc comment named the
    // Swift bug rather than fixing it. `appendBlob` is the one spelling now; a bare append of the
    // blob means a second copy has come back.
    //
    // This is the half a vocabulary pin cannot see. The gate above pins the right file pair and
    // compares the right map, and the blob-length bug lived six lines from where it looks for as
    // long as that gate existed — because a vocabulary pin cannot see BEHAVIOUR. Every
    // cross-language defect this project has found is behavioural (`docs/55` §8).
    report.absorb(check_all(tree, &[Claim::Lacks {
        path: SWIFT_INTENT,
        pattern: r"^[[:space:]]*out\.append\(blob\)",
        view: View::Code,
        message: "Sources/SlopDeskWorkspaceModel/State/WorkspaceIntent.swift appends a blob without cutting \
                  it to the declared length — use appendBlob (docs/55 §8)",
    }]));
    report
}

/// The topology's two ring caps, its reserved-root set, and the reaping line — all ASKED, never
/// transcribed.
///
/// The field NUMBERS are compared because both languages have to declare them: a `switch` on a
/// Swift enum needs Swift cases. These are a different thing — they are NUMBERS, nothing switches
/// on them, and the host is what applies them. So they are asked through doors, and what this rule
/// stops is the transcription coming back.
///
/// None of the ways it would drift say anything at the time. A client with the larger cap renders a
/// ring whose tail the host already reaped; one with the smaller hides tabs ⇧⌘T would still reopen;
/// a reserved set one number off DELETES the field it was meant to leave alone. One level up, a
/// reaping predicate that is wider deletes a cell the host persisted and one that is narrower
/// strands a cell nothing will ever clear.
#[must_use]
pub fn topology_and_reaping(tree: &Tree) -> Report {
    let mut report = check_all(tree, &[
        Claim::Matches {
            path: SWIFT_TOPOLOGY,
            pattern: r"slopdesk_ws_topology_ring_cap\(0\)",
            view: View::Code,
            message: "WorkspaceTopology.swift stopped asking slopdesk_ws_topology_ring_cap(0) — a reaping \
                      threshold spelled twice reaps two different rings (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_TOPOLOGY,
            pattern: r"slopdesk_ws_topology_ring_cap\(1\)",
            view: View::Code,
            message: "WorkspaceTopology.swift stopped asking slopdesk_ws_topology_ring_cap(1) — a reaping \
                      threshold spelled twice reaps two different rings (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_TOPOLOGY,
            pattern: r"slopdesk_ws_reserved_root_fields\(",
            view: View::Code,
            message: "WorkspaceTopology.swift stopped asking slopdesk_ws_reserved_root_fields — a reserved \
                      set one number off deletes the field it was meant to leave alone (docs/45 §5.3)",
        },
        Claim::Lacks {
            path: SWIFT_TOPOLOGY,
            pattern: r"closedTabRingCap *= *[0-9]|focusMRUCap *= *[0-9]",
            view: View::Code,
            message: "WorkspaceTopology.swift transcribed a ring cap back — ask \
                      slopdesk_ws_topology_ring_cap (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_TOPOLOGY,
            pattern: r"slopdesk_ws_key_is_topology\(",
            view: View::Code,
            message: "WorkspaceTopology.swift decides isTopology itself — ask slopdesk_ws_key_is_topology \
                      (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_LIVENESS,
            pattern: r"slopdesk_ws_pane_fields\((0|half)",
            view: View::Code,
            message: "PaneLiveness.swift stopped asking slopdesk_ws_pane_fields for the first half — a pane \
                      field on the wrong side of the reaping line deletes a persisted title (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_LIVENESS,
            pattern: r"slopdesk_ws_pane_fields\((1|half)",
            view: View::Code,
            message: "PaneLiveness.swift stopped asking slopdesk_ws_pane_fields for the second half — a \
                      pane field on the wrong side of the reaping line deletes a persisted title (docs/45 \
                      §5.3)",
        },
    ]);

    // A field alone on its line is an ARRAY LITERAL element only when what OPENED it was a bracket,
    // or when the line above it was another such element. A wrapped call argument — which is how
    // the encoder legitimately names one field at a time — sits under a line that opened a paren
    // instead, so the previous line is what tells the two apart.
    if let Some(source) = report.source(tree, SWIFT_LIVENESS, "the reaping halves are asked there") {
        let element = crate::text::cached(r"^ *WorkspacePaneField\.[A-Za-z]+,$");
        let opens = crate::text::cached(r"\[$");
        let mut previous = "";
        let transcribed = source.code().lines().any(|line| {
            let hit = element.is_match(line) && (opens.is_match(previous) || element.is_match(previous));
            previous = line;
            hit
        });
        report.fail_if(
            transcribed,
            "PaneLiveness.swift transcribed a pane-field half back — ask slopdesk_ws_pane_fields (docs/45 \
             §5.3)",
        );
    }
    report
}

/// The scalar codec is a face over `rust/slopdesk-workspace`, and the count-and-length parse is not
/// in it.
///
/// Twelve banned strings, because each is a piece of the parse a wrapper cannot have; thirteen
/// doors that must still be called, because the wrong-width DROP is the codec's safety property and
/// a decoder that stopped asking the crate would be a lenient prefix read nobody notices until a
/// mis-numbered field renders as a plausible value.
///
/// `decode_bool` and `encode_i32` are on the door list for a different reason from the rest. They
/// are not decodes the compiler could miss — they are COMPOSITIONS the near side was making for
/// itself, `decodeU8(data).map { $0 != 0 }` and `encodeU32(UInt32(bitPattern: value))`, beside two
/// crate functions that sat without a caller for a month waiting for exactly them.
#[must_use]
pub fn scalar_codec(tree: &Tree) -> Report {
    const GHOSTS: &str = r"func decodeEntry|func decodeEntries|maxEntryCount = |reserveCapacity\(Int\(count\)\)|func decodeLayoutNode|func readWeight|func appendWeight|depth: Int|SplitNode\.maxDepth|struct ByteReader|func appendBE|append\(uuid:";
    const DOORS: &[&str] = &[
        "slopdesk_ws_decode_u8",
        "slopdesk_ws_decode_u32",
        "slopdesk_ws_decode_i64",
        "slopdesk_ws_decode_bool",
        "slopdesk_ws_encode_i32",
        "slopdesk_ws_decode_uuid_list",
        "slopdesk_ws_decode_snapshot",
        "slopdesk_ws_decode_diff",
        "slopdesk_ws_decode_layout",
        "slopdesk_ws_decode_weights",
        "slopdesk_ws_decode_uuid",
        "slopdesk_ws_decode_detached_panes",
        "slopdesk_ws_decode_video_target",
    ];

    let claims = [
        Claim::Lacks {
            path: SWIFT_CODEC,
            pattern: GHOSTS,
            view: View::Code,
            message: "WorkspaceStateCodec.swift grew the count-and-length parse back — it lives in \
                      rust/slopdesk-workspace (docs/55 §6)",
        },
        Claim::Names {
            path: SWIFT_CODEC,
            needle: "import CSlopDeskFFI",
            message: "WorkspaceStateCodec.swift no longer calls the Rust crate — the scalar codec was \
                      undone (docs/55 §6)",
        },
        Claim::Mentions {
            path: SWIFT_CODEC,
            names: DOORS,
            message: "WorkspaceStateCodec.swift stopped calling {entry} — the strict-width drop lives in \
                      Rust (docs/55 §6)",
        },
        // The layout decoder's two refusals are different REPORTS, and the flag is the only thing
        // carrying that difference across the boundary. A decoder that stopped reading it would
        // pass every round-trip test while telling a person "corrupt" about a document that is
        // merely too deep.
        // The other half of why `decode_bool` and `encode_i32` are on the door list: a ban on the
        // COMPOSITION, not just a demand for the call. Without it the door survives beside a
        // hand-rolled second reading and becomes decorative while the composition below it is what
        // actually runs. These two are the exact spellings that were here.
        Claim::Lacks {
            path: SWIFT_CODEC,
            pattern: r"decodeU8\(.*\)\.map|UInt32\(bitPattern:",
            view: View::Code,
            message: "WorkspaceStateCodec.swift composes a scalar field again — ask slopdesk_ws_decode_bool \
                      / slopdesk_ws_encode_i32 instead of re-deriving the byte rule here (docs/55 §6)",
        },
        Claim::Names {
            path: SWIFT_CODEC,
            needle: "depthExceeded",
            message: "WorkspaceStateCodec.swift stopped distinguishing a too-deep tree from a malformed one \
                      (docs/55 §6)",
        },
    ];
    check_all(tree, &claims)
}

/// One answer to "may this cell touch the disk".
///
/// `WorkspaceStateFile` was 129 lines of Swift that were a near-verbatim second copy of
/// `rust/slopdesk-wire`'s `document::state_file`: the same version constant, the same
/// persisted-field set, the same base64 rows, the same refusals. Two answers to that question do
/// not CONFLICT, they render — the wider one brings a pane back as `liveness: attached` with no
/// process behind it, busy dots spinning for a child that exited weeks ago, and the narrower one
/// silently loses the arrangement the person made. Neither logs anything, which is why a compiler
/// could never find it.
///
/// The file moved to `Codec/` when it became a marshaller, and the old path staying gone is half
/// the check: a re-implementation grows back where the original was, not beside its replacement.
#[must_use]
pub fn state_file(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskWorkspaceModel/State/WorkspaceStateFile.swift",
            message: "the rule is rust/slopdesk-wire's document::state_file (docs/55 §6)",
        },
        Claim::Exists {
            path: "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift",
            message: "the state file's door has no Swift face, so the ban below stopped checking anything \
                      (docs/55 §6)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"static let persistedPaneFields\b|(struct|private struct) Row: Codable\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift state-file policy is back in {files} — the persisted set and the row shape \
                      live in rust/slopdesk-wire (docs/55 §6)",
        },
    ];
    check_all(tree, &claims)
}

/// `decodeIfPresent(…) ?? x`, which is a default that cannot run.
///
/// `decodeIfPresent` on a key that is PRESENT with a value its type refuses does NOT answer `nil` —
/// it THROWS, so the `??` written beside it never runs. On a persisted split that cost the user
/// their WHOLE arrangement to one typo in a hand-editable file: the throw unwound the entire
/// `TreeWorkspace` decode and `WorkspacePersistence.load()` wrote a `.corrupt` sidecar. Rust
/// repaired and Swift bricked.
///
/// WHAT IS BANNED IS THE PAIRING, not the call. `decodeIfPresent` is correct where absence and
/// unreadability are BOTH faults — a discriminator key is the standing example, and
/// `persist::decode_raw_node` faults on an unreadable one too — so a call shaped like that agrees
/// with Rust and must stay. What cannot be right is `decodeIfPresent(…) ?? x`: the `??` says "fill
/// on absence", the throw fires first on a bad value, and the default the author wrote is
/// unreachable on the one path it was written for. The first draft banned the call outright and
/// went red on that correct discriminator immediately, which is the ban list's standing hazard.
///
/// THE CONTAINER FORM IS THE SAME TRAP. `"specs": 5` or `"detached": {}` is a key present with a
/// value a `[…]` element type refuses, so `decodeIfPresent([…].self, …) ?? []` threw past its own
/// `?? []` and cost the user every session in the file. `[`, `Set<` and `Dictionary<` are all
/// matched because the shape of the container is not what makes it wrong; the pairing is.
///
/// The lookahead is ONE LINE, because swiftformat wraps a long `decodeIfPresent` before its `??`
/// and a same-line-only match would miss the form a long generic type takes.
///
/// The four allowlisted sites are the same defect, each named so the gate can go green without
/// being narrowed into blindness. All four are in device-local SETTINGS sidecars, where the throw
/// resets that file to defaults instead of taking the workspace with it. Deleting an entry here is
/// the fix; editing the line re-arms the gate on it, which is the point of keying on the
/// `CodingKey` rather than on the file. A wrapped call whose `forKey:` landed on the OTHER line
/// yields no key and is REPORTED — an allowlist that silently swallowed what it could not identify
/// would be the vacuous-gate defect wearing an exemption.
#[must_use]
pub fn optional_fills(tree: &Tree) -> Report {
    const ALLOWED: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift",
            ".rawOverrides",
        ),
        (
            "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
            ".overrides",
        ),
        (
            "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
            ".textBindings",
        ),
        (
            "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
            ".unbinds",
        ),
    ];
    const SUSPECT: &str = r"decodeIfPresent\((SplitAxis|SplitNodeID|PaneID|PaneKind)\.self|decodeIfPresent\((\[|Set<|Dictionary<)";

    let mut report = Report::new();
    let (suspect, key) = (
        crate::text::cached(SUSPECT),
        crate::text::cached(r"forKey: (\.[A-Za-z0-9_]+)"),
    );
    let mut offenders = Vec::new();
    let mut swift_files = 0_usize;

    for (path, source) in tree.under("Sources") {
        if path.extension().and_then(|ext| ext.to_str()) != Some("swift") {
            continue;
        }
        swift_files += 1;
        let display = path.to_string_lossy().into_owned();
        // Comment lines are dropped first, and that is not cosmetic: `TerminalPreferences.swift`
        // explains this trap in prose directly above the calls it governs, so a gate that read
        // comments would fire on the very comment describing why it fires.
        let code = source.code();
        let lines: Vec<&str> = code.lines().collect();
        for (index, line) in lines.iter().enumerate() {
            if !suspect.is_match(line) {
                continue;
            }
            // The `??` is on this line, or on the next one — and only the next one, because a
            // second line of lookahead would start pairing a fill with a call it does not belong to.
            let filled = line.contains("??") || lines.get(index + 1).is_some_and(|next| next.contains("??"));
            if !filled {
                continue;
            }
            let named = key
                .captures(line)
                .and_then(|caps| caps.get(1))
                .map(|m| m.as_str().to_owned());
            let excused = named.as_deref().is_some_and(|coding_key| {
                ALLOWED
                    .iter()
                    .any(|(file, allowed)| *file == display && *allowed == coding_key)
            });
            if !excused {
                offenders.push(format!("{display}:{}", index + 1));
            }
        }
    }

    // A gate whose haystack is empty is not a gate. The shell learned this the expensive way: its
    // file list came from a helper defined further down the script, bash resolved nothing, the
    // redirect swallowed the "command not found" and `|| true` turned the corpse into a pass — a
    // vacuous gate that survived a clean-tree run looking exactly like a pass.
    report.fail_if(
        swift_files < 400,
        format!(
            "the decodeIfPresent gate found only {swift_files} Swift files under Sources/ — its haystack \
             has gone stale, so it is checking nothing",
        ),
    );
    report.fail_if(
        !offenders.is_empty(),
        format!(
            "a raw-value enum, id or container filled with decodeIfPresent(…) ?? x at {} — the throw beats \
             the default; use (try? decode(…)) ?? x, or a tolerant-container/strict-element read like \
             Session.decodeArray (docs/55 §8)",
            offenders.join(", "),
        ),
    );
    report
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A cap transcribed back does not conflict, it renders: a ring whose tail the host reaped.
    #[test]
    fn a_transcribed_ring_cap_is_caught() {
        let fixture = topology_fixture("ws-ring-cap");
        assert!(super::topology_and_reaping(&fixture.tree()).is_clean());

        fixture.write(
            super::SWIFT_TOPOLOGY,
            &format!("{TOPOLOGY_DOORS}let closedTabRingCap = 32\n"),
        );
        let report = super::topology_and_reaping(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("ring cap back")),
            "{report:?}"
        );
    }

    /// The array-literal form and the wrapped-argument form look identical on their own line, so
    /// the line ABOVE is the whole discrimination.
    #[test]
    fn an_array_literal_half_is_caught_and_a_wrapped_argument_is_not() {
        let fixture = topology_fixture("ws-pane-fields");
        fixture.write(
            super::SWIFT_LIVENESS,
            &format!("{LIVENESS_DOORS}let x = reap(\n    WorkspacePaneField.title,\n)\n"),
        );
        assert!(super::topology_and_reaping(&fixture.tree()).is_clean());

        fixture.write(
            super::SWIFT_LIVENESS,
            &format!(
                "{LIVENESS_DOORS}let half: [UInt8] = [\n    WorkspacePaneField.title,\n    \
                 WorkspacePaneField.kind,\n]\n"
            ),
        );
        let report = super::topology_and_reaping(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("transcribed a pane-field half")),
            "{report:?}"
        );
    }

    /// The pairing is what is banned, not the call — a bare `decodeIfPresent` is correct where
    /// absence and unreadability are both faults.
    #[test]
    fn a_fill_is_caught_and_a_bare_discriminator_is_not() {
        let fixture = sources_fixture("ws-optional-fill");
        fixture.write(
            "Sources/A/Ok.swift",
            "let axis = try c.decodeIfPresent(SplitAxis.self, forKey: .axis)\n",
        );
        assert!(
            !super::optional_fills(&fixture.tree())
                .violations()
                .iter()
                .any(|v| v.contains("decodeIfPresent")),
        );

        fixture.write(
            "Sources/A/Bad.swift",
            "let axis = try c.decodeIfPresent(SplitAxis.self, forKey: .axis) ?? .horizontal\n",
        );
        let report = super::optional_fills(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("Sources/A/Bad.swift:1")),
            "{report:?}"
        );
    }

    /// swiftformat wraps a long call before its `??`, and that is the form a long generic type
    /// takes — so a same-line-only match would miss exactly the sites most likely to have one.
    #[test]
    fn a_wrapped_fill_is_caught_one_line_down() {
        let fixture = sources_fixture("ws-wrapped-fill");
        fixture.write(
            "Sources/A/Wrapped.swift",
            "let specs = try container.decodeIfPresent([PaneSpec].self, forKey: .specs)\n    ?? []\n",
        );
        let report = super::optional_fills(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("Sources/A/Wrapped.swift:1")),
            "{report:?}"
        );
    }

    /// The allowlist keys on the `CodingKey`, so editing the line re-arms the gate on it.
    #[test]
    fn an_allowlisted_site_passes_and_a_different_key_in_the_same_file_does_not() {
        let fixture = sources_fixture("ws-allowlist");
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift",
            "let o = try c.decodeIfPresent([String: String].self, forKey: .rawOverrides) ?? [:]\n",
        );
        assert!(
            !super::optional_fills(&fixture.tree())
                .violations()
                .iter()
                .any(|v| v.contains("decodeIfPresent")),
        );

        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift",
            "let o = try c.decodeIfPresent([String: String].self, forKey: .newKey) ?? [:]\n",
        );
        let report = super::optional_fills(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("EnvBridge")),
            "{report:?}"
        );
    }

    /// The defect the shell committed inside a new gate: a haystack that read as nothing, passing
    /// while checking nothing.
    #[test]
    fn a_haystack_that_went_stale_says_so() {
        let fixture = Fixture::new("ws-empty-haystack");
        fixture.write("Sources/A/One.swift", "let x = 1\n");
        let report = super::optional_fills(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("gone stale")),
            "{report:?}"
        );
    }

    const TOPOLOGY_DOORS: &str = "\
let a = slopdesk_ws_topology_ring_cap(0)
let b = slopdesk_ws_topology_ring_cap(1)
let c = slopdesk_ws_reserved_root_fields()
let d = slopdesk_ws_key_is_topology(key)
";
    const LIVENESS_DOORS: &str = "\
let e = slopdesk_ws_pane_fields(0)
let f = slopdesk_ws_pane_fields(1)
";

    fn topology_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::SWIFT_TOPOLOGY, TOPOLOGY_DOORS)
            .write(super::SWIFT_LIVENESS, LIVENESS_DOORS);
        fixture
    }

    /// The fill gate refuses a haystack under 400 Swift files, so its fixtures need a corpus.
    fn sources_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        for index in 0..400 {
            fixture.write(&format!("Sources/Bulk/F{index}.swift"), "let x = 1\n");
        }
        fixture
    }
}
