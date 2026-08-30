//! Two renderers over one vocabulary: the code panel's four surfaces, the two device panels, the
//! chrome they share and the design floor all three stand on.
//!
//! Ported from the deleted `check-supervisor.sh` (increments 51, 52, 53, 55). Every rule here is
//! the same shape from a different angle — what a surface SAYS and which state it is IN are
//! decisions that live one floor down, and only the drawing is per-half. The failure they guard
//! against is never a build error: a second copy of a title, a shell or a caps recipe compiles,
//! renders, and differs from its twin only on the screen nobody has open.
//!
//! ⚠️ EVERY PHONE PATH IN THIS MODULE WAS RE-AIMED ON 2026-08-28, and the WHY matters more than the
//! rename. `3f11c6e6` deleted the entire `SwiftUI` iOS client without touching this ledger, so
//! every rule below spent a week reporting "… is gone" about a subject that had not been withdrawn
//! — it had been REWRITTEN. That verdict is the worst kind a ratchet can give: it is red, so nobody
//! reads it as vacuous, and it is wrong, so nobody can act on it. The `UIKit` twins landed in the
//! same directories under the settled `Phone*` convention (`292e2548`, `8f738207`), carrying the
//! same responsibility and, as it turns out, the same type names with the same prefix. The rules
//! now name those. The break-test fixtures moved with them: a fixture still spelling the dead name
//! proves the rule against a subject the tree does not have, which is how a rule goes green on
//! nothing.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The phone's four-surface switch.
///
/// ⚠️ RE-AIMED 2026-08-28, and the DIRECTORY went with the file.
/// `CodeSidebar/CodePanelSurfaces.swift` was the `SwiftUI` renderer and `3f11c6e6` took the whole
/// tree with it; the phone has no `CodeSidebar/` at all now. What replaced it is a view controller
/// under `Panel/` — same job, same name for the job, the settled `Phone*` convention — and it is
/// where the four surfaces are chosen today (`PhonePanelSurfacesViewController.swift:178` folds the
/// workbench phase through `CodePanelPresentation.workbench(…)`, which is exactly what this rule
/// was written to keep down one floor).
const PHONE_SURFACES: &str = "Sources/SlopDeskPhoneUI/Panel/PhonePanelSurfacesViewController.swift";
/// The phone's empty states, which is where the open GATE is worded.
///
/// A second const rather than a second claim on [`PHONE_SURFACES`], because the `UIKit` rebuild
/// SPLIT what the deleted file held: the surfaces controller picks the state and
/// `PhonePanelEmptyStates` draws the three that have no workbench in them —
/// `PhoneCodeOpenGateView` reads `CodeOpenGateReading`'s symbol, title and button word at
/// `:163-190`. Pointing both claims at one path would have made one of them unsatisfiable by a tree
/// that is correct, which is the failure this whole module's header is about, one register in.
const PHONE_EMPTY_STATES: &str = "Sources/SlopDeskPhoneUI/Panel/PhonePanelEmptyStates.swift";
/// The phone's panel subtree — the corpus the representable ban below reads.
const PHONE_PANEL: &[&str] = &["Sources/SlopDeskPhoneUI/Panel"];
const MAC_SURFACES: &str = "Sources/SlopDeskMacUI/Panel/MacCodePanelSurfaces.swift";
const MAC_EMPTY_STATES: &str = "Sources/SlopDeskMacUI/Panel/MacPanelEmptyStates.swift";
const PRESENTATION: &str = "Sources/SlopDeskClientCore/CodeSidebar/CodePanelPresentation.swift";
/// The non-drawing half of both code panels, typed once: the plan, the loops, the parking bracket
/// and the device reports. Landed 2026-08-28 by the carve that took ~700 lines out of the two
/// shells.
const SURFACE_RUNTIME: &str = "Sources/SlopDeskClientCore/CodeSidebar/CodePanelSurfaceRuntime.swift";
const MAC_SHARED_PARTS: &str = "Sources/SlopDeskMacUI/Panel/MacDevicePanelParts.swift";
const MAC_CAPS_RECIPE: &str = "Sources/SlopDeskMacUI/Chrome/MacCapsLabel.swift";
const KEY_EVENT: &str = "Sources/SlopDeskDevicePanels/Input/DeviceKeyEvent.swift";

