//! Six answers that cross a boundary, and the literals that must not grow back beside them.
//!
//! Ported from the deleted `check-supervisor.sh`. Each rule here is a door that already answers a
//! question, plus the Swift or Rust spelling that used to answer it a second time. What they share
//! is that no test can catch the pair parting: a defaulted codec draws a black rectangle, a
//! re-spelled threshold makes a client quietly stop repairing, a fourth built-in row added on one
//! side only shows up weeks later as a duplicated menu entry with nothing in any log.

use crate::claim::{Claim, RUST, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The panel that used to overrule a refusal with H.264.
const ANDROID_STREAM: &str = "Sources/SlopDeskDevicePanels/Android/AndroidStreamConnection.swift";
/// Where the decodable-codec set is asked for.
const ANDROID_PROTOCOL: &str = "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift";
/// The policy whose multi-loss threshold was spelled three times.
const FEC_POLICY: &str = "Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift";
/// The codec that reads two raw level bytes.
const METADATA_CODEC: &str = "Sources/SlopDeskProtocol/Metadata/MetadataCodec.swift";
/// The crate that holds the two shipped tables — and must not hold a dead expansion.
const TEMPLATES: &str = "rust/slopdesk-workspace/src/templates.rs";
/// The GUI video host, which holds both drains of the paced send.
///
/// A DIRECTORY rather than a file, for the reason [`crate::rules::video_host`] states: the two
/// drains already live in two of the daemon's modules and the split is still moving, so a claim
/// pinned to a filename would report an ordinary relocation as the schedule going missing.
const DAEMON: &str = "rust/slopdesk-videohostd";
/// The model file whose built-ins are the crate's session templates.
const MODEL_TEMPLATE: &str = "Sources/SlopDeskWorkspaceModel/Domain/SessionTemplate.swift";
/// Its sibling, holding the launch presets.
const MODEL_PRESET: &str = "Sources/SlopDeskWorkspaceModel/Domain/LaunchPreset.swift";

/// An undecodable Android stream ENDS rather than defaulting
///
/// `slopdesk_android_stream_decodable_codec` answers "this Mac cannot display that"; the panel used
/// to overrule it with `?? .h264`, which configured an H.264 NAL-type reading for AV1 parameter
/// sets and handed `VTDecompressionSession` a mis-typed format description — the black rectangle
/// `AndroidVideoCodec`'s omission of AV1 exists to prevent, with nothing logged.
#[must_use]
pub fn an_undecodable_stream_ends(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Lacks {
            path: ANDROID_STREAM,
            pattern: r"AndroidVideoCodec\(streamIdentifier:.*\?\?",
            view: View::Raw,
            message: "the Android panel defaults an unrecognised codec again — the door already refused it",
        },
        Claim::Matches {
            path: ANDROID_PROTOCOL,
            pattern: r"slopdesk_android_stream_decodable_codec\(",
            view: View::Statements,
            message: "AndroidStreamProtocol stopped asking which codecs decode — that set is Rust's",
        },
    ])
}

/// The multi-loss THRESHOLD is one answer, not a literal in each language
///
/// `parityCount >= 2` (or `m >= 2`) reappearing in Swift is the whole rule. The bounds cannot stand
/// in for it — `M_MIN` is 1 — so a reader who does not know the door exists reaches for the
/// literal, which is how it came to be spelled twice in Swift and a third time inside the crate's
/// own tier table. A host and a client that disagree about it emit and expect different parity
/// counts per group, and neither end logs anything: the client simply stops repairing.
#[must_use]
pub fn the_multi_loss_threshold_is_one_answer(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Lacks {
            path: FEC_POLICY,
            pattern: r"(parityCount|resolveParityCount\([^)]*\)) *>= *2",
            view: View::Code,
            message: "the FEC policy spells the multi-loss threshold again — ask \
                      slopdesk_adaptive_fec_multi_loss_active",
        },
        Claim::Matches {
            path: FEC_POLICY,
            pattern: r"slopdesk_adaptive_fec_multi_loss_active\(",
            view: View::Statements,
            message: "the FEC policy stopped asking the door whether multi-loss is active",
        },
    ])
}

