//! The floor both device panels and the code panel stand on, and the platform gates that must not
//! come back onto it.
//!
//! Ported from the deleted `check-supervisor.sh`. Every rule here guards the same failure, which is
//! why they share a module: a `#if os(macOS)` wrapped around a whole file COMPILES on the phone —
//! to nothing. Forty-one empty files build green, so a gate is not a warning here, it is a parity
//! gap with a passing test suite over it.
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

const DEVICE_PANELS: &str = "Sources/SlopDeskDevicePanels";
const POOL: &str = "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarWebViewPool.swift";

/// The device-panel floor is platform-neutral
///
/// Every file in `SlopDeskDevicePanels` was once wrapped whole in `#if os(macOS)` — inherited from
/// the days the panels were a Mac-only surface, never from a Mac-only dependency. The module
/// imports `Foundation`, `CoreGraphics`, `CoreMedia` and `Network`; the phone has all four. The
/// gates cost nothing to add and hid the whole parity gap behind a green build.
///
/// So no platform gate goes back in. `SimulatorKeyMap` is the one that will tempt someone — its
/// table is keyed on macOS virtual key codes — and its answer is `AndroidKeyMap`'s: spell the
/// numbers, pin them against the SDK in a macOS-only TEST, and leave the shared floor buildable
/// everywhere.
#[must_use]
pub fn the_device_panel_floor_builds_for_the_phone(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &[DEVICE_PANELS],
            extensions: SWIFT,
            pattern: r"^#if.*os\(macOS\)",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "a platform gate is back in SlopDeskDevicePanels ({files}) — the panel floor is the \
                      phone's too",
        },
        Claim::NoneUnder {
            roots: &[DEVICE_PANELS],
            extensions: SWIFT,
            pattern: "import Carbon",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "SlopDeskDevicePanels imports Carbon ({files}) — that module does not exist on the iOS \
                      triple",
        },
    ];
    check_all(tree, &claims)
}

