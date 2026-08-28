//! A frameworkless value descends to the floor; a value with a colour in it stays paired.
//!
//! Ported from the deleted `check-supervisor.sh`. The whole family here answers one question asked
//! seven times: when two renderers must agree about a number or an ink, where does the agreement
//! live? If the value has no framework in it — an alpha is a `Double`, a corner radius is a
//! `CGFloat` — it goes DOWN to `SlopDeskSlate` and both halves read one token. If it resolves to a
//! `Color`, it cannot descend, because `Color` is Slate's own and Slate sits above the logic floor
//! that names the cases. Then the BRANCH descends and the LOOKUP stays per renderer, and what needs
//! a gate is that every renderer still answers every rung.
//!
//! The rest of the module is the same shape one layer up: a scene that injects environment nothing
//! reads, a fold whose two halves must not import each other, a dead flag that must not be
//! translated into a second language, and one list of test-lint relaxations shared by link rather
//! than by copy.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The design floor, which is where a value with no framework in it ends up.
const SLATE_DESIGN: &str = "Sources/SlopDeskSlate/SlateDesign.swift";
/// The Mac's scene root — the one file that could inject an environment key nothing resolves.
const MAC_APP: &str = "Sources/SlopDeskMacUI/SlopDeskMacApp.swift";
/// The two halves of the pane status pill, both of which ship today.
const PILL_HALVES: &[&str] = &[
    "Sources/SlopDeskPhoneUI/Pane/PaneStatusPillsView.swift",
    "Sources/SlopDeskMacUI/Pane/MacPaneStatusPills.swift",
];
/// Where the pill's ink cases are declared.
const PILL_INK_SRC: &str = "Sources/SlopDeskWorkspaceModel/Reading/PaneStatusPillPresentation.swift";

/// The rungs of a `package enum`, read out of the enum rather than listed.
///
/// The name is bounded by `[:[:space:]{]` rather than left open, and that bound is load-bearing:
/// an open `^package enum DropZoneInk` also matches `DropZoneInkRung`, so an enum RENAMED out from
/// under a rule would keep parsing and the rule would keep passing against a table nothing declares
/// any more. Read RAW, because `grep -oE '^[[:space:]]*case '` already refuses a `///` line — the
/// anchor is the comment strip here, and it is the one the shell used.
///
/// The pattern stops at the `(`, so a case with an associated value (`fixed(PaneStatusPillInk)`)
/// reads as `fixed` — which is also what the renderer probe below matches, since `(` is a word
/// boundary and `case \.fixed\b` catches `case .fixed:` and `case .fixed(let ink):` alike.
const fn rungs_of(path: &'static str, enumeration: &'static str) -> Extract {
    Extract::raw(path, r"^[[:space:]]*case ([a-zA-Z]+)").within(enumeration, r"^\}")
}

