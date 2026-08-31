//! What a terminal pane owns that is not a drawing: the callback wiring, the ⎋ event tap and the
//! phone's key path.
//!
//! Ported from the deleted `check-supervisor.sh`. Each of these was a resource with a PAIR — wire
//! and clear, install and remove, press and release — living inside a `View` body or an
//! `NSViewRepresentable`'s coordinator, where the pairing was invisible and the `AppKit` rewrite
//! would have had to reproduce it from scratch. They descended whole; what is left in a renderer is
//! two calls.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const WIRING: &str = "Sources/SlopDeskClientCore/Pane/TerminalPaneWiring.swift";
/// The leaf's lifecycle, one floor below both shells — and the one caller of the wiring above.
const LIFECYCLE: &str = "Sources/SlopDeskClientCore/Pane/TerminalLeafLifecycle.swift";
const ESCAPE_MONITOR: &str = "Sources/SlopDeskClientCore/Input/PaneMoveEscapeMonitorController.swift";
/// The phone terminal pane's responder.
///
/// ⚠️ RE-AIMED 2026-08-28, and this one was NOT a rename. `TerminalInputHost.swift` is deleted
/// outright — docs/62 §2.4 rules the `UIViewRepresentable` out and says the `UIResponder` "becomes
/// the pane controller's own input surface", which it now is: `TerminalInputHostView: UIView,
/// UIKeyInput` lives at `TerminalLeafView.swift:1099`, in the leaf it always served. The TYPE
/// survives under its old name and the FILE does not, so the messages below still name
/// `TerminalInputHost` where they mean the responder, and the file where they mean the file.
const PHONE_HOST: &str = "Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift";
const PHONE_KEY: &str = "Sources/SlopDeskWorkspaceCore/iOS/PhoneKey.swift";

/// One terminal wiring, and its teardown order is part of it
///
/// A terminal leaf's callbacks are five wire/clear PAIRS, and every one of them is a retain-cycle
/// obligation rather than a layout: nil the closure or the dead leaf keeps driving a live model.
/// They were a 555-line `View` body, which meant the `AppKit` rewrite would have had to copy them —
/// so they descended whole, and what is left in the leaf is two calls.
///
/// THE TEARDOWN ORDER is the one thing here that is not obvious from reading either half.
/// `clearSecureInput` releases the PROCESS-GLOBAL `EnableSecureEventInput` FIRST and only then
/// reaches for the model. Behind the guard it would be skipped for exactly the pane that needs it
/// most — one whose model has already gone — and the lock would outlive the app's own window,
/// taking the keyboard out of every other app.
#[must_use]
pub fn one_terminal_wiring_and_its_teardown_order(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: WIRING,
            message: "TerminalPaneWiring.swift is gone — the terminal leaf's callback wiring is not a \
                      view's to own (docs/56 §3)",
        },
        // The pieces that must not regrow in a renderer. Each is a DECISION (when to connect, whether
        // to autotype, which pill dismisses to what, whether secure input is owed) and none is a
        // drawing.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI", "Sources/SlopDeskMacUI"],
            extensions: SWIFT,
            pattern: "class CommandNavigatorChrome|func runAutotypeIfRequested|func connectIfNeeded|func \
                      reconcileSecureInput",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a terminal-wiring decision grew back in a renderer ({files}) — it is \
                      TerminalPaneWiring's, for BOTH halves",
        },
        // And SOMETHING outside the renderers must actually drive it. A leaf that quietly re-inlined
        // the wiring would pass the ban above by spelling the closures without the helper names.
        //
        // ⚠️ RE-AIMED, and the move is the rule's own subject rather than a rename. This pinned the
        // PHONE LEAF as the caller, which was true only while each shell drove the wiring itself; the
        // leaf's whole lifecycle has since descended into `TerminalLeafLifecycle` for BOTH shells, so
        // the caller the rule wants is one floor down and there is exactly one of it. Pinning a shell
        // here now would be pinning the duplication the descent removed.
        //
        // `Matches` over `Mentions`: the latter reads RAW, so this file's own prose naming
        // `wiring.wire(` would satisfy it — a rule that its own documentation can turn green.
        Claim::Matches {
            path: LIFECYCLE,
            pattern: r"wiring\.wire\(",
            message: "the terminal lifecycle stopped calling wiring.wire( — a renderer is wiring itself \
                      again (docs/56 §3)",
        },
        Claim::Matches {
            path: LIFECYCLE,
            pattern: r"wiring\.clear\(",
            message: "the terminal lifecycle stopped calling wiring.clear( — five wire/clear pairs are \
                      retain-cycle obligations, not layout (docs/56 §3)",
        },
        Claim::Names {
            path: WIRING,
            needle: "secureInput.teardown()",
            message: "TerminalPaneWiring stopped tearing the secure-input lock down at all — the \
                      process-global stays held",
        },
        Claim::Within {
            path: WIRING,
            start: r"secureInput\.teardown\(\)",
            end: r"^    \}",
            pattern: r"guard let model = live\?\.terminalModel",
            message: "TerminalPaneWiring: the secure-input teardown is no longer above its guard — a pane \
                      whose model died keeps the lock",
        },
    ];
    check_all(tree, &claims)
}

