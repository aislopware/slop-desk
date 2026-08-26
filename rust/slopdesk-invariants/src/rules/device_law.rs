//! One device-panel law, one chrome, one pasteboard, one open — and the four small rules that were
//! each measured once and written down twice.
//!
//! Ported from the deleted `check-supervisor.sh`. The simulator panel and the Android panel differ
//! in almost everything and should — one rotates on the client and the other on the device, one
//! sends touches in the fitted rect's space and the other in the video's own pixel grid, because
//! `scrcpy` DROPS a mismatched pair. What they never differed in is the ARITHMETIC, and every rule
//! here says so about one piece of it.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The two panel targets a shared law could be respelled in, and the one directory that holds it.
const PANEL_ROOTS: &[&str] = &["Sources/SlopDeskPhoneUI", "Sources/SlopDeskDevicePanels"];
const PANEL_SHARED: &str = "Sources/SlopDeskDevicePanels/Shared/";
const GEOMETRY: &str = "Sources/SlopDeskDevicePanels/Shared/DevicePanelGeometry.swift";
/// Every target that draws a device list: the shared panel code and the two renderers over it.
const SECTION_ROOTS: &[&str] = &[
    "Sources/SlopDeskDevicePanels",
    "Sources/SlopDeskPhoneUI",
    "Sources/SlopDeskMacUI",
];
const ANDROID_SECTIONS: &str = "Sources/SlopDeskDevicePanels/Android/AndroidDeviceSections.swift";
const SIMULATOR_SECTIONS: &str = "Sources/SlopDeskDevicePanels/Simulator/SimulatorDeviceSections.swift";