/// A frameworkless value goes to the floor, not into a pair
///
/// The ACCENT RING's alpha is spelled three times across TWO renderers: `ViModeOverlay` and
/// `TerminalFindBar` in `SwiftUI`, and `MacGlobalSearch` in `AppKit` — the last drawing the ON chip
/// of the very pill whose header pins that the find bar and the global-search bar render
/// identically. The ink of that pair needs a gate because a `Color` table cannot descend below
/// `SlopDeskSlate`. An ALPHA can: it is a `Double` with no framework in it, so it went to the floor
/// and all three read one token. That is the general finding — before pinning a pair, ask whether
/// the value has a colour in it.
///
/// The literal is banned only WHERE THE RING IS DRAWN, never repo-wide. A second `0.5` family — the
/// locked/disabled dim in `FontSettingsView`, `GuiLeafView` and `MacFontFamilySurface.lockedAlpha`
/// — is deliberately un-minted, and a blanket ban would be red for values that are right.
///
/// ## The grab pill, whose drawings are compared inside ONE gesture
/// Merging a satellite home means grabbing the pill in the detached window, crossing, and releasing
/// on the leaf whose own pill is the target. A 44 that became a 42 does not read as two files
/// disagreeing; it reads as the thing in the user's hand changing size. Four drawings now, and the
/// row that moved is the point: R11 landed the Mac halves of both the canvas handle and the
/// satellite strip and deleted the `SwiftUI` satellite, so the Mac path REPLACED its row rather
/// than joining beside it. The two `SwiftUI` rows that remain are the phone's.
#[must_use]
pub fn a_frameworkless_value_goes_to_the_floor(tree: &Tree) -> Report {
    /// The three files that draw the accent ring, in either framework.
    const RING_SITES: &[&str] = &[
        "Sources/SlopDeskPhoneUI/Pane/ViModeOverlayView.swift",
        "Sources/SlopDeskPhoneUI/Pane/TerminalFindBarView.swift",
        "Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift",
    ];
    /// The three files that draw the grab pill.
    const PILL_DRAWINGS: &[&str] = &[
        "Sources/SlopDeskPhoneUI/Pane/PaneMoveAffordance.swift",
        "Sources/SlopDeskMacUI/Pane/MacPaneMoveAffordance.swift",
        "Sources/SlopDeskMacUI/Pane/MacSatellitePaneContent.swift",
    ];

    let mut claims = vec![
        Claim::Matches {
            path: SLATE_DESIGN,
            pattern: r"static let accentRing\b",
            view: View::Code,
            message: "`Slate` stopped minting `accentRing` — its readers span two renderers and the literal \
                      cannot be compared across them (docs/56 stage F, P6)",
        },
        Claim::Matches {
            path: SLATE_DESIGN,
            pattern: r"static let glyphPlate\b",
            view: View::Code,
            message: "`Slate` stopped minting `glyphPlate` — its readers span two renderers and the literal \
                      cannot be compared across them (docs/56 stage F, P6)",
        },
        // The ban and the readers together: a file that stopped reading the token would satisfy the
        // ban by drawing no ring at all, and a file that reads the token beside a fresh literal is
        // the drift the token was minted to end.
        Claim::NoneOf {
            paths: RING_SITES,
            pattern: r"\.opacity\(0\.5\)|withAlphaComponent\(0\.5\)",
            view: View::Code,
            message: "the accent ring's alpha is a literal again in a file that reads the token beside it \
                      (docs/56 stage F, P6)",
        },
    ];
    for site in RING_SITES {
        claims.push(Claim::Names {
            path: site,
            needle: "Slate.Opacity.accentRing",
            message: "a ring site stopped reading `Slate.Opacity.accentRing` — the third spelling is the \
                      one that shipped drifted (docs/56 stage F, P6)",
        });
    }
    for drawing in PILL_DRAWINGS {
        claims.push(Claim::Names {
            path: drawing,
            needle: "Slate.GrabPill",
            message: "a grab-pill drawing is back on its own numbers — the two pills are compared across a \
                      SINGLE drag (docs/56 stage F, P6)",
        });
    }
    check_all(tree, &claims)
}

/// The Mac injects no environment it does not read
///
/// `SlopDeskMacApp` handed its scene root three of the draining target's environment keys —
/// `\.preferencesStore`, `\.agentHooksController`, `\.overlayCoordinator` — and re-applied all
/// three to every satellite root against the hosting-root env trap. Every reader of all three is a
/// PHONE view. Each has an `AppKit` twin the Mac mounts instead, and each twin takes its dependency
/// as an INIT PARAMETER.
///
/// A dead injection is worse than dead code, which is why this is a gate and not a cleanup. It
/// costs nothing at runtime, cannot fail a test, and survives every rewrite that deletes its last
/// reader — so it accumulates, and it reads to the next person as evidence that a subtree still
/// resolves keys it stopped resolving three increments ago.
///
/// The patterns are NOT anchored to the start of a line, deliberately: `.a().b()` chained on one
/// line is the same injection and the obvious way to reintroduce it. The `(` is what keeps this off
/// the `\.key` spelling every sentence above uses. `overlayCoordinator` joined the ban in 57a — not
/// because nobody reads it, the satellite's subtree does, but because naming it HERE is what made
/// `SlopDeskMacUI` import the whole phone target to spell one modifier.
///
/// ## And the satellite's seam is gone
/// The paragraph that shipped with this gate predicted it: "it dies with increment 62, when the
/// satellite's content is `AppKit`". R11 landed that content, so `SatellitePaneContent.swift` — the
/// `SatellitePaneHost.contentView` seam and the `SatellitePaneRootView` it hosted — was deleted
/// rather than left mounted by nothing. The assertion INVERTS rather than retiring, for the
/// `staticMirror` reason: a seam whose whole job was to carry a `SwiftUI` view across a target
/// boundary is exactly the thing a later agent re-creates while porting something adjacent, and it
/// would compile. There is no environment left for it to inject into, so the file coming back means
/// the split un-happened for one window class and nothing else would say so.
#[must_use]
pub fn the_mac_injects_no_environment_it_does_not_read(tree: &Tree) -> Report {
    /// The path the deleted hosting seam occupied.
    const SATELLITE_HOST: &str = "Sources/SlopDeskPhoneUI/Pane/SatellitePaneContent.swift";

    let mut claims = vec![
        Claim::Absent {
            path: SATELLITE_HOST,
            message: "the satellite's content is AppKit, so its hosting seam has no job (docs/56 §3.5)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "SatellitePaneHost",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "SatellitePaneHost is named again in {files} — the seam it spelled was deleted with \
                      R11 (docs/56 §3.5)",
        },
    ];
    for key in ["preferencesStore", "agentHooksController", "overlayCoordinator"] {
        claims.push(Claim::Lacks {
            path: MAC_APP,
            // Built per key rather than as one alternation so the sentence can name the key that
            // came back; the pattern is the shell's `\.${key}\(` exactly.
            pattern: match key {
                "preferencesStore" => r"\.preferencesStore\(",
                "agentHooksController" => r"\.agentHooksController\(",
                _ => r"\.overlayCoordinator\(",
            },
            view: View::Code,
            message: match key {
                "preferencesStore" => {
                    "the Mac scene injects \\.preferencesStore again — it is off the draining floor (docs/56 \
                     §3.5)"
                },
                "agentHooksController" => {
                    "the Mac scene injects \\.agentHooksController again — it is off the draining floor \
                     (docs/56 §3.5)"
                },
                _ => {
                    "the Mac scene injects \\.overlayCoordinator again — naming it here is what the \
                     phone-target import was for (docs/56 §3.5)"
                },
            },
        });
    }
    check_all(tree, &claims)
}

