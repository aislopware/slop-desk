//! What decides a pane's AGENT state — the badge ladder, the hook body's one reading, the one
//! detector per pane, the secret vocabulary, and what a fresh install carries.
//!
//! Ported from `scripts/check-supervisor.sh`. `docs/50` is the architecture; what is pinned here is
//! the shape that architecture rules out. Two machines per pane FIGHT: both emit type-27 with no
//! reconciliation, so a hook `.working` and a foreground-poll `.idle` clobber each other on the one
//! control stream, and with neither owning `.tick(at:)` the `.done → .idle` decay never fires — a
//! finished turn stays lit forever. Both of the machines that had to die kept COMPILING afterwards,
//! constructed by nothing in `Sources/` and kept alive by a test file each: the shape `CLAUDE.md`
//! names outright, a second implementation surviving as a test fake.

use crate::claim::{Claim, Extract, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_BADGE: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Tabs/TabBadge.swift";
const SWIFT_BADGE_KIND: &str = "Sources/SlopDeskWorkspaceModel/Reading/TabBadgeKind.swift";
const SWIFT_DETECTOR: &str = "Sources/SlopDeskHost/ClaudePaneDetector.swift";
const SWIFT_FOREGROUND: &str = "Sources/SlopDeskHost/ForegroundProcessProbes.swift";
const SWIFT_REDACTOR: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Domain/SecretRedactor.swift";
const SWIFT_SECRET_PASTE: &str = "Sources/SlopDeskWorkspaceCore/Video/SecretPasteClassifier.swift";
const SWIFT_TERMPREFS: &str = "Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift";

/// One badge ladder for a tab row
///
/// Ten precedence rungs over four independent signals, with two placements that are the whole reason
/// it is a rule: the AGENT finish above the busy tiers (claude holds the OSC-133 block open for its
/// whole lifetime), a COMMAND's exit below them. It was pure Swift with no Rust twin at all.
///
/// The KIND is a second file: `TabBadgeResolver` needs the store's badge gates and stayed, the
/// discriminant does not and descended to the value model, where `SlopDeskSlate` can name it without
/// naming a store. The census is bounded on the enum's own line for the reason the pill-ink arm is:
/// an open address also matches `TabBadgeKindRung`, so the enum renamed out from under the claim
/// would keep counting nine.
#[must_use]
pub fn one_badge_ladder_for_a_tab_row(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: SWIFT_BADGE_KIND,
            message: "the case list this claim counts moved, and a missing file counts ZERO cases",
        },
        Claim::Lacks {
            path: SWIFT_BADGE,
            pattern: "sudoBasenames|caffeinateBasenames|privilegeBadge|agent == .needsPermission",
            view: View::Code,
            message: "TabBadge.swift walks the badge ladder in Swift — slopdesk-agent::badge resolves it",
        },
        Claim::Names {
            path: SWIFT_BADGE,
            needle: "slopdesk_agent_tab_badge",
            message: "TabBadge.swift stopped asking the door — it is a face over the ladder, not a second one",
        },
        Claim::Census {
            label: "the TabBadgeKind / TabBadge::ALL case count",
            cases: Extract::code(SWIFT_BADGE_KIND, "^    case ")
                .within(r"^public enum TabBadgeKind[:\s{]", "^}"),
            declared: Extract::code(
                "rust/slopdesk-agent/src/badge.rs",
                r"pub const ALL: \[Self; ([0-9]+)\]",
            ),
        },
    ];
    check_all(tree, &claims)
}