/// One device-panel law, two device protocols
///
/// The aspect fit, the click mapping, the pinch pair, the safe-area margin and the regrip live in
/// `DevicePanelGeometry`, and the `CoreMedia` wrap in `DevicePanelSampleBuffer`; only
/// `formatDescription` is genuinely per-panel (avcC record vs Annex-B). The law itself is Rust now:
/// the Swift side calls one door, and that door's crate reaches `displayed_video_rect` rather than
/// fitting a frame again.
///
/// ## The clamp, which is why the ban and the four callers are both here
/// `clampedDevicePoint` asks `slopdesk_panel_clamped_device_point`, which clamps to the LAST
/// ADDRESSABLE POINT inside the fitted rect. The Android views have gone through it since it
/// existed. Both simulator views spelled the clamp themselves, and both copies clamped to the
/// fitted rect's SIZE instead — one point past the end on each axis. A drag to the right edge of a
/// 200-point frame reported `x = 200` into a surface whose columns are `0..<200`, and the host
/// scales that straight off the far side of the framebuffer. Confirmed by PROBE before anything was
/// touched: same point, same rect `CGRect(x: 50, y: 20, width: 200, height: 400)`, hand-rolled
/// Swift answered `(200.0, 400.0)` and the shared rule answered `(199, 399)`.
///
/// A ban alone would be satisfied by a view that stopped clamping altogether, which is the other
/// half of the same bug: a drag leaving the frame would be dropped, and the gesture would freeze at
/// the boundary with the button still held. So the four callers are asserted too.
///
/// `Shared/` is an EXEMPTION on the corpus rather than a comparison after the fact, and that is the
/// whole difference between this gate working and not. The shell's `spells` returned the FIRST file
/// it matched and stopped, so a rule written as `if [[ "${hit}" != ".../Shared/…" ]]` went silent
/// for the entire corpus the moment the exempt file happened to be the first hit.
///
/// What the panels DRAW is the same argument: the empty stage, its caption, the empty-list notice
/// and the loading-veil asymmetry are one design decision each, recorded in the singular in
/// `docs/DECISIONS.md` and written down twice. The measured veil DELAYS stay per panel (400 ms vs
/// 600 ms, two pieces of hardware). Checked positively, because the veil and the notice are
/// ordinary `SwiftUI` whose ingredients are used everywhere else.
#[must_use]
pub fn one_device_panel_law(tree: &Tree) -> Report {
    /// A file that must still ask a shared law for its answer.
    const CALLERS: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift",
            "SimulatorScreenLayout.clampedDevicePoint",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift",
            "SimulatorScreenLayout.clampedDevicePoint",
        ),
        (
            "Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift",
            "AndroidScreenLayout.clampedDevicePoint",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift",
            "AndroidScreenLayout.clampedDevicePoint",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Android/AndroidStageView.swift",
            "DevicePanelChrome.veil",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorStageView.swift",
            "DevicePanelChrome.veil",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Android/AndroidDeviceList.swift",
            "DevicePanelChrome.notice",
        ),
        (
            "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift",
            "DevicePanelChrome.notice",
        ),
        (
            "Sources/SlopDeskDevicePanels/Android/AndroidVideoFormat.swift",
            "DevicePanelSampleBuffer.dimensions",
        ),
        (
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorVideoFormat.swift",
            "DevicePanelSampleBuffer.dimensions",
        ),
    ];

    let mut report = Report::new();
    for (caller, law) in CALLERS {
        Claim::Names {
            path: caller,
            needle: law,
            // The sentence names the path itself, since a table cannot carry a placeholder the claim
            // does not fill.
            message: "a device panel stopped calling a shared law — the two panels agree by sharing, not by \
                      luck",
        }
        .check(tree, &mut report);
    }

    let claims = [
        Claim::NoneUnder {
            roots: PANEL_ROOTS,
            extensions: SWIFT,
            pattern: r"bounds.width / contentSize.width|CMBlockBufferCreateWithMemoryBlock|2\.0\.squareRoot",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[PANEL_SHARED],
            message: "{files} grew a device-panel law back outside Sources/SlopDeskDevicePanels/Shared — it \
                      is shared",
        },
        Claim::Names {
            path: GEOMETRY,
            needle: "slopdesk_panel_fitted_rect",
            message: "the device panels stopped calling slopdesk_panel_fitted_rect — a click lands where it \
                      is drawn",
        },
        Claim::Names {
            path: "rust/slopdesk-devicepanel/src/geometry.rs",
            needle: "displayed_video_rect",
            message: "slopdesk-devicepanel stopped using geometry::displayed_video_rect — a click lands \
                      where it is drawn",
        },
        // With a vacuity floor: a renamed target would drain the corpus and this gate would report a
        // clean tree while reading nothing.
        Claim::Populated {
            roots: PANEL_ROOTS,
            extensions: SWIFT,
            minimum: 20,
            message: "the device-panel corpus read as {found} files — the hand-rolled clamp ban is passing \
                      vacuously",
        },
        // The ban is on the frame-relative subtraction INSIDE a clamp, which is the whole shape and is
        // specific enough not to catch the pinch-spread clamp two files over.
        Claim::NoneUnder {
            roots: PANEL_ROOTS,
            extensions: SWIFT,
            pattern: r"max\((point|location)\.[xy] *- *fitted\.min[XY]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[PANEL_SHARED],
            message: "{files} clamps a dragged point to the fitted rect by hand again — the shared rule \
                      clamps to the last ADDRESSABLE point, one less on each axis",
        },
    ];
    report.absorb(check_all(tree, &claims));
    report
}