/// The fold is shut from both sides
///
/// `SlopDeskClientUI` could not be renamed `SlopDeskPhoneUI` while ANY `SlopDeskMacUI` file
/// imported it. That was a count for eleven increments — 13 files, then 2, then 0 — and each step
/// got its own per-file gate, because naming the file was the only way to say anything true while
/// others still legitimately imported it.
///
/// The condition has been MET AND SPENT: the rename happened, and this is now what keeps it. Read
/// it in the present tense — the two halves do not import each other — rather than as a countdown
/// to something still ahead. At zero the per-file form stops being the assertion: a gate that names
/// three files is silent about the fourth, and the fourth is exactly what a later agent adds.
/// Reaching for one `some View` from a new `AppKit` surface is a one-line import that compiles,
/// passes every test, and puts the fold back behind a port. So the census is the TARGET, not a list
/// — the three per-file gates the shell kept "for the history in their comments" are this comment.
///
/// It reads the RAW import lines rather than the comment-stripped view: an import is never inside a
/// doc comment, and the ban has to survive a file whose header legitimately discusses the draining
/// floor by name (several do, including `MacContentColumn`'s account of what it stopped hosting).
///
/// ## And the edge is cut in the manifest
/// That is the half an import census cannot assert. A dependency the graph still contains is an
/// import one keystroke away and a build that will not complain; a dependency it does not contain
/// is a compile error at the first `import`. Both halves are gates because they fail at different
/// moments — the manifest one makes re-adding the import a BUILD failure rather than a lint
/// failure, and the census is what says why when it happens.
#[must_use]
pub fn the_fold_is_shut_from_both_sides(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::NoFileUnder {
            roots: &["Sources/SlopDeskMacUI"],
            extensions: SWIFT,
            pattern: "^import SlopDeskPhoneUI",
            rescued_by: None,
            view: View::Raw,
            exempt: &[],
            message: "{files} imports the draining floor — the fold's gate condition was met in increment \
                      61 and this un-meets it (docs/56)",
        },
        Claim::NotDepends {
            target: "SlopDeskMacUI",
            dependency: "SlopDeskPhoneUI",
            message: "increment 61 cut that edge in Package.swift, not only in the imports (docs/56)",
        },
    ])
}

/// One test-lint relaxation, two test trees
///
/// `Tests/.swiftlint.yml` turns off the nine rules that are idiomatic in a test and noise
/// everywhere else (force-unwrap a known-good fixture, `var sut: Foo!` in `setUp`, the
/// assertion-style rules). Increment 63 gave the repo a SECOND test tree —
/// `Apps/ClientApp-iOS/Tests`, the iOS-triple bundle that is now the only place a `SlopDeskPhoneUI`
/// view suite can compile — and it needs the same nine.
///
/// It gets them by SYMLINK, not by copy. A copy is two lists that drift, and the failure is silent
/// in the worst direction: one test tree quietly enforcing different rules than the other,
/// discovered whenever somebody edits one list and not the other. This is the same defect as a gate
/// that names its symbols, one layer down, so it is pinned the same way — as a FACT (is it a link?)
/// rather than as a comparison anybody has to remember to re-run.
#[must_use]
pub fn two_test_trees_one_relaxation(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Symlink {
        path: "Apps/ClientApp-iOS/Tests/.swiftlint.yml",
        target: "Tests/.swiftlint.yml",
        message: "the test relaxations are spelled once, and the second tree reads them by link rather than \
                  by copy (docs/56 F4c)",
    }])
}

