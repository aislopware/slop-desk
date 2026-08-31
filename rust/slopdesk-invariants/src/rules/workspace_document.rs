//! The workspace document: its field numbers, its intent verbs, its two reaping rules, and the
//! codec that is a face over `rust/slopdesk-workspace` rather than a second copy of it.
//!
//! Ported from the deleted `check-supervisor.sh`. The SOLVERS moved to Rust and the document's
//! value types stayed Swift on purpose — 262 files import them — so the line is INSIDE the module
//! rather than around it, and every rule here is a per-file question.

use crate::claim::{Claim, SWIFT, SWIFT_ROOTS, View, check_all};
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
            message: "WorkspaceTopology.swift stopped asking slopdesk_ws_topology_ring_cap(0) — a reaping \
                      threshold spelled twice reaps two different rings (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_TOPOLOGY,
            pattern: r"slopdesk_ws_topology_ring_cap\(1\)",
            message: "WorkspaceTopology.swift stopped asking slopdesk_ws_topology_ring_cap(1) — a reaping \
                      threshold spelled twice reaps two different rings (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_TOPOLOGY,
            pattern: r"slopdesk_ws_reserved_root_fields\(",
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
            message: "WorkspaceTopology.swift decides isTopology itself — ask slopdesk_ws_key_is_topology \
                      (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_LIVENESS,
            pattern: r"slopdesk_ws_pane_fields\((0|half)",
            message: "PaneLiveness.swift stopped asking slopdesk_ws_pane_fields for the first half — a pane \
                      field on the wrong side of the reaping line deletes a persisted title (docs/45 §5.3)",
        },
        Claim::Matches {
            path: SWIFT_LIVENESS,
            pattern: r"slopdesk_ws_pane_fields\((1|half)",
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
            roots: SWIFT_ROOTS,
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
            // second line of lookahead would start pairing a fill with a call it does not belong
            // to.
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

/// The Swift face of the channel client's run ladder.
const RUN_FACE: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Sync/ChannelRun.swift";

/// The one client that drives it — and may keep none of what it answers.
const CHANNEL_CLIENT: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Sync/WorkspaceChannelClient.swift";

/// Every door the run face must keep asking.
const RUN_DOORS: &[&str] = &[
    "slopdesk_channel_run_new",
    "slopdesk_channel_run_free",
    "slopdesk_channel_run_state",
    "slopdesk_channel_run_may_send_intent",
    "slopdesk_channel_run_start",
    "slopdesk_channel_run_stop",
    "slopdesk_channel_run_claim",
    "slopdesk_channel_run_release_if_owned",
    "slopdesk_channel_run_finish",
    "slopdesk_channel_run_publish",
    "slopdesk_channel_run_mint_presence_clock",
];

/// One run, one ladder — the generation, the channel claim and the presence clock
///
/// The workspace channel's client loop is restarted on every link, so at any moment a run may be
/// unwinding behind an `await` while a newer one is already opening. Three scalars settle that, and
/// each has a failure no build catches. A generation kept beside the state lets a dying run publish
/// `closed` over a live channel, and nothing reopens it. A channel id released by both `stop()` and
/// the run's own exit path closes a pooled connection a reconnect has already rebuilt under the
/// same key. A presence clock restarted below what the host has kept leaves every other client
/// looking at the view this user already left, permanently.
///
/// So the three are `rust/slopdesk-workspace`'s `channel_run` now, and this pins the halves that
/// keep it one implementation: the face asks every door, and the client keeps none of them back.
/// The queues, the drains and the bounded handshake race stay Swift on purpose — an ORDER argument
/// about main-actor hops is not a decision, and a `Task` slot is not a number.
#[must_use]
pub fn one_run_one_ladder(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: RUN_FACE,
            message: "Sources/SlopDeskWorkspaceCore/Workspace/Sync/ChannelRun.swift is gone — which run \
                      still speaks, who releases the channel and which presence clock is next are not \
                      WorkspaceChannelClient's to re-derive (docs/45 §5.1)",
        },
        Claim::Doors {
            path: RUN_FACE,
            entries: RUN_DOORS,
            message: "ChannelRun.swift no longer calls {entry} — a face that drops a door is a ladder step \
                      growing back beside the one that owns it",
        },
        Claim::NoneOf {
            paths: &[CHANNEL_CLIENT],
            pattern: r"var runGeneration|var presenceClock|var channelID|var state:\s*State\s*=",
            view: View::Code,
            message: "{files} STORES a run generation, a presence clock, a channel claim or a state of its \
                      own — each is the far side's, and a second copy beside it is a guard that silently \
                      stops guarding. The projection `var state: State { run.state }` is the shape that is \
                      allowed: it reads the ladder, it does not keep one (docs/45 §5.1)",
        },
        Claim::Matches {
            path: CHANNEL_CLIENT,
            pattern: r"private let run = ChannelRun\(\)",
            message: "WorkspaceChannelClient.swift no longer holds a ChannelRun — the ladder it answers is \
                      what keeps a superseded run from reporting the live one dead (docs/45 §5.1)",
        },
    ];
    check_all(tree, &claims)
}