/// One writer to the client pasteboard, and one fork for a system open
///
/// Two things ride on `ClientPasteboard` and neither is visible at a call site: the board is a
/// per-PROCESS named one under `XCTest` (a copy test that reached `.general` would clobber the
/// developer's own clipboard), and on `AppKit` the `clearContents` before a `setString` is
/// load-bearing — `NSPasteboard` accumulates types within a declaration, so a write without it
/// appends to whatever the last writer declared. The PLATFORM fork is inside the funnel too; it was
/// written out at four call sites before it was written once.
///
/// The clipboard SYNC engines are not in scope: they write an INJECTED board (a named one in
/// tests), which is why they take a `pasteboard` parameter at all.
///
/// The two device panels' capture write is that same funnel, not a third `writeObjects` pair. It is
/// `writeImage`, which answers a `Bool` rather than the decoded image — that return type is what
/// lets a panel MODEL say "copy this frame" without naming a platform image type, and is why the
/// two models could leave the view target at all (`docs/56`).
///
/// The system-open fork has the same one home, on the CLIENT. The host's `HostPathActionPerformer`
/// is deliberately out of scope: it READS the return of `NSWorkspace.open` to answer `.ok`/`.error`
/// over the wire, it never has a `UIKit` arm to fork on, and its target cannot see the phone half.
/// Same call, different law — which is why the ban's corpus is the phone half alone.
#[must_use]
pub fn one_pasteboard_and_one_open(tree: &Tree) -> Report {
    const PASTEBOARD: &str = "Sources/SlopDeskWorkspaceCore/Terminal/ClientPasteboard.swift";

    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "NSPasteboard.general.clearContents|UIPasteboard.general.string = ",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[PASTEBOARD],
            message: "{files} is a second client pasteboard write — ClientPasteboard.write is the only one",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift",
            needle: "ClientPasteboard.writeImage(",
            message: "the Android panel model stopped calling ClientPasteboard.writeImage — the capture \
                      write is one funnel",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift",
            needle: "ClientPasteboard.writeImage(",
            message: "the simulator panel model stopped calling ClientPasteboard.writeImage — the capture \
                      write is one funnel",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI"],
            extensions: SWIFT,
            pattern: r"NSWorkspace.shared.open\(url\)|UIApplication.shared.open\(url\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} is a second URL-open fork — ExternalOpen.url owns the platform branch",
        },
    ];
    check_all(tree, &claims)
}

/// The small rules that were spelled twice
///
/// Each of these is one law with two call sites, and each had two spellings until it did not.
///
/// `autoReplyPing` is the one worth naming: setting it on an INSERTED options object is inert — the
/// stack stores a copy that reads the flag back as its default — so a lane without an explicit pong
/// is dropped on the server's idle timer minutes in. That was measured once and written down twice,
/// and there is no error anywhere in the failure.
///
/// `VideoDecoder.stampDisplayImmediately` is deliberately NOT one of these: it is a different
/// target with a lower dependency floor (`SlopDeskVideoProtocol` carries no media framework on
/// purpose) and a different reason — Parsec-parity present-on-decode before a VT submit, not
/// marking a panel's sample for an `AVSampleBufferDisplayLayer`. Sharing it would widen a leaf's
/// purpose for three lines of `CoreFoundation`.
///
/// One discriminant-to-enum mapping per enum: `docs/55` §6 makes the case list a contract, and a
/// `SLOPDESK_MODE_EVENT_*` added to one reader and not the other is that contract silently
/// splitting.
#[must_use]
pub fn the_small_rules_are_spelled_once(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "autoReplyPing = true",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} sets autoReplyPing on an inserted options object, where it is INERT — \
                      SimulatorWebSocketLane sends the pong",
        },
        Claim::NoneUnder {
            roots: &[
                "Sources/SlopDeskPhoneUI",
                "Sources/SlopDeskDevicePanels",
                "Sources/SlopDeskHost",
                "Sources/SlopDeskWorkspaceCore",
                "Sources/SlopDeskProtocol",
            ],
            extensions: SWIFT,
            pattern: r#"obj\["method"\] as\? String|kCMSampleAttachmentKey_DisplayImmediately"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/SlopDeskProtocol/ControlLine.swift", PANEL_SHARED],
            message: "{files} grew an NDJSON control-line or CoreMedia rule back — ControlLine / \
                      DevicePanelSampleBuffer own them",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/SlopDeskClaudeCode/TerminalMode.swift"],
            message: "{files} is a second TerminalModeEvent mapping — it belongs on the enum",
        },
    ];
    check_all(tree, &claims)
}