/// The escape monitor is an event tap, not a view
///
/// Cancelling a pane move on ⎋ needs a LOCAL event monitor, which is an `AppKit` resource with a
/// paired install/remove and no `SwiftUI` expression. It lived inside an `NSViewRepresentable`'s
/// coordinator, where the pairing was invisible and the `AppKit` rewrite would have had to
/// reproduce it from scratch. The controller is what lets the `AppKit` column and the `SwiftUI`
/// leaf share ONE monitor rather than tapping the event stream twice.
///
/// The file-count floor is not decoration. The shell's pathspec for these directories was
/// `Pane/**/*.swift`, git reads `**` as spanning one or more directory levels, `Pane/` is flat, so
/// the glob matched ZERO files and the gate passed while checking nothing — the third time this
/// gate has died quietly by resolving to an empty list. A ban over nothing passes; a ban over
/// nothing that SAYS so is a ban.
///
/// `Sources/SlopDeskMacUI/Pane` is listed before it exists, and that is the point: wave R creates
/// it eleven batches deep, and a ban whose scope omits the directory the new renderers land in goes
/// stale exactly when it starts mattering. Roots that match nothing cost nothing — the floor is
/// what makes an empty corpus loud, and the other two clear it on their own.
#[must_use]
pub fn one_escape_monitor_installed_and_removed_once(tree: &Tree) -> Report {
    const PANE_VIEWS: &[&str] = &[
        "Sources/SlopDeskPhoneUI/Pane",
        "Sources/SlopDeskMacUI/Terminal",
        "Sources/SlopDeskMacUI/Pane",
    ];
    let claims = [
        Claim::Exists {
            path: ESCAPE_MONITOR,
            message: "PaneMoveEscapeMonitorController.swift is gone — without it a pane move cannot be \
                      cancelled (docs/56 §3)",
        },
        Claim::Mentions {
            path: ESCAPE_MONITOR,
            names: &[
                "func arm(onCancel",
                "func disarm()",
                "addLocalMonitorForEvents",
                "removeMonitor",
            ],
            message: "PaneMoveEscapeMonitorController lost {entry} — install and remove are a PAIR, and \
                      arm/disarm is the seam",
        },
        Claim::Lacks {
            path: ESCAPE_MONITOR,
            pattern: r"^\s*import SwiftUI",
            view: View::Raw,
            message: "PaneMoveEscapeMonitorController imported SwiftUI — it taps events, it draws nothing",
        },
        // ⚠️ ONE FLOOR PER ROOT, and `3f11c6e6` is the whole argument. This was a single
        // `Populated{ roots: PANE_VIEWS, minimum: 20 }`, and the demolition emptied
        // `SlopDeskPhoneUI/Pane` to ZERO without moving it: the two Mac roots clear 20 between them,
        // so the combined floor stayed green over a ban that had stopped reading the phone entirely.
        // A floor that sums its roots cannot see one of them drain — the same finding `ui_split.rs`
        // records about its own video half, arrived at twice independently (docs/62 stage E.0).
        Claim::Populated {
            roots: &["Sources/SlopDeskPhoneUI/Pane"],
            extensions: SWIFT,
            minimum: 6,
            message: "the phone's pane-view corpus came back nearly empty ({found} files) — the escape-tap \
                      ban below has gone stale and is checking nothing on the phone",
        },
        Claim::Populated {
            roots: &["Sources/SlopDeskMacUI/Terminal", "Sources/SlopDeskMacUI/Pane"],
            extensions: SWIFT,
            minimum: 14,
            message: "the Mac's pane-view corpus came back nearly empty ({found} files) — this gate has \
                      gone stale and is checking nothing",
        },
        // Comments stripped: the controller's header EXPLAINS where the monitor went and has to name
        // the call to be worth reading. The app-level `WorkspaceKeyDispatcher` and the keybinding
        // editor tap the stream on purpose and are not pane views, so they are outside these roots
        // rather than allowlisted inside them.
        Claim::NoneUnder {
            roots: PANE_VIEWS,
            extensions: SWIFT,
            pattern: "addLocalMonitorForEvents",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a pane view tapped the event stream directly ({files}) — the monitor is the \
                      controller's, armed through the seam",
        },
    ];
    check_all(tree, &claims)
}