/// One reading of a hook body
///
/// A hook body used to be read TWICE over: a typed `HookPayload` enum modelling the JSON in
/// `SlopDeskInspector`, and a `mapToHookEvent` adapter a module away in `SlopDeskHost` turning a
/// payload into the event the machine folds. Splitting an event's IDENTITY from its MEANING is what
/// let them drift — a payload case could gain a field the adapter never read, and the rules that
/// decide a pane's status (`AskUserQuestion` is a BLOCK, an interrupt is a FINISHED TURN, the idle
/// nudge is not a raised hand) lived nowhere near the case they governed. `rust/slopdesk-hookevent`
/// owns both halves now; Swift marshals.
///
/// The Swift MARSHALLER over that reader is gone too, and this rule names no file it must still
/// exist in. It could not: a body now crosses as raw bytes inside the fold that reads it, so a Swift
/// file whose whole job was to turn a body into an event is a decode with nothing left to hand its
/// answer to. The standalone `slopdesk_hook_event_parse` door went with it — a door nothing calls is
/// a second way to ask what `slopdesk_agent_detector_hook` already answers.
#[must_use]
pub fn one_reading_of_a_hook_body(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"(enum|struct) *(HookPayload|StopInfo|ToolUseBlock|NotificationInfo|ClaudeHookBody|ClaudeHookEvent)\b|func +(mapToHookEvent|classifyNotification|stopLabel)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift hook-body parser is back in Sources/ ({files}) — rust/slopdesk-hookevent owns \
                      the reading AND the mapping",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: "slopdesk_hook_event_parse",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a standalone hook-body door is back ({files}) — the body crosses raw, inside \
                      slopdesk_agent_detector_hook",
        },
        // The DETECTOR used to be named here as the one caller of that door. It is not a caller at
        // all now: the body crosses as raw bytes and the Rust detector reads it on the far side, in
        // the same call that folds it. So this inverts — a body read on the Swift side of the fold
        // is a reading that has to agree with the Rust one.
        Claim::Lacks {
            path: SWIFT_DETECTOR,
            pattern: "ClaudeHookBody|JSONSerialization|hook_event_name",
            view: View::Code,
            message: "ClaudePaneDetector.swift reads a hook body — it hands the raw bytes to \
                      slopdesk_agent_detector_hook, which reads them once",
        },
        // The LISTENER routes now and reads nothing, so this inverts too: a body read back there is
        // a second fold growing back, which is stronger than "it still uses the right door".
        Claim::Lacks {
            path: "Sources/SlopDeskHost/AgentHookListener.swift",
            pattern: "ClaudeHookBody|ClaudeStatusMachine",
            view: View::Code,
            message: "AgentHookListener.swift reads a hook body again — the listener ROUTES; the pane's \
                      detector is what folds",
        },
        Claim::Mentions {
            path: "rust/slopdesk-hookevent/src/lib.rs",
            names: &["pub fn parse", "fn classify", "fn stop_label", "fn question_label"],
            message: "rust/slopdesk-hookevent/src/lib.rs lost {entry} — one body, one reading, one meaning",
        },
    ];
    check_all(tree, &claims)
}