/// ONE SECTIONING for both device lists, and one spelling of the version it lifts.
///
/// The running group first and not cut by family, the families after it in rank order, the fact a
/// whole group agrees on lifted into its heading, the row identity qualified by that heading: one
/// machine, and it was written twice — `AndroidDeviceSections` lifting a platform version,
/// `SimulatorDeviceSections` lifting a runtime, otherwise the same file with different nouns. Each
/// panel is drawn by TWO renderers, so a drift there would not have been a bug in one list, it
/// would have been four surfaces disagreeing about what a heading means.
///
/// `slopdesk_devicepanel::sections` holds it now, through one door per panel. The bans are on the
/// four shapes the Swift had, because each is a rule that a re-derivation gets subtly wrong while
/// looking perfectly reasonable:
///
/// * the family grouping — `Dictionary(grouping:)` then a sort by rank, which is where a stable
///   partition quietly becomes an unstable one and the host's own ordering is lost;
/// * the lifting — an ABSENT value must count as a disagreement, never as a shared one;
/// * the version label — `Android 16` vs `API 36`, which the heading compares and the row prints,
///   so two spellings mean a header stating a version the grouping never compared;
/// * the row identity — `heading/key`, the value the reflow watches, which is what makes a boot
///   animate as a move instead of a delete and an insert.
#[must_use]
pub fn one_sectioning_for_both_panels(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: ANDROID_SECTIONS,
            entries: &["slopdesk_android_sections", "slopdesk_android_version_label"],
            message: "Sources/SlopDeskDevicePanels/Android/AndroidDeviceSections.swift no longer calls \
                      {entry} — the grouping and the version it lifts are slopdesk_devicepanel::sections",
        },
        Claim::Doors {
            path: SIMULATOR_SECTIONS,
            entries: &["slopdesk_simulator_sections"],
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorDeviceSections.swift no longer calls \
                      {entry} — both panels section their list through one crate, or they are two products",
        },
        Claim::NoneUnder {
            roots: SECTION_ROOTS,
            extensions: SWIFT,
            pattern: r"Dictionary\(grouping:|func shared(Runtime|Version)\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a device list is grouped or has a fact lifted in {files} — the ordering, the family \
                      cut and the shared-value rule are slopdesk_devicepanel::sections, which is the one \
                      place an ABSENT value counts as a disagreement",
        },
        Claim::NoneUnder {
            roots: SECTION_ROOTS,
            extensions: SWIFT,
            pattern: r#""Android " ?\+|"Android \\\(|"API \\\("#,
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "an Android version label is spelled in {files} — the heading compares what the row \
                      prints, so both read slopdesk_android_version_label",
        },
        Claim::NoneUnder {
            roots: SECTION_ROOTS,
            extensions: SWIFT,
            pattern: r#""\\\(title\)/\\\("#,
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "a row identity is assembled in {files} — it comes back from the sectioning door, \
                      qualified by the heading the door itself chose",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn panels(fixture: &Fixture) -> &Fixture {
        for (path, law) in [
            (
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift",
                "SimulatorScreenLayout.clampedDevicePoint",
            ),
            (
                "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift",
                "SimulatorScreenLayout.clampedDevicePoint",
            ),
            (
                "Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift",
                "AndroidScreenLayout.clampedDevicePoint",
            ),
            (
                "Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift",
                "AndroidScreenLayout.clampedDevicePoint",
            ),
            (
                "Sources/SlopDeskPhoneUI/Panel/Android/AndroidStageView.swift",
                "DevicePanelChrome.veil",
            ),
            (
                "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorStageView.swift",
                "DevicePanelChrome.veil",
            ),
            (
                "Sources/SlopDeskPhoneUI/Panel/Android/AndroidDeviceList.swift",
                "DevicePanelChrome.notice",
            ),
            (
                "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift",
                "DevicePanelChrome.notice",
            ),
            (
                "Sources/SlopDeskDevicePanels/Android/AndroidVideoFormat.swift",
                "DevicePanelSampleBuffer.dimensions",
            ),
            (
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorVideoFormat.swift",
                "DevicePanelSampleBuffer.dimensions",
            ),
        ] {
            fixture.write(path, &format!("{law}(point, in: fitted)\n"));
        }
        // Past the vacuity floor, which the ten above do not reach on their own.
        for index in 0..12 {
            fixture.write(
                &format!("Sources/SlopDeskPhoneUI/Panel/Filler{index}.swift"),
                "struct Filler: View {}\n",
            );
        }
        fixture
            .write(super::GEOMETRY, "slopdesk_panel_fitted_rect(w, h, cw, ch)\n")
            .write(
                "rust/slopdesk-devicepanel/src/geometry.rs",
                "pub fn fitted() { displayed_video_rect(…) }\n",
            )
    }

    #[test]
    fn the_clamp_lives_in_one_place_and_every_view_asks_for_it() {
        let fixture = Fixture::new("device-law");
        panels(&fixture);
        assert!(super::one_device_panel_law(&fixture.tree()).is_clean());

        // The live bug this was written for: a hand-rolled clamp, one point past the end.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift",
            "SimulatorScreenLayout.clampedDevicePoint(p)\nlet x = max(point.x - fitted.minX, 0)\n",
        );
        assert!(!super::one_device_panel_law(&fixture.tree()).is_clean());

        // `Shared/` holds the one legal caller and is exempt by CORPUS, not by comparison.
        panels(&fixture);
        fixture.write(
            super::GEOMETRY,
            "slopdesk_panel_fitted_rect(w, h, cw, ch)\nlet x = max(point.x - fitted.minX, 0)\n",
        );
        assert!(super::one_device_panel_law(&fixture.tree()).is_clean());

        // The other half of the same bug: a view that stopped clamping at all.
        panels(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift",
            "send(point)\n",
        );
        assert!(!super::one_device_panel_law(&fixture.tree()).is_clean());
    }

    /// A drained corpus is the shell's own recurring failure: a ban over no files passes.
    #[test]
    fn a_drained_panel_corpus_fails_rather_than_passing() {
        let fixture = Fixture::new("device-law-drained");
        fixture
            .write(super::GEOMETRY, "slopdesk_panel_fitted_rect(w, h, cw, ch)\n")
            .write(
                "rust/slopdesk-devicepanel/src/geometry.rs",
                "pub fn fitted() { displayed_video_rect(…) }\n",
            );
        assert!(!super::one_device_panel_law(&fixture.tree()).is_clean());
    }

    fn funnels(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/ClientPasteboard.swift",
                "NSPasteboard.general.clearContents()\nUIPasteboard.general.string = text\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift",
                "ClientPasteboard.writeImage(frame)\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift",
                "ClientPasteboard.writeImage(frame)\n",
            )
    }

    #[test]
    fn one_funnel_writes_the_board_and_one_forks_the_open() {
        let fixture = Fixture::new("device-funnels");
        funnels(&fixture);
        assert!(super::one_pasteboard_and_one_open(&fixture.tree()).is_clean());

        // A copy path that reaches `.general` clobbers the developer's own clipboard under XCTest.
        fixture.write(
            "Sources/SlopDeskMacUI/Terminal/MacCopy.swift",
            "NSPasteboard.general.clearContents()\n",
        );
        assert!(!super::one_pasteboard_and_one_open(&fixture.tree()).is_clean());

        // A second platform fork for a URL open.
        funnels(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/OpenLink.swift",
            "UIApplication.shared.open(url)\n",
        );
        assert!(!super::one_pasteboard_and_one_open(&fixture.tree()).is_clean());
    }

    /// The four ways one list starts sectioning itself differently from the other: it regroups, it
    /// lifts a fact by its own rule, it respells the version a heading compares, or it assembles
    /// the identity the reflow watches. All four looked perfectly reasonable in the Swift they
    /// came out of, and none of them would fail a test written against the panel that still
    /// agreed with itself.
    #[test]
    fn a_second_sectioning_of_a_device_list_is_caught() {
        let fixture = Fixture::new("device-sections");
        let android = "\
slopdesk_android_sections(families, count, transports, count, levels, count, out, cap)
slopdesk_android_version_label(bytes, len, release != nil, level, apiLevel != nil, out, cap)
";
        let simulator = "slopdesk_simulator_sections(families, count, running, count, out, cap)\n";
        fixture
            .write(super::ANDROID_SECTIONS, android)
            .write(super::SIMULATOR_SECTIONS, simulator);
        assert!(super::one_sectioning_for_both_panels(&fixture.tree()).is_clean());

        // A door dropped: one panel went back to deciding its own groups.
        fixture.write(
            super::SIMULATOR_SECTIONS,
            "// sections(for:) folds the list itself again\n",
        );
        let report = super::one_sectioning_for_both_panels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_simulator_sections")),
            "{report:?}"
        );

        // The grouping and the lifting, back beside a view that then owns its own reading of them.
        fixture.write(super::SIMULATOR_SECTIONS, simulator).write(
            "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift",
            "let families = Dictionary(grouping: devices) { $0.kind }\n",
        );
        let report = super::one_sectioning_for_both_panels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("grouped or has a fact lifted")),
            "{report:?}"
        );

        // The version label respelled where a header prints it — the heading would then compare a
        // string nothing else builds.
        let fixture = Fixture::new("device-sections-label");
        fixture
            .write(super::ANDROID_SECTIONS, android)
            .write(super::SIMULATOR_SECTIONS, simulator)
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidDeviceHeader.swift",
                "let caption = \"Android \" + release\n",
            );
        let report = super::one_sectioning_for_both_panels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("version label is spelled")),
            "{report:?}"
        );

        // And the row identity, assembled by a list that then animates on its own name for a row.
        let fixture = Fixture::new("device-sections-identity");
        fixture
            .write(super::ANDROID_SECTIONS, android)
            .write(super::SIMULATOR_SECTIONS, simulator)
            .write(
                "Sources/SlopDeskMacUI/Panel/Android/MacAndroidDeviceList.swift",
                "let ids = devices.map { \"\\(title)/\\($0.key)\" }\n",
            );
        let report = super::one_sectioning_for_both_panels(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("row identity is assembled")),
            "{report:?}"
        );
    }

    #[test]
    fn the_small_rules_keep_their_one_spelling() {
        let fixture = Fixture::new("device-smalls");
        fixture.write(
            "Sources/SlopDeskProtocol/ControlLine.swift",
            "guard let method = obj[\"method\"] as? String else { return nil }\n",
        );
        assert!(super::the_small_rules_are_spelled_once(&fixture.tree()).is_clean());

        // The inert flag, set minutes before the lane is dropped on an idle timer.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorLane.swift",
            "options.autoReplyPing = true\n",
        );
        assert!(!super::the_small_rules_are_spelled_once(&fixture.tree()).is_clean());

        // A second NDJSON reader outside ControlLine.
        let fixture = Fixture::new("device-smalls-ndjson");
        fixture
            .write(
                "Sources/SlopDeskProtocol/ControlLine.swift",
                "guard let method = obj[\"method\"] as? String else { return nil }\n",
            )
            .write(
                "Sources/SlopDeskHost/Panel/HostLane.swift",
                "let method = obj[\"method\"] as? String\n",
            );
        assert!(!super::the_small_rules_are_spelled_once(&fixture.tree()).is_clean());

        // And a second mode-event mapping, which is the case-list contract splitting in silence.
        let fixture = Fixture::new("device-smalls-modes");
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/ModeReader.swift",
            "case SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN: return .enteredAltScreen\n",
        );
        assert!(!super::the_small_rules_are_spelled_once(&fixture.tree()).is_clean());
    }
}
