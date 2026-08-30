//! The UI split holds its shape, and the video surface stays split with it (`docs/56` §3).
//!
//! Ported from the deleted `check-supervisor.sh`. Three boundaries, and each fails SILENTLY rather
//! than loudly if it slips: a frameworkless file in a UI target compiles, a dead platform arm
//! compiles, and a seam sink wired on one half and forgotten on the other compiles. None of them is
//! a build error, and all of them are the same failure — one implementation becoming two.
//!
//! A fourth boundary joined them once the client finished crossing, and it is the only one here
//! that is not about the split at all: [`no_declarative_framework_survives`] bans `SwiftUI` from
//! every Swift root at once. It lives beside these because the split is what it protects — two
//! IMPERATIVE renderers can hold a decision in a stored property and pass it across the seam, and a
//! declarative one re-derives it in a body where the other half cannot read it.

use crate::claim::{Claim, Corpus, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// FOUR targets, not two, since the video carve. `SlopDeskVideoClientMac` and
/// `SlopDeskVideoClientPhone` are the two arms of what was `VideoWindowView.swift`, and they are UI
/// targets in exactly the sense this section means.
const UI_TARGETS: &[&str] = &[
    "Sources/SlopDeskMacUI",
    "Sources/SlopDeskPhoneUI",
    "Sources/SlopDeskVideoClientMac",
    "Sources/SlopDeskVideoClientPhone",
];
const MAC_VIEW_TARGETS: &[&str] = &["Sources/SlopDeskMacUI", "Sources/SlopDeskVideoClientMac"];
const PHONE_VIEW_TARGETS: &[&str] = &["Sources/SlopDeskPhoneUI", "Sources/SlopDeskVideoClientPhone"];
const ENGINE: &str = "Sources/SlopDeskVideoClient";
const MAC_HALF: &str = "Sources/SlopDeskVideoClientMac";
const PHONE_HALF: &str = "Sources/SlopDeskVideoClientPhone";

/// A UI target holds views only, and carries no platform gate but its own
///
/// A file in a UI target that names no view framework compiles perfectly well — it is simply logic
/// sitting where only one of the two halves can reach it, which is how the same model ends up
/// written twice. The test is textual and deliberately blunt: `import SwiftUI`, `AppKit` or
/// `UIKit`, or belong in `SlopDeskClientCore`.
///
/// A PLATFORM GATE IN A PLATFORM TARGET means the file is in the wrong target. These targets are
/// one platform's and nothing else builds them, so every `#if os(...)` in one is dead text that
/// reads as a live rule. The ONE allowed gate is a phone target's whole-file `#if os(iOS)`, which
/// is how an iOS-only view declares itself to `swift build` (`SwiftPM` compiles every target on the
/// host triple).
///
/// ⚠️ TWO PATHS PER SIDE, NOT ONE, since the video carve. `SlopDeskVideoClientMac` is the `AppKit`
/// half of a surface that until the carve WAS an `#if os(macOS)` arm — the single most likely place
/// in the tree for the gate to grow back is the file that used to be one.
///
/// And that whole-file gate is the ONLY directive a phone file may carry. The ban above names the
/// platforms the phone does not build for, which leaves an inner `#if os(iOS)` — a gate that is
/// always TRUE in this target — sailing through. Not a hypothetical: normalising the fold left
/// several files with a whole-file guard AND inner arms that had been the iOS side of a two-arm
/// split, each one dead scaffolding around code that now always runs.
///
/// ⚠️ THE VACUITY FLOOR IS PER-TARGET, and that is not tidiness. This walks two targets, and ONE
/// combined floor would stay green if `SlopDeskVideoClientPhone` globbed to zero files, because
/// `SlopDeskPhoneUI` alone clears it — a gate that passes by reading nothing. The video half's
/// floor is small because the half IS small.
///
/// ⚠️ AND BOTH FLOORS ARE TRIPWIRES, NOT RATCHETS. They were pinned at 50 and 2 against the
/// `SwiftUI` phone; `3f11c6e6` deleted that phone whole and both went red without a single
/// directive having drifted. A floor pinned just under the live count re-fails on every honest
/// deletion, so these sit well under the rebuild's floor instead — 15 and 1 say "the target still
/// globs", which is all the directive shape below needs to be reading something (docs/62 stage A).
///
/// ⚠️ AND EACH HALF NAMES ONE FRAMEWORK, NOT THREE. The rescue above used to admit `SwiftUI` as a
/// third; it no longer does, because there is no longer a file anywhere in `Sources` for it to
/// rescue. That is [`no_declarative_framework_survives`]'s subject rather than this rule's, and the
/// history is worth keeping here because it decided the fate of a whole [`Claim`] variant.
/// `Claim::CeilingUnder` existed to hold two migrations that were supposed to drain slowly — the
/// phone's `SwiftUI` importers, and design-system files carrying both spellings — and its own
/// docstring claimed "two rules use it" while ZERO ever constructed it. Then `3f11c6e6` and
/// `32519299` drained both subjects to nought in two commits, and a ceiling of nought is a ban. So
/// the variant is deleted, and the ban that replaced it turned out to be a tree-wide law rather
/// than a phone-shaped one: the migration finished before the ratchet for it was ever written.
///
/// NEITHER HALF IMPORTS THE OTHER. `Package.swift` already makes that a link error; this catches
/// the edit that would ADD the dependency there, which is the moment a shared view ancestor becomes
/// possible. Two halves, so exactly two edges — increment 63 collapsed four into two, because two
/// of them named the draining floor by its old name and one then read as a target forbidden from
/// importing ITSELF, which is not a rule and which no file can violate.
#[must_use]
pub fn the_ui_split_holds_its_shape(tree: &Tree) -> Report {
    let claims = [
        // `pattern: "."` is "any file with a byte in it", so `rescued_by` carries the rule: the
        // offenders are the files that name no view framework at all.
        Claim::NoFileUnder {
            roots: UI_TARGETS,
            extensions: SWIFT,
            pattern: ".",
            // TWO frameworks, not three. The alternation carried `SwiftUI` until the client finished
            // crossing; leaving it would have let a rescued file name a framework that no longer
            // exists anywhere in `Sources`, which is dead vocabulary in the position that decides
            // whether a file is a view at all.
            //
            // ⚠️ `\b` RATHER THAN `$`, AND `Statements` RATHER THAN `Raw`, and both were live bugs.
            // The end-anchor meant a DOCUMENTED import did not rescue: `RailStatusRollup.swift` says
            // `import AppKit // the cluster and its slots are NSViews`, and this rule reported an
            // AppKit view as holding no view framework. A rule that goes red on a correct file is one
            // somebody eventually deletes. `Statements` blanks the trailing comment so the anchor
            // reads the code, and it closes the other end at the same time — under `Raw` a file that
            // merely NAMED the import in prose rescued itself.
            rescued_by: Some(r"^import (AppKit|UIKit)\b"),
            view: View::Statements,
            exempt: &[],
            message: "{files} holds no view framework — a UI target holds views only, and a frameworkless \
                      file belongs in SlopDeskClientCore (docs/56 §3)",
        },
        Claim::NoneUnder {
            roots: MAC_VIEW_TARGETS,
            extensions: SWIFT,
            pattern: r"#if os\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} carries a platform gate in a macOS UI target — the file is in the wrong \
                      target (docs/56 §3)",
        },
        Claim::NoneUnder {
            roots: PHONE_VIEW_TARGETS,
            extensions: SWIFT,
            pattern: r"#if (os\((macOS|watchOS|tvOS)\)|canImport\(AppKit\))",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} gates on a platform the phone never builds for (docs/56 §3)",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskPhoneUI"],
            extensions: SWIFT,
            minimum: 15,
            message: "only {found} files globbed under Sources/SlopDeskPhoneUI — the directive shape below \
                      would pass by reading nothing",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskVideoClientPhone"],
            extensions: SWIFT,
            minimum: 1,
            message: "only {found} files globbed under Sources/SlopDeskVideoClientPhone — the directive \
                      shape below would pass by reading nothing",
        },
        // ⚠️ THE PHONE'S `SwiftUI` BAN USED TO SIT HERE, AND IT WAS NARROWER THAN THE TRUTH. It read
        // the two phone targets only, on the reading that the Mac had crossed to AppKit first and
        // the phone was the half still migrating. Both halves have landed:
        // `no_declarative_framework_survives` below bans the import across `Sources`, `Apps` and
        // `Tests` at once, which strictly subsumes this claim, so a copy here would be a ban that
        // can never be the one to fire — the dead weight a reader has to prove is dead before
        // touching either. The floors above stay: they belong to the two directive claims around
        // them, which ARE phone-only.
        Claim::PerFileCounts {
            roots: PHONE_VIEW_TARGETS,
            extensions: SWIFT,
            expect: &[
                (r"^[[:space:]]*#(if|elseif|else|endif)", 2),
                (r"^#if os\(iOS\)$", 1),
                (r"^#endif$", 1),
            ],
            view: View::Statements,
            exempt: &[],
            message: "{files} carries more than the one whole-file '#if os(iOS)' — the readings are \
                      total/opens/ends, and every other arm is always-true scaffolding (docs/56 §3)",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskMacUI"],
            extensions: SWIFT,
            pattern: "import SlopDeskPhoneUI",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} reached for the phone half — the two halves share no view ancestor (docs/56 \
                      §3)",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI"],
            extensions: SWIFT,
            pattern: "import SlopDeskMacUI",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} reached for the Mac half — the two halves share no view ancestor (docs/56 §3)",
        },
    ];
    check_all(tree, &claims)
}