/// One panel vocabulary, four surfaces, two renderers
///
/// The right panel's four surfaces are drawn twice since increment 51 — `MacCodePanelSurfaces` in
/// `AppKit`, `CodePanelSurfaces` (`#if os(iOS)`) in `SwiftUI` — off ONE `CodePanelPresentation` in
/// `SlopDeskClientCore`.
///
/// The FOLD, not just the words. Gate outranks root outranks awaited-key outranks placeholder, and
/// that ordering had already drifted between the two halves before it descended: the Mac deferred
/// the poll behind the open gate and the phone did not. Both must ASK for the state rather than
/// switch on its parts.
///
/// ONE poll task, outside the state switch. The first draft of the phone's renderer hung a
/// `.task(id:)` on three of the four branches, which reads correctly and cancels the poll on every
/// transition the poll itself caused. Three is the bug's signature; one is the fix.
///
/// ⚠️ AND THAT CLAUSE IS NO LONGER CHECKED, which is worth more written down than quietly dropped.
/// It was `Claim::Exactly { pattern: r"\.task\(id: pollKey\)", count: 1 }` — a pin on a `SwiftUI`
/// MODIFIER, and the phone has no `SwiftUI` (docs/62). The LAW survives the spelling: one poll,
/// started once, not restarted by the transitions it causes. Its `UIKit` spelling cannot be pinned
/// yet because the surface it would read has not been written — stage G — and a pattern guessed
/// against a view controller nobody has typed would be a rule that fires on the first honest draft.
/// So the clause is excised rather than re-aimed, and this paragraph is the debt: when
/// `CodePanelSurfaces` returns as a view controller, pin the single start site (one
/// `Task`/`Timer`/`AsyncStream` per poll key, in one lifecycle callback rather than per branch)
/// and delete this note. A rule that pins an ARRANGEMENT of one framework's modifiers expires the
/// day the framework leaves; the sentence above is what it was FOR.
///
/// And the clip is measured once. Two `static let`s carrying one measurement is how the phone kept
/// clipping 30pt after the workbench moved its title bar.
///
/// ## ⚠️ THE PHONE HALF RE-AIMED 2026-08-28, AND IT MOVED FROM ONE FILE TO TWO
/// Every phone claim here named `CodeSidebar/CodePanelSurfaces.swift`, a directory the phone no
/// longer has. The `UIKit` rebuild kept the responsibility and split the file: the SURFACE CHOICE
/// is `PhonePanelSurfacesViewController`, and the words for the three states with no workbench in
/// them are `PhonePanelEmptyStates`. Both still read down — the whole law — so the two claims that
/// used to land on one path land on the file that actually does each thing. Re-aiming both to one
/// path would have been the same lie in the other direction: a claim that no correct tree can
/// satisfy.
///
/// The `Populated` floor moved with them, and it got a bigger number for a real reason. It was 1
/// over a directory holding one file, which is a floor that only notices a total drain — and a
/// total drain is what happened. Over `Panel/` the floor is 4 against the two dozen files there
/// today: well below what a healthy tree holds, well above what a demolition leaves.
#[must_use]
pub fn one_panel_vocabulary_four_surfaces(tree: &Tree) -> Report {
    let claims = [
        // Per-root, and NOT on `Sources/SlopDeskPhoneUI` — the shell target globs a hundred-odd files
        // while this rule's whole phone half lives in one directory, so a floor on the parent is a
        // floor that cannot see the drain it exists for.
        Claim::Populated {
            roots: PHONE_PANEL,
            extensions: SWIFT,
            minimum: 4,
            message: "only {found} Swift files under Sources/SlopDeskPhoneUI/Panel — the representable ban \
                      below reads an empty tree and passes (docs/56, increment 51)",
        },
        // ⚠️ RE-AIMED 2026-08-28, and the OLD pair was worse than red — it was VACUOUS. Both claims
        // read `Claim::Names` against the two shells, and `Names` reads the file RAW, so a shell that
        // had stopped reading `CodePanelPresentation` in code still passed on the sentence in its own
        // header explaining where the wording went. The shells are wrappers now: the whole non-drawing
        // half (the plan, the loops, the parking bracket, the device reports) is
        // ``CodePanelSurfaceRuntime``, one file for both, and each shell holds ONE dependency instead
        // of the nine it used to list.
        //
        // So the pin follows the reading down. What each shell must still do is take its plan from the
        // floor rather than compute one — that is `CodePanelSurfacePlan`, read as CODE so a header
        // cannot satisfy it.
        Claim::Matches {
            path: PHONE_SURFACES,
            pattern: r"CodePanelSurfacePlan",
            view: View::Statements,
            message: "the phone's code panel stopped taking a CodePanelSurfacePlan — a panel surface \
                      deciding its own state is the second speller (docs/56, increment 51)",
        },
        Claim::Matches {
            path: MAC_SURFACES,
            pattern: r"CodePanelSurfacePlan",
            view: View::Statements,
            message: "the Mac's code panel stopped taking a CodePanelSurfacePlan — a panel surface deciding \
                      its own state is the second speller (docs/56, increment 51)",
        },
        // And neither shell reaches PAST the plan to the wording itself. A shell that reads
        // `CodePanelPresentation.` again has grown a second decision beside the one the runtime makes
        // — the exact shape the carve deleted, and the one a plan cannot stop by existing.
        Claim::Lacks {
            path: PHONE_SURFACES,
            pattern: r"CodePanelPresentation\.",
            view: View::Code,
            message: "the phone's code panel reads CodePanelPresentation directly again — the plan is the \
                      only thing a shell asks for; the reading is the runtime's",
        },
        Claim::Lacks {
            path: MAC_SURFACES,
            pattern: r"CodePanelPresentation\.",
            view: View::Code,
            message: "the Mac's code panel reads CodePanelPresentation directly again — the plan is the \
                      only thing a shell asks for; the reading is the runtime's",
        },
        // On the EMPTY STATES, not the surfaces controller — see the header. The gate is a card with
        // a symbol, a title and a button word, and all three are the reading's.
        Claim::Names {
            path: PHONE_EMPTY_STATES,
            needle: "CodeOpenGateReading",
            message: "the phone's code panel stopped reading CodeOpenGateReading — the open gate is a \
                      decision, not a drawing (docs/56, increment 51)",
        },
        Claim::Names {
            path: MAC_EMPTY_STATES,
            needle: "CodeOpenGateReading",
            message: "the Mac's empty states stopped reading CodeOpenGateReading — the open gate is a \
                      decision, not a drawing (docs/56, increment 51)",
        },
        // TWO CLAIMS COLLAPSED INTO ONE, which is the whole point of the carve: the fold used to be
        // typed once per shell — the same four-state switch in AppKit and in UIKit — and it is now
        // typed once, full stop. A rule that still asked each shell for it would be asking them to
        // re-grow the clone.
        Claim::Matches {
            path: SURFACE_RUNTIME,
            pattern: r"CodePanelPresentation\.workbench\(",
            view: View::Statements,
            message: "the shared panel runtime folds the workbench phase somewhere else — the four states \
                      are one switch, one floor down, for both shells",
        },
        // The macOS half of the webview mount stays deleted: it is `MacCodeWorkbenchView`, an `NSView`,
        // and a representable in the phone's target would be the second mount racing the same pooled
        // page. Read as CODE since the re-aim: `PhoneCodeWorkbenchView.swift`'s header names the
        // deleted `UIViewRepresentable` in prose, and a raw read over a wider corpus would fire on a
        // file explaining what it stopped being.
        Claim::NoneUnder {
            roots: PHONE_PANEL,
            extensions: SWIFT,
            pattern: "NSViewRepresentable",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} brought a CodeSidebar representable back — the Mac mounts the pooled webview \
                      in AppKit (docs/56, increment 51)",
        },
        Claim::Names {
            path: PRESENTATION,
            needle: "let clippedTitleBarHeight",
            message: "CodePanelPresentation stopped declaring the clipped title-bar height — one \
                      measurement, one owner",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "let clippedTitleBarHeight",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[PRESENTATION],
            message: "{files} declares the clipped title-bar height too — two static lets carrying one \
                      measurement is how the phone kept clipping 30pt after the workbench moved its title \
                      bar",
        },
    ];
    check_all(tree, &claims)
}