/// One drop chip drawn twice, and one pill switch called twice
///
/// THE DROP CHIP IS DRAWN TWICE AND BOTH CAN BE ON SCREEN AT ONCE, which is what makes it different
/// from every other "drawn twice" pair in the gate. The canvas overlay's ghost chip is anchored to
/// the zone it describes; `MacPaneDragChipPanel`'s capsule takes over the moment the cursor leaves
/// the content column. Drag from the canvas to the sidebar slowly and a user sees both — so a
/// half-step of padding or a different rim does not read as two files disagreeing, it reads as the
/// chip glitching.
///
/// `PaneDropChipArt.swift` is the shared answer: the `Mark` → `SFSymbol` table and the four numbers
/// the capsule is made of. Both renderers must READ it rather than restate it. The banned literals
/// are exactly the ones open-coded in the `SwiftUI` chip before the port — a re-introduced `0.4`
/// rim or a raw `10` pad is precisely how the two would drift apart again — and a half that
/// switches on a `Mark` itself has grown a second symbol table, which is how `.beside` ends up as
/// `rectangle.stack` in one chip and something else in the other.
///
/// ## The pill fill is ONE switch now, not a pair
/// `PaneStatusPillView.fillColor` and `MacPaneStatusPillView.fillColor` used to be two
/// independently-maintained tables, spelled once per renderer on the reasoning that `Color` could
/// not be pushed DOWN to meet the ink enum without the floor importing the ladder standing on it.
/// `Slate/agentInk` already crosses that same edge the other way — the enum read UP into Slate,
/// never a token pushed down — which is what a shared switch here is too.
/// `Slate.paneStatusPillFill` and `Slate.Native.paneStatusPillFill` hold the ONE switch; each
/// renderer only CALLS it, so a case dropped from either resolution is a Swift compile error at the
/// switch itself.
///
/// ⚠️ THE CASE NAMES ARE READ OUT OF THE ENUM, never spelled here. This gate shipped for an hour
/// with `case \.(security|sync):` written inline, which is the defect increment 62 caught in the
/// `Tests/` allowlist one register up: a check that NAMES the symbols it watches goes quietly blind
/// the day one is renamed, and nothing re-reads a regex.
///
/// Both pill halves ship today, so they are ASSERTED rather than skipped. The shell's
/// `[[ -e ]] || continue` was written when the Mac twin did not exist; a rule that skips a file
/// which does exist is the quiet green this crate is for. The skip-if-absent facility stays in
/// [`Claim::Resolved`], where a row written ahead of its renderer still needs it.
#[must_use]
pub fn one_drop_chip_two_drawings(tree: &Tree) -> Report {
    /// The four numbers the capsule is made of.
    const RUNGS: &[&str] = &["glyphGap", "padH", "padV", "cancelRim"];
    /// The two files that draw the chip, in either framework.
    const CHIP_HALVES: &[&str] = &[
        "Sources/SlopDeskPhoneUI/Pane/PaneMoveAffordance.swift",
        "Sources/SlopDeskMacUI/App/MacPaneDragChipPanel.swift",
    ];

    let mut claims = vec![
        Claim::Exists {
            path: "Sources/SlopDeskSlate/PaneDropChipArt.swift",
            message: "the drop chip's two drawings have nothing left to agree on (docs/56 §3.5)",
        },
        Claim::Exists {
            path: PILL_INK_SRC,
            message: "PaneStatusPillInk is the name Slate's one switch reads (docs/56 §3.5)",
        },
        // BOTH spellings, `Color` and `Native`. One of them alone is the pair growing back with the
        // other framework's table inlined at its call site.
        Claim::AtLeast {
            path: SLATE_DESIGN,
            pattern: "static func paneStatusPillFill",
            minimum: 2,
            message: "{found} paneStatusPillFill spellings in the floor, not both (Color + Native) — the \
                      one switch split back into a pair (docs/56 §3.5)",
        },
        // The regression this guards: a renderer switching on `PaneStatusPillInk` ITSELF, rather
        // than handing the ink straight to the shared function, is the old per-renderer table
        // creeping back one case at a time.
        Claim::NoneQuoting {
            roots: PILL_HALVES,
            extensions: SWIFT,
            needles: rungs_of(PILL_INK_SRC, "^package enum PaneStatusPillInk[:[:space:]{]"),
            template: "case .{needle}:",
            view: View::Code,
            exempt: &[],
            message: "{files} switches on PaneStatusPillInk directly — that switch is \
                      Slate.paneStatusPillFill's alone now (docs/56 §3.5)",
        },
    ];
    for half in PILL_HALVES {
        claims.push(Claim::Names {
            path: half,
            needle: "paneStatusPillFill",
            message: "a pill renderer stopped calling Slate's paneStatusPillFill — a re-derived table is \
                      exactly how the pair this replaced grows back (docs/56 §3.5)",
        });
    }
    for half in CHIP_HALVES {
        claims.push(Claim::Exists {
            path: half,
            message: "the drop chip has two drawings and this ratchet pins both (docs/56 §3.5)",
        });
        for rung in RUNGS {
            claims.push(Claim::Names {
                path: half,
                // A `Slate.DropChip.padH` read, spelled the way the shell grepped it — the enum's
                // own name and the rung, which is what a re-derived number would not carry.
                needle: match *rung {
                    "glyphGap" => "DropChip.glyphGap",
                    "padH" => "DropChip.padH",
                    "padV" => "DropChip.padV",
                    _ => "DropChip.cancelRim",
                },
                message: "a drop-chip half stopped reading one of Slate.DropChip's four numbers — the two \
                          chips drift, and a user sees both at once (docs/56 §3.5)",
            });
        }
        claims.push(Claim::Lacks {
            path: half,
            pattern: r"case \.(splitColumns|splitRows|newWindow):",
            view: View::Code,
            message: "a drop-chip half switches on a PaneDropRegister.Mark — the mark→artwork table is \
                      PaneDropChipArt.swift's alone (docs/56 §3.5)",
        });
    }
    check_all(tree, &claims)
}