/// The phone's key path is Rust, and its Swift is a marshaller
///
/// Four Swift files used to hold it — a C0 fold, an arrow table, a routing switch, a threshold and
/// a travel accumulator — and every one of them was a rule about bytes with no view in it. They are
/// `slopdesk_workspace::phone_key` now, reached through `slopdesk_phone_*`, and `PhoneKey.swift` is
/// what is left: the vocabulary the responder builds a press in, and the crossing.
///
/// The four deleted names must stay gone. A file that spells one again is the second implementation
/// the one-implementation rule exists to refuse — and this particular second implementation is the
/// one that would drift silently, because both halves would keep passing their own tests.
///
/// The RESPONDER is the other place a rule would grow, and the likelier one: it is the file holding
/// a live `UIKey`, so a table there would look local rather than duplicated. It must spell no
/// escape sequence and no HID number — `UIKeyboardHIDUsage`'s own cases are the only spelling of a
/// usage allowed, and what each one MEANS is `slopdesk_workspace::phone_key`'s alone.
#[must_use]
pub fn the_phone_key_path_is_rust(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskWorkspaceCore/iOS/KeyEncoding.swift",
            message: "KeyEncoding.swift is back — the phone's key rules are Rust (docs/55)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskWorkspaceCore/iOS/InputRouting.swift",
            message: "InputRouting.swift is back — the phone's key rules are Rust (docs/55)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskWorkspaceCore/iOS/FloatingCursorMapping.swift",
            message: "FloatingCursorMapping.swift is back — the phone's key rules are Rust (docs/55)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskWorkspaceCore/iOS/KeyboardAccessoryDecision.swift",
            message: "KeyboardAccessoryDecision.swift is back — the phone's key rules are Rust (docs/55)",
        },
        // The rules themselves, by the shapes they take in Swift. A C0 fold is `& 0x1F` or `- 0x60`;
        // an arrow table is the four private-use scalars. None of them may appear in the module that
        // used to own them — the marshaller passes bytes through, it makes none.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskWorkspaceCore"],
            extensions: SWIFT,
            pattern: r"0x4F : 0x5B|0x5B : 0x4F|& 0x1F|u\{F70[0-3]\}",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a phone key RULE grew back in Swift ({files}) — the fold, the introducer and the \
                      arrows are Rust",
        },
        Claim::Exists {
            path: PHONE_HOST,
            message: "TerminalLeafView.swift is gone — without it the phone's terminal cannot receive a \
                      keystroke (docs/56 §16, docs/62 §2.4)",
        },
        Claim::Lacks {
            path: PHONE_HOST,
            pattern: r"0x1B|0x5B|0x4F|u\{1B\}|\\u\{F70|& 0x1F|hidUsage: [0-9]",
            view: View::Code,
            message: "the phone's responder spelled a key RULE — it reads a UIKey and asks PhoneKey, it \
                      decides nothing",
        },
        Claim::Mentions {
            path: PHONE_HOST,
            names: &[
                "PhoneKey.routesToKeyEncoding",
                "PhoneKey.encode",
                "PhoneKey.keyChord",
                "PhoneKey.foldArmedControl",
                "PhoneKey.showsAccessoryBar",
            ],
            message: "TerminalInputHost stopped asking {entry} — a question it answers itself is a rule \
                      written twice",
        },
        // And the marshaller must actually call the doors it claims to. A `PhoneKey` that quietly
        // answered from Swift again would pass every check above.
        Claim::Mentions {
            path: PHONE_KEY,
            names: PHONE_DOORS,
            message: "PhoneKey.swift stopped calling {entry} — a rule it answers itself is a rule written \
                      twice",
        },
        Claim::Mentions {
            path: "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            names: PHONE_DOORS,
            message: "{entry} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does \
                      not name",
        },
        // The chord's modifier word crosses UNTRANSLATED, so the two numberings must be the same four
        // bits. The Rust side pins its own half against `KeyChord.Modifiers` in `slopdesk-ffi`; this
        // pins the Swift half, which is the one a future `OptionSet` reorder would break without a
        // compile error anywhere.
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeyChord.swift",
            names: &[
                "shift = Self(rawValue: 1 << 0)",
                "control = Self(rawValue: 1 << 1)",
                "option = Self(rawValue: 1 << 2)",
                "command = Self(rawValue: 1 << 3)",
            ],
            message: "KeyChord.Modifiers renumbered ({entry}) — the phone's flag word crosses as those \
                      exact bits",
        },
    ];
    check_all(tree, &claims)
}

