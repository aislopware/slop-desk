//! `docs/56` stage D: the four modal surfaces the split draws twice, and the shared host that must
//! stay the phone's alone.
//!
//! Ported from the deleted `check-supervisor.sh`. Each surface is drawn by two views and worded by
//! one type. What is banned in the views is not "a string" but a SECOND DERIVATION — an excerpt
//! cut, a verb table, a confirmation's shape — because those drift silently: one half quietly grows
//! an action the other has not got, and nothing is red until somebody notices their phone is
//! different.
//!
//! Three claims did NOT come across. The shell asked `grep -A4 'draws:' MacWorkspaceRootView.swift`
//! for `.peekReply`, `.globalSearch` and `.palette`; `draws:` exists nowhere in the tree and that
//! file no longer names `OverlayHostView` at all, so all three had been matching nothing and
//! passing for it. The claim that carries the same meaning and is live — the host is not mounted
//! over the Mac's split at all — is [`the_stage_d_ledger_is_empty`].

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const PHONE_HOST: &str = "Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift";
const PHONE_SWITCHER: &str = "Sources/SlopDeskPhoneUI/Overlays/PaneSwitcherOverlay.swift";
const MAC_SWITCHER: &str = "Sources/SlopDeskMacUI/Overlays/MacPaneSwitcher.swift";
const MAC_PEEK: &str = "Sources/SlopDeskMacUI/Overlays/MacPeekReply.swift";
const PHONE_PEEK: &str = "Sources/SlopDeskPhoneUI/Overlays/PeekReplyOverlay.swift";
const MAC_SEARCH: &str = "Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift";
const PHONE_SEARCH: &str = "Sources/SlopDeskPhoneUI/Overlays/GlobalSearchView.swift";
const MAC_PICKER: &str = "Sources/SlopDeskMacUI/Overlays/MacOpenQuickly.swift";
const PHONE_PICKER: &str = "Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift";
const MAC_PALETTE: &str = "Sources/SlopDeskMacUI/Overlays/MacPalette.swift";
const PHONE_PALETTE: &str = "Sources/SlopDeskPhoneUI/Overlays/PaletteView.swift";
const MAC_ROOT: &str = "Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift";

/// The shared overlay host holds no AMBIENT layer, and the ⌃⇥ walk has two halves
///
/// `docs/56` stage D's dividend, and the reason it is a gate: an ALWAYS-MOUNTED full-bleed
/// `SwiftUI` layer claims every hit inside its bounds, and the only way to survive that is a
/// hit-testing flag someone has to keep honest. That is what `allowsHitTesting` on this file means
/// and why it stays banned — a layer mounted only while its state is live needs no such flag.
///
/// The ⌃⇥ CARD is NOT that hazard and is no longer forbidden. It was, on the reading that "the
/// phone has no modifier stream to open the gesture with, so a second half could never render" —
/// which was about the OPENING CHORD and was never the only way in: the binding row is
/// `Platform::Both` (`rust/slopdesk-workspace/src/binding_rows.rs`) and the palette carries the
/// same row. The phone opened the gesture, `PaneRecedeScrim` veiled every pane off
/// `store.paneSwitcher`, and nothing drew — a veiled workspace with no way to step, commit or
/// cancel. So the gate is inverted: the phone's half must EXIST, and both halves must keep reading
/// the shared row builder and measurements.
///
/// Comment lines are stripped first: the file's header is where the history is RECORDED, and it has
/// to be free to name what left (and what came back) without the gate reading prose as a
/// regression.
#[must_use]
pub fn the_overlay_host_holds_no_ambient_layer(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: PHONE_HOST,
            pattern: "allowsHitTesting",
            view: View::Code,
            message: "the shared overlay host grew an ambient layer again — an always-mounted host eats the \
                      split's clicks",
        },
        Claim::Exists {
            path: PHONE_SWITCHER,
            message: "the phone has no ⌃⇥ card — a gesture that veils every pane and draws nothing is a \
                      soft lockup",
        },
        // The phone's card may not grow a SECOND commit door. `commitPaneSwitcher()` unwinds the
        // follow-along preview before it stages focus and refuses a candidate whose pane closed under
        // the gesture; a view reaching past it for `revealPaneTree` has neither guard, and both
        // failures are silent.
        Claim::Lacks {
            path: PHONE_SWITCHER,
            pattern: "revealPaneTree",
            view: View::Code,
            message: "the phone's ⌃⇥ card commits past commitPaneSwitcher() — the preview unwind and the \
                      dead-pane refusal are its",
        },
        Claim::Mentions {
            path: MAC_SWITCHER,
            names: &["PaneSwitcherRowsBuilder", "PaneSwitcherMetrics"],
            message: "MacPaneSwitcher.swift stopped reading {entry} — the card's rows and measurements live \
                      below the view",
        },
        Claim::Mentions {
            path: PHONE_SWITCHER,
            names: &["PaneSwitcherRowsBuilder", "PaneSwitcherMetrics"],
            message: "PaneSwitcherOverlay.swift stopped reading {entry} — the card's rows and measurements \
                      live below the view",
        },
    ];
    check_all(tree, &claims)
}