/// Both device panels draw on both platforms
///
/// The simulator and Android surfaces are the phone's too (`docs/56` stage D). Fifteen of their
/// seventeen files are plain `SwiftUI` and carry NO gate at all; the two that host a video stage
/// carry both halves in one file, `#if os(macOS)` … `#elseif os(iOS)`. A bare `#if os(macOS)` in
/// those directories is the old Mac-only shape coming back.
///
/// ONE VOCABULARY, TWO NUMBERINGS. A Mac reports a virtual key code and an iPad a USB HID usage;
/// the NAMES they resolve to, and every rule about what to do with them, are cut once — in
/// `slopdesk_devicepanel::panel_key`, which both panels reach through one door apiece. What this
/// used to check was that the two HID TABLES existed in Swift. They are gone: the numbering rides
/// as the door's `hid` flag, and the HID side is derived from the remote-desktop path's own usage →
/// keycode map rather than written a second time. So the check inverts — the tables must stay
/// DELETED (a reappearance would compile and pass its own tests) and the two ENTRY POINTS that
/// carry the iPad's numbering must stay reachable, because a port that quietly dropped the HID half
/// would leave an iPad keyboard typing nothing.
///
/// ## ⚠️ THE TWO STAGE PINS WERE RE-SPELLED 2026-08-28, AND THEY WERE ALREADY LYING
/// Both read `Claim::Names { needle: "UIViewRepresentable" }`. That premise died twice over. A
/// `UIKit` phone cannot write a representable AT ALL — the wrapper existed only to put a `UIView`
/// inside a `SwiftUI` tree, and after docs/62 there is no `SwiftUI` tree — so the pin could only go
/// red for the port succeeding. Worse, and this is the part that was true BEFORE the port:
/// [`Claim::Names`] reads the file RAW, and `PhoneSimulatorScreenView.swift:11` carries the word
/// "`UIViewRepresentable`" in its own prose. The claim was already satisfiable by a COMMENT, which
/// means it had stopped pinning the code some time ago and nothing said so (docs/62 §4.8 names both
/// halves of this).
///
/// The LAW survives the spelling, and it is the rule's own title: the device stage draws on the
/// phone. What makes that true in `UIKit` is that the stage IS a `UIView`, so the needle is `:
/// UIView` read as CODE — comment-proof, and red for the thing worth being red about. This is the
/// general lesson §4.8 draws: a rule that pins an ARRANGEMENT (which wrapper type hosts the view)
/// expires silently when its premise dies, where a rule that pins a BEHAVIOUR (the phone has a
/// drawable stage) survives the framework it was written against.
#[must_use]
pub fn both_device_panels_draw_on_both_platforms(tree: &Tree) -> Report {
    let claims = [
        Claim::NoFileUnder {
            roots: &[
                "Sources/SlopDeskPhoneUI/Panel/Simulator",
                "Sources/SlopDeskPhoneUI/Panel/Android",
            ],
            extensions: SWIFT,
            pattern: r"^#if os\(macOS\)",
            rescued_by: Some(r"^#elseif os\(iOS\)"),
            view: View::Raw,
            exempt: &[],
            message: "{files} is macOS-only again — both device panels draw on the phone too",
        },
        // RE-SPELLED 2026-08-28 — see the header's last paragraph for what these two used to say.
        Claim::Matches {
            path: "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorScreenView.swift",
            pattern: r": UIView\b",
            view: View::Statements,
            message: "PhoneSimulatorScreenView lost its UIKit half — the phone's device stage is a UIView, \
                      which is what makes the simulator mirror draw on the phone at all (docs/62 §4.8)",
        },
        Claim::Matches {
            path: "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidScreenView.swift",
            pattern: r": UIView\b",
            view: View::Statements,
            message: "PhoneAndroidScreenView lost its UIKit half — the phone's device stage is a UIView, \
                      which is what makes the Android mirror draw on the phone at all (docs/62 §4.8)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "byVirtualKey|byHIDUsage|functionalKeys|hidFunctionalKeys",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "a Swift key table is back ({files}) — panel_key.rs is the one table (docs/55 §8)",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorKeyMap.swift",
            needle: "code(hidUsage:",
            message: "SimulatorKeyMap lost its HID entry point — an iPad numbers its keys as HID usages",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidKeycode.swift",
            needle: "hidUsage: UInt16",
            message: "AndroidKeyMap lost its HID entry point — an iPad numbers its keys as HID usages",
        },
        Claim::Names {
            path: "rust/slopdesk-devicepanel/src/panel_key.rs",
            needle: "hid_virtual_key::virtual_key",
            message: "panel_key stopped deriving its HID side — that is how the two numberings cannot drift",
        },
        // The map panel_key derives FROM, and the gesture plan beside it, went the same way. Both are
        // faces now: a door call per answer and not one number of their own. The tables they lost were
        // `private`, so nothing outside would notice them growing back — a reader would see a
        // plausible Swift constant and no reason to doubt it. So the SHAPE is pinned instead of the
        // names: neither file may hold a collection literal or a numeric constant, because in a face
        // there is nothing for one to be.
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskVideoClient/HIDVirtualKeyMap.swift",
                "Sources/SlopDeskVideoClient/TouchPointerPlan.swift",
            ],
            pattern: r"static let [A-Za-z]+(: [A-Za-z<>:, ]+)? = [-0-9\[]",
            view: View::Code,
            message: "{files} grew a constant of its own — it is a face, and the numbers are Rust's \
                      (docs/55 §6)",
        },
        // Comments stripped first — the tables' docs NAME the UIKit type they exist to stay away from.
        Claim::NoneUnder {
            roots: &[DEVICE_PANELS],
            extensions: SWIFT,
            pattern: "UIKeyboardHIDUsage",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} names UIKeyboardHIDUsage — that is UIKit, and the floor is not",
        },
    ];
    check_all(tree, &claims)
}