/// NO DECLARATIVE FRAMEWORK SURVIVES ANYWHERE IN THE SWIFT TREE.
///
/// Measured 2026-08-28, and the measurement is the whole rule: `^\s*import SwiftUI` across
/// `Sources`, `Apps` and `Tests` returns NOTHING, and `canImport(SwiftUI)` returns nothing in code
/// either. The Mac entry point is a plain `NSObject, NSApplicationDelegate`
/// (`Sources/SlopDeskMacUI/SlopDeskMacApp.swift`), not a `SwiftUI` `App`. So the ban goes in at the
/// measured truth, which is zero — the same doctrine as the shared-vocabulary ceiling, from the
/// clean end of it for once.
///
/// ## Why this is ONE rule and not the seven it replaces
///
/// Every ban on this import was scoped to the target somebody happened to be repairing:
/// [`the_ui_split_holds_its_shape`] read the two phone targets,
/// [`client_layers::presentation_logic_draws_nothing_both`](super::client_layers::presentation_logic_draws_nothing_both)
/// read `SlopDeskClientCore` alone. Between them they covered three of the sixteen Swift targets,
/// and everything else — `SlopDeskMacUI`, `SlopDeskWorkspaceCore`, `SlopDeskSlate`,
/// `SlopDeskTerminal`, every sidecar face, both `Apps/` shells and all of `Tests` — was unpinned
/// while the standing directive said the framework was gone from ALL of it. A per-target ban is the
/// right shape for a MIGRATION, where one target crosses at a time; it is the wrong shape for a
/// FINISHED one, because the next target to regress is by definition one nobody has repaired yet.
///
/// Both narrow claims are DELETED rather than left underneath this one. A subsumed ban cannot be
/// the one that fires, so it reads as a second opinion when it is really dead weight — and the
/// reader who eventually touches either rule has to prove the redundancy before they can move.
/// Their doc comments now point here, which is the part that has to survive: this rule is the
/// load-bearing one.
///
/// `Tests` is in scope though the directive named only `Sources` and `Apps`, because it measures
/// zero as well and a test target is exactly where a re-entry gets excused as "only for the
/// fixture".
///
/// ## ⚠️ THE VIEW IS `Statements`, AND `Code` WOULD NOT HAVE BEEN ENOUGH
///
/// Every surviving mention of this import in the tree is PROSE asserting that it is gone —
/// `SlopDeskSplitViewController.swift`, `MacStatusMark.swift`, `PreferencesStore.swift`,
/// `PaneImmersiveCapture.swift`. A `View::Raw` ban goes in RED against four files that are correct
/// and gets disabled by whoever hits it first, which is how a rule dies. `View::Code` drops
/// WHOLE-LINE comments and would clear all four today, but the `canImport` half of the pattern is
/// not line-anchored, so a trailing `// … canImport(SwiftUI) …` after real code would fire it.
/// [`View::Statements`] blanks every comment with a tokenizer while keeping the line structure the
/// anchor needs, which is the only view that reads both halves correctly.
///
/// The `canImport` half is not decoration: `PaneImmersiveCapture.swift`'s own header records that a
/// `#if canImport(SwiftUI)` was once added to satisfy a ratchet, which is the re-entry route this
/// pattern exists to close.
#[must_use]
pub fn no_declarative_framework_survives(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"^\s*import SwiftUI|canImport\(SwiftUI\)",
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "{files} named SwiftUI — the client is AppKit and UIKit with no SwiftUI anywhere, and \
                      the two IMPERATIVE view frameworks are the only ones a Swift file here may import. A \
                      declarative surface is a stage that has not landed rather than a choice (CLAUDE.md \
                      'Rust is the default', docs/62)",
        },
        // ⚠️ ONE FLOOR PER ROOT, and `3f11c6e6` is the argument every time: a ban with nothing
        // required beside it is satisfied perfectly by a root that globbed to nothing. Summing them
        // would hide `Apps` completely — eight files against six hundred. The numbers sit far under
        // today's 642 / 8 / 567 because what they catch is a root that VANISHED or was RENAMED, not
        // a tree that shrank.
        Claim::Populated {
            roots: &["Sources"],
            extensions: SWIFT,
            minimum: 200,
            message: "only {found} Swift files under Sources — the SwiftUI ban over it is reading almost \
                      nothing, so check the root was not renamed or moved",
        },
        Claim::Populated {
            roots: &["Apps"],
            extensions: SWIFT,
            minimum: 4,
            message: "only {found} Swift files under Apps — the SwiftUI ban over it is reading almost \
                      nothing, so check the root was not renamed or moved",
        },
        Claim::Populated {
            roots: &["Tests"],
            extensions: SWIFT,
            minimum: 200,
            message: "only {found} Swift files under Tests — the SwiftUI ban over it is reading almost \
                      nothing, so check the root was not renamed or moved",
        },
    ];
    check_all(tree, &claims)
}