/// One peek card, two frameworks
///
/// `docs/56` stage D's second MODAL surface, and the first whose CONTENT moves under it: a reply
/// advances the queue and the card is re-cut for the next blocked pane. The two halves may arrange
/// it differently and must not word it differently — `PeekReplyPresentation` owns the header
/// caption, the "N of M" counter, the stand-in note for a pane with no reported question and the
/// zero-state line, and `AgentReadout` owns the status→glyph→ink reading both halves draw.
///
/// The status glyph crossed as a design-system LEAF (`MacAgentGlyphView`), which is only allowed
/// because the decision under it did not: a status becomes a reading and an ink in `AgentReadout`,
/// and each framework does the ladder lookup alone (`Slate.agentInk` / `Slate.Native.agentInk`).
#[must_use]
pub fn one_peek_card_two_frameworks(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: MAC_PEEK,
            names: &["PeekReplyPresentation"],
            message: "MacPeekReply.swift stopped reading {entry} — the two peek cards would drift on the \
                      first copy change",
        },
        Claim::Mentions {
            path: PHONE_PEEK,
            names: &["PeekReplyPresentation"],
            message: "PeekReplyOverlay.swift stopped reading {entry} — the two peek cards would drift on \
                      the first copy change",
        },
        // The caption's join is the piece that looks too small to share and is not: the scent goes
        // LAST so a tail truncation eats the prose first and the status word never.
        //
        // Comments are stripped first: both halves' headers NAME the copy they no longer spell, and a
        // gate that read its own rationale as a regression would make the departure undocumentable.
        Claim::NoneOf {
            paths: &[MAC_PEEK, PHONE_PEEK],
            pattern: r#"\\\(label\) · |"Peek & Reply"|The agent is waiting for your input"#,
            view: View::Code,
            message: "{files} respells a peek-card string — every one of them is PeekReplyPresentation's",
        },
        Claim::Mentions {
            path: MAC_PEEK,
            names: &["AgentReadout"],
            message: "the Mac's peek header stopped reading {entry} — two spellings of one pane's state",
        },
    ];
    check_all(tree, &claims)
}

/// The paste-as-keystrokes table and the peek RULES are Rust's, and only Rust's
///
/// `KeystrokeReplay` and `PeekReply` crossed in `docs/56` §4. What is left in Swift is marshalling
/// and the vocabulary types; the US-QWERTY table, the grapheme rule, the pane scan and the queue
/// arithmetic are `slopdesk_workspace::{keystroke_replay, peek_reply}` and
/// `slopdesk_agent::attention`.
///
/// ⚠️ THE UNIT IS A GRAPHEME CLUSTER, AND THE FIELD SHOWS DOTS. Walked as scalars, a decomposed `é`
/// types a bare `e` and reports one skip — a DIFFERENT password, accepted, with nothing on screen
/// to say so. `unicode-segmentation` is what makes the cluster the unit, and it is not an
/// optimisation anyone may drop as unused.
#[must_use]
pub fn the_keystroke_table_and_peek_rules_are_rusts(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Video/KeystrokeReplay.swift",
            needle: "slopdesk_",
            message: "KeystrokeReplay.swift stopped asking the door — a rule decided in Swift is the second \
                      implementation (docs/56 §4)",
        },
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift",
            needle: "slopdesk_",
            message: "PeekReply.swift stopped asking the door — a rule decided in Swift is the second \
                      implementation (docs/56 §4)",
        },
        Claim::Matches {
            path: "rust/slopdesk-workspace/Cargo.toml",
            pattern: "^unicode-segmentation",
            view: View::Raw,
            message: "slopdesk-workspace dropped unicode-segmentation — chars() would type a decomposed é \
                      as a bare e",
        },
        Claim::Names {
            path: "rust/slopdesk-workspace/src/keystroke_replay.rs",
            needle: "UnicodeSegmentation",
            message: "the keystroke table stopped walking graphemes — see the ⚠️ in its module header",
        },
        // The cap is ONE number. Swift reads the `#define`; the crate exports the same constant and a
        // test asserts they agree, because a Swift-side copy that drifted LOW would silently truncate
        // a password.
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Video/KeystrokeReplay.swift",
            needle: "Int(SLOPDESK_KEYSTROKE_MAX_LENGTH)",
            message: "KeystrokeReplay.maxLength stopped reading the header define — a drifting cap \
                      truncates a password",
        },
    ];
    check_all(tree, &claims)
}