/// The Swift face of the client's replica of the document.
const MIRROR_FACE: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Sync/WorkspaceMirrorBox.swift";

/// The value type it replaced. It held the three layers AND the pending patches in Swift, and asked
/// Rust one question at a time about numbers it kept itself.
const MIRROR_DELETED: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Sync/HostWorkspaceMirror.swift";

/// Every door the mirror face must keep asking. Each names a LAYER or a decision over one, and a
/// face that stopped asking is that layer growing back on this side.
const MIRROR_DOORS: &[&str] = &[
    "slopdesk_ws_mirror_new",
    "slopdesk_ws_mirror_free",
    "slopdesk_ws_mirror_apply",
    "slopdesk_ws_mirror_forget",
    "slopdesk_ws_mirror_write_fast_path",
    "slopdesk_ws_mirror_fast_path_holds",
    "slopdesk_ws_mirror_clear_fast_path",
    "slopdesk_ws_mirror_stage_intent",
    "slopdesk_ws_mirror_note_intent_result",
    "slopdesk_ws_mirror_expire_pending",
    "slopdesk_ws_mirror_drop_pending",
    "slopdesk_ws_mirror_pending_count",
    "slopdesk_ws_mirror_is_pending",
    "slopdesk_ws_mirror_value",
    "slopdesk_ws_mirror_resolved",
    "slopdesk_ws_mirror_host_truth",
    "slopdesk_ws_mirror_state_num",
    "slopdesk_ws_mirror_known_state_num",
    "slopdesk_ws_mirror_frames_applied",
    "slopdesk_ws_mirror_pane_ids",
    "slopdesk_ws_mirror_fast_path_pane_ids",
];