/// Two device panels, drawn twice and spelled once
///
/// Increment 52. Each panel has an `AppKit` renderer in `SlopDeskMacUI/Panel/<Device>/` and a
/// `SwiftUI` one in `SlopDeskPhoneUI/<Device>/`, off one `*Presentation` in `SlopDeskDevicePanels`.
///
/// The phone's are the PHONE's, and the gate is asked as "every file carries `#if os(iOS)`" rather
/// than "no file lacks it", because a file-level absence is what the shell's `grep -rL` read. A
/// macOS caller reaching back into them is the `AppKit` half half-ported, which compiles perfectly
/// well and ships two renderers for one surface.
///
/// The two display-layer views are the floor's, and NOT because they are shared: they are `NSView`s
/// with no design token and no layout decision in them. A representable back in the phone's target
/// would be a second mount racing the same layer.
///
/// ⚠️ ONE MODIFIER FOLD, WITHIN THE PANELS. `AndroidScreenNSView` carried a private six-line copy
/// for exactly one increment, because the shared one sat one target UP while the view was still in
/// the phone's half. Both are in the floor now; a second walk in either panel target is that copy
/// back. Scoped to the panel targets on purpose — `SlopDeskVideoClient/VideoWindowView` and, on the
/// far end, `rust/slopdesk-video`'s `input_routing` as the daemon asks it (`docs/61` §3) fold the
/// same flags for the GUI-video path, which is a different direction over a different wire, and
/// naming them here would be pinning a coincidence. That the host end is no longer even Swift is
/// the same argument at full strength: two folds in two languages for two wires are two rules, and
/// this one is about the panels.
#[must_use]
pub fn two_device_panels_drawn_twice(tree: &Tree) -> Report {
    const FACES: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorSurface.swift",
            "SimulatorSidebarModel",
        ),
        (
            "Sources/SlopDeskMacUI/Panel/Android/MacAndroidSurface.swift",
            "AndroidSidebarModel",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorDeviceList.swift",
            "SimulatorPresentation",
        ),
        (
            "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorDeviceList.swift",
            "SimulatorPresentation",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidDeviceList.swift",
            "AndroidPresentation",
        ),
        (
            "Sources/SlopDeskMacUI/Panel/Android/MacAndroidDeviceList.swift",
            "AndroidPresentation",
        ),
    ];

    let mut report = Report::new();
    for (half, face) in FACES {
        Claim::Names {
            path: half,
            needle: face,
            // The sentence names the path itself, since a table cannot carry a placeholder the claim
            // does not fill.
            message: "a device panel renderer stopped reading its Presentation — a panel wording itself is \
                      the second speller (docs/56, increment 52)",
        }
        .check(tree, &mut report);
    }

    let claims = [
        // `pattern: "."` is "any file with a byte in it", so `rescued_by` carries the whole rule: the
        // offenders are the files that do NOT name the gate. That inversion is the only way to ask a
        // `grep -rL` here, and it is honest — an empty file is not an ungated view.
        Claim::NoFileUnder {
            roots: &[
                "Sources/SlopDeskPhoneUI/Panel/Simulator",
                "Sources/SlopDeskPhoneUI/Panel/Android",
            ],
            extensions: SWIFT,
            pattern: ".",
            rescued_by: Some(r"#if os\(iOS\)"),
            view: View::Raw,
            exempt: &[],
            message: "{files} lost its iOS gate — the Mac draws these in AppKit now (docs/56, increment 52)",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift",
            needle: "NSView",
            message: "SimulatorScreenSurface no longer holds the display-layer NSView (docs/56, increment \
                      52)",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift",
            needle: "NSView",
            message: "AndroidScreenNSView no longer holds the display-layer NSView (docs/56, increment 52)",
        },
        // Comments STRIPPED first: both files' headers name the representable they lost, and a gate
        // that cannot quote the rule it guards is a gate nobody may document.
        Claim::NoneUnder {
            roots: &[
                "Sources/SlopDeskPhoneUI/Panel/Simulator",
                "Sources/SlopDeskPhoneUI/Panel/Android",
            ],
            extensions: SWIFT,
            pattern: "NSViewRepresentable",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} brought a device screen representable back — the Mac mounts the NSView \
                      directly (docs/56, increment 52)",
        },
        Claim::Names {
            path: KEY_EVENT,
            needle: "contains(.capsLock)",
            message: "DeviceKeyEvent stopped folding the modifiers — one fold, one file, both frameworks",
        },
        Claim::NoneUnder {
            roots: &[
                "Sources/SlopDeskDevicePanels",
                "Sources/SlopDeskPhoneUI",
                "Sources/SlopDeskMacUI",
            ],
            extensions: SWIFT,
            pattern: r"contains\(\.capsLock\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[KEY_EVENT],
            message: "{files} spells the panels' modifier fold outside DeviceKeyEvent — one fold, one file, \
                      both frameworks",
        },
    ];
    report.absorb(check_all(tree, &claims));
    report
}