/// The code panel crosses, and only its keyboard stays behind
///
/// `CodeSidebarWebView.swift` was a thousand lines of which the larger half was a first-responder
/// duel — a focused embedded VS Code and a focused terminal fighting over one `AppKit` window. That
/// duel has no iOS analogue at all (no app-level event monitor, no menu bar, no shared field
/// editor), and for as long as it sat in the same file as the pool, the whole code surface was
/// Mac-only.
///
/// Five files now, across THREE targets, and the split is the rule. Below both UI halves, in
/// `SlopDeskClientCore`: the DECISIONS in `CodeSidebarFocusPolicy` (pure, and the only place a
/// focus rule may be written), the POOL in `CodeSidebarWebViewPool` (projects and their warm
/// pages), and the PAGE in `CodeSidebarPage` (the mint, and the Mac's responder-seam subclass). The
/// MOUNT is per-half and always was. And one target up in `SlopDeskMacUI`: the keyboard DUEL in
/// `CodeSidebar/MacCodeSidebarKeyboard.swift`. `docs/56` increments 42, 43, 45 and 51 are the four
/// moves.
///
/// THE POOL CARRIES NO GATE AT ALL, which is stronger than the four whole-file bans and is the
/// point of increments 42–43. A gate reappearing there is not a gate problem; it is the signal that
/// whatever it guards belongs in the keyboard file or the page file instead, and a comment saying
/// so is not a pin.
#[must_use]
pub fn the_code_panel_crosses(tree: &Tree) -> Report {
    let claims = [
        // RE-SPELLED 2026-08-28, for the reason the sibling rule's header gives in full: the needle
        // was `UIViewRepresentable`, which a UIKit phone cannot write and which `Claim::Names` would
        // have accepted from a comment anyway. What the phone's code mount must be is a WEB VIEW —
        // the panel mounting on both platforms is the law, and `WKWebView` is how the phone keeps it
        // (docs/56, docs/62 §4.8).
        //
        // RE-AIMED the same day, and RE-SPELLED again in the same edit — the second half matters more
        // than the first. The wrapper this claim watched — `CodeSidebar/CodeSidebarWebView.swift`, a
        // `UIViewRepresentable` — was DELETED by the UIKit port (commit `3f11c6e6`), so the claim was
        // pointing at nothing; `Claim::Matches` on a missing file is red, so the row did report, but it
        // reported the wrong fact.
        //
        // Moving the path alone would have left the row red anyway, and TRUTHFULLY: the mount
        // (`Panel/PhoneCodeWorkbenchView.swift`) never writes `WKWebView` in code at all. It cannot —
        // the pooled page is minted ONCE, in `SlopDeskClientCore`, and the mount only re-parents it
        // (docs/56 increment 45). `WKWebView` as the needle was a fact about the deleted wrapper, which
        // did mint its own. What the phone's mount must keep doing is ASK THE POOL, so that is what is
        // pinned: the same needle the Mac half is held to, one file up.
        Claim::Matches {
            path: "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
            pattern: r"CodeSidebarWebViewPool\.shared\.webView\(",
            view: View::Statements,
            message: "the phone's code mount stopped taking its page from the pool — the code panel mounts \
                      on both platforms, off ONE warm page each (docs/56 increment 45, docs/62 §4.8)",
        },
        Claim::Names {
            path: "Sources/SlopDeskMacUI/Panel/MacCodeWorkbenchView.swift",
            needle: "noteRemount",
            message: "MacCodeWorkbenchView lost noteRemount — the code panel mounts on both platforms \
                      (docs/56)",
        },
        Claim::Names {
            path: POOL,
            needle: "func noteRemount",
            message: "the code-page pool lost noteRemount — the code panel mounts on both platforms \
                      (docs/56)",
        },
        // The webview SUBCLASS is the responder seam and nothing else, so it exists only where a
        // responder duel does. The phone mints a plain `WKWebView`; the name reached from anywhere but
        // the file that owns it is that seam leaking back out. Comments stripped first: the seam is
        // DOC-linked from the policy and the pure state it drives, and a doc link is exactly the
        // reference that is allowed to cross.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "CodeSidebarWKWebView",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPage.swift"],
            message: "{files} names CodeSidebarWKWebView — it is the Mac's responder seam, not an API",
        },
        // A gate INSIDE one of these four is fine. What is banned is the wrapper that makes the file
        // compile to nothing on the phone, and that shape is exactly "the first line of code is
        // `#if os(macOS)`".
        // RE-AIMED 2026-08-28 with the row above: the phone's surfaces file moved out of `CodeSidebar/`
        // and became `Panel/PhonePanelSurfacesViewController.swift` — a controller, since the UIKit port
        // gave the surfaces a mount lifetime rather than a `body`.
        Claim::Opening {
            path: "Sources/SlopDeskPhoneUI/Panel/PhonePanelSurfacesViewController.swift",
            forbidden: &["#if os(macOS)"],
            message: "the phone's panel surfaces are wrapped in a macOS gate again — the code panel is the \
                      phone's too",
        },
        Claim::Opening {
            path: POOL,
            forbidden: &["#if os(macOS)"],
            message: "CodeSidebarWebViewPool.swift is wrapped in a macOS gate again — the code panel is the \
                      phone's too",
        },
        Claim::Opening {
            path: "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarProxy.swift",
            forbidden: &["#if os(macOS)"],
            message: "CodeSidebarProxy.swift is wrapped in a macOS gate again — Network is Network",
        },
        Claim::Opening {
            path: "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarFontSchemeHandler.swift",
            forbidden: &["#if os(macOS)"],
            message: "CodeSidebarFontSchemeHandler.swift is wrapped in a macOS gate again — WebKit is WebKit",
        },
        Claim::Lacks {
            path: POOL,
            pattern: r"^\s*#if os\(",
            view: View::Raw,
            message: "the code-page pool grew a platform gate — it manages pages, it does not draw them",
        },
        // AND THE POOL IS BELOW BOTH UI HALVES, which is what the gate removal bought (increment 45).
        // It is a RESOURCE manager, not a view, and `SlopDeskMacUI` reaching it through the phone half
        // was the import stage D deleted.
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/CodeSidebar/CodeSidebarWebViewPool.swift",
            message: "the code-page pool climbed back into the UI target — it manages pages, it does not \
                      draw them",
        },
        // A focus RULE lives in the policy, which is pure and testable; the seam only calls it. The
        // three spellings below are the ones that were inline before the split and would be inline
        // again first.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI"],
            extensions: SWIFT,
            pattern: "func shouldAcceptFocus|func isReservedAppChord|func evictionVictim",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a code-panel focus rule grew back outside CodeSidebarFocusPolicy ({files}) — it is \
                      pure on purpose",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    #[test]
    fn the_shared_floor_stays_buildable_on_the_phone() {
        let fixture = Fixture::new("floor-device-panels");
        fixture.write(
            "Sources/SlopDeskDevicePanels/Shared/DeviceLogLine.swift",
            "import Foundation\n",
        );
        assert!(super::the_device_panel_floor_builds_for_the_phone(&fixture.tree()).is_clean());

        // The wrapper that compiles forty-one files to nothing.
        fixture.append(
            "Sources/SlopDeskDevicePanels/Shared/DeviceLogLine.swift",
            "#if os(macOS)\n",
        );
        assert!(!super::the_device_panel_floor_builds_for_the_phone(&fixture.tree()).is_clean());

        // And a module the iOS triple has never heard of.
        fixture.write(
            "Sources/SlopDeskDevicePanels/Shared/DeviceLogLine.swift",
            "import Carbon\n",
        );
        assert!(!super::the_device_panel_floor_builds_for_the_phone(&fixture.tree()).is_clean());
    }

    fn panels(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorScreenView.swift",
                "#if os(macOS)\nfinal class Stage: NSView {}\n#elseif os(iOS)\nfinal class Stage: UIView \
                 {}\n#endif\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidScreenView.swift",
                "#if os(macOS)\nfinal class Stage: NSView {}\n#elseif os(iOS)\nfinal class Stage: UIView \
                 {}\n#endif\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorKeyMap.swift",
                "code(hidUsage: usage)\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidKeycode.swift",
                "hidUsage: UInt16\n",
            )
            .write(
                "rust/slopdesk-devicepanel/src/panel_key.rs",
                "hid_virtual_key::virtual_key(usage)\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/HIDVirtualKeyMap.swift",
                "slopdesk_panel_key\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/TouchPointerPlan.swift",
                "slopdesk_touch_plan\n",
            );
    }

    #[test]
    fn a_device_stage_keeps_both_halves_and_the_tables_stay_deleted() {
        let fixture = Fixture::new("floor-both-panels");
        panels(&fixture);
        assert!(super::both_device_panels_draw_on_both_platforms(&fixture.tree()).is_clean());

        // The one shape a line-wise ban cannot see: a gate PRESENT and its phone half ABSENT.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidScreenView.swift",
            "#if os(macOS)\nfinal class Stage: NSView {}\nfinal class Stage: UIView {}\n#endif\n",
        );
        assert!(!super::both_device_panels_draw_on_both_platforms(&fixture.tree()).is_clean());

        // A Swift key table, back.
        panels(&fixture);
        fixture.write(
            "Sources/SlopDeskDevicePanels/Simulator/Table.swift",
            "let byHIDUsage: [UInt16: Key] = [:]\n",
        );
        assert!(!super::both_device_panels_draw_on_both_platforms(&fixture.tree()).is_clean());

        // A face growing a number of its own.
        panels(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/TouchPointerPlan.swift",
            "static let slop: Double = 4\n",
        );
        assert!(!super::both_device_panels_draw_on_both_platforms(&fixture.tree()).is_clean());
    }

    fn code_panel(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
                "final class PhoneCodeWorkbenchView: UIView {\n    let web = \
                 CodeSidebarWebViewPool.shared.webView(for: root, url: url)\n}\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Panel/MacCodeWorkbenchView.swift",
                "pool.noteRemount(project)\n",
            )
            .write(super::POOL, "func noteRemount(_ project: Project) {}\n")
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhonePanelSurfacesViewController.swift",
                "// a header\nimport UIKit\n",
            )
            .write(
                "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarProxy.swift",
                "import Network\n",
            )
            .write(
                "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarFontSchemeHandler.swift",
                "import WebKit\n",
            )
            .write(
                "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPage.swift",
                "final class CodeSidebarWKWebView: WKWebView {}\n",
            );
    }

    #[test]
    fn the_pool_carries_no_gate_and_the_seam_does_not_leak() {
        let fixture = Fixture::new("floor-code-panel");
        code_panel(&fixture);
        assert!(super::the_code_panel_crosses(&fixture.tree()).is_clean());

        // A gate as the OPENING line — the wrapper. A gate further in is ordinary code.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/PhonePanelSurfacesViewController.swift",
            "// a header\n#if os(macOS)\nimport AppKit\n#endif\n",
        );
        assert!(!super::the_code_panel_crosses(&fixture.tree()).is_clean());

        code_panel(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/PhonePanelSurfacesViewController.swift",
            "import UIKit\n#if os(macOS)\nimport AppKit\n#endif\n",
        );
        assert!(super::the_code_panel_crosses(&fixture.tree()).is_clean());

        // The pool is stricter: no gate ANYWHERE in it.
        code_panel(&fixture);
        fixture.append(super::POOL, "#if os(macOS)\nimport AppKit\n#endif\n");
        assert!(!super::the_code_panel_crosses(&fixture.tree()).is_clean());

        // The seam named outside the file that owns it — a doc link still may.
        code_panel(&fixture);
        fixture.write(
            "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarFocusPolicy.swift",
            "/// See ``CodeSidebarWKWebView``.\n",
        );
        assert!(super::the_code_panel_crosses(&fixture.tree()).is_clean());
        fixture.append(
            "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarFocusPolicy.swift",
            "let view = CodeSidebarWKWebView()\n",
        );
        assert!(!super::the_code_panel_crosses(&fixture.tree()).is_clean());

        // And a focus rule inline in the phone's half.
        code_panel(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Pane/Focus.swift",
            "func shouldAcceptFocus() -> Bool { true }\n",
        );
        assert!(!super::the_code_panel_crosses(&fixture.tree()).is_clean());
    }
}
