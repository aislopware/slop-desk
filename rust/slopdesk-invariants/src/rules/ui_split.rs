//! The UI split holds its shape, and the video surface stays split with it (`docs/56` §3).
//!
//! Ported from the deleted `check-supervisor.sh`. Three boundaries, and each fails SILENTLY rather
//! than loudly if it slips: a frameworkless file in a UI target compiles, a dead platform arm
//! compiles, and a seam sink wired on one half and forgotten on the other compiles. None of them is
//! a build error, and all of them are the same failure — one implementation becoming two.

use crate::claim::{Claim, Corpus, SWIFT, View, check_all};
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
            rescued_by: Some(r"^import (SwiftUI|AppKit|UIKit)$"),
            view: View::Raw,
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
            minimum: 50,
            message: "only {found} files globbed under Sources/SlopDeskPhoneUI — the directive shape below \
                      would pass by reading nothing",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskVideoClientPhone"],
            extensions: SWIFT,
            minimum: 2,
            message: "only {found} files globbed under Sources/SlopDeskVideoClientPhone — the directive \
                      shape below would pass by reading nothing",
        },
        Claim::PerFileCounts {
            roots: PHONE_VIEW_TARGETS,
            extensions: SWIFT,
            expect: &[
                (r"^[[:space:]]*#(if|elseif|else|endif)", 2),
                (r"^#if os\(iOS\)$", 1),
                (r"^#endif$", 1),
            ],
            view: View::Code,
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
            view: View::Raw,
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
        Claim::NoneUnder {
            roots: &[ENGINE],
            extensions: SWIFT,
            pattern: r"^import SwiftUI$",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} imports SwiftUI in the video engine target — it belongs in \
                      SlopDeskVideoClientMac or …Phone (docs/56 §3)",
        },
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
                view: View::Raw,
            },
            right: Corpus {
                root: PHONE_HALF,
                extensions: SWIFT,
                pattern: SEAM_SINK,
                view: View::Raw,
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
                view: View::Raw,
            },
            right: Corpus {
                root: PHONE_HALF,
                extensions: SWIFT,
                pattern: PIPELINE_SINK,
                view: View::Raw,
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
                "#if os(iOS)\nimport SwiftUI\nstruct V: View { var body: some View { Text(\"\") } \
                 }\n#endif\n",
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
            "#if os(iOS)\nimport SwiftUI\n#if os(iOS)\nlet a = 1\n#endif\nstruct V: View {}\n#endif\n",
        );
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());

        // A dead gate in a target only one platform builds.
        split(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClientMac/Half1.swift",
            "import AppKit\n#if os(macOS)\nfinal class H: NSView {}\n#endif\n",
        );
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());

        // And one half reaching for the other, which is where a shared view ancestor starts.
        split(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Views/MacView0.swift",
            "import AppKit\nimport SlopDeskPhoneUI\nfinal class V: NSView {}\n",
        );
        assert!(!super::the_ui_split_holds_its_shape(&fixture.tree()).is_clean());
    }

    /// The per-target floor: one combined count would stay green on a drained video half.
    #[test]
    fn a_drained_video_half_fails_where_a_combined_floor_would_not() {
        let fixture = Fixture::new("ui-split-drained");
        for index in 0..60 {
            fixture.write(
                &format!("Sources/SlopDeskPhoneUI/Views/View{index}.swift"),
                "#if os(iOS)\nimport SwiftUI\nstruct V: View {}\n#endif\n",
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

        // The half that catches a FIX: the phone grew the excused sink, so the ledger entry is stale.
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