/// The six doors the phone's key path crosses on, named once for both sides that must carry them.
const PHONE_DOORS: &[&str] = &[
    "slopdesk_phone_key_routes_to_encoding",
    "slopdesk_phone_key_encode",
    "slopdesk_phone_key_chord",
    "slopdesk_phone_key_fold_control",
    "slopdesk_phone_shows_accessory_bar",
    "slopdesk_phone_floating_cursor_feed",
];

/// The Swift face of the connect ladder.
const CONNECT_FACE: &str = "Sources/SlopDeskWorkspaceCore/Connection/ConnectRun.swift";

/// The two objects that dial — a pane's client, and the app's shared mux pin.
const CONNECT_DIALLERS: &[&str] = &[
    "Sources/SlopDeskWorkspaceCore/Connection/ConnectionViewModel.swift",
    "Sources/SlopDeskWorkspaceCore/Connection/AppConnection.swift",
];

/// Every door the connect face must keep asking.
const CONNECT_DOORS: &[&str] = &[
    "slopdesk_connect_run_new",
    "slopdesk_connect_run_free",
    "slopdesk_connect_run_begin",
    "slopdesk_connect_run_is_current",
    "slopdesk_connect_run_close_deliberately",
    "slopdesk_connect_run_supersede",
    "slopdesk_connect_run_admit_without_dialling",
    "slopdesk_connect_run_note_host_close",
    "slopdesk_connect_run_may_auto_dial",
    "slopdesk_connect_run_disconnect_is_quiet",
    "slopdesk_connect_run_reconnect_is_welcome",
    "slopdesk_connect_run_was_closed_deliberately",
];

