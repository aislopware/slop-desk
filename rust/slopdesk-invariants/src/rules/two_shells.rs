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

/// The connect form's own words. Rust, not Swift: the form's vocabulary crossed the FFI
/// boundary with the rest of its reading, and the ban's paired claim has to follow the floor
/// wherever it moved or it starts guarding an empty room — the same move `SEARCH` records.
const CONNECT: &str = "rust/slopdesk-workspace/src/connect_form.rs";
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

/// No body is written twice across the split
///
/// Eight consecutive substantive lines appearing in both shells. The normalisation, the window and
/// the debt list are all [`Claim::NoCloneAcross`]'s, which is where the reasoning for each lives;
/// what is here is the ledger itself.
///
/// The ledger held six until `3f11c6e6` — `MacGuiLeafView`↔`GuiLeafView`,
/// `MacPromptJumpFlashOverlay`↔`PromptJumpFlashOverlay`, `MacTerminalFindBar`↔`TerminalFindBar`,
/// `MacTerminalLeafView`↔`TerminalLeafView`, `MacCodePanelSurfaces`↔`CodePanelSurfaces`,
/// `MacWorkspaceRootView`↔`WorkspaceRootView` — and that commit deleted every phone side while the
/// AppKit shell's own de-SwiftUI took `MacWorkspaceRootView` with it. An entry ASSERTS a clone
/// exists today, so a row whose files are gone is not a debt in abeyance; it is a false claim, and
/// the ledger fails on it exactly as it fails on an unledgered clone. The ledger went empty, and
/// the note here said so.
///
/// ## THE TWIN CAME BACK, AND SO DID FIVE OF THE SIX ROWS — 2026-08-28
///
/// The paragraph above predicted this: "every pair returns the moment its UIKit twin is written
/// against the same Mac source, and the right response then is to re-ledger it with the floor file
/// it waits on, not to widen the window." The twins landed, and the prediction was RIGHT about the
/// mechanism and WRONG about the scale. Thirty-five pairs, not six, and only some of them are the
/// thing this rule was built to find. They sort into four kinds, and only two get a row.
///
/// ⚠️ TWO COUNTS OF THIS ARE IN CIRCULATION AND BOTH ARE RIGHT. A parallel measurement reported
/// ~1,324 windows over 44 pairs where the numbers below say 839 over 35. The difference is
/// `shingles`' `or_insert`: this rule keys a window by its BODY and keeps the first site, so one
/// body spelled in three files is one pair, and a body a file repeats internally is one window. A
/// count that tallies every occurrence sees more of both. The figures here are the ones this rule
/// acts on. Every one of them is also a snapshot — four UIKit stages were landing files while it
/// ran, and the pair count moved three times in one session.
///
/// 1. **Whole-file copies — RED, and the rule working.** `MacGuiLeafView`↔`GuiLeafView` shares 194
///    windows, `MacCodePanelSurfaces`↔`PhonePanelSurfacesViewController` 121,
///    `MacTerminalLeafView`↔ `TerminalLeafView` 90, `MacSplitCanvasView`↔`SplitCanvasView` 70. A
///    file that shares two hundred windows was COPIED, and no ledger row should make that quiet.
///    They are not re-ledgered from the old list: the debt is real, it is the port's method, and it
///    is owed by the stage that typed it.
/// 2. **One extracted surface — RED, addressed to stage F/H.** `MacSidebarHeader`↔
///    `SidebarGitLineView`, 38 windows over eleven regions. Same subject, two renderers, and the
///    fix deletes Mac code through the shared ladder. ⚠️ The Mac half has NO
///    `MacGitLineView.swift`; the git line is still inside `MacSidebarHeader.swift`, so the dedup
///    has to EXTRACT before it can delete, which is a bigger move than the phone half's name
///    suggests.
/// 3. **The mandated prologue — one row, and it dissolves rather than being paid.** See the ledger.
/// 4. **Auto Layout scaffolding — RED, but small, and a first draft of this note got it badly
///    wrong.** That draft said "about fifteen pairs share nothing but
///    `translatesAutoresizingMaskIntoConstraints = false` / `addSubview` /
///    `NSLayoutConstraint.activate([`", and proposed re-pinning `window` on the strength of it.
///    Then the shared lines were CLASSIFIED instead of eyeballed, and the split across all 839
///    shared windows is **9% scaffolding, 12% injection lists, 4% prologue, and 73% ordinary
///    logic**. Only EIGHT pairs are scaffolding-dominated, none bigger than thirteen windows,
///    together 6% of the total: `MacAndroidStageView`, `MacGuiPaneControls`, `MacGuiPaneOverlays`,
///    `MacCodeWorkbenchView`, `MacHintModeOverlay`, `MacViModeOverlay`, `MacToastStack`,
///    `MacSimulatorSurface`. So the `window: 8` premise is NOT expiring, and raising it would have
///    hidden the 73% to be rid of the 9%. The eyeball read the FIRST window of each pair, which is
///    disproportionately the `init` and the constraint block because that is where a Swift view
///    file starts — a sampling artefact, and the exact mistake this rule exists to prevent someone
///    making about the code itself.
///
/// ⚠️ AND THE 73% IS WHY "PRICE A PAIR ONCE, PER FLOOR" CANNOT WORK HERE. 34 of the 35 pairs
/// already reference a `…Presentation` / `…Reading` / `…Geometry` / `Slate.` symbol somewhere in
/// both halves, so "does a floor exist for these twins" does not discriminate anything — yet they
/// still share 839 windows. The two facts are consistent, and their consistency is the finding: a
/// body can only be SHARED here if it did not go through the floor, because a decision that reached
/// a floor is one call line on each side and one line cannot fill an eight-line window. The shared
/// body IS, by construction, the residue that stayed in the renderers. A ledger keyed on floors
/// would price the part that is already fine and stay silent about the part that is not.
///
/// A row LEAVES honestly only one way: the clone stops existing because a shared floor absorbed it
/// (`SlopDeskMacApp` ↔ `SlopDeskPhoneApp` left that way in stage A, once `PhoneAppDelegate` called
/// `ClientNotificationSinks`). The six above left the other way — deleted, not deduplicated — and
/// the doc records which so the next reader does not mistake an empty ledger for a paid one.
///
/// BREAK-TEST (2026-08-22): copied `KeybindingsEditorReading.swift`'s `conflictLines(_:)` body back
/// into BOTH shells' editors as private methods — the exact shape the dedup removed. Rule FIRED,
/// naming both sites. Restored both files by `cp` from /tmp; rule green. Also verified the inverse:
/// with the tree as it stood the rule found exactly the seven ledgered pairs, i.e. it was not
/// passing by finding nothing. That editor is gone with the rest of the settings GUI — a key
/// binding is a `[keybind]` line now — so its nine sentences left the ledger with it.
#[must_use]
pub fn no_body_crosses_the_ui_split(tree: &Tree) -> Report {
    check_all(tree, &[Claim::NoCloneAcross {
        left: MAC,
        right: PHONE,
        extensions: SWIFT,
        window: 8,
        // TWO rows, and each is a pair whose shared lines are ONE contiguous region — which is what
        // separates them from the thirty-two pairs left red. A pair that shares seven scattered
        // regions is not "the prologue"; it is a copy that happens to contain one.
        known: &[
            // The `withObservationTracking` re-arm and nothing else: five overlapping windows, all
            // inside one ~12-line span. Dissolves when the shared `follow` helper lands — the
            // duplicated lines are the mandated docs/62 §3.1 prologue, not duplicated behaviour, and
            // that helper deletes them from every site at once. This row is therefore the FIRST in
            // the ledger's history that is not expected to be PAID: it will go red as "the debt is
            // PAID, drop the entry", and dropping it is the whole of the work.
            (
                "Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift",
                "Sources/SlopDeskPhoneUI/Columns/NavigatorSectionHeaderCell.swift",
            ),
            // A FALSE POSITIVE, ledgered because there is nowhere else to say so. Two windows, one
            // span: a `switch` over `SidebarRowReading`'s weight rungs, and the
            // `arrangedSubviews`/`removeArrangedSubview`/`removeFromSuperview` teardown loop. Two
            // exhaustive switches over one enum are the LANGUAGE's shape for exhaustiveness — the
            // named-ink family exists because that switch is supposed to be per-renderer — and the
            // teardown is the framework's only spelling for emptying a stack view. Neither is a
            // copied body, and there is no floor that could absorb either.
            (
                "Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift",
                "Sources/SlopDeskPhoneUI/Columns/NavigatorRowCell.swift",
            ),
        ],
        floor: 15,
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
/// ⚠️ RE-PIN AFTER A DELIBERATE MERGE, never raise to make a change fit. The remaining 28 are the
/// GUI pane control block (ten of them, the next floor file worth writing), the panel strip's three
/// reload tooltips, the `SLOPDESK_AUTOCONNECT_HOST` gate name spelled in three places — docs/46
/// says one accessor — and the bare system verbs, Done / Cancel / Close, which are deliberately NOT
/// merged: those are the platform's words for the platform's buttons, and one constant behind them
/// would buy an indirection and no agreement.
///
/// RE-PINNED 2026-08-24, downward on both numbers: the settings GUI and the onboarding flow came
/// out of both shells, which took the phone's whole reading from 60-odd phrases to 38 and the
/// shared set from 33 to 28. The FLOOR moved with it — it exists so a pattern that has stopped
/// matching cannot pass as a clean tree, and 40 was above the phone's entire vocabulary.
///
/// RE-PINNED 2026-08-28, downward again and much harder: `3f11c6e6` deleted the SwiftUI phone
/// whole, and the UIKit rebuild has not written its copy yet. The Mac still reads 63 phrases; the
/// phone reads THREE — `Cancel`, the `SLOPDESK_AUTOCONNECT_HOST` gate name, and the ghostty
/// headless-build hint — and all three are shared. Ceiling 3, floor 1.
///
/// ⚠️ WHAT THE OLD NUMBERS WERE DOING WHILE THE PHONE WAS EMPTY, and the reason this is the rule
/// the demolition damaged worst. A ceiling of 28 over a shared set of 3 forbids nothing: the phone
/// could re-spell twenty-five of the Mac's sentences and the gate would stay green. Only the FLOOR
/// went red, and a floor's message says "this ceiling would hold by reading nothing" — which reads
/// as a stale pattern, not as a ceiling that had quietly stopped biting. A ceiling pinned well
/// above the live count is not a lenient ratchet; it is a rule that has expired without saying so.
///
/// So the pin is deliberately the tightest number the tree admits — every phrase the phone owns is
/// already shared, so the ceiling is at the top of its own range and the very next phrase the
/// rebuild spells on both sides is red. It read 3 when this paragraph was first written and 4 by
/// the time the change landed, because the pane leaves arriving in the same hour added `"Copied"`
/// to both sides. That churn is the point rather than a nuisance: 4 is a DEBT of four phrases, each
/// of which belongs in `SlopDeskClientCore`, and re-measuring is the last act before every commit
/// that touches either shell. That is the LAW, not an accident of timing: a stage that
/// re-types a Mac sentence in UIKit must route it through `SlopDeskClientCore` instead. Expect this
/// number to be re-pinned repeatedly as docs/62 lands — DOWNWARD as ClientCore absorbs a phrase,
/// and upward only after a merge that is genuinely refused (the Done / Cancel / Close class).
///
/// ⚠️ AND IT WAS 14 BY THE TIME THIS COMMIT LANDED, WHICH IS THE RULE WORKING RATHER THAN A STALE
/// PIN. The panel and settings stages typed ten more of the Mac's sentences into UIKit in the same
/// hour — `"Stream quality"`, `"FPS cap"`, `"Bitrate ceiling"`, `"Clipboard Ring"`, `"Paste as
/// Keystrokes"`, `"Refresh Displays"`, `"No display list from host"`, `"No recent clips"`,
/// `"Dismiss"` and the two settings captions. The ceiling was NOT raised to 14 to absorb them, and
/// the reason is the same one that forbids writing a `known` debt pair for a clone without arguing
/// against deduplication first: every one of those ten is a sentence, not a platform verb, so the
/// fix is `SlopDeskClientCore`, and a ceiling raised to fit them is the "expired without saying so"
/// failure arriving from the other direction. The red is addressed to the stage that typed them.
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
        ceiling: 4,
        // Under the SMALLER side's reading, and during the rebuild the smaller side is TINY. The
        // two shells were always asymmetric — the Mac spells menu-bar items with no phone surface
        // at all — and the UIKit port has taken the phone to three phrases, so a floor set anywhere
        // near the Mac's 63 would fail on every ordinary edit instead of on a pattern going stale.
        // One is the whole job here: it separates "the phone reads a little" from "the regex
        // matches nothing", which is the only failure the count itself cannot show.
        floor: 1,
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
    /// The two arms are confusable again, exactly as this note predicted while the ledger was
    /// empty: a fixture holds neither ledgered pair, so every run reports two paid debts, which is
    /// the ledger working and noise to a test about the clone arm. Hence the discrimination. The
    /// ledger's own both-ways behaviour is exercised where it can be parameterised, on
    /// [`crate::claim::Claim::NoCloneAcross`] directly; what is exercised HERE is that the two rows
    /// in this rule's ledger excuse the pairs they name and nothing else.
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

    /// The ledgered prologue is excused, and a SECOND clone one file over is not
    ///
    /// The pair-wise half of the ledger. A `known` entry is an exact `(left, right)` path pair, so
    /// the interesting failure is not "does the row work" —
    /// [`crate::claim::Claim::NoCloneAcross`]'s own tests cover that — but "does the row excuse
    /// more than it names". It must not: the Mac half of the ledgered prologue row is
    /// `MacSidebarHeader.swift`, which is ALSO the left half of the git-line clone this rule
    /// deliberately leaves red, and a row that excused a path rather than a pair would have
    /// silenced stage H's debt as a side effect of parking a re-arm.
    ///
    /// ⚠️ THE SECOND CLONE NEEDS ITS OWN BODY, and the first draft of this test did not give it one
    /// — it wrote the SAME body into a third file and asserted red. It was green, and the rule was
    /// right: `shingles` keeps the first site per distinct body (`or_insert`), so one body spelled
    /// in three files is ONE pair, not two. That is worth knowing about the live tree too — the
    /// git-line pair is red because it shares thirty-eight DIFFERENT bodies with the header, not
    /// because one body appears twice.
    #[test]
    fn a_ledgered_pair_is_excused_and_a_second_clone_beside_it_is_not() {
        let fixture = Fixture::new("ui-clone-ledger");
        shells(&fixture, "struct Unused {}\n", "struct Unused {}\n");
        let prologue = body("return []");
        // A different eight lines, so this clone forms its own pair rather than folding into the
        // one above. EIGHT SUBSTANTIVE ones: both closing braces normalise away as noise, which is
        // the trap `body`'s own comment records, and a seven-line draft of this found nothing.
        let git_line = "func rungs(_ ladder: GitLadder) -> [Rung] {\n    var out: [Rung] = []\n    let \
                        source = ladder.rungs\n    for rung in source where rung.width > 0 {\n        \
                        out.append(rung)\n    }\n    out.sort()\n    let trimmed = out.prefix(4)\n    \
                        return Array(trimmed)\n}\n";

        // The ledgered pair, spelled at the two paths the ledger names.
        fixture.write("Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift", &prologue);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Columns/NavigatorSectionHeaderCell.swift",
            &prologue,
        );
        assert!(!cloned(&super::no_body_crosses_the_ui_split(&fixture.tree())));

        // The same Mac file against a DIFFERENT phone file, sharing a DIFFERENT body — the git-line
        // shape. The row above names a pair, so this one is a stranger and stays red.
        fixture.write(
            "Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift",
            &format!("{prologue}{git_line}"),
        );
        fixture.write(
            "Sources/SlopDeskPhoneUI/Columns/SidebarGitLineView.swift",
            git_line,
        );
        let found = super::no_body_crosses_the_ui_split(&fixture.tree());
        assert!(cloned(&found), "expected a clone, got {:?}", found.violations());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("SidebarGitLineView.swift")),
            "the unledgered pair must be the one named, got {:?}",
            found.violations(),
        );
    }

    /// A ledger row whose clone dissolved says so
    ///
    /// The prologue row is the first entry here that is EXPECTED to dissolve rather than be paid —
    /// the shared `follow` helper deletes the duplicated lines from every site at once. When it
    /// lands, this rule must go red and name the row, so that dropping the entry is forced rather
    /// than remembered. Seeded by writing the two ledgered files with no shared body at all.
    #[test]
    fn a_ledger_row_whose_prologue_dissolved_is_named() {
        let fixture = Fixture::new("ui-clone-dissolved");
        shells(&fixture, "struct Unused {}\n", "struct Unused {}\n");
        fixture.write(
            "Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift",
            "func follow() { self.follow(store) { $0.gitSummary } }\n",
        );
        fixture.write(
            "Sources/SlopDeskPhoneUI/Columns/NavigatorSectionHeaderCell.swift",
            "func follow() { self.follow(store) { $0.rollup } }\n",
        );
        let found = super::no_body_crosses_the_ui_split(&fixture.tree());
        assert!(!cloned(&found));
        assert!(
            found.violations().iter().any(|line| {
                line.contains("NavigatorSectionHeaderCell.swift") && line.contains("the debt is PAID")
            }),
            "a dissolved prologue row must name itself, got {:?}",
            found.violations(),
        );
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
        // Re-aimed 2026-08-28 from 28/29/27 onto the ceiling the UIKit rebuild left, and re-pinned
        // in the same session from 3 to 4 when the pane leaves landed `"Copied"` on both sides. The
        // old numbers exercised the same arms, but a break-test written against a ceiling the rule
        // no longer carries proves nothing about the rule that is registered — so this fixture
        // tracks the pin rather than a number it once had.
        vocabulary(&fixture, 4);
        assert!(super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());

        // The break-test's UP direction: one phrase this rule's named sibling has never heard of,
        // typed on both sides. Only the ceiling can see it.
        vocabulary(&fixture, 5);
        assert!(!super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());

        // And the DOWN direction, which stays green — it bites upward only, because the overlap
        // moves under every ordinary rename on one side.
        vocabulary(&fixture, 3);
        assert!(super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_drained_vocabulary_is_red() {
        // Below the floor on one side, which is a pattern that has gone stale rather than a split
        // that has been cleaned up; its own fixture, because writes accumulate.
        //
        // Re-aimed 2026-08-28 with the floor. At floor 34 a shell holding ONE phrase was already
        // under it; at floor 1 the drain has to be total, so the phone half here spells no
        // capitalised literal at all — which is exactly the tree `3f11c6e6` left and exactly what
        // the floor now exists to catch.
        let fixture = Fixture::new("shared-vocabulary-drained");
        fixture.write("Sources/SlopDeskMacUI/Leaf.swift", "Text(\"Bitrate ceiling\")\n");
        fixture.write(
            "Sources/SlopDeskPhoneUI/Leaf.swift",
            "final class Leaf: UIView {}\n",
        );
        assert!(!super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());

        // And the tripwire is a tripwire, not a ratchet: one phrase per side clears it.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Leaf.swift",
            "Text(\"Bitrate ceiling\")\n",
        );
        assert!(super::the_shared_vocabulary_only_shrinks(&fixture.tree()).is_clean());
    }
}