/// And ONE state machine per pane
///
/// The fusion landed, and the machine it replaced kept compiling anyway: `ForegroundProcessDetector`,
/// holding its own `ClaudeStatusMachine`, its own basename edge anchor and its own status dedupe
/// anchor, constructed by nothing in `Sources/` and kept alive by a test file of its own. It was
/// TWO, not one: `AgentHookHandler` beside the hook listener did the same thing for the same reason.
///
/// Counted rather than named, because the failure is arithmetic — and the count is now ZERO, because
/// the FUSION itself moved: `rust/slopdesk-agent::detector` owns the two dedupe anchors, the
/// stickiness clock and its two absence suppressors, the block-class carry, the intent latch and the
/// title ownership record, and it is the only thing anywhere that constructs a machine.
/// `ClaudePaneDetector` is the handle over it plus the `WireMessage` shapes, which is the one part
/// that has to stay Swift. Each rule pattern carries its open paren: without it `fn topic_line`
/// matches `fn topic_lineX`, and a rule renamed out of existence would satisfy the claim that exists
/// to notice exactly that.
#[must_use]
pub fn one_pane_detector_and_the_probes_only_probe(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"ClaudeStatusMachine\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a ClaudeStatusMachine is constructed in Sources/ ({files}) — the ONE per pane is \
                      rust/slopdesk-agent's PaneDetector (docs/50)",
        },
        Claim::Names {
            path: SWIFT_DETECTOR,
            needle: "slopdesk_agent_detector_new(",
            message: "ClaudePaneDetector.swift stopped opening the Rust detector — it is the handle over the \
                      fusion, not a second one",
        },
        // A handle holds no fold state. Each name below WAS a field here, and each is now an anchor
        // the crate owns; one reappearing means the Swift face started deciding again, in parallel.
        Claim::Lacks {
            path: SWIFT_DETECTOR,
            pattern: "lastEmittedName|lastEmittedIntent|lastEmittedStatus =|hookAuthority|lastNotificationKind|agentOwnsTitle|lastAuthoritativeAt",
            view: View::Code,
            message: "ClaudePaneDetector.swift grew fold state back — every anchor belongs to \
                      rust/slopdesk-agent::detector (docs/50)",
        },
        Claim::Mentions {
            path: "rust/slopdesk-agent/src/detector.rs",
            names: &[
                "fn sample(",
                "fn hook(",
                "fn report(",
                "fn tick(",
                "fn screen(",
                "fn title(",
                "fn user_input(",
                "fn reestablish_on_reattach(",
                "fn intent_line(",
                "fn topic_line(",
                "fn block_kind(",
            ],
            message: "rust/slopdesk-agent/src/detector.rs lost {entry} — the fusion is one place or it is two",
        },
        // The probe file is the shim half of that split, and it must stay a shim: the moment it
        // folds a signal or holds an emit anchor it has become the reducer again, under a new name.
        Claim::Lacks {
            path: SWIFT_FOREGROUND,
            pattern: "ClaudeStatusMachine|lastEmitted|struct Emission|mutating func sample|mutating func tick",
            view: View::Code,
            message: "ForegroundProcessProbes.swift decides something — the probes resolve a NAME, \
                      ClaudePaneDetector folds it (docs/50)",
        },
        // And the triple stays one type. Three emitters anchor on it; a fourth spelling of the same
        // three fields is how the dedupe anchors drift into two answers for "is this a repeat".
        Claim::Names {
            path: "Sources/SlopDeskAgentDetect/ClaudeStatus.swift",
            needle: "public struct ClaudeStatusTriple:",
            message: "ClaudeStatusTriple left Sources/SlopDeskAgentDetect/ClaudeStatus.swift — it is the \
                      vocabulary's, not an emitter's",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: "struct StatusTriple",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a second status triple is declared in Sources/ ({files}) — ClaudeStatusTriple is the \
                      one shape of a type-27 emit",
        },
    ];
    check_all(tree, &claims)
}

/// One vocabulary of secret shapes, for the title and for the paste
///
/// Ten compiled `NSRegularExpression`s masked credentials out of untrusted titles, and a second
/// Swift heuristic decided whether typing the clipboard would leak one. Both read the SAME shapes,
/// and the paste guard reached the redactor to say so — one rule with two callers, spelled twice.
#[must_use]
pub fn one_vocabulary_of_secret_shapes(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: SWIFT_REDACTOR,
            pattern: "NSRegularExpression|AKIA|ghp_|xox|AIza",
            view: View::Code,
            message: "SecretRedactor.swift compiles the secret shapes in Swift — \
                      slopdesk-workspace::secrets scans them",
        },
        Claim::Lacks {
            path: SWIFT_SECRET_PASTE,
            pattern: "shannonEntropy|charClassCount|log2",
            view: View::Code,
            message: "SecretPasteClassifier.swift measures entropy in Swift — the crate sums it in a \
                      deterministic order",
        },
        // The shell asked "does EITHER face mention this door", which passed while one face carried
        // all three. Each door is pinned to the face that actually asks it, so a face that stopped
        // asking is named rather than covered by its neighbour.
        Claim::Mentions {
            path: SWIFT_REDACTOR,
            names: &["slopdesk_ws_redact_secrets"],
            message: "SecretRedactor.swift has stopped asking {entry} — the faces must ask the door, not \
                      restate it",
        },
        Claim::Mentions {
            path: SWIFT_SECRET_PASTE,
            names: &["slopdesk_ws_paste_risk", "slopdesk_ws_looks_secret"],
            message: "SecretPasteClassifier.swift has stopped asking {entry} — the faces must ask the door, \
                      not restate it",
        },
        Claim::Census {
            label: "the PasteRisk case count",
            cases: Extract::code(SWIFT_SECRET_PASTE, "^    case ").within("^public enum PasteRisk", "^}"),
            declared: Extract::code(
                "rust/slopdesk-workspace/src/secrets.rs",
                r"pub const ALL: \[Self; ([0-9]+)\]",
            ),
        },
    ];
    check_all(tree, &claims)
}