/// The video surface stays split, and the engine under it holds no views
///
/// `SlopDeskVideoClient` was the one view target the split never reached. Thirty-three files, and
/// ONE of them — `VideoWindowView.swift` — carried a 2,514-line `#if os(macOS)` / `#elseif os(iOS)`
/// two-armed conditional: an `AppKit` implementation and a `UIKit` one in the same file, linked by
/// both shells. That is the exact shape this section exists to abolish, and it hid a live parity
/// gap for a release: the swipe-peel chip was MOUNTED on both platforms and DRIVEN on one, so a
/// two-finger swipe on the phone navigated the remote app with no chip and no haptic while the
/// shared overlay sat permanently dark — and the stale doc comment that caused it ("never set on
/// iOS, no trackpad scroll phases") had been false since the phone started sending phase-carrying
/// scroll.
///
/// ## Rule A — the engine holds no views
/// THE SHAPE, NOT A COUNT. Four files here legitimately carry `#if os(macOS)` and are named in Rule
/// C; each is `docs/56` §3's second bullet — "a framework call is not a view; a `some View` is" —
/// an ACTUATOR picking an API, not a surface drawn twice. Counting their directives would pin a
/// number that cannot say which fact it counted. What is banned is the thing they are not: a view
/// DECLARATION.
///
/// ⚠️ THE PATTERN MATCHES A DECLARATION, NOT A MENTION, and the difference is not pedantry. This
/// rule was first written with a bare `: *NSView\b`, and its very first finding was
/// `FramePacer.swift` — on `start(view: NSView)`, a PARAMETER, which is the exact case Rule C
/// excuses `FramePacer` for. Two rules disagreeing about the same file is how an allowlist grows an
/// entry that hides a real violation later: the cheap fix is to widen Rule C, and a Rule C wide
/// enough to satisfy Rule A no longer says anything.
///
/// ## Rule B — the two-armed file stays gone
/// Deliberately NOT routed through the deleted-Swift union: that union's patterns are grepped
/// across all of `Sources/`, and `VideoLayerView` / `MetalLayerBackedView` / `VideoWindowView` are
/// the LEGITIMATE type names in the phone half (the house convention gives the Mac the `Mac` prefix
/// and the phone the bare name — `MacGuiLeafView` vs `GuiLeafView`, sixty such pairs). A union
/// entry would false-positive forever, which is how a ban gets deleted for being noisy. The PATH is
/// the unambiguous fact, so the path is what this checks.
///
/// ## Rule C — the carve-out, named, with its reason, and self-invalidating
/// `FramePacer` (`NSView` vs `UIView` display link), `VideoWindowPipeline` (the `HostView`
/// typealias plus `NSScreen`), `ClientCursorCompositor` (`NSCursor` vs the position-overlay
/// sublayer) and `MetalVideoRenderer` (`displaySyncEnabled`, which iOS has no spelling for). Four
/// actuators, four different APIs, no drawing in any of them. `AudioPlaybackEngine` was the fifth
/// and it LEFT rather than being dropped: its arm was AUHAL vs `RemoteIO`, and
/// `rust/slopdesk-audio-out` opens the output stream through `cpal` on both platforms.
///
/// ⚠️ IT FAILS BOTH WAYS ON PURPOSE. An entry that no longer carries the arm this carve-out exists
/// for is a gate that has quietly stopped checking anything. An allowlist nobody re-validates is
/// worse than no allowlist, because it reads as a decision that was made.
#[must_use]
pub fn the_video_surface_stays_split(tree: &Tree) -> Report {
    /// The four actuators, each of which must still carry the arm it is excused for.
    const ACTUATORS: &[&str] = &[
        "Sources/SlopDeskVideoClient/FramePacer.swift",
        "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift",
        "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift",
        "Sources/SlopDeskVideoClient/MetalVideoRenderer.swift",
    ];

    let mut report = Report::new();
    for actuator in ACTUATORS {
        Claim::Matches {
            path: actuator,
            pattern: r"^[[:space:]]*#if.*os\(macOS\)",
            view: View::Statements,
            // The sentence names the path itself, since a table cannot carry a placeholder the claim
            // does not fill.
            message: "a named video actuator no longer carries the platform arm this carve-out exists for — \
                      drop it from the ledger (docs/56 §3)",
        }
        .check(tree, &mut report);
    }

    let claims = [
        Claim::Populated {
            roots: &[ENGINE],
            extensions: SWIFT,
            minimum: 25,
            message: "only {found} files globbed under Sources/SlopDeskVideoClient — this gate would pass \
                      by reading nothing",
        },
        // ⚠️ THE ENGINE'S `SwiftUI` BAN WAS THE THIRD COPY, and it is gone for the same reason as the
        // phone's: `no_declarative_framework_survives` reads every Swift root, so this claim could
        // never have been the one to fire. The DECLARATION ban below is what carries the engine's
        // own law — a view type here belongs in one of the two shells — and it names `View` and both
        // `…Representable` spellings, which are what a re-entry would have to declare even if the
        // import somehow arrived by another route.
        Claim::NoneUnder {
            roots: &[ENGINE],
            extensions: SWIFT,
            pattern: r"^[[:space:]]*[@A-Za-z ]*\b(struct|class|enum|extension) [A-Za-z_][A-Za-z0-9_.]*[^{]*:[^{]*\b(View|NSViewRepresentable|UIViewRepresentable|NSView|UIView|NSHostingView)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} declares a view type in the video engine target — it belongs in \
                      SlopDeskVideoClientMac or …Phone (docs/56 §3)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoClient/VideoWindowView.swift",
            message: "its two arms are two targets now (docs/56 §3)",
        },
        Claim::NoneUnder {
            roots: &[ENGINE],
            extensions: SWIFT,
            pattern: r"^[[:space:]]*#if.*os\((macOS|iOS)\)",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: ACTUATORS,
            message: "{files} carries a platform arm outside the four named actuators — if the file draws, \
                      it belongs in a half (docs/56 §3)",
        },
    ];
    report.absorb(check_all(tree, &claims));
    report
}