/// One global search, two frameworks
///
/// `docs/56` stage D's third MODAL surface. What the two halves must not re-derive is not copy this
/// time so much as READING: `GlobalSearchPresentation.excerptSlices` cuts a hit's excerpt around a
/// UTF-16 highlight range that can land inside a surrogate pair, and the rule for that case —
/// degrade to a flat excerpt, never trap, never guess a run — has to be one rule or the half that
/// re-wrote it indexes out of bounds on the first scrollback line containing an emoji.
///
/// The mode pills are a VALUE both surfaces read, which is the only way the locked "the find bar
/// and the global-search query bar render the pills IDENTICALLY" invariant survives one of them
/// becoming an `NSView`.
#[must_use]
pub fn one_global_search_two_frameworks(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: MAC_SEARCH,
            names: &["GlobalSearchPresentation", "FindModePill"],
            message: "MacGlobalSearch.swift stopped reading {entry} — two cuts of one excerpt, one of them \
                      wrong",
        },
        Claim::Mentions {
            path: PHONE_SEARCH,
            names: &["GlobalSearchPresentation", "FindModePill"],
            message: "GlobalSearchView.swift stopped reading {entry} — two cuts of one excerpt, one of them \
                      wrong",
        },
        // Comments are stripped first, for the peek gate's reason: both headers NAME what they no
        // longer spell. The two zero-state lines and a hand-rolled UTF-16 walk are the regressions.
        Claim::NoneOf {
            paths: &[MAC_SEARCH, PHONE_SEARCH],
            pattern: r"No results\.|scrollback\.”|samePosition\(in:",
            view: View::Code,
            message: "{files} respells a global-search string or re-derives the excerpt cut — both are \
                      GlobalSearchPresentation's",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift",
            pattern: r#""Case sensitive"|"Whole word"|"Regex \(ICU\)""#,
            view: View::Code,
            message: "TerminalFindBar respells a mode pill — the labels and help are FindModePill's, for \
                      all three surfaces",
        },
    ];
    check_all(tree, &claims)
}