/// One set of shells under both device panels, and one engraved caps heading over the whole half
///
/// Increment 53. The two `AppKit` halves each grew a `Mac*Parts.swift`, and eleven of the shells in
/// them were the same file twice: the keyed loop, the two label helpers, the section header, the
/// plate tray, the glyph button, the spinner, the search plate, the veil, the row shell and the
/// flow grid. They are `MacDevicePanelParts.swift` now.
///
/// THE TYPE IS THE SIGNATURE, and it is the only thing standing between this merge and the device
/// abstraction increment 52b banned. A shell taking `String`, `NSView`, `SFSymbol` or nothing at
/// all is CHROME and belongs in one file; a function taking a `SimulatorDevice`, a `SimulatorFact`,
/// an `AndroidDevice`, an `AndroidFact` or either `Ink` is PROTOCOL and may never be folded — the
/// two panels share not one byte of wire, so a common device vocabulary would be an abstraction
/// over a coincidence.
///
/// The other direction: a shell that went down must not grow back beside one caller. Each of the
/// nine is a `Mac*` name that may be DECLARED exactly once, and a re-minted copy compiles perfectly
/// well.
///
/// Increment 55 is the same argument one floor out. The four-attribute dictionary that makes a caps
/// micro-heading — the instrument face at `Typeface.small`, `.uppercased()`, and
/// `Typeface.instrumentTracking` kerning — was open-coded SIX times, and five of them even carried
/// their own copy of the "wide enough to read as engraving" comment. `MacCapsLabel.swift` is the
/// one recipe, and the kerning constant is the tell that cannot be faked: any seventh copy has to
/// spell `instrumentTracking` to look the same. The INK is deliberately not pinned — an overlay's
/// ladder is not a page's, and the six sites disagree on purpose.
#[must_use]
pub fn one_set_of_shells_and_one_caps_heading(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: MAC_SHARED_PARTS,
            pattern: "SimulatorDevice|SimulatorFact|SimulatorInk|AndroidDevice|AndroidFact|AndroidInk",
            view: View::Code,
            message: "MacDevicePanelParts names a device type — a shared shell is chrome, never a device \
                      abstraction (docs/56, increment 53)",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskMacUI"],
            extensions: SWIFT,
            pattern: r"^(final )?class MacDevicePanel(Loop|SectionHeader|PlateTray|GlyphButton|Spinner|SearchPlate|Veil|RowShell|Grid)[[:space:]:]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[MAC_SHARED_PARTS],
            message: "{files} declares a device-panel shell outside MacDevicePanelParts — one shell, one \
                      set of constants (docs/56, increment 53)",
        },
        // Both halves keep exactly the four parts that name a device, and each still asks its own
        // `*Presentation` for the words. The simulator's Copy title was BUILT IN THE RENDERER until
        // increment 53 while the Android half already asked for it — one sentence, two spellings, and
        // only one of them could drift.
        Claim::Matches {
            path: "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorParts.swift",
            pattern: "SimulatorPresentation",
            view: View::Statements,
            message: "MacSimulatorParts stopped asking SimulatorPresentation for its words — the renderer \
                      is not where a title lives",
        },
        Claim::Matches {
            path: "Sources/SlopDeskMacUI/Panel/Android/MacAndroidParts.swift",
            pattern: "AndroidPresentation",
            view: View::Statements,
            message: "MacAndroidParts stopped asking AndroidPresentation for its words — the renderer is \
                      not where a title lives",
        },
        Claim::NoneUnder {
            roots: &[
                "Sources/SlopDeskMacUI/Panel",
                "Sources/SlopDeskPhoneUI/Panel/Simulator",
                "Sources/SlopDeskPhoneUI/Panel/Android",
            ],
            extensions: SWIFT,
            pattern: r#""Copy \\\("#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} spells a Copy verb in a renderer — \
                      SimulatorPresentation/AndroidPresentation.copyTitle owns it",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskMacUI"],
            extensions: SWIFT,
            pattern: "instrumentTracking",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[MAC_CAPS_RECIPE],
            message: "{files} spells a caps heading outside MacCapsLabel — macCapsString/macCapsLabel own \
                      the recipe (docs/56, increment 55)",
        },
        Claim::Names {
            path: MAC_CAPS_RECIPE,
            needle: "macCapsString(words, color: color, weight: weight)",
            message: "MacCapsLabel's label spelling stopped going through its string spelling — that IS the \
                      merge",
        },
    ];
    check_all(tree, &claims)
}