/// What a fresh install carries is spelled once
///
/// The product defaults sat in a Swift `init`'s default arguments AND in the config crate's own test
/// fixture, six values apiece with nothing connecting the two lists. A fixture that restates the
/// other language's constants is the cross-language mirror `CLAUDE.md` bans, and the two colours
/// were already the same literal in both files.
#[must_use]
pub fn what_a_fresh_install_carries(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: SWIFT_TERMPREFS,
            pattern: r#"22212C|F8F8F2|"SF Mono"|= 10000"#,
            view: View::Code,
            message: "TerminalPreferences.swift spells a factory default in Swift — \
                      slopdesk-terminal::config carries them",
        },
        Claim::Names {
            path: SWIFT_TERMPREFS,
            needle: "slopdesk_terminal_factory_text",
            message: "TerminalPreferences.swift stopped asking the door — the defaults are read, not retyped",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/src/config.rs",
            needle: "pub const fn factory",
            message: "rust/slopdesk-terminal/src/config.rs lost its factory — the fixture and the app read \
                      one answer",
        },
        Claim::AtLeast {
            path: "rust/slopdesk-terminal/src/config.rs",
            pattern: "FACTORY_",
            minimum: 7,
            message: "rust/slopdesk-terminal/src/config.rs carries only {found} FACTORY_ lines — each \
                      default is named once",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    #[test]
    fn the_badge_ladder_census_compares_two_live_readings() {
        let fixture = Fixture::new("agent-fold-badge");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    super::SWIFT_BADGE_KIND,
                    "public enum TabBadgeKind: UInt8 {\n    case none\n    case busy\n}\n",
                )
                .write(super::SWIFT_BADGE, "slopdesk_agent_tab_badge\n")
                .write(
                    "rust/slopdesk-agent/src/badge.rs",
                    "pub const ALL: [Self; 2] = [];\n",
                );
        };
        seed(&fixture);
        assert!(super::one_badge_ladder_for_a_tab_row(&fixture.tree()).is_clean());

        // A rung added on one side only.
        fixture.write(
            "rust/slopdesk-agent/src/badge.rs",
            "pub const ALL: [Self; 3] = [];\n",
        );
        assert!(!super::one_badge_ladder_for_a_tab_row(&fixture.tree()).is_clean());

        // A rename that breaks BOTH readings leaves two zeros, which agree — and must still fail.
        seed(&fixture);
        fixture
            .write(
                super::SWIFT_BADGE_KIND,
                "public enum TabBadgeRung: UInt8 {\n    case none\n}\n",
            )
            .write("rust/slopdesk-agent/src/badge.rs", "pub const EVERY: [Self; 1] = [];\n");
        assert!(!super::one_badge_ladder_for_a_tab_row(&fixture.tree()).is_clean());

        // And the ladder walked in Swift again.
        seed(&fixture);
        fixture.append(super::SWIFT_BADGE, "let s = sudoBasenames\n");
        assert!(!super::one_badge_ladder_for_a_tab_row(&fixture.tree()).is_clean());
    }

    fn hook(fixture: &Fixture) {
        fixture
            .write("Sources/Generated.swift", "kept so the ban has a haystack\n")
            .write(super::SWIFT_DETECTOR, "kept so the ban has a haystack\n")
            .write(
                "Sources/SlopDeskHost/AgentHookListener.swift",
                "kept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-hookevent/src/lib.rs",
                "pub fn parse\nfn classify\nfn stop_label\nfn question_label\n",
            );
    }

    #[test]
    fn the_hook_body_is_read_on_one_side_of_the_fold() {
        let fixture = Fixture::new("agent-fold-hook");
        hook(&fixture);
        assert!(super::one_reading_of_a_hook_body(&fixture.tree()).is_clean());

        // A Swift parser back under any path.
        fixture.append("Sources/Generated.swift", "struct HookPayload {}\n");
        assert!(!super::one_reading_of_a_hook_body(&fixture.tree()).is_clean());

        // The listener folding again rather than routing.
        hook(&fixture);
        fixture.append(
            "Sources/SlopDeskHost/AgentHookListener.swift",
            "var machine = ClaudeStatusMachine\n",
        );
        assert!(!super::one_reading_of_a_hook_body(&fixture.tree()).is_clean());
    }

    fn detector(fixture: &Fixture) {
        fixture
            .write("Sources/Generated.swift", "kept so the ban has a haystack\n")
            .write(super::SWIFT_DETECTOR, "slopdesk_agent_detector_new(\n")
            .write(super::SWIFT_FOREGROUND, "kept so the ban has a haystack\n")
            .write(
                "Sources/SlopDeskAgentDetect/ClaudeStatus.swift",
                "public struct ClaudeStatusTriple: Equatable {}\n",
            )
            .write(
                "rust/slopdesk-agent/src/detector.rs",
                "fn sample(\nfn hook(\nfn report(\nfn tick(\nfn screen(\nfn title(\nfn user_input(\n\
                 fn reestablish_on_reattach(\nfn intent_line(\nfn topic_line(\nfn block_kind(\n",
            );
    }

    #[test]
    fn a_second_machine_per_pane_is_caught_by_construction() {
        let fixture = Fixture::new("agent-fold-detector");
        detector(&fixture);
        assert!(super::one_pane_detector_and_the_probes_only_probe(&fixture.tree()).is_clean());

        // A machine constructed anywhere in Sources/, even if nothing but a test reaches it.
        fixture.append("Sources/Generated.swift", "let m = ClaudeStatusMachine()\n");
        assert!(!super::one_pane_detector_and_the_probes_only_probe(&fixture.tree()).is_clean());

        // The handle growing an anchor back.
        detector(&fixture);
        fixture.append(super::SWIFT_DETECTOR, "var lastEmittedName: String?\n");
        assert!(!super::one_pane_detector_and_the_probes_only_probe(&fixture.tree()).is_clean());

        // And the probe deciding rather than probing.
        detector(&fixture);
        fixture.append(super::SWIFT_FOREGROUND, "mutating func tick(at: Date) {}\n");
        assert!(!super::one_pane_detector_and_the_probes_only_probe(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_secret_vocabulary_crosses_with_its_discriminant() {
        let fixture = Fixture::new("agent-fold-secrets");
        let seed = |fixture: &Fixture| {
            fixture
                .write(super::SWIFT_REDACTOR, "slopdesk_ws_redact_secrets\n")
                .write(
                    super::SWIFT_SECRET_PASTE,
                    "slopdesk_ws_paste_risk\nslopdesk_ws_looks_secret\npublic enum PasteRisk {\n    \
                     case none\n    case likely\n}\n",
                )
                .write(
                    "rust/slopdesk-workspace/src/secrets.rs",
                    "pub const ALL: [Self; 2] = [];\n",
                );
        };
        seed(&fixture);
        assert!(super::one_vocabulary_of_secret_shapes(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-workspace/src/secrets.rs",
            "pub const ALL: [Self; 4] = [];\n",
        );
        assert!(!super::one_vocabulary_of_secret_shapes(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.append(super::SWIFT_REDACTOR, "NSRegularExpression(pattern: \"AKIA\")\n");
        assert!(!super::one_vocabulary_of_secret_shapes(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_factory_defaults_are_read_rather_than_retyped() {
        let fixture = Fixture::new("agent-fold-factory");
        let seed = |fixture: &Fixture| {
            fixture
                .write(super::SWIFT_TERMPREFS, "slopdesk_terminal_factory_text\n")
                .write(
                    "rust/slopdesk-terminal/src/config.rs",
                    "pub const fn factory\nFACTORY_A\nFACTORY_B\nFACTORY_C\nFACTORY_D\nFACTORY_E\n\
                     FACTORY_F\nFACTORY_G\n",
                );
        };
        seed(&fixture);
        assert!(super::what_a_fresh_install_carries(&fixture.tree()).is_clean());

        // A default dropped on the Rust side.
        fixture.write(
            "rust/slopdesk-terminal/src/config.rs",
            "pub const fn factory\nFACTORY_A\nFACTORY_B\n",
        );
        assert!(!super::what_a_fresh_install_carries(&fixture.tree()).is_clean());

        // Or retyped on the Swift side.
        seed(&fixture);
        fixture.append(super::SWIFT_TERMPREFS, "let background = \"22212C\"\n");
        assert!(!super::what_a_fresh_install_carries(&fixture.tree()).is_clean());
    }
}