/// One picker, two frameworks
///
/// `docs/56` stage D's LAST modal surface. The verb table is the piece that must not be written
/// twice: unlike a copy string it does not fail loudly when it drifts — one half quietly grows an
/// action the other has not got, and nothing is red until a user notices their phone's picker is
/// different.
#[must_use]
pub fn one_picker_two_frameworks(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: MAC_PICKER,
            names: &[
                "OpenQuicklyPresentation",
                "OpenQuicklyActions",
                "OpenQuicklyMetrics",
            ],
            message: "MacOpenQuickly.swift stopped reading {entry} — two pickers, and the drift would be \
                      silent",
        },
        Claim::Mentions {
            path: PHONE_PICKER,
            names: &[
                "OpenQuicklyPresentation",
                "OpenQuicklyActions",
                "OpenQuicklyMetrics",
            ],
            message: "OpenQuicklyView.swift stopped reading {entry} — two pickers, and the drift would be \
                      silent",
        },
        // Comments are stripped first, for the peek gate's reason: both headers NAME what they no
        // longer spell. A verb title, a footer hint or a zero-state line in code is the regression.
        Claim::NoneOf {
            paths: &[MAC_PICKER, PHONE_PICKER],
            pattern: r#""Split Right"|"Reopen Tab"|"Copy Session ID"|"No matches"|"Quick Select"|"Change Directory""#,
            view: View::Code,
            message: "{files} respells a picker verb or hint — every one of them is \
                      OpenQuicklyPresentation's or OpenQuicklyActions's",
        },
        // The fzf mark is cut in ONE place for all four surfaces that draw one (the palette and the
        // picker, each drawn twice). A half walking `titleRanges` itself is a fifth cut waiting to
        // disagree.
        Claim::Mentions {
            path: MAC_PALETTE,
            names: &["FuzzyMatcher.runs("],
            message: "MacPalette.swift stopped reading {entry} — a fifth spelling of one fzf mark",
        },
        Claim::Mentions {
            path: MAC_PICKER,
            names: &["FuzzyMatcher.runs("],
            message: "MacOpenQuickly.swift stopped reading {entry} — a fifth spelling of one fzf mark",
        },
        Claim::Mentions {
            path: PHONE_PALETTE,
            names: &["FuzzyMatcher.runs("],
            message: "PaletteView.swift stopped reading {entry} — a fifth spelling of one fzf mark",
        },
        Claim::Mentions {
            path: PHONE_PICKER,
            names: &["FuzzyMatcher.runs("],
            message: "OpenQuicklyView.swift stopped reading {entry} — a fifth spelling of one fzf mark",
        },
    ];
    check_all(tree, &claims)
}