/// A named ink table is answered by every renderer present
///
/// The pill inks were not the only pair of that shape — increment 56c ratcheted one of three and
/// missed two. `DropZoneInk` and `GuiUploadTint` are the identical arrangement for the identical
/// reason: each is a NAME in `SlopDeskClientCore` because its resolution is a `Color`, `Color` is
/// `SlopDeskSlate`'s, and Slate sits ABOVE the logic floor — so the branch descends and the LOOKUP
/// stays in each renderer, one four-line `switch` per framework. 56c's own sentence is why they are
/// pinned now rather than after the canvas rewrite: *a ratchet written after the second renderer
/// arrives is a ratchet written too late*.
///
/// The `\b` after the rung's name is load-bearing on the drop-zone table: without it `case
/// \.accent` also matches `case .accentMuted:`, so a half that resolved only the muted rung would
/// pass for the rung it dropped. `M` follows `t` with no word boundary between them, which is
/// exactly the hole.
///
/// ## The guessed path was wrong, and the gate is what caught it
/// The `GuiUploadTint` row was written ahead of the Mac half, on the reasonable guess that the twin
/// of a 1005-line `GuiLeafView.swift` would be one file too. R10 split it into three, and the
/// upload overlay — the only thing that resolves this table — landed in `MacGuiPaneOverlays.swift`
/// with the rest of the chrome. The row names the file that HAS the switch now. That is the failure
/// mode a written-ahead row is FOR: it went red the day the twin landed, on the file, instead of
/// going quietly green against a path that would never resolve anything.
///
/// `FindTogglePillAppearance` is not a future risk the way the rows above it were: both halves ship
/// today — `TerminalFindBar`'s `SwiftUI` chips and `MacGlobalSearch`'s `updateLayer` — and its own
/// header states the invariant nothing was checking, *"the find bar and the global-search query bar
/// render the pills identically"*. Read side by side they DO agree, case for case, so the row pins
/// an agreement rather than codifying a drift — the only condition under which a row of this kind
/// is worth having.
///
/// Two rows declare their enum in a file another row already names, and that is deliberate: the
/// rule keys on the ENUM and the range is anchored to `^package enum <name>[:[:space:]{]`, so two
/// ranges in one file are read independently and a name that is a prefix of the other still cannot
/// capture it.
///
/// ## ⚠️ RE-AIMED 2026-08-28, AND FLOORED, BECAUSE THE SKIP IS ALSO THE HOLE
/// The written-ahead row is this rule's best feature and its worst one, depending on which way the
/// tree moves. `Claim::Resolved` skips an absent half BY DESIGN, so a half that has not been
/// written yet costs nothing — and a half that gets DELETED costs nothing either. `3f11c6e6`
/// deleted the SwiftUI phone wholesale and every phone half here went absent at once: five rows,
/// ten halves, and the rule stayed green while checking exactly the Mac side. That is a rule that
/// expired without saying so.
///
/// Two things fix it. The halves are re-aimed at the UIKit twins `bbb9845d` landed
/// (`PaneDropOverlay` → `PaneDropOverlayView`, `PaneStatusPills` → `PaneStatusPillsView`,
/// `TerminalFindBar` → `TerminalFindBarView`; `GuiLeafView` keeps its name, docs/62 stage E.1), and
/// a `Claim::Populated` floor over the two `Pane` targets runs FIRST, so a drained renderer target
/// fails loudly instead of letting every row skip in silence. The floor is a tripwire against an
/// empty tree, not a ratchet: 6 against a live 16 says "the phone still draws panes", which is the
/// only precondition the rows below need.
#[must_use]
pub fn a_named_ink_table_answers_every_renderer(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Populated {
            roots: &["Sources/SlopDeskPhoneUI/Pane"],
            extensions: SWIFT,
            minimum: 6,
            message: "only {found} Swift files under Sources/SlopDeskPhoneUI/Pane — every ink row below \
                      SKIPS an absent half, so a drained renderer target reads as agreement (docs/56 §3.5, \
                      docs/62 stage E.1)",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskMacUI/Pane"],
            extensions: SWIFT,
            minimum: 6,
            message: "only {found} Swift files under Sources/SlopDeskMacUI/Pane — every ink row below SKIPS \
                      an absent half, so a drained renderer target reads as agreement (docs/56 §3.5)",
        },
        Claim::Resolved {
            label: "DropZoneInk",
            needles: rungs_of(
                "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
                "^package enum DropZoneInk[:[:space:]{]",
            ),
            halves: &[
                "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlayView.swift",
                "Sources/SlopDeskMacUI/Pane/MacPaneDropOverlay.swift",
            ],
            template: r"case \.{needle}\b",
            view: View::Code,
            message: "{half} does not resolve the DropZoneInk .{needle} rung — the renderers would ink it \
                      differently (docs/56 §3.5)",
        },
        Claim::Resolved {
            label: "GuiUploadTint",
            needles: rungs_of(
                "Sources/SlopDeskClientCore/Pane/GuiPaneReadout.swift",
                "^package enum GuiUploadTint[:[:space:]{]",
            ),
            halves: &[
                "Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift",
                "Sources/SlopDeskMacUI/Pane/MacGuiPaneOverlays.swift",
            ],
            template: r"case \.{needle}\b",
            view: View::Code,
            message: "{half} does not resolve the GuiUploadTint .{needle} rung — the renderers would ink it \
                      differently (docs/56 §3.5)",
        },
        Claim::Resolved {
            label: "FindTogglePillAppearance",
            needles: rungs_of(
                "Sources/SlopDeskClientCore/Pane/FindBarPresentation.swift",
                "^package enum FindTogglePillAppearance[:[:space:]{]",
            ),
            halves: &[
                "Sources/SlopDeskPhoneUI/Pane/TerminalFindBarView.swift",
                "Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift",
            ],
            template: r"case \.{needle}\b",
            view: View::Code,
            message: "{half} does not resolve the FindTogglePillAppearance .{needle} rung — the find bar \
                      and the global-search bar render the pills identically (docs/56 §3.5)",
        },
        // The first row whose enum has an ASSOCIATED VALUE (`fixed(PaneStatusPillInk)`). Both
        // ends handle it without a change: the parse stops at the `(` and yields `fixed`, and
        // `case \.fixed\b` matches `case .fixed:` and `case .fixed(let ink):` alike. Checked
        // rather than assumed — a row that silently matched nothing would read as green while
        // pinning air.
        Claim::Resolved {
            label: "PaneStatusPillFill",
            needles: rungs_of(PILL_INK_SRC, "^package enum PaneStatusPillFill[:[:space:]{]"),
            halves: PILL_HALVES,
            template: r"case \.{needle}\b",
            view: View::Code,
            message: "{half} does not resolve the PaneStatusPillFill .{needle} rung — the renderers would \
                      ink it differently (docs/56 §3.5)",
        },
        Claim::Resolved {
            label: "DropZoneLabelInk",
            needles: rungs_of(
                "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
                "^package enum DropZoneLabelInk[:[:space:]{]",
            ),
            halves: &[
                "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlayView.swift",
                "Sources/SlopDeskMacUI/Pane/MacPaneDropOverlay.swift",
            ],
            template: r"case \.{needle}\b",
            view: View::Code,
            message: "{half} does not resolve the DropZoneLabelInk .{needle} rung — the renderers would ink \
                      it differently (docs/56 §3.5)",
        },
    ])
}