/// One replica, and its three layers are Rust's
///
/// The client's replica of the host-owned document is `slopdesk_wire::document::mirror` — host
/// truth, the control-push overlay and the optimistic patches, behind ONE handle. It was a Swift
/// value type that kept all three and crossed to Rust for a verdict per question, which is the
/// split state machine `docs/55` §8 names: the erasure rule lived on one side of the boundary and
/// the bytes it erased on the other, so every new question was a new door and a new chance for the
/// two halves to disagree.
///
/// What this pins is the shape that keeps it ONE implementation. The face asks every door. The
/// value type it replaced stays deleted. And the near side keeps no layer of its own: a `fastPath`
/// dictionary, an `entries` state or a pending-patch array declared beside the handle is the same
/// bug in a smaller font, because the erasure rule cannot reach it.
///
/// The presence roster is deliberately NOT behind the handle and this rule does not ask for it: it
/// is never versioned, never diffed and its lifetime is the CONNECTION rather than the document, so
/// it is not a layer of the replica at all.
#[must_use]
pub fn one_replica_three_layers(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: MIRROR_FACE,
            message: "Sources/SlopDeskWorkspaceCore/Workspace/Sync/WorkspaceMirrorBox.swift is gone — the \
                      client's replica of the host document has no face, and the store and the channel must \
                      share ONE (docs/45 §7.1)",
        },
        Claim::Absent {
            path: MIRROR_DELETED,
            message: "HostWorkspaceMirror.swift is back — the three layers in Swift with a door per \
                      question is the split state machine that port ended (docs/45 §7.1, docs/55 §8)",
        },
        Claim::Doors {
            path: MIRROR_FACE,
            entries: MIRROR_DOORS,
            message: "WorkspaceMirrorBox.swift no longer calls {entry} — a face that drops a door is a \
                      layer of the replica growing back on this side",
        },
        Claim::NoneOf {
            paths: &[MIRROR_FACE],
            pattern: r"var fastPath:|var entries:|var pending:|var pendingPatches|var framesApplied",
            view: View::Code,
            message: "{files} STORES a layer of the replica beside the handle — host truth, the overlay and \
                      the pending patches are all one document, and a copy on this side is a cell the \
                      erasure rule cannot reach (docs/45 §7.1)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// Every door the run face must keep asking, as a fixture body.
    fn run_doors() -> String {
        let mut body = String::new();
        for door in super::RUN_DOORS {
            body.push_str(door);
            body.push_str("()\n");
        }
        body
    }

    /// A tree where the run ladder lives on one side and the client holds the handle.
    fn write_one_run_one_ladder(fixture: &Fixture) {
        fixture
            .write(super::RUN_FACE, &run_doors())
            .write(super::CHANNEL_CLIENT, "    private let run = ChannelRun()\n");
    }

    #[test]
    fn one_run_one_ladder_keeps_the_ladder_on_one_side() {
        let fixture = Fixture::new("one-run-one-ladder");
        write_one_run_one_ladder(&fixture);
        assert!(super::one_run_one_ladder(&fixture.tree()).is_clean());

        // The face stopped asking — a ladder step grew back beside the one that owns it.
        fixture.write(super::RUN_FACE, "slopdesk_channel_run_new()\n");
        assert!(!super::one_run_one_ladder(&fixture.tree()).is_clean());
        write_one_run_one_ladder(&fixture);

        // Each scalar the far side owns, one at a time.
        for drift in [
            "    private var runGeneration = 0\n",
            "    private var presenceClock: Int64 = 0\n",
            "    private var channelID: UInt32?\n",
            "    public private(set) var state: State = .idle\n",
        ] {
            fixture.append(super::CHANNEL_CLIENT, drift);
            assert!(
                !super::one_run_one_ladder(&fixture.tree()).is_clean(),
                "the ban missed {drift}",
            );
            write_one_run_one_ladder(&fixture);
        }

        // The client dropped the handle the whole ladder is reached through.
        fixture.write(
            super::CHANNEL_CLIENT,
            "public final class WorkspaceChannelClient {\n",
        );
        assert!(!super::one_run_one_ladder(&fixture.tree()).is_clean());

        // A bare tree has no face at all.
        let bare = Fixture::new("one-run-one-ladder-bare");
        assert!(!super::one_run_one_ladder(&bare.tree()).is_clean());
    }

    /// A tree where the replica lives behind the handle and the face asks for all of it.
    fn write_one_replica(fixture: &Fixture) {
        let mut body = String::new();
        for door in super::MIRROR_DOORS {
            body.push_str(door);
            body.push_str("()\n");
        }
        fixture.write(super::MIRROR_FACE, &body);
        fixture.remove(super::MIRROR_DELETED);
    }

    #[test]
    fn one_replica_keeps_its_three_layers_behind_the_handle() {
        let fixture = Fixture::new("one-replica-three-layers");
        write_one_replica(&fixture);
        assert!(super::one_replica_three_layers(&fixture.tree()).is_clean());

        // The face stopped asking — a layer grew back on this side.
        fixture.write(super::MIRROR_FACE, "slopdesk_ws_mirror_new()\n");
        assert!(!super::one_replica_three_layers(&fixture.tree()).is_clean());
        write_one_replica(&fixture);

        // The value type that kept all three layers in Swift is back.
        fixture.write(super::MIRROR_DELETED, "public struct HostWorkspaceMirror {}\n");
        assert!(!super::one_replica_three_layers(&fixture.tree()).is_clean());
        write_one_replica(&fixture);

        // Each layer, declared beside the handle, one at a time.
        for drift in [
            "    private var fastPath: [WorkspaceKey: Data] = [:]\n",
            "    private var entries: HostWorkspaceState = .init()\n",
            "    private var pending: [PendingPatch] = []\n",
            "    private var pendingPatches = 0\n",
            "    private var framesApplied: UInt64 = 0\n",
        ] {
            fixture.append(super::MIRROR_FACE, drift);
            assert!(
                !super::one_replica_three_layers(&fixture.tree()).is_clean(),
                "the ban missed {drift}",
            );
            write_one_replica(&fixture);
        }

        // A bare tree has no face at all.
        let bare = Fixture::new("one-replica-bare");
        assert!(!super::one_replica_three_layers(&bare.tree()).is_clean());
    }

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