/// …and the stage-D ledger is empty
///
/// THE LEDGER IS GONE, which is what stage D was counting to. `draws` let the Mac drop the shared
/// host's cards one at a time; with the last one moved it must not come back, and the host's card
/// machinery is the phone's alone. NOTHING SWIFTUI FLOATS OVER THE MAC's SPLIT either: the Mac's
/// last two tenants, the Connect FORM and the close-confirmation ALERT, are `AppKit` sheets driven
/// from the scene. Re-mounting the host is not a cosmetic regression — an `NSHostingView` claims
/// every hit inside its own bounds, so an always-mounted `SwiftUI` layer over the split makes the
/// window click-dead everywhere its ink is not (`docs/56` §3.5, measured 2026-08-17).
///
/// What is left over the Mac's split is two SHEETS and two shared wordings, and both wordings are
/// here for the same reason the cards' were: a dialog that says the wrong true-sounding thing looks
/// exactly like one that says the right thing.
#[must_use]
pub fn the_stage_d_ledger_is_empty(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: PHONE_HOST,
            pattern: "draws",
            view: View::Code,
            message: "the transitional `draws` ledger is back in OverlayHostView — every card has left the \
                      Mac",
        },
        Claim::Lacks {
            path: MAC_ROOT,
            pattern: "OverlayHostView",
            view: View::Raw,
            message: "MacWorkspaceRootView mounts the shared host again — an NSHostingView over the split \
                      eats the clicks",
        },
        // The two surfaces that were never cards exist on the Mac and are DRIVEN. Each defaults to
        // doing nothing when nobody reconciles it, which is exactly the failure that reads as "the
        // flag never flipped": a Connect chord that opens no window, a parked close that never asks.
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Overlays/MacOverlayPanels.swift",
            names: &["MacConnectSheet", "MacCloseConfirmation"],
            message: "{entry} is not reconciled by MacOverlayPanels — the Mac would never raise it",
        },
        // ONE WORDING for the confirmation, and it is `CloseConfirmationCopy`. Which line a park
        // deserves is three branches and a join; a half that respells any of them drifts silently,
        // because a dialog that says the wrong true-sounding thing looks exactly like one that says
        // the right thing.
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Overlays/MacCloseConfirmation.swift",
            names: &["CloseConfirmationCopy"],
            message: "MacCloseConfirmation.swift stopped reading {entry} — two dialogs, and the drift would \
                      be silent",
        },
        Claim::Mentions {
            path: PHONE_HOST,
            names: &["CloseConfirmationCopy"],
            message: "OverlayHostView.swift stopped reading {entry} — two dialogs, and the drift would be \
                      silent",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Overlays/MacCloseConfirmation.swift",
                PHONE_HOST,
            ],
            pattern: r#""A process is still running|"This window has multiple tabs|Closing it will close the project"#,
            view: View::Code,
            message: "{files} respells the close-confirmation copy — every line of it is \
                      CloseConfirmationCopy's",
        },
        // ONE SHAPE for the three clipboard questions, and it is `ClipboardConfirmPresentation`. The
        // WORDS were never in danger — they are `slopdesk_terminal::paste`'s, reached through
        // `PasteSafetyAnalyzer` — but the SHAPE was decided twice: bullets or the ask's reason, the
        // preview or nothing, the bullet glyph, the caption. A half that respells any of it is a
        // second guard saying something slightly different about the same payload, which is the
        // failure increment 65 found on the phone in its worst form (a `#else` that auto-approved).
        // The `informativeText` join lives in the shared type for the same reason: it is a
        // serialisation, not a layout, so an `NSAlert` reads it rather than composing one beside
        // itself.
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift",
            names: &["ClipboardConfirmPresentation"],
            message: "PasteProtectionSheet.swift stopped reading {entry} — two guards, and the drift would \
                      be silent",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCard.swift",
            names: &["ClipboardConfirmPresentation"],
            message: "ClipboardConfirmCard.swift stopped reading {entry} — two guards, and the drift would \
                      be silent",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift",
                "Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCard.swift",
            ],
            pattern: r#""Clipboard preview|"•"#,
            view: View::Code,
            message: "{files} respells the clipboard confirmation's shape — the bullet and the caption are \
                      the shared type's",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn switcher(fixture: &Fixture) {
        fixture
            .write(
                super::PHONE_HOST,
                "// allowsHitTesting is named in prose only\nstruct OverlayHostView: View {}\n",
            )
            .write(
                super::PHONE_SWITCHER,
                "PaneSwitcherRowsBuilder\nPaneSwitcherMetrics\ncommitPaneSwitcher()\n",
            )
            .write(
                super::MAC_SWITCHER,
                "PaneSwitcherRowsBuilder\nPaneSwitcherMetrics\n",
            );
    }

    #[test]
    fn the_host_stays_unmounted_and_both_halves_walk() {
        let fixture = Fixture::new("overlay-switcher");
        switcher(&fixture);
        // The header may NAME the flag; only code may not carry it.
        assert!(super::the_overlay_host_holds_no_ambient_layer(&fixture.tree()).is_clean());

        fixture.append(super::PHONE_HOST, ".allowsHitTesting(false)\n");
        assert!(!super::the_overlay_host_holds_no_ambient_layer(&fixture.tree()).is_clean());

        // The second commit door.
        switcher(&fixture);
        fixture.append(super::PHONE_SWITCHER, "store.revealPaneTree(id)\n");
        assert!(!super::the_overlay_host_holds_no_ambient_layer(&fixture.tree()).is_clean());

        // A half that stopped reading the shared measurements.
        switcher(&fixture);
        fixture.write(super::MAC_SWITCHER, "PaneSwitcherRowsBuilder\n");
        assert!(!super::the_overlay_host_holds_no_ambient_layer(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_peek_card_is_worded_once() {
        let fixture = Fixture::new("overlay-peek");
        let seed = |fixture: &Fixture| {
            fixture
                .write(super::MAC_PEEK, "PeekReplyPresentation\nAgentReadout\n")
                .write(super::PHONE_PEEK, "PeekReplyPresentation\n");
        };
        seed(&fixture);
        assert!(super::one_peek_card_two_frameworks(&fixture.tree()).is_clean());

        fixture.append(super::PHONE_PEEK, "Text(\"Peek & Reply\")\n");
        assert!(!super::one_peek_card_two_frameworks(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.write(super::MAC_PEEK, "PeekReplyPresentation\n");
        assert!(!super::one_peek_card_two_frameworks(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_keystroke_unit_stays_a_grapheme() {
        let fixture = Fixture::new("overlay-keystroke");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    "Sources/SlopDeskWorkspaceCore/Video/KeystrokeReplay.swift",
                    "slopdesk_workspace_keystroke_replay\nInt(SLOPDESK_KEYSTROKE_MAX_LENGTH)\n",
                )
                .write(
                    "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift",
                    "slopdesk_workspace_peek\n",
                )
                .write(
                    "rust/slopdesk-workspace/Cargo.toml",
                    "unicode-segmentation = \"1\"\n",
                )
                .write(
                    "rust/slopdesk-workspace/src/keystroke_replay.rs",
                    "use unicode_segmentation::UnicodeSegmentation;\n",
                );
        };
        seed(&fixture);
        assert!(super::the_keystroke_table_and_peek_rules_are_rusts(&fixture.tree()).is_clean());

        // The dependency dropped as unused is the failure the ⚠️ is about.
        fixture.write("rust/slopdesk-workspace/Cargo.toml", "serde = \"1\"\n");
        assert!(!super::the_keystroke_table_and_peek_rules_are_rusts(&fixture.tree()).is_clean());

        // A cap copied into Swift instead of read from the header.
        seed(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Video/KeystrokeReplay.swift",
            "slopdesk_workspace_keystroke_replay\nlet maxLength = 4096\n",
        );
        assert!(!super::the_keystroke_table_and_peek_rules_are_rusts(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_excerpt_is_cut_once_and_the_pills_are_one_value() {
        let fixture = Fixture::new("overlay-search");
        let seed = |fixture: &Fixture| {
            fixture
                .write(super::MAC_SEARCH, "GlobalSearchPresentation\nFindModePill\n")
                .write(super::PHONE_SEARCH, "GlobalSearchPresentation\nFindModePill\n")
                .write(
                    "Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift",
                    "FindModePill\n",
                );
        };
        seed(&fixture);
        assert!(super::one_global_search_two_frameworks(&fixture.tree()).is_clean());

        // A half re-deriving the UTF-16 walk.
        fixture.append(
            super::PHONE_SEARCH,
            "let i = range.lowerBound.samePosition(in: text)\n",
        );
        assert!(!super::one_global_search_two_frameworks(&fixture.tree()).is_clean());

        // And the find bar respelling a pill.
        seed(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift",
            "Toggle(\"Whole word\", isOn: $whole)\n",
        );
        assert!(!super::one_global_search_two_frameworks(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_picker_is_one_verb_table_and_the_ledger_is_empty() {
        let fixture = Fixture::new("overlay-picker");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    super::MAC_PICKER,
                    "OpenQuicklyPresentation\nOpenQuicklyActions\nOpenQuicklyMetrics\nFuzzyMatcher.runs(\n",
                )
                .write(
                    super::PHONE_PICKER,
                    "OpenQuicklyPresentation\nOpenQuicklyActions\nOpenQuicklyMetrics\nFuzzyMatcher.runs(\n",
                )
                .write(super::MAC_PALETTE, "FuzzyMatcher.runs(\n")
                .write(super::PHONE_PALETTE, "FuzzyMatcher.runs(\n")
                .write(super::PHONE_HOST, "CloseConfirmationCopy\n")
                .write(super::MAC_ROOT, "MacSplitView()\n")
                .write(
                    "Sources/SlopDeskMacUI/Overlays/MacOverlayPanels.swift",
                    "MacConnectSheet\nMacCloseConfirmation\n",
                )
                .write(
                    "Sources/SlopDeskMacUI/Overlays/MacCloseConfirmation.swift",
                    "CloseConfirmationCopy\n",
                )
                .write(
                    "Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift",
                    "ClipboardConfirmPresentation\n",
                )
                .write(
                    "Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCard.swift",
                    "ClipboardConfirmPresentation\n",
                );
        };
        seed(&fixture);
        assert!(super::one_picker_two_frameworks(&fixture.tree()).is_clean());
        assert!(super::the_stage_d_ledger_is_empty(&fixture.tree()).is_clean());

        // The ledger, back.
        fixture.append(super::PHONE_HOST, "let draws: Set<Card> = [.palette]\n");
        assert!(!super::the_stage_d_ledger_is_empty(&fixture.tree()).is_clean());

        // The host re-mounted over the Mac's split.
        seed(&fixture);
        fixture.append(super::MAC_ROOT, "OverlayHostView(store: store)\n");
        assert!(!super::the_stage_d_ledger_is_empty(&fixture.tree()).is_clean());

        // A fifth cut of the fzf mark.
        seed(&fixture);
        fixture.write(super::PHONE_PALETTE, "for run in item.titleRanges {}\n");
        assert!(!super::one_picker_two_frameworks(&fixture.tree()).is_clean());

        // A verb respelled in a half.
        seed(&fixture);
        fixture.append(super::MAC_PICKER, "Button(\"Split Right\") {}\n");
        assert!(!super::one_picker_two_frameworks(&fixture.tree()).is_clean());
    }
}