/// One design floor, two renderers, and the floor never draws
///
/// `SlopDeskSlate` is the layer BOTH halves stand on: the token ladder in its `NSColor`/`UIColor`
/// spelling and its `Color` one, the status mark's geometry and its wandering tempo, the vector
/// artwork, the nerd splice and the chrome field's configuration. It exists because the draining
/// target is the PHONE's at the end of stage D, and an `AppKit` target importing the phone's would
/// be the common view ancestor `docs/56` §3 forbids.
///
/// The line it holds is "a value, never a drawing". Let one `some View` in and the next mark to be
/// ported has somewhere to be written that both halves can see, which is how two renderers become
/// one renderer plus a fallback — and nothing goes red: a hosted `SwiftUI` view compiles perfectly
/// well inside an `AppKit` window.
///
/// The floor may not CLIMB either: it is below both UI halves, so importing one would make a cycle
/// of the layering and hand the phone's views to the Mac through the back door. And the Mac must
/// read the ladder FROM the floor rather than from the draining target — that is the whole point of
/// the move, because every token read still going through `SlopDeskPhoneUI` would have had to move
/// on rename day instead of on this one.
#[must_use]
pub fn one_design_floor_two_renderers(tree: &Tree) -> Report {
    const MARKS: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskPhoneUI/DesignSystem/StatusDotView.swift",
            "AgentSpinner",
        ),
        (
            "Sources/SlopDeskMacUI/Overlays/MacAgentGlyph.swift",
            "AgentSpinner",
        ),
        (
            "Sources/SlopDeskPhoneUI/DesignSystem/VectorIconView.swift",
            "SVGPath",
        ),
        ("Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift", "SVGPath"),
    ];

    let mut report = Report::new();
    for (half, spelling) in MARKS {
        Claim::Names {
            path: half,
            needle: spelling,
            message: "a mark's renderer stopped reading the floor's value — a renderer that re-derives the \
                      mark drifts silently",
        }
        .check(tree, &mut report);
    }

    let claims = [
        // Comments are STRIPPED first: the floor's own headers NAME the boundary they hold, and a gate
        // that cannot quote the rule it guards is a gate nobody may document.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskSlate"],
            extensions: SWIFT,
            // ⚠️ The IMPERATIVE spellings are in this alternation too (docs/62 stage C). Every entry
            // to the left of them is SwiftUI's, so a floor that grew a `UIView` subclass — the one
            // shape the phone's port produces by the dozen — would have walked straight through a
            // rule whose whole job is to keep this target values-only.
            //
            // ⚠️ THE IMPERATIVE HALF IS ANCHORED TO A `class` DECLARATION, and the SwiftUI half is not,
            // because they fail differently. `some View` and `…Representable` appear nowhere but a
            // declaration; a bare `: CALayer` is also how a function TAKES one — `travel(_ plate:
            // CALayer, …)` — and the floor is allowed to take one, because QuartzCore is ONE framework
            // on both platforms and a shared animation that hands its layer back to the shell is
            // exactly the de-duplication this floor exists for. Unanchored, the rule read that
            // parameter as a subclass and fired on `SlatePlate.swift`: a false red, which costs a
            // ratchet its credibility as surely as a vacuous green does. The prefix reach is kept —
            // `UIView` still covers `UIViewController` and `NSView` its controller — because the
            // alternation is not word-anchored on the right.
            pattern: r": View|some View|NSViewRepresentable|UIViewRepresentable|: Shape|class \w+ *: *[\w, ]*(UIView|NSView|UIControl|CALayer)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} grew a VIEW in the design floor — it holds values both renderers read, never \
                      a drawing either owns",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskSlate"],
            extensions: SWIFT,
            pattern: "^import SlopDeskMacUI|^import SlopDeskPhoneUI",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} imported a UI target from the design floor — it is BELOW both halves, and the \
                      layering says so",
        },
        Claim::MentionsUnder {
            root: "Sources/SlopDeskMacUI",
            names: &["import SlopDeskSlate"],
            message: "SlopDeskMacUI stopped naming SlopDeskSlate — the Mac reads the ladder from the floor",
        },
    ];
    report.absorb(check_all(tree, &claims));
    report
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The phone's `Panel/` corpus, at the floor's own number.
    ///
    /// Two of the four are the claims' own subjects and two are filler, because the floor is a
    /// statement about the DIRECTORY rather than about them: a fixture that met it with the
    /// subjects alone could not tell "the corpus drained" from "the two files moved".
    fn surfaces(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                super::PHONE_SURFACES,
                "private func mount(_ plan: CodePanelSurfacePlan) {}\n",
            )
            .write(super::PHONE_EMPTY_STATES, "CodeOpenGateReading\n")
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhonePanelBar.swift",
                "final class PhonePanelBar: UIView {}\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
                "final class PhoneCodeWorkbenchView: UIView {}\n",
            )
            .write(
                super::MAC_SURFACES,
                "private func mount(_ plan: CodePanelSurfacePlan) {}\n",
            )
            .write(
                super::SURFACE_RUNTIME,
                "let state = CodePanelPresentation.workbench(phase)\n",
            )
            .write(super::MAC_EMPTY_STATES, "CodeOpenGateReading\n")
            .write(
                super::PRESENTATION,
                "package static let clippedTitleBarHeight = 30.0\n",
            )
    }

    #[test]
    fn one_poll_task_outside_the_switch_and_one_owner_for_the_clip() {
        let fixture = Fixture::new("panel-surfaces");
        surfaces(&fixture);
        assert!(super::one_panel_vocabulary_four_surfaces(&fixture.tree()).is_clean());

        // WHERE THE POLL CASE USED TO BE. It seeded `.task(id: pollKey)` twice — a task per branch,
        // restarting the loop it caused — and that claim is excised, because `.task(id:)` has no
        // UIKit spelling and the count would go to 0 for the port succeeding (see the header).
        // What replaces it here is the failure the excision creates room for: a DRAINED `Panel/`,
        // over which the representable ban walks nothing and passes. `3f11c6e6` is exactly this
        // shape, one directory over, and it went a week unreported.
        for drained in [
            super::PHONE_SURFACES,
            super::PHONE_EMPTY_STATES,
            "Sources/SlopDeskPhoneUI/Panel/PhonePanelBar.swift",
            "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
        ] {
            fixture.remove(drained);
        }
        let report = super::one_panel_vocabulary_four_surfaces(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|line| line.contains("reads an empty tree and passes"))
        );

        // A second static let carrying one measurement.
        surfaces(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Panel/MacPanelMetrics.swift",
            "static let clippedTitleBarHeight = 30.0\n",
        );
        assert!(!super::one_panel_vocabulary_four_surfaces(&fixture.tree()).is_clean());

        // The shared runtime no longer folding the workbench phase. ONE claim since the carve,
        // where there were two: the fold is typed once for both shells, so asking each
        // shell for it would be asking them to re-grow the clone it deleted.
        surfaces(&fixture);
        fixture.write(super::SURFACE_RUNTIME, "switch phase { case .booting: break }\n");
        assert!(!super::one_panel_vocabulary_four_surfaces(&fixture.tree()).is_clean());

        // A shell reaching PAST the plan to the wording — the second decision, growing back beside
        // the runtime's. Naming the type in PROSE is still fine, and that is the arm the
        // old `Claim::Names` pair got backwards: it read the file raw and a header sentence
        // satisfied it.
        surfaces(&fixture);
        // ⚠️ `surfaces` re-WRITES its own files and removes nothing, so the second-owner seed above
        // is still in the tree. Any case that asserts CLEAN has to undo it by hand.
        fixture.remove("Sources/SlopDeskMacUI/Panel/MacPanelMetrics.swift");
        fixture.append(
            super::PHONE_SURFACES,
            "// the wording is CodePanelPresentation.workbench(phase), one floor down\n",
        );
        assert!(super::one_panel_vocabulary_four_surfaces(&fixture.tree()).is_clean());
        fixture.append(
            super::PHONE_SURFACES,
            "let state = CodePanelPresentation.workbench(phase)\n",
        );
        assert!(!super::one_panel_vocabulary_four_surfaces(&fixture.tree()).is_clean());

        // And a shell that stopped taking a plan at all.
        surfaces(&fixture);
        fixture.write(super::MAC_SURFACES, "private func mount(_ plan: Plan) {}\n");
        assert!(!super::one_panel_vocabulary_four_surfaces(&fixture.tree()).is_clean());

        // And the representable back in the phone's panel — the second mount racing the pooled
        // page. Over `Panel/` rather than the deleted `CodeSidebar/`, which is where a
        // phone code mount lives now.
        surfaces(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
            "struct WorkbenchMount: NSViewRepresentable {}\n",
        );
        assert!(!super::one_panel_vocabulary_four_surfaces(&fixture.tree()).is_clean());
    }

    fn panels(fixture: &Fixture) -> &Fixture {
        for (path, face) in [
            (
                "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorSurface.swift",
                "SimulatorSidebarModel",
            ),
            (
                "Sources/SlopDeskMacUI/Panel/Android/MacAndroidSurface.swift",
                "AndroidSidebarModel",
            ),
            (
                "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorDeviceList.swift",
                "SimulatorPresentation",
            ),
            (
                "Sources/SlopDeskMacUI/Panel/Android/MacAndroidDeviceList.swift",
                "AndroidPresentation",
            ),
        ] {
            fixture.write(path, &format!("{face}\n"));
        }
        fixture
            .write(
                "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorDeviceList.swift",
                "#if os(iOS)\nSimulatorPresentation\n#endif\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidDeviceList.swift",
                "#if os(iOS)\nAndroidPresentation\n#endif\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift",
                "final class SimulatorScreenSurface: NSView {}\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift",
                "final class AndroidScreenNSView: NSView {}\n",
            )
            .write(super::KEY_EVENT, "if modifiers.contains(.capsLock) { … }\n")
    }

    #[test]
    fn the_phone_halves_stay_gated_and_the_fold_stays_in_one_file() {
        let fixture = Fixture::new("device-panels");
        panels(&fixture);
        assert!(super::two_device_panels_drawn_twice(&fixture.tree()).is_clean());

        // A phone view that lost its gate is the AppKit half half-ported.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidDeviceList.swift",
            "AndroidPresentation\n",
        );
        assert!(!super::two_device_panels_drawn_twice(&fixture.tree()).is_clean());

        // The six-line copy of the modifier fold, back beside one caller.
        panels(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Panel/Android/MacAndroidKeys.swift",
            "if flags.contains(.capsLock) { out |= 1 }\n",
        );
        assert!(!super::two_device_panels_drawn_twice(&fixture.tree()).is_clean());
    }

    fn shells(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                super::MAC_SHARED_PARTS,
                "final class MacDevicePanelLoop: NSView {}\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorParts.swift",
                "SimulatorPresentation.copyTitle\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Panel/Android/MacAndroidParts.swift",
                "AndroidPresentation.copyTitle\n",
            )
            .write(
                super::MAC_CAPS_RECIPE,
                "let tracking = Typeface.instrumentTracking\nmacCapsString(words, color: color, weight: \
                 weight)\n",
            )
    }

    #[test]
    fn a_shell_is_declared_once_and_a_caps_recipe_lives_in_one_file() {
        let fixture = Fixture::new("panel-shells");
        shells(&fixture);
        assert!(super::one_set_of_shells_and_one_caps_heading(&fixture.tree()).is_clean());

        // A re-minted shell beside one caller compiles perfectly well.
        fixture.write(
            "Sources/SlopDeskMacUI/Panel/Android/MacAndroidGrid.swift",
            "final class MacDevicePanelGrid: NSView {}\n",
        );
        assert!(!super::one_set_of_shells_and_one_caps_heading(&fixture.tree()).is_clean());

        // The seventh open-coded caps heading, given away by the kerning constant.
        shells(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Overlays/MacPeekCard.swift",
            "attrs[.kern] = Typeface.instrumentTracking\n",
        );
        assert!(!super::one_set_of_shells_and_one_caps_heading(&fixture.tree()).is_clean());

        // A device type in the shared shell is the abstraction increment 52b banned.
        shells(&fixture);
        fixture.write(
            super::MAC_SHARED_PARTS,
            "final class MacDevicePanelLoop: NSView {}\nfunc row(for device: SimulatorDevice) {}\n",
        );
        assert!(!super::one_set_of_shells_and_one_caps_heading(&fixture.tree()).is_clean());

        // And a Copy verb built in the renderer.
        shells(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorRow.swift",
            "menu.addItem(withTitle: \"Copy \\(device.udid)\")\n",
        );
        assert!(!super::one_set_of_shells_and_one_caps_heading(&fixture.tree()).is_clean());
    }

    fn floor(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                "Sources/SlopDeskSlate/SlateDesign.swift",
                "enum Slate { static let ink = 1 }\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/DesignSystem/StatusDotView.swift",
                "AgentSpinner.phase(at: now)\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Overlays/MacAgentGlyph.swift",
                "AgentSpinner.phase(at: now)\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/DesignSystem/VectorIconView.swift",
                "SVGPath.parse(d)\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift",
                "import SlopDeskSlate\nSVGPath.parse(d)\n",
            )
    }

    #[test]
    fn the_floor_holds_values_and_never_climbs() {
        let fixture = Fixture::new("design-floor");
        floor(&fixture);
        assert!(super::one_design_floor_two_renderers(&fixture.tree()).is_clean());

        // One `some View` is how two renderers become one renderer plus a fallback.
        fixture.write(
            "Sources/SlopDeskSlate/SlateStatusMark.swift",
            "var body: some View { Circle() }\n",
        );
        assert!(!super::one_design_floor_two_renderers(&fixture.tree()).is_clean());

        // And one `UIView` subclass is the SAME collapse spelled imperatively — the shape the
        // phone's port produces by the dozen, which is why it had to join the alternation
        // before stage C put the first one in the tree.
        floor(&fixture);
        fixture.write(
            "Sources/SlopDeskSlate/SlateStatusMarkView.swift",
            "final class SlateStatusMarkView: UIView {}\n",
        );
        assert!(!super::one_design_floor_two_renderers(&fixture.tree()).is_clean());

        floor(&fixture);
        fixture.write(
            "Sources/SlopDeskSlate/SlatePlateControl.swift",
            "final class SlatePlateControl: UIControl {}\n",
        );
        assert!(!super::one_design_floor_two_renderers(&fixture.tree()).is_clean());

        // ⚠️ AND THE FALSE RED, which is the case the anchoring exists for: a floor that TAKES a
        // `CALayer` and hands it back is the shared QuartzCore de-duplication, not a view. A rule
        // that fires here teaches its readers to ignore it.
        //
        // ⚠️ `floor` RE-WRITES ITS OWN FILES AND REMOVES NOTHING, so the two seeded subclasses
        // above are still in the tree and would fail this CLEAN assertion for the wrong
        // reason. Every case that asserts clean after an earlier red has to take the
        // earlier seed back out by hand.
        floor(&fixture);
        fixture.remove("Sources/SlopDeskSlate/SlateStatusMark.swift");
        fixture.remove("Sources/SlopDeskSlate/SlateStatusMarkView.swift");
        fixture.remove("Sources/SlopDeskSlate/SlatePlateControl.swift");
        fixture.write(
            "Sources/SlopDeskSlate/SlatePlate.swift",
            "public static func travel(_ plate: CALayer, to frame: CGRect) {}\n",
        );
        assert!(super::one_design_floor_two_renderers(&fixture.tree()).is_clean());

        // Subclassing one is still the collapse, spelled through the layer instead of the view.
        fixture.write(
            "Sources/SlopDeskSlate/SlatePlate.swift",
            "final class SlatePlateLayer: CALayer {}\n",
        );
        assert!(!super::one_design_floor_two_renderers(&fixture.tree()).is_clean());

        // The floor climbing is a cycle in the layering.
        floor(&fixture);
        fixture.write(
            "Sources/SlopDeskSlate/SlateDesign.swift",
            "import SlopDeskPhoneUI\n",
        );
        assert!(!super::one_design_floor_two_renderers(&fixture.tree()).is_clean());

        // And the Mac reading the ladder from the draining target instead of the floor.
        floor(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift",
            "SVGPath.parse(d)\n",
        );
        assert!(!super::one_design_floor_two_renderers(&fixture.tree()).is_clean());
    }
}
