//! The two UI shells share a floor, not a clipboard.
//!
//! Ported from the deleted `check-supervisor.sh`. Every other rule in this crate catches a file in
//! the WRONG target — frameworkless, or platform-gated. None of them can catch the thing that
//! actually happened nine times over: a helper, a copy string or a constant that is in the RIGHT
//! target on both sides of the split and spelled twice.
//!
//! `ensureEndpoint` sat in both panel files with a static dedupe key each, pointed at ONE
//! host-global settings file. The Open Quickly picker assembled the same five corpora and
//! snapshotted the same eighteen lines of focused pane in both halves. Every label on the Connect
//! form was typed twice — including three port prompts that were one slot off the real defaults on
//! BOTH sides, which is precisely how a duplicate hides a bug: the two copies agreed, so nothing
//! disagreed with them.
//!
//! So these three ask a different question from every rule around them. Not "is this import
//! missing" — a duplicated helper imports fine — but "does this body / this sentence / this number
//! appear on both sides of a split whose whole purpose is that it does not".

use crate::claim::{Claim, Corpus, SWIFT, View, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// The macOS shell.
const MAC: &str = "Sources/SlopDeskMacUI/";
/// The iOS shell.
const PHONE: &str = "Sources/SlopDeskPhoneUI/";
/// Both, as a ban's roots.
const BOTH: &[&str] = &[MAC, PHONE];

/// No body is written twice across the split
///
/// Eight consecutive substantive lines appearing in both shells. The normalisation, the window and
/// the debt list are all [`Claim::NoCloneAcross`]'s, which is where the reasoning for each lives;
/// what is here is the ledger itself.
///
/// Two of the seven pairs — `CodePanelSurfaces`, `SlopDeskPhoneApp` — have their floor types
/// written already, `CodeServerEnsure` and `ClientNotificationSinks`, and are waiting only on the
/// phone-side edit. The rest are waiting on a floor file nobody has written yet, the GUI/video pane
/// leaf being the largest and the next one worth doing.
///
/// BREAK-TEST (2026-08-22): copied `KeybindingsEditorReading.swift`'s `conflictLines(_:)` body back
/// into BOTH `MacKeybindingsEditor.swift` and `KeybindingsEditorView.swift` as private methods —
/// the exact shape the dedup removed. Rule FIRED, naming both sites. Restored both files by `cp`
/// from /tmp; rule green. Also verified the inverse: with the tree as it stands the rule finds
/// exactly the seven ledgered pairs, i.e. it is not passing by finding nothing.
/// The connect form's own words. Rust, not Swift: the form's vocabulary crossed the FFI
/// boundary with the rest of its reading, and the ban's paired claim has to follow the floor
/// wherever it moved or it starts guarding an empty room — the same move `SEARCH` records.
const CONNECT: &str = "rust/slopdesk-workspace/src/connect_form.rs";
/// The keybindings editor's.
const KEYS: &str = "Sources/SlopDeskClientCore/Settings/KeybindingsEditorReading.swift";
/// A notification's.
const TOAST: &str = "Sources/SlopDeskClientCore/Overlays/ToastPresentation.swift";
/// The cross-tab search field's. Rust, not Swift: the field's words crossed the FFI boundary
/// with the rest of the global-search reading, and the ban's paired claim has to follow the
/// floor wherever it moved or it starts guarding an empty room.
const SEARCH: &str = "rust/slopdesk-workspace/src/global_search.rs";
/// The command palette's.
const PALETTE: &str = "Sources/SlopDeskClientCore/Palette/PalettePresentation.swift";

/// Each sentence, the file that owns it, and the symbol a caller reaches it by.
const OWNED: &[(&str, &str, &str)] = &[
    (
        "Connect to Host",
        CONNECT,
        "slopdesk_workspace::connect_form::Word::Title",
    ),
    (
        "host.local or 10.0.0.7",
        CONNECT,
        "slopdesk_workspace::connect_form::Word::HostPrompt",
    ),
    (
        "Video ports",
        CONNECT,
        "slopdesk_workspace::connect_form::Word::VideoPortsLabel",
    ),
    (
        "Media port",
        CONNECT,
        "slopdesk_workspace::connect_form::Word::MediaPortLabel",
    ),
    (
        "Cursor port",
        CONNECT,
        "slopdesk_workspace::connect_form::Word::CursorPortLabel",
    ),
    ("Keyboard Shortcuts", KEYS, "KeybindingsEditorCopy.title"),
    (
        "Click a shortcut to record a replacement",
        KEYS,
        "KeybindingsEditorCopy.subtitle",
    ),
    ("Search key bindings", KEYS, "KeybindingsEditorCopy.searchPrompt"),
    ("Reset to Default", KEYS, "KeybindingsEditorCopy.resetAction"),
    (
        "Reset every customized shortcut to its default",
        KEYS,
        "KeybindingsEditorCopy.resetHelp",
    ),
    (
        r"Reset all key bindings\?",
        KEYS,
        "KeybindingsEditorCopy.resetConfirmTitle",
    ),
    (
        "This clears every customized shortcut",
        KEYS,
        "KeybindingsEditorCopy.resetConfirmBody",
    ),
    ("Shortcut conflicts", KEYS, "KeybindingsEditorCopy.conflictsTitle"),
    (
        "This shortcut conflicts with another command",
        KEYS,
        "KeybindingsEditorCopy.conflictHelp",
    ),
    ("Dismiss notification", TOAST, "ToastPresentation.dismissLabel"),
    (
        "Jump to the pane this notification came from",
        TOAST,
        "ToastPresentation.jumpHint",
    ),
    (
        "Search across all tabs…",
        SEARCH,
        "slopdesk_workspace::global_search::QUERY_PROMPT",
    ),
    ("Search for commands…", PALETTE, "PalettePresentation.queryPrompt"),
];

#[must_use]
pub fn no_body_crosses_the_ui_split(tree: &Tree) -> Report {
    check_all(tree, &[Claim::NoCloneAcross {
        left: MAC,
        right: PHONE,
        extensions: SWIFT,
        window: 8,
        known: &[
            // GUI/video pane leaf — the largest remaining pair, and the next one worth a floor.
            (
                "Sources/SlopDeskMacUI/Pane/MacGuiLeafView.swift",
                "Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift",
            ),
            (
                "Sources/SlopDeskMacUI/Pane/MacPromptJumpFlashOverlay.swift",
                "Sources/SlopDeskPhoneUI/Pane/PromptJumpFlashOverlay.swift",
            ),
            (
                "Sources/SlopDeskMacUI/Pane/MacTerminalFindBar.swift",
                "Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift",
            ),
            (
                "Sources/SlopDeskMacUI/Pane/MacTerminalLeafView.swift",
                "Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift",
            ),
            // Waiting on `CodeServerEnsure` being called from the phone half.
            (
                "Sources/SlopDeskMacUI/Panel/MacCodePanelSurfaces.swift",
                "Sources/SlopDeskPhoneUI/CodeSidebar/CodePanelSurfaces.swift",
            ),
            (
                "Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift",
                "Sources/SlopDeskPhoneUI/WorkspaceRootView.swift",
            ),
            // Waiting on `ClientNotificationSinks` being called from the phone half.
            (
                "Sources/SlopDeskMacUI/SlopDeskMacApp.swift",
                "Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift",
            ),
        ],
        floor: 50,
        message: "eight identical lines in both UI targets ({pairs}) — one implementation, never two \
                  (docs/56 §3, CLAUDE.md)",
    }])
}

/// A named sentence has one speller
///
/// Every literal below was typed once per shell and now lives in the shared logic target; a UI
/// target that spells one raw again has re-forked it. Named individually rather than counted,
/// because the failure can then say WHERE the sentence lives, and because the ban is what makes the
/// floor symbol the only way to reach the words.
///
/// This is not a style rule. A user-facing string spelled twice is a translation bug that has
/// already happened — the day one half is reworded the two platforms ship different copy for the
/// same control and nothing notices. The keybindings editor alone had ten, including a destructive
/// confirmation whose title, body and both buttons were duplicated.
///
/// Each ban is PAIRED with a claim that its owner still spells the phrase, which is the one thing
/// the shell did by hand and recorded in a comment. A ban on a sentence nobody says any more
/// forbids nothing, and it would go on passing for exactly as long as it took somebody to reword
/// the floor.
///
/// BREAK-TEST (2026-08-22): reverted `MacConnectSheet.swift`'s title to the literal `"Connect to
/// Host"` and `KeybindingsEditorView.swift`'s dialog title to `"Reset all key bindings?"`. Rule
/// FIRED on both, each naming its floor symbol. Restored by `cp` from /tmp; rule green.
#[must_use]
pub fn owned_copy_has_one_speller(tree: &Tree) -> Report {
    let mut report = Report::new();
    for (phrase, owner, symbol) in OWNED {
        // Interned, because a claim's pattern and message are both `'static` and the alternative is
        // nineteen hand-written copies of the same two sentences — the table IS what a reader wants
        // to see here.
        let quoted = text::intern(format!("\"{phrase}"));
        let says = text::intern(format!(
            "{owner} no longer spells \"{phrase}\" — the ban below forbids a sentence the floor has stopped \
             saying, so it now forbids nothing (docs/56 §3)"
        ));
        let banned = text::intern(format!(
            "a UI target respells copy that {symbol} owns ({{files}}) — a sentence typed twice is a \
             translation bug (docs/56 §3)"
        ));
        report.absorb(check_all(tree, &[
            Claim::Matches {
                path: owner,
                pattern: quoted,
                view: View::Code,
                message: says,
            },
            Claim::NoneUnder {
                roots: BOTH,
                extensions: SWIFT,
                pattern: quoted,
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: banned,
            },
        ]));
    }
    report
}

/// The shared-vocabulary ceiling
///
/// A COUNT, so the rule above does not only catch what it already knows: how many distinct
/// capitalised phrase literals are spelled in BOTH shells.
///
/// Capitalised and at least four characters is the user-facing filter. An SF Symbol name, a
/// defaults key and a JSON field are lowercase or dotted, and a bare `"OK"` is the platform's word
/// rather than ours.
///
/// ⚠️ RE-PIN AFTER A DELIBERATE MERGE, never raise to make a change fit. The remaining 33 are the
/// GUI pane control block (ten of them, the next floor file worth writing), the panel strip's three
/// reload tooltips, the `SLOPDESK_AUTOCONNECT_HOST` gate name spelled in three places — docs/46
/// says one accessor — and the bare system verbs, Done / Cancel / Close / Back / Next / Settings,
/// which are deliberately NOT merged: those are the platform's words for the platform's buttons,
/// and one constant behind them would buy an indirection and no agreement.
///
/// BREAK-TEST (2026-08-22), both directions. UP: replaced `ConnectForm.videoPortsLabel` with the
/// literal `"Advanced Transport Options"` in BOTH `MacConnectSheet.swift` and
/// `ConnectHostView.swift` — a phrase the named ban has never heard of, so only the ceiling can see
/// it. Count read 34, rule FIRED naming both numbers and printing the whole shared set. Restored by
/// `cp`; count read 33, green. DOWN: renamed ONE side of an existing pair, `"FPS cap"` to `"Frames
/// per second cap"` in `MacGuiPaneControls.swift`. Count fell to 32 and the rule stayed green — it
/// bites upward only.
#[must_use]
pub fn the_shared_vocabulary_only_shrinks(tree: &Tree) -> Report {
    /// A quoted phrase that starts with a capital and runs at least four characters. `\n` is in the
    /// negated class because the match runs over the whole file rather than line by line, and
    /// without it a quote at the end of one line pairs with a quote on the next.
    const PHRASE: &str = r#""([A-Z][^"\\\n]{3,})""#;
    /// One shell's phrases, comment lines dropped.
    const fn phrases(root: &'static str) -> Corpus {
        Corpus {
            root,
            extensions: SWIFT,
            pattern: PHRASE,
            view: View::Code,
        }
    }

    check_all(tree, &[Claim::OverlapUnder {
        label: "phrases",
        left: phrases(MAC),
        right: phrases(PHONE),
        ceiling: 33,
        // Under the SMALLER side's reading. The two shells are deliberately asymmetric here —
        // the Mac spells nearly twice the phrases the phone does, most of them menu-bar items
        // that have no phone surface — so a floor set near the larger one would fail on an
        // ordinary edit rather than on a pattern going stale.
        floor: 40,
        message: "{found} phrases are spelled in BOTH UI targets, ceiling {ceiling} — a new one belongs in \
                  SlopDeskClientCore (docs/56 §3): {shared}",
    }])
}

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;

    use super::CONNECT;
    use crate::tests::Fixture;

    /// Eight substantive lines, plus the padding that makes each side a corpus rather than a pair
    /// of files. The floor is 50 per side, so the padding is what the rule spends most of its
    /// reading on.
    fn shells(fixture: &Fixture, mac_body: &str, phone_body: &str) {
        for (root, body) in [
            ("Sources/SlopDeskMacUI", mac_body),
            ("Sources/SlopDeskPhoneUI", phone_body),
        ] {
            fixture.write(&format!("{root}/Leaf.swift"), body);
            for index in 0..60 {
                fixture.write(
                    &format!("{root}/Filler{index}.swift"),
                    &format!("struct Filler{index} {{ let n = {index} }}\n"),
                );
            }
        }
    }

    /// A body long enough to be a clone, parameterised so the two sides can differ at the tail.
    ///
    /// Eight SUBSTANTIVE lines before the tail, which is what the window counts — the import, the
    /// attribute, the lone braces and the whole-line comment are all normalised away, and a body
    /// that forgot them would be seven lines and no finding.
    fn body(tail: &str) -> String {
        format!(
            "import SwiftUI\n@MainActor\nfunc conflictLines(_ rows: [Row]) -> [String] {{\n\x20   var seen: \
             [String: Int] = [:]\n    let ordered = rows.sorted()\n\x20   for row in ordered {{\n\x20       \
             seen[row.chord, default: 0] += 1\n    }}\n\x20   let clashing = seen.filter {{ $0.value > 1 \
             }}\n\x20   let names = clashing.keys.sorted()\n\x20   // a re-worded comment cannot hide a \
             clone\n\x20   return names.isEmpty ? [] : names\n    {tail}\n}}\n"
        )
    }

    /// Whether the CLONE arm fired, as opposed to the ledger arm.
    ///
    /// A fixture holds none of the seven ledgered pairs, so every run of this rule against one
    /// reports seven paid debts. That is the ledger working — it is checked both ways — and it is
    /// noise to a test about the clone arm, so the two are told apart by their sentences. The
    /// ledger's own both-ways behaviour is exercised where it can be parameterised, on
    /// [`crate::claim::Claim::NoCloneAcross`] directly.
    fn cloned(report: &crate::report::Report) -> bool {
        report
            .violations()
            .iter()
            .any(|line| line.contains("eight identical lines"))
    }

    #[test]
    fn a_body_written_on_both_sides_is_red() {
        let fixture = Fixture::new("ui-clone");
        shells(&fixture, &body("return []"), &body("return [\"one\"]"));
        // Ten substantive lines against nine shared ones: the window is eight, and the two sides
        // agree on lines 1..9, so the clone is real and unledgered.
        assert!(cloned(&super::no_body_crosses_the_ui_split(&fixture.tree())));

        // Deduplicated onto a shared floor type, which is the fix rather than a carve-out.
        shells(
            &fixture,
            "import SwiftUI\nlet lines = KeybindingsEditorReading.conflictLines(rows)\n",
            "import SwiftUI\nlet lines = KeybindingsEditorReading.conflictLines(rows)\n",
        );
        assert!(!cloned(&super::no_body_crosses_the_ui_split(&fixture.tree())));
    }

    #[test]
    fn a_drained_shell_is_red() {
        // Its own fixture, because writes accumulate: a corpus below the floor would otherwise
        // report the healthiest answer this rule can print.
        let fixture = Fixture::new("ui-clone-drained");
        fixture.write("Sources/SlopDeskMacUI/Leaf.swift", "struct Leaf {}\n");
        fixture.write("Sources/SlopDeskPhoneUI/Leaf.swift", "struct Leaf {}\n");
        let found = super::no_body_crosses_the_ui_split(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("would pass by reading nothing"))
        );
    }

    /// A shell holding one phrase per line, and the floor file that owns the sentence — Rust, since
    /// the connect form's vocabulary crossed the FFI boundary with the rest of its reading.
    fn copy(fixture: &Fixture, mac: &str, phone: &str) {
        fixture
            .write(
                CONNECT,
                "impl Word {\n    fn text(self) -> &'static str {\n\x20       match self {\n\x20      \
                 \x20     Self::Title => \"Connect to Host\",\n\x20           Self::HostPrompt => \
                 \"host.local or 10.0.0.7\",\n\x20           Self::VideoPortsLabel => \"Video \
                 ports\",\n\x20           Self::MediaPortLabel => \"Media port\",\n\x20           \
                 Self::CursorPortLabel => \"Cursor port\",\n\x20       }\n    }\n}\n",
            )
            .write("Sources/SlopDeskMacUI/MacConnectSheet.swift", mac)
            .write("Sources/SlopDeskPhoneUI/ConnectHostView.swift", phone);
    }

    #[test]
    fn a_respelled_sentence_is_red() {
        let fixture = Fixture::new("owned-copy");
        copy(
            &fixture,
            "Text(ConnectForm.word(.title))\n",
            "Text(ConnectForm.word(.title))\n",
        );
        // Only the connect form's five are exercised here; the other owners are absent, and an
        // absent owner is itself a failure, so this asserts on the connect claims by name.
        let found = super::owned_copy_has_one_speller(&fixture.tree());
        assert!(
            !found
                .violations()
                .iter()
                .any(|line| line.contains("connect_form"))
        );

        // The revert the break-test performed: the shell types the sentence again.
        copy(
            &fixture,
            "Text(\"Connect to Host\")\n",
            "Text(ConnectForm.word(.title))\n",
        );
        let found = super::owned_copy_has_one_speller(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("connect_form::Word::Title"))
        );
    }

    #[test]
    fn a_floor_that_stopped_saying_it_is_red() {
        // A ban on a sentence nobody says forbids nothing, and would pass for as long as it took
        // somebody to reword the floor; its own fixture, because writes accumulate.
        let fixture = Fixture::new("owned-copy-stale");
        fixture
            .write(
                CONNECT,
                "impl Word {\n    fn text(self) -> &'static str {\n\x20       match self {\n\x20      \
                 \x20     Self::Title => \"Connect to a Host\",\n\x20       }\n    }\n}\n",
            )
            .write(
                "Sources/SlopDeskMacUI/MacConnectSheet.swift",
                "Text(ConnectForm.word(.title))\n",
            );
        let found = super::owned_copy_has_one_speller(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("stopped saying"))
        );
    }

    /// Two shells that share `shared` phrases, each above the floor on its own words.
    fn vocabulary(fixture: &Fixture, shared: usize) {
        for (index, root) in ["Sources/SlopDeskMacUI", "Sources/SlopDeskPhoneUI"]
            .iter()
            .enumerate()
        {
            // One file per shell rather than per phrase: the rule reads a corpus, and the number of
            // FILES is not what it counts. The unshared half is what clears the floor.
            let mut copy = String::new();
            for slot in 0..shared {
                writeln!(copy, "Text(\"Shared phrase {slot}\")").expect("string");
            }
            for slot in 0..60 {
                writeln!(copy, "Text(\"Only {index} mine {slot}\")").expect("string");
            }
            fixture.write(&format!("{root}/Copy.swift"), &copy);
        }
    }

    #[test]
    fn a_vocabulary_that_grew_is_red() {
        let fixture = Fixture::new("shared-vocabulary");
        vocabulary(&fixture, 33);
        assert!(super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());

        // The break-test's UP direction: one phrase this rule's named sibling has never heard of,
        // typed on both sides. Only the ceiling can see it.
        vocabulary(&fixture, 34);
        assert!(!super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());

        // And the DOWN direction, which stays green — it bites upward only, because the overlap
        // moves under every ordinary rename on one side.
        vocabulary(&fixture, 32);
        assert!(super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_drained_vocabulary_is_red() {
        // Below the floor on one side, which is a pattern that has gone stale rather than a split
        // that has been cleaned up; its own fixture, because writes accumulate.
        let fixture = Fixture::new("shared-vocabulary-drained");
        fixture.write("Sources/SlopDeskMacUI/Leaf.swift", "Text(\"Bitrate ceiling\")\n");
        fixture.write(
            "Sources/SlopDeskPhoneUI/Leaf.swift",
            "Text(\"Bitrate ceiling\")\n",
        );
        assert!(!super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());
    }
}