/// The two RAW level bytes are READ through their doors
///
/// `MemoryPressure(rawValue: pressureByte)` / `ServiceState(rawValue: stateByte)` — the raw field
/// going straight into the Swift enum restates "an unrecognised byte reads as the benign level"
/// beside `slopdesk_wire`'s own copy of that rule. Neither enum has a `compare_abi_enum` pin, so a
/// renumber on one side is invisible; the doors are what make the reading single.
#[must_use]
pub fn the_level_bytes_are_read_through_doors(tree: &Tree) -> Report {
    /// The two raw readings that used to sit beside the doors.
    const RAW: &[&str] = &[
        r"MemoryPressure\(rawValue: pressureByte\)",
        r"ServiceState\(rawValue: stateByte\)",
    ];

    let mut claims = vec![Claim::Mentions {
        path: METADATA_CODEC,
        names: &[
            "slopdesk_metadata_memory_pressure(",
            "slopdesk_metadata_service_state(",
        ],
        message: "MetadataCodec no longer calls {entry} — the level readings are rust/slopdesk-wire's",
    }];
    for raw in RAW {
        claims.push(Claim::Lacks {
            path: METADATA_CODEC,
            pattern: raw,
            view: View::Raw,
            message: "MetadataCodec reads a raw level byte directly again — go through the door",
        });
    }
    check_all(tree, &claims)
}

/// The dead Rust launch-preset expansion stays deleted
///
/// The expansion is `LaunchPresetEngine.plan`'s and stays Swift (`docs/55` §8); a Rust copy that
/// nothing calls cannot be caught disagreeing, because no input ever reaches both — and `dead_code`
/// cannot see a `pub` item in a library crate, so nothing else would notice either. The one it had
/// already drifted on: `TemplatePane::keystrokes` hardcoded `None` for the cwd and so could not
/// emit a `cd` line.
#[must_use]
pub fn the_dead_rust_expansion_stays_deleted(tree: &Tree) -> Report {
    /// The four items that were the second expansion.
    const REVIVED: &[&str] = &[
        r"pub fn plan\(",
        r"struct LaunchPlan",
        r"struct PaneLaunch",
        r"pub fn keystrokes\(&self\)",
    ];

    let claims: Vec<Claim> = REVIVED
        .iter()
        .map(|revived| {
            Claim::Lacks {
                path: TEMPLATES,
                pattern: revived,
                view: View::Raw,
                message: "templates.rs grew the preset expansion back — it is LaunchPresetEngine.plan's, \
                          and a Rust copy nothing calls cannot be caught disagreeing",
            }
        })
        .collect();
    check_all(tree, &claims)
}

/// ONE pacing schedule and ONE pacing gap, whichever drain sends the frame
///
/// `SLOPDESK_SEND_LANE=0` runs the same job on the session actor instead of the lane, and it used
/// to hand-roll both: it chunked and deadlined the frame itself, and — having no `keyframe` in
/// scope — floored EVERY frame at the delta pace target. So the gate documented as a byte-identical
/// fallback actually paced a recovery IDR off a post-backoff ABR, serializing for hundreds of ms
/// the one frame whose delivery time IS the client's recovery time. Nothing could fail on it: the
/// inline path has no test, and the two paths are never both live.
///
/// The gap is computed once by the caller and the schedule comes from `send_pacing::pace_plan`,
/// which both drains ask.
///
/// `docs/61` deleted the Swift session and the Swift lane and moved both drains into
/// `rust/slopdesk-videohostd`, and the defect they had is exactly as available there: the two are
/// still two, they still send the same job down different code, and the inline one still has no
/// test that a divergence would fail. What changed is only which language a second schedule would
/// be written in. So the rule keeps both halves and re-aims them at the daemon: it must still ASK
/// `send_pacing`, and it may not respell what that module answers.
///
/// The COUNTED claim could not survive the move and is the one thing here that is genuinely
/// different. `Exactly` counts occurrences in ONE file, and the two drains are now two modules — a
/// count over either alone would be one number about half the question, and the split is still
/// moving besides. The ban replaces it and is stronger than the count was: rather than "the gap is
/// computed once", it says the daemon may not hold a pacing computation AT ALL. `pace_plan`
/// answers the schedule and `may_send_inline` answers whether the inline drain may take the frame,
/// so a `fn` here named for either is the hand-rolled half coming back — which is what actually
/// paced a recovery IDR off a post-backoff ABR the first time.
///
/// Daemon-scoped, like every other ban re-aimed by `docs/61`:
/// `rust/slopdesk-video/src/send_pacing.rs` declares all four of these names, because declaring
/// them is what it is for.
#[must_use]
pub fn one_pacing_schedule_and_one_gap(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["send_pacing", "pace_plan"],
            message: "the daemon stopped asking {entry} — the chunk boundaries and the deadline they carry \
                      are rust/slopdesk-video's, and a drain that stopped asking is a drain that has \
                      started chunking (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bfn (pace_plan|total_span_nanos|may_send_inline)\b|\bstruct PacedChunk\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon declares a pacing schedule of its own in {files} — the plan, its span, its \
                      chunk and the inline admission are send_pacing.rs's, and the second copy is invisible \
                      because the two drains are never both live (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bfn [a-z_]*pace_gap[a-z_]*\b|\bfn [a-z_]*chunk_boundaries\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon computes a pacing gap in {files} — that is the copy that had no keyframe \
                      in scope and floored EVERY frame at the delta target, serializing the one frame whose \
                      delivery time is the client's recovery time (docs/61 §3)",
        },
    ])
}