/// `staticMirror` stays deleted
///
/// IT WAS A PARAMETER NOTHING EVER SET. `staticMirror` threaded through `SplitContainer`,
/// `PaneContainer`, `GuiLeafView` and `TerminalLeafView`, branched at ~20 sites, and rode as a dead
/// argument on four `SlopDeskClientCore` predicates. Every production caller took the default; the
/// only `true` in the repo was in three unit tests, which is the shape of a feature kept alive by
/// its own tests — the same finding increment 45b recorded about a second git-line renderer.
///
/// It is deleted BEFORE the canvas is rewritten, and the timing is the whole point: ~20 of those
/// branches would otherwise have been translated into `AppKit` by hand, for a path nothing reaches.
/// A flag that is dead in one language is cheap; the same flag alive in two is the "one
/// implementation, never two" failure `CLAUDE.md` bans, and a rewrite is exactly when it gets
/// committed by accident.
///
/// Read comment-stripped, so the paragraph above — which names the flag five times — is not read as
/// the code it is warning against.
#[must_use]
pub fn the_static_mirror_stays_deleted(tree: &Tree) -> Report {
    check_all(tree, &[Claim::NoneUnder {
        roots: &["Sources", "Apps"],
        extensions: SWIFT,
        pattern: "staticMirror",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "`staticMirror` is back as CODE in {files} — it was a dead branch deleted before the \
                  AppKit canvas rewrite (docs/56 §3.5)",
    }])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The floor, the three ring sites and the three pill drawings, all agreeing.
    fn floor(fixture: &Fixture) {
        fixture
            .write(
                super::SLATE_DESIGN,
                "package static let accentRing = 0.5\npackage static let glyphPlate: CGFloat = 16\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/ViModeOverlayView.swift",
                "Slate.Opacity.accentRing\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/TerminalFindBarView.swift",
                "Slate.Opacity.accentRing\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift",
                "Slate.Opacity.accentRing\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/PaneMoveAffordance.swift",
                "Slate.GrabPill.width\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacPaneMoveAffordance.swift",
                "Slate.GrabPill.width\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacSatellitePaneContent.swift",
                "Slate.GrabPill.width\n",
            );
    }

    #[test]
    fn the_alpha_descends_and_the_pill_is_one_size() {
        let fixture = Fixture::new("ink-floor");
        floor(&fixture);
        assert!(super::a_frameworkless_value_goes_to_the_floor(&fixture.tree()).is_clean());

        // The literal back beside the token it replaced — the drift the mint was for.
        fixture.write(
            "Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift",
            "Slate.Opacity.accentRing\nring.withAlphaComponent(0.5)\n",
        );
        assert!(!super::a_frameworkless_value_goes_to_the_floor(&fixture.tree()).is_clean());

        // And a grab pill back on its own numbers, which a user feels inside one drag.
        floor(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Pane/MacPaneMoveAffordance.swift",
            "let width: CGFloat = 42\n",
        );
        assert!(!super::a_frameworkless_value_goes_to_the_floor(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_scene_injects_nothing_and_the_seam_stays_gone() {
        let fixture = Fixture::new("ink-scene");
        fixture.write(super::MAC_APP, "WindowGroup { MacWorkspaceRootView() }\n");
        assert!(super::the_mac_injects_no_environment_it_does_not_read(&fixture.tree()).is_clean());

        // Chained on one line, which is why the pattern is not line-anchored.
        fixture.write(
            super::MAC_APP,
            "root.environment(\\.foo).preferencesStore(store)\n",
        );
        assert!(!super::the_mac_injects_no_environment_it_does_not_read(&fixture.tree()).is_clean());

        // The deleted hosting seam, re-created while porting something adjacent.
        let fixture = Fixture::new("ink-seam");
        fixture
            .write(super::MAC_APP, "WindowGroup { MacWorkspaceRootView() }\n")
            .write(
                "Sources/SlopDeskPhoneUI/Pane/SatellitePaneContent.swift",
                "enum SatellitePaneHost {}\n",
            );
        assert!(!super::the_mac_injects_no_environment_it_does_not_read(&fixture.tree()).is_clean());
    }

    /// Enough files under either `Pane` target to clear the ink rule's vacuity floors.
    ///
    /// The floors exist so a DRAINED renderer target cannot let every `Resolved` row skip in
    /// silence, which is what `3f11c6e6` did to the phone half. Every fixture that asserts a row's
    /// own verdict has to clear them first, or it is asserting the floor instead.
    fn pane_fillers(fixture: &Fixture) {
        for index in 0..6 {
            fixture
                .write(
                    &format!("Sources/SlopDeskPhoneUI/Pane/Filler{index}.swift"),
                    "final class Filler: UIView {}\n",
                )
                .write(
                    &format!("Sources/SlopDeskMacUI/Pane/MacFiller{index}.swift"),
                    "final class MacFiller: NSView {}\n",
                );
        }
    }

    /// A drained renderer target is RED, not unanimously inked.
    ///
    /// The break-test for the demolition itself: delete the phone's pane drawings and every ink row
    /// skips its phone half, so without the floor the rule reads clean while checking one side.
    #[test]
    fn a_drained_renderer_target_fails_the_ink_rows_rather_than_skipping_them() {
        let fixture = Fixture::new("ink-drained");
        fixture
            .write(
                "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
                "package enum DropZoneInk {\n    case ok\n}\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacPaneDropOverlay.swift",
                "case .ok: break\n",
            );
        let report = super::a_named_ink_table_answers_every_renderer(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("Sources/SlopDeskPhoneUI/Pane"))
        );
    }

    #[test]
    fn a_renderer_that_drops_a_rung_is_red() {
        let fixture = Fixture::new("ink-tables");
        pane_fillers(&fixture);
        fixture
            .write(
                "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
                "package enum DropZoneInk {\n    case ok\n    case accent\n    case accentMuted\n}\npackage \
                 enum DropZoneLabelInk {\n    case primary\n}\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Pane/GuiPaneReadout.swift",
                "package enum GuiUploadTint {\n    case icon\n}\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Pane/FindBarPresentation.swift",
                "package enum FindTogglePillAppearance {\n    case idle\n}\n",
            )
            .write(
                super::PILL_INK_SRC,
                "package enum PaneStatusPillInk {\n    case security\n}\npackage enum PaneStatusPillFill \
                 {\n    case chrome\n    case fixed(PaneStatusPillInk)\n}\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlayView.swift",
                "case .ok: break\ncase .accent: break\ncase .accentMuted: break\ncase .primary: break\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacPaneDropOverlay.swift",
                "case .ok: break\ncase .accent: break\ncase .accentMuted: break\ncase .primary: break\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift",
                "case .icon: break\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacGuiPaneOverlays.swift",
                "case .icon: break\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/TerminalFindBarView.swift",
                "case .idle: break\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift",
                "case .idle: break\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/PaneStatusPillsView.swift",
                "case .chrome: break\ncase .fixed(let ink): break\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacPaneStatusPills.swift",
                "case .chrome: break\ncase .fixed(let ink): break\n",
            );
        assert!(super::a_named_ink_table_answers_every_renderer(&fixture.tree()).is_clean());

        // The `\b` hole: a half that resolves only the muted rung must NOT pass for `.accent`.
        fixture.write(
            "Sources/SlopDeskMacUI/Pane/MacPaneDropOverlay.swift",
            "case .ok: break\ncase .accentMuted: break\ncase .primary: break\n",
        );
        assert!(!super::a_named_ink_table_answers_every_renderer(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_enum_renamed_out_from_under_the_rule_is_red() {
        // The bounded anchor: an enum that is gone parses EMPTY, and an empty reading fails rather
        // than agreeing with everybody.
        let fixture = Fixture::new("ink-renamed");
        pane_fillers(&fixture);
        fixture
            .write(
                "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
                "package enum DropZoneInkRung {\n    case ok\n}\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlayView.swift",
                "case .ok: break\n",
            );
        assert!(!super::a_named_ink_table_answers_every_renderer(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_dead_mirror_never_reaches_the_rewrite() {
        let fixture = Fixture::new("ink-mirror");
        fixture.write(
            "Sources/SlopDeskPhoneUI/Pane/SplitCanvasView.swift",
            "// staticMirror was a dead branch\nlet body = content\n",
        );
        assert!(super::the_static_mirror_stays_deleted(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskPhoneUI/Pane/SplitCanvasView.swift",
            "let body = content(staticMirror: false)\n",
        );
        assert!(!super::the_static_mirror_stays_deleted(&fixture.tree()).is_clean());
    }
}