/// ONE CONNECT LADDER, AND IT IS NOT SWIFT'S.
///
/// A generation and three latches decide whether a post-handshake write still owns the pane,
/// whether an automatic dial may proceed, and whether a `.disconnected` is a definite disconnect or
/// the start of a campaign. The two host closes answer the automatic paths DIFFERENTLY — a reap
/// gates them, an eviction must not — and a second copy of either latch beside the far side's is a
/// guard that silently stops guarding (docs/45 Phase 6).
#[must_use]
pub fn one_connect_one_ladder(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: CONNECT_FACE,
            message: "Sources/SlopDeskWorkspaceCore/Connection/ConnectRun.swift is gone — which attempt \
                      owns the pane, and whether a reap or an eviction was said, are not the diallers' to \
                      re-derive (docs/45 Phase 6)",
        },
        Claim::Doors {
            path: CONNECT_FACE,
            entries: CONNECT_DOORS,
            message: "ConnectRun.swift no longer calls {entry} — a face that drops a door is a ladder step \
                      growing back beside the one that owns it",
        },
        Claim::NoneOf {
            paths: CONNECT_DIALLERS,
            pattern: r"var connectGeneration|var deliberatelyClosed|var retiredByHost|var evictedByHost",
            view: View::Code,
            message: "{files} STORES a connect generation or one of the three close latches — each is the \
                      far side's, and the reap/eviction asymmetry is exactly what a hand-kept copy loses \
                      (docs/45 Phase 6)",
        },
        Claim::Matches {
            path: CONNECT_DIALLERS[0],
            pattern: r"private let connectRun = ConnectRun\(\)",
            message: "ConnectionViewModel.swift no longer holds a ConnectRun — the ladder it answers is \
                      what keeps a superseded attempt from painting a torn-down pane green (docs/45 Phase 6)",
        },
        Claim::Matches {
            path: CONNECT_DIALLERS[1],
            pattern: r"private let connectRun = ConnectRun\(\)",
            message: "AppConnection.swift no longer holds a ConnectRun — the same ladder, minus the two \
                      host latches it never sets (docs/45 Phase 6)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn connect_ladder(fixture: &Fixture) {
        let mut face = String::new();
        for door in super::CONNECT_DOORS {
            face.push_str(door);
            face.push_str("()\n");
        }
        fixture.write(super::CONNECT_FACE, &face);
        for dialler in super::CONNECT_DIALLERS {
            fixture.write(dialler, "    private let connectRun = ConnectRun()\n");
        }
    }

    #[test]
    fn one_connect_one_ladder_keeps_the_two_host_closes_apart() {
        let fixture = Fixture::new("one-connect-one-ladder");
        connect_ladder(&fixture);
        assert!(super::one_connect_one_ladder(&fixture.tree()).is_clean());

        // The face stopped asking — a ladder step grew back beside the one that owns it.
        fixture.write(super::CONNECT_FACE, "slopdesk_connect_run_new()\n");
        assert!(!super::one_connect_one_ladder(&fixture.tree()).is_clean());
        connect_ladder(&fixture);

        // Each scalar the far side owns, in each dialler, one at a time.
        for drift in [
            "    private var connectGeneration = 0\n",
            "    private var deliberatelyClosed = false\n",
            "    private var retiredByHost = false\n",
            "    private var evictedByHost = false\n",
        ] {
            for dialler in super::CONNECT_DIALLERS {
                fixture.append(dialler, drift);
                assert!(
                    !super::one_connect_one_ladder(&fixture.tree()).is_clean(),
                    "the ban missed {drift} in {dialler}",
                );
                connect_ladder(&fixture);
            }
        }

        // A dialler that dropped the handle the whole ladder is reached through.
        fixture.write(super::CONNECT_DIALLERS[1], "public final class AppConnection {\n");
        assert!(!super::one_connect_one_ladder(&fixture.tree()).is_clean());

        // A bare tree has no face at all.
        let bare = Fixture::new("one-connect-one-ladder-bare");
        assert!(!super::one_connect_one_ladder(&bare.tree()).is_clean());
    }

    const CLEAR: &str = "\
    func clearSecureInput() {
        secureInput.teardown()
        guard let model = live?.terminalModel else { return }
        model.release()
    }