/// The two shipped tables are the CRATE's, and there is no second copy of them
///
/// `SessionTemplate.builtIns` / `LaunchPreset.builtIns` going back to a Swift literal beside the
/// crate's `built_in_*` tables is the arrangement `CLAUDE.md` bans by name, and the cost is
/// specific rather than stylistic: a built-in's UUID is FIXED so that re-seeding a workspace
/// MATCHES its row instead of appending a second one, so a fourth row added to one side only hands
/// every device a different set depending on which side seeded it — surfacing weeks later as a
/// duplicated menu row with nothing in any log. `compare_abi_enum` cannot see it (it pins names and
/// numbers it was told about), and the differential that used to see it is gone precisely because
/// there is now one table.
///
/// The `builtInID` helper is banned too: it existed only to spell a literal UUID for a table, so
/// its return is the shape of the mirror coming back.
#[must_use]
pub fn the_shipped_tables_are_the_crates(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: MODEL_TEMPLATE,
            pattern: r"SessionTemplateCrossing\.builtInTemplatesFromTheCrate\(\)",
            view: View::Statements,
            message: "SessionTemplate.swift stopped seeding from the crate — the shipped table is \
                      templates.rs's",
        },
        Claim::Matches {
            path: MODEL_PRESET,
            pattern: r"SessionTemplateCrossing\.builtInLaunchPresetsFromTheCrate\(\)",
            view: View::Statements,
            message: "LaunchPreset.swift stopped seeding from the crate — the shipped table is \
                      templates.rs's",
        },
        Claim::NoneOf {
            paths: &[MODEL_TEMPLATE, MODEL_PRESET],
            pattern: r"builtInID\(",
            view: View::Raw,
            message: "a model file spells a built-in UUID again ({files}) — the rows come from the crate",
        },
        Claim::Mentions {
            path: TEMPLATES,
            names: &[
                "pub fn built_in_session_templates(",
                "pub fn built_in_launch_presets(",
            ],
            message: "templates.rs lost {entry} — Swift seeds a fresh device from it",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    #[test]
    fn a_defaulted_android_codec_is_red() {
        let fixture = Fixture::new("crossed-android");
        fixture
            .write(
                super::ANDROID_STREAM,
                "guard let codec = AndroidVideoCodec(streamIdentifier: id) else { return end() }\n",
            )
            .write(
                super::ANDROID_PROTOCOL,
                "let set = slopdesk_android_stream_decodable_codec(id)\n",
            );
        assert!(super::an_undecodable_stream_ends(&fixture.tree()).is_clean());

        // The `?? .h264` that handed VTDecompressionSession a mis-typed format description.
        fixture.write(
            super::ANDROID_STREAM,
            "let codec = AndroidVideoCodec(streamIdentifier: id) ?? .h264\n",
        );
        assert!(!super::an_undecodable_stream_ends(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_re_spelled_multi_loss_threshold_is_red() {
        let fixture = Fixture::new("crossed-fec");
        fixture.write(
            super::FEC_POLICY,
            "/// The threshold used to read `parityCount >= 2` here and again in the tier table.\nlet multi \
             = slopdesk_adaptive_fec_multi_loss_active(tier)\n",
        );
        // The prose records the literal it replaced, so the ban reads code.
        assert!(super::the_multi_loss_threshold_is_one_answer(&fixture.tree()).is_clean());

        fixture.write(
            super::FEC_POLICY,
            "let multi = slopdesk_adaptive_fec_multi_loss_active(tier)\nlet alsoMulti = parityCount >= 2\n",
        );
        assert!(!super::the_multi_loss_threshold_is_one_answer(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_raw_level_byte_read_directly_is_red() {
        let fixture = Fixture::new("crossed-levels");
        fixture.write(
            super::METADATA_CODEC,
            "let pressure = slopdesk_metadata_memory_pressure(pressureByte)\nlet state = \
             slopdesk_metadata_service_state(stateByte)\n",
        );
        assert!(super::the_level_bytes_are_read_through_doors(&fixture.tree()).is_clean());

        // Restating "an unrecognised byte reads as the benign level" beside slopdesk_wire's copy.
        fixture.write(
            super::METADATA_CODEC,
            "let pressure = MemoryPressure(rawValue: pressureByte) ?? .nominal\nlet state = \
             slopdesk_metadata_service_state(stateByte)\n",
        );
        assert!(!super::the_level_bytes_are_read_through_doors(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_revived_rust_expansion_is_red() {
        let fixture = Fixture::new("crossed-templates");
        fixture.write(
            super::TEMPLATES,
            "pub fn built_in_session_templates() -> Vec<Template> { vec![] }\npub fn \
             built_in_launch_presets() -> Vec<Preset> { vec![] }\n",
        );
        assert!(super::the_dead_rust_expansion_stays_deleted(&fixture.tree()).is_clean());

        // A pub item nothing calls: dead_code cannot see it in a library crate, and no input ever
        // reaches both copies, so it cannot be caught disagreeing either.
        fixture.append(
            super::TEMPLATES,
            "pub struct LaunchPlan { pub panes: Vec<PaneLaunch> }\npub fn plan(preset: &Preset) -> \
             LaunchPlan { LaunchPlan { panes: vec![] } }\n",
        );
        assert!(!super::the_dead_rust_expansion_stays_deleted(&fixture.tree()).is_clean());
    }

    /// One schedule, no gap of its own, both drains asking the module.
    fn pacing(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-videohostd/src/sendlane.rs",
                "use slopdesk_video::send_pacing::{SendJob, may_send_inline, pace_plan};\nlet plan = \
                 pace_plan(job.spec());\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/session_pump.rs",
                "use slopdesk_video::send_pacing::pace_plan;\nlet plan = pace_plan(job.spec());\n",
            );
    }

    #[test]
    fn a_second_pacing_gap_is_red() {
        let fixture = Fixture::new("crossed-pacing");
        pacing(&fixture);
        assert!(super::one_pacing_schedule_and_one_gap(&fixture.tree()).is_clean());

        // The inline drain deciding the gap for itself, which is the copy that had no keyframe in
        // scope and floored every frame at the delta target.
        fixture.append(
            "rust/slopdesk-videohostd/src/session_pump.rs",
            "fn adaptive_pace_gap_nanos(target_bps: u64) -> u64 { 1_000_000_000 / target_bps }\n",
        );
        assert!(!super::one_pacing_schedule_and_one_gap(&fixture.tree()).is_clean());

        // And the lane hand-rolling the chunk boundaries again, in the language the port left it
        // in.
        pacing(&fixture);
        fixture.write(
            "rust/slopdesk-videohostd/src/sendlane.rs",
            "use slopdesk_video::send_pacing::SendJob;\nfn pace_plan(job: SendJob) -> Vec<Chunk> { \
             chunked(job) }\n",
        );
        assert!(!super::one_pacing_schedule_and_one_gap(&fixture.tree()).is_clean());

        // The daemon that stopped asking at all — nothing is respelled, so only the ask can fail.
        pacing(&fixture);
        fixture
            .write(
                "rust/slopdesk-videohostd/src/sendlane.rs",
                "let plan = self.schedule;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/session_pump.rs",
                "let plan = self.schedule;\n",
            );
        assert!(!super::one_pacing_schedule_and_one_gap(&fixture.tree()).is_clean());
    }

    /// Both models seeded from the crate, and both tables still declared there.
    fn tables(fixture: &Fixture) {
        fixture
            .write(
                super::MODEL_TEMPLATE,
                "static let builtIns = SessionTemplateCrossing.builtInTemplatesFromTheCrate()\n",
            )
            .write(
                super::MODEL_PRESET,
                "static let builtIns = SessionTemplateCrossing.builtInLaunchPresetsFromTheCrate()\n",
            )
            .write(
                super::TEMPLATES,
                "pub fn built_in_session_templates() -> Vec<Template> { vec![] }\npub fn \
                 built_in_launch_presets() -> Vec<Preset> { vec![] }\n",
            );
    }

    #[test]
    fn a_swift_mirror_of_a_shipped_table_is_red() {
        let fixture = Fixture::new("crossed-tables");
        tables(&fixture);
        assert!(super::the_shipped_tables_are_the_crates(&fixture.tree()).is_clean());

        // The helper existed only to spell a literal UUID for a table, so its return IS the mirror.
        fixture.write(
            super::MODEL_PRESET,
            "static let builtIns = [LaunchPreset(id: builtInID(3), name: \"Review\")]\n",
        );
        assert!(!super::the_shipped_tables_are_the_crates(&fixture.tree()).is_clean());

        // And the crate losing the table Swift seeds a fresh device from.
        tables(&fixture);
        fixture.write(
            super::TEMPLATES,
            "pub fn built_in_session_templates() -> Vec<Template> { vec![] }\n",
        );
        assert!(!super::the_shipped_tables_are_the_crates(&fixture.tree()).is_clean());
    }
}