/// The two video halves accept the same seam sinks and subscribe the same pipeline callbacks
///
/// ## Rule D — the seam sinks
/// The one real cost of duplicating the pane adapter: two lists of a dozen-odd closures that can
/// drift, and a sink wired on one half and forgotten on the other is invisible until somebody uses
/// the feature on the platform that lost it. `RemotePaneContext` is the single source both halves
/// transcribe; this asserts the transcriptions agree.
///
/// ⚠️ THE EXTRACTION IS THE STORED SEAM PROPERTIES, not every `on…Ready|Changed` token in the
/// target. A token grep also scoops up the `VideoWindowPipeline` callbacks each half subscribes to,
/// which are a DIFFERENT contract with a different asymmetry — Rule E owns those. Written the broad
/// way this rule failed on three symbols that were none of its business while saying nothing about
/// the one that was: a gate that conflates two ledgers reports each one's exceptions as the other's
/// noise, and gets relaxed until it means nothing.
///
/// ⚠️ THE EXCEPTION IS THE FEATURE. `onSystemKeyInjectorReady` is genuinely absent from the phone
/// half and should be: its argument is a raw `NSEvent.ModifierFlags` bit pattern whose only
/// producer is `SystemKeyCaptureController`'s `CGEventTap`, and neither exists in the iOS SDK —
/// `PaneImmersiveCapture.isSupported` is already false there, so publishing a sink would light
/// `RemoteWindowModel.canInjectSystemKeys` for a capture that can never run. Adding a name to this
/// ledger must cost a sentence saying why.
///
/// ## Rule E — the pipeline callbacks
/// `VideoWindowPipeline` publishes its own `on…` callbacks, distinct from the seam sinks: these are
/// the ENGINE talking back to whichever half mounted it. One is subscribed by the Mac half and not
/// the phone, and it is a REAL floor — `onRemoteCursorChanged` does not exist on iOS, because
/// `VideoWindowPipeline` declares it inside `#if os(macOS)` to carry an `NSCursor`, and the reason
/// it carries one is that `NSCursor(image:hotSpot:)` takes an arbitrary bitmap while
/// `UIPointerStyle` does not. The two halves answer "what shape is the host cursor" differently ON
/// PURPOSE: macOS paints the shape onto the local pointer and adds no overlay, and the phone keeps
/// the position overlay it already composites and hides the local pointer over it.
///
/// TWO ENTRIES ARE GONE, and both left the same way — the gate went red and named the one to
/// delete. `onSwipeNavStatusChanged` was never a floor, it was a bug: what was missing was never
/// the drawing but the DRIVER, and the premise that kept it missing ("a touch produces no scroll
/// phases") was false in the file that stated it. `onServerCursorVisibilityChanged` was a floor
/// written on a false premise: `TARGETED_DEVICE_FAMILY` is "1,2", so an iPad with a trackpad always
/// had a cursor, and the tree had zero `UIPointerInteraction` — a whole input modality missing on a
/// first-class device, not a layout difference.
///
/// Failing both ways matters more here than anywhere else in this section: a ledger that only fails
/// on regression is half a ledger, and both of those deletions were the half that catches a FIX.
#[must_use]
pub fn the_two_video_halves_agree(tree: &Tree) -> Report {
    const SEAM_SINK: &str = r"^ +(?:public )?let (on[A-Za-z]+):";
    const PIPELINE_SINK: &str = r"pipeline\.(on[A-Za-z]+) *=";

    let claims = [
        Claim::SameSetUnder {
            label: "seam sinks",
            left: Corpus {
                root: MAC_HALF,
                extensions: SWIFT,
                pattern: SEAM_SINK,
            },
            right: Corpus {
                root: PHONE_HALF,
                extensions: SWIFT,
                pattern: SEAM_SINK,
            },
            left_only: &["onSystemKeyInjectorReady"],
            floor: 14,
        },
        Claim::SameSetUnder {
            label: "pipeline callbacks",
            left: Corpus {
                root: MAC_HALF,
                extensions: SWIFT,
                pattern: PIPELINE_SINK,
            },
            right: Corpus {
                root: PHONE_HALF,
                extensions: SWIFT,
                pattern: PIPELINE_SINK,
            },
            left_only: &["onRemoteCursorChanged"],
            floor: 8,
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A phone target that clears its floor, every file gated exactly once.
    fn phone(fixture: &Fixture, count: usize) {
        for index in 0..count {
            fixture.write(
                &format!("Sources/SlopDeskPhoneUI/Views/View{index}.swift"),
                "#if os(iOS)\nimport UIKit\nfinal class V: UIView {}\n#endif\n",
            );
        }
        for index in 0..3 {
            fixture.write(
                &format!("Sources/SlopDeskVideoClientPhone/Half{index}.swift"),
                "#if os(iOS)\nimport UIKit\nfinal class H: UIView {}\n#endif\n",
            );
        }
    }

    fn split(fixture: &Fixture) -> &Fixture {
        phone(fixture, 52);
        for index in 0..4 {
            fixture
                .write(
                    &format!("Sources/SlopDeskMacUI/Views/MacView{index}.swift"),
                    "import AppKit\nfinal class V: NSView {}\n",
                )
                .write(
                    &format!("Sources/SlopDeskVideoClientMac/Half{index}.swift"),
                    "import AppKit\nfinal class H: NSView {}\n",
                );
        }
        fixture
    }

    #[test]
    fn a_ui_target_holds_views_and_the_phone_carries_one_gate() {
        let fixture = Fixture::new("ui-split");
        split(&fixture);
        assert!(super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());

        // ⚠️ A DOCUMENTED IMPORT RESCUES, WHICH IS THE HALF THAT WAS BROKEN, and it goes here
        // because every later case seeds a violation that `split()` does not undo.
        // `RailStatusRollup` spells `import AppKit // the cluster and its slots are
        // NSViews` and this rule reported it as holding no view framework, because the `$`
        // anchor could not see past the comment. A rule that goes red on a correct file is
        // one somebody eventually deletes.
        fixture.write(
            "Sources/SlopDeskMacUI/Views/MacView0.swift",
            "import AppKit // the slots are NSViews\nfinal class V: NSView {}\n",
        );
        assert!(super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());

        // Logic sitting where only one half can reach it is how a model gets written twice.
        fixture.write(
            "Sources/SlopDeskMacUI/Views/MacRanking.swift",
            "import Foundation\nstruct Ranking {}\n",
        );
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());

        // The always-true inner arm: dead scaffolding around code that now always runs.
        split(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Views/View3.swift",
            "#if os(iOS)\nimport UIKit\n#if os(iOS)\nlet a = 1\n#endif\nfinal class V: UIView {}\n#endif\n",
        );
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());

        // A dead gate in a target only one platform builds.
        split(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClientMac/Half1.swift",
            "import AppKit\n#if os(macOS)\nfinal class H: NSView {}\n#endif\n",
        );
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());

        // A file naming no view framework at all, which is what the narrowed rescue now decides. It
        // imports the framework the phone half does NOT build with, so the only thing keeping it
        // out is the alternation having dropped SwiftUI.
        split(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Views/View7.swift",
            "#if os(iOS)\nimport SwiftUI\nfinal class V: UIView {}\n#endif\n",
        );
        let report = super::the_ui_split_holds_its_shape(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|line| line.contains("holds no view framework")),
            "{report:?}"
        );

        // The PROSE-ONLY direction of the same repair: naming the import in a comment must NOT
        // rescue, or widening the anchor would open a hole where the anchor was.
        split(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Views/MacView0.swift",
            "// import AppKit went with the SwiftUI shell\nlet rung = 0\n",
        );
        let report = super::the_ui_split_holds_its_shape(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|line| line.contains("MacView0.swift")),
            "{report:?}"
        );

        // And one half reaching for the other, which is where a shared view ancestor starts.
        split(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Views/MacView0.swift",
            "import AppKit\nimport SlopDeskPhoneUI\nfinal class V: NSView {}\n",
        );
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());
    }

    /// The tree-wide ban, in the four directions it can fail.
    ///
    /// The PROSE direction is the one that decides whether this rule survives contact: four live
    /// files say `import SwiftUI` in a comment to record that it is gone, and a rule that goes red
    /// against a correct file is a rule somebody deletes. Both a whole-line comment and a TRAILING
    /// one are seeded, because only the second distinguishes [`View::Statements`] from `View::Code`
    /// and only the second covers the un-anchored `canImport` half of the pattern.
    #[test]
    fn a_declarative_import_anywhere_in_the_swift_tree_is_caught_and_prose_is_not() {
        let fixture = Fixture::new("no-swiftui-anywhere");
        seed_swift_roots(&fixture);
        assert!(super::no_declarative_framework_survives(&fixture.tree()).is_clean());

        // A target nothing pinned before this rule: neither the phone ban nor the ClientCore one
        // could see `SlopDeskWorkspaceCore`.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/Rail.swift",
            "import SwiftUI\nstruct Rail: View { var body: some View { EmptyView() } }\n",
        );
        let report = super::no_declarative_framework_survives(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("Rail.swift")),
            "{report:?}"
        );

        // The conditional-compilation route back in, which is how it arrived last time.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/Rail.swift",
            "import Foundation\n#if canImport(SwiftUI)\nlet declarative = true\n#endif\n",
        );
        assert!(
            !super::no_declarative_framework_survives(&fixture.tree()).is_clean(),
            "the canImport half of the pattern is not reading anything",
        );

        // And an indented import inside a directive, which is why the anchor is `^\s*` and not `^`.
        fixture.write(
            "Tests/SlopDeskWorkspaceCoreTests/RailTests.swift",
            "#if os(iOS)\n    import SwiftUI\n#endif\n",
        );
        let report = super::no_declarative_framework_survives(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("RailTests.swift")),
            "Tests is in scope and the anchor tolerates leading space: {report:?}"
        );

        // ⚠️ PROSE IS NOT A REGRESSION, in either comment position. Four live files depend on this.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/Rail.swift",
            "// `import SwiftUI` went with the SwiftUI phone, and `#if canImport(SwiftUI)` with it.\nlet \
             rung = 0 // no canImport(SwiftUI) anywhere either\n",
        );
        fixture.write("Tests/SlopDeskWorkspaceCoreTests/RailTests.swift", "let ok = 1\n");
        assert!(
            super::no_declarative_framework_survives(&fixture.tree()).is_clean(),
            "a header recording that the framework is gone must not read as the framework arriving",
        );
    }

    /// A root that vanished satisfies the ban perfectly. Per root, because `Apps` holds eight files
    /// against `Sources`' six hundred and would disappear under any combined count.
    #[test]
    fn a_swift_root_that_vanished_is_named_rather_than_passing() {
        let fixture = Fixture::new("no-swiftui-floor-vacuity");
        seed_swift_roots(&fixture);
        for index in 0..4 {
            fixture.remove(&format!("Apps/ClientApp-iOS/App{index}.swift"));
        }
        let report = super::no_declarative_framework_survives(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("only 0 Swift files under Apps")),
            "{report:?}"
        );
    }

    /// Enough plain files under each Swift root to clear all three floors.
    fn seed_swift_roots(fixture: &Fixture) {
        for index in 0..200 {
            fixture.write(
                &format!("Sources/SlopDeskWorkspaceCore/Filler{index}.swift"),
                "import Foundation\n",
            );
            fixture.write(
                &format!("Tests/SlopDeskWorkspaceCoreTests/Filler{index}.swift"),
                "import XCTest\n",
            );
        }
        for index in 0..4 {
            fixture.write(&format!("Apps/ClientApp-iOS/App{index}.swift"), "import UIKit\n");
        }
    }

    /// The per-target floor: one combined count would stay green on a drained video half.
    #[test]
    fn a_drained_video_half_fails_where_a_combined_floor_would_not() {
        let fixture = Fixture::new("ui-split-drained");
        for index in 0..60 {
            fixture.write(
                &format!("Sources/SlopDeskPhoneUI/Views/View{index}.swift"),
                "#if os(iOS)\nimport UIKit\nfinal class V: UIView {}\n#endif\n",
            );
        }
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());
    }

    fn engine(fixture: &Fixture) -> &Fixture {
        for index in 0..26 {
            fixture.write(
                &format!("Sources/SlopDeskVideoClient/Engine{index}.swift"),
                "import Foundation\nfinal class Engine {}\n",
            );
        }
        for actuator in [
            "FramePacer",
            "VideoWindowPipeline",
            "ClientCursorCompositor",
            "MetalVideoRenderer",
        ] {
            fixture.write(
                &format!("Sources/SlopDeskVideoClient/{actuator}.swift"),
                "#if os(macOS)\nlet link = CVDisplayLink()\n#else\nlet link = CADisplayLink()\n#endif\n",
            );
        }
        fixture
    }

    #[test]
    fn the_engine_declares_no_view_and_only_the_named_actuators_fork() {
        let fixture = Fixture::new("video-engine");
        engine(&fixture);
        assert!(super::the_video_surface_stays_split(&fixture.tree()).is_clean());

        // A view DECLARATION is what is banned; a `view: NSView` parameter is not.
        fixture.write(
            "Sources/SlopDeskVideoClient/Engine1.swift",
            "import Foundation\nfunc start(view: NSView) {}\n",
        );
        assert!(super::the_video_surface_stays_split(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoClient/Engine1.swift",
            "import Foundation\nfinal class VideoLayerView: NSView {}\n",
        );
        assert!(!super::the_video_surface_stays_split(&fixture.tree()).is_clean());

        // A platform arm outside the four named actuators.
        engine(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/Engine2.swift",
            "#if os(macOS)\nlet a = 1\n#endif\n",
        );
        assert!(!super::the_video_surface_stays_split(&fixture.tree()).is_clean());

        // The ledger fails BOTH ways: an actuator that stopped carrying its arm.
        engine(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/FramePacer.swift",
            "import Foundation\nfinal class FramePacer {}\n",
        );
        assert!(!super::the_video_surface_stays_split(&fixture.tree()).is_clean());

        // And the two-armed file itself, which is checked by PATH.
        engine(&fixture);
        fixture.write("Sources/SlopDeskVideoClient/VideoWindowView.swift", "// back\n");
        assert!(!super::the_video_surface_stays_split(&fixture.tree()).is_clean());
    }

    fn halves(fixture: &Fixture, mac: &[&str], phone: &[&str], mac_pipe: &[&str], phone_pipe: &[&str]) {
        use std::fmt::Write as _;

        let declare = |names: &[&str]| {
            let mut out = String::new();
            for name in names {
                let _ = writeln!(out, "    let {name}: () -> Void");
            }
            out
        };
        let subscribe = |names: &[&str]| {
            let mut out = String::new();
            for name in names {
                let _ = writeln!(out, "pipeline.{name} = {{ }}");
            }
            out
        };
        fixture
            .write(
                "Sources/SlopDeskVideoClientMac/MacSeam.swift",
                &format!("{}{}", declare(mac), subscribe(mac_pipe)),
            )
            .write(
                "Sources/SlopDeskVideoClientPhone/PhoneSeam.swift",
                &format!("{}{}", declare(phone), subscribe(phone_pipe)),
            );
    }

    /// Fourteen shared sink names plus the one platform floor, and eight shared pipeline callbacks.
    const SHARED_SINKS: &[&str] = &[
        "onPaneReady",
        "onPaneClosed",
        "onFocusChanged",
        "onSizeChanged",
        "onCursorMoved",
        "onScrollPhase",
        "onKeyDown",
        "onKeyUp",
        "onDropReady",
        "onPasteReady",
        "onTitleChanged",
        "onBadgeChanged",
        "onZoomChanged",
        "onTeardown",
    ];
    const SHARED_PIPE: &[&str] = &[
        "onFrame", "onStall", "onResize", "onAudio", "onStats", "onError", "onReady", "onClosed",
    ];

    #[test]
    fn the_two_halves_agree_and_the_ledger_fails_both_ways() {
        let fixture = Fixture::new("video-halves");
        let mac: Vec<&str> = SHARED_SINKS
            .iter()
            .copied()
            .chain(["onSystemKeyInjectorReady"])
            .collect();
        let mac_pipe: Vec<&str> = SHARED_PIPE
            .iter()
            .copied()
            .chain(["onRemoteCursorChanged"])
            .collect();
        halves(&fixture, &mac, SHARED_SINKS, &mac_pipe, SHARED_PIPE);
        assert!(super::the_two_video_halves_agree(&fixture.tree()).is_clean());

        // A sink wired on one half and forgotten on the other.
        let short: Vec<&str> = SHARED_SINKS[1..].to_vec();
        halves(&fixture, &mac, &short, &mac_pipe, SHARED_PIPE);
        assert!(!super::the_two_video_halves_agree(&fixture.tree()).is_clean());

        // The half that catches a FIX: the phone grew the excused sink, so the ledger entry is
        // stale.
        let both: Vec<&str> = SHARED_SINKS
            .iter()
            .copied()
            .chain(["onSystemKeyInjectorReady"])
            .collect();
        halves(&fixture, &mac, &both, &mac_pipe, SHARED_PIPE);
        assert!(!super::the_two_video_halves_agree(&fixture.tree()).is_clean());

        // And a drained extraction, which would otherwise compare nothing to nothing.
        halves(&fixture, &[], &[], &[], &[]);
        assert!(!super::the_two_video_halves_agree(&fixture.tree()).is_clean());
    }
}