";

    fn wiring(fixture: &Fixture) {
        fixture
            .write(super::WIRING, CLEAR)
            .write(super::LIFECYCLE, "wiring.wire(store)\nwiring.clear(live: live)\n");
    }

    #[test]
    fn the_lock_is_released_before_the_model_is_asked_for() {
        let fixture = Fixture::new("pane-wiring");
        wiring(&fixture);
        assert!(super::one_terminal_wiring_and_its_teardown_order(&fixture.tree()).is_clean());

        // The order inverted — the failure no type can express, and the one that takes the keyboard
        // out of every other app.
        fixture.write(
            super::WIRING,
            "    func clearSecureInput() {\n        guard let model = live?.terminalModel else { return \
             }\n\x20       secureInput.teardown()\n    }\n",
        );
        assert!(!super::one_terminal_wiring_and_its_teardown_order(&fixture.tree()).is_clean());

        // A wiring decision re-inlined in a renderer.
        wiring(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Terminal/MacTerminalLeaf.swift",
            "func connectIfNeeded() {}\n",
        );
        assert!(!super::one_terminal_wiring_and_its_teardown_order(&fixture.tree()).is_clean());

        // The lifecycle stops driving it — the shape the ban above cannot see, because a leaf that
        // re-inlined the five pairs by hand spells none of the banned names.
        wiring(&fixture);
        fixture.write(super::LIFECYCLE, "wiring.wire(store)\n");
        assert!(!super::one_terminal_wiring_and_its_teardown_order(&fixture.tree()).is_clean());

        // And the file's own PROSE does not count, which is what `Mentions` here used to allow.
        fixture.write(
            super::LIFECYCLE,
            "// The two calls this file owns are `wiring.wire(` and `wiring.clear(`.\n",
        );
        assert!(!super::one_terminal_wiring_and_its_teardown_order(&fixture.tree()).is_clean());
    }

    fn monitor(fixture: &Fixture) {
        fixture.write(
            super::ESCAPE_MONITOR,
            "func arm(onCancel: @escaping () -> Void) { addLocalMonitorForEvents() }\nfunc disarm() { \
             removeMonitor(token) }\n",
        );
        // Both floors, separately: the phone's pane target and the Mac's. A fixture that filled
        // only one of them is exactly the state `3f11c6e6` left the real tree in.
        for index in 0..20 {
            fixture.write(
                &format!("Sources/SlopDeskPhoneUI/Pane/View{index}.swift"),
                "import UIKit\n",
            );
        }
        for index in 0..20 {
            fixture.write(
                &format!("Sources/SlopDeskMacUI/Pane/MacView{index}.swift"),
                "import AppKit\n",
            );
        }
    }

    #[test]
    fn a_drained_corpus_is_loud_rather_than_green() {
        let fixture = Fixture::new("pane-escape-monitor");
        monitor(&fixture);
        assert!(super::one_escape_monitor_installed_and_removed_once(&fixture.tree()).is_clean());

        // A pane view tapping the stream itself.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Pane/View3.swift",
            "NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in nil }\n",
        );
        assert!(!super::one_escape_monitor_installed_and_removed_once(&fixture.tree()).is_clean());

        // ONE ROOT DRAINING, WHICH A SUMMED FLOOR CANNOT SEE. Empty the phone's pane target and
        // leave the Mac's alone: the old combined `minimum: 20` was still satisfied by the Mac side
        // and the ban read nothing on the phone. Per-root, this is red.
        monitor(&fixture);
        for index in 0..20 {
            fixture.remove(&format!("Sources/SlopDeskPhoneUI/Pane/View{index}.swift"));
        }
        let report = super::one_escape_monitor_installed_and_removed_once(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|line| line.contains("the phone's pane-view corpus came back nearly empty"))
        );

        // And the failure the shell only found by break-testing: a scope that resolves to nothing.
        let empty = Fixture::new("pane-escape-monitor-drained");
        empty.write(
            super::ESCAPE_MONITOR,
            "func arm(onCancel: @escaping () -> Void) { addLocalMonitorForEvents() }\nfunc disarm() { \
             removeMonitor(token) }\n",
        );
        assert!(!super::one_escape_monitor_installed_and_removed_once(&empty.tree()).is_clean());
    }

    fn phone_key(fixture: &Fixture) {
        let doors = super::PHONE_DOORS.join("\n");
        fixture
            .write(super::PHONE_KEY, &doors)
            .write("rust/slopdesk-ffi/include/slopdesk_ffi.h", &doors)
            .write(
                super::PHONE_HOST,
                "PhoneKey.routesToKeyEncoding\nPhoneKey.encode\nPhoneKey.keyChord\nPhoneKey.\
                 foldArmedControl\nPhoneKey.showsAccessoryBar\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeyChord.swift",
                "shift = Self(rawValue: 1 << 0)\ncontrol = Self(rawValue: 1 << 1)\noption = Self(rawValue: \
                 1 << 2)\ncommand = Self(rawValue: 1 << 3)\n",
            );
    }

    #[test]
    fn the_responder_asks_and_the_marshaller_crosses() {
        let fixture = Fixture::new("pane-phone-key");
        phone_key(&fixture);
        assert!(super::the_phone_key_path_is_rust(&fixture.tree()).is_clean());

        // A C0 fold, back in the responder.
        fixture.append(super::PHONE_HOST, "let byte = scalar & 0x1F\n");
        assert!(!super::the_phone_key_path_is_rust(&fixture.tree()).is_clean());

        // A door the header stopped naming — Swift cannot reach it, and nothing else would say so.
        phone_key(&fixture);
        fixture.write(
            "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            "slopdesk_phone_key_encode\n",
        );
        assert!(!super::the_phone_key_path_is_rust(&fixture.tree()).is_clean());

        // And the modifier word renumbered.
        phone_key(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeyChord.swift",
            "shift = Self(rawValue: 1 << 1)\n",
        );
        assert!(!super::the_phone_key_path_is_rust(&fixture.tree()).is_clean());
    }
}
