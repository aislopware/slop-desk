//! The phone's capabilities, which are not allowed to be the Mac's minus a few.
//!
//! Ported from the deleted `check-supervisor.sh`. The user's rule for this app is one sentence: the
//! iOS app differs from the macOS app in LAYOUT and in nothing else. Every rule here pins one
//! capability that was Mac-only until it was closed, and each of them was Mac-only in the same way
//! — not by a decision, but because the phone's renderer was written later and something did not
//! get carried across. That is precisely the failure a ratchet catches and a review does not:
//! nobody deletes a capability, it just fails to be added back the next time a file is rewritten.
//!
//! Every rule below was BREAK-TESTED against the real tree — the file was edited back to the banned
//! shape, the rule was run, and the verdict is recorded in the rule's own comment.
//!
//! Where the shell guarded each check with `[[ -f … ]] &&`, these do not: an absent file here fails
//! rather than passing quietly, because a renamed subject is the one bug a gate cannot notice by
//! reading its own output.
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
use crate::text;
use crate::tree::Tree;

/// The phone app's object, which is also the rung at the end of its responder chain. ONE path since
/// docs/62 stage A: the delegate that owns the composition IS the delegate the chain ends at, so
/// the two constants this rule used to hold named the same file the moment the `App` struct went.
const PHONE_APP: &str = "Sources/SlopDeskPhoneUI/PhoneAppDelegate.swift";
/// The `@main` shell that hands the process to it.
const PHONE_MAIN: &str = "Apps/ClientApp-iOS/AppMain.swift";
/// The phone terminal pane's responder.
///
/// ⚠️ RE-AIMED 2026-08-28, and this one was NOT a rename. `TerminalInputHost.swift` is deleted
/// outright — docs/62 §2.4 rules the `UIViewRepresentable` out and says the `UIResponder` "becomes
/// the pane controller's own input surface", which it now is: `TerminalInputHostView: UIView,
/// UIKeyInput` lives at `TerminalLeafView.swift:1099`, in the leaf it always served. So the TYPE
/// survives under its old name and the FILE does not, which is exactly the case a path-keyed rule
/// gets wrong in the direction that looks alarming: it reported "the phone's terminal cannot
/// receive a keystroke" about a terminal that could.
const INPUT_HOST: &str = "Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift";
/// The one resolve both shells' rungs share.
const INTERCEPTOR: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Keybinding.swift";
/// The code panel's shared model.
const CODE_SIDEBAR: &str = "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarModel.swift";
/// The phone's panel control — the four plates, minted from `PanelTabs`.
///
/// RE-AIMED 2026-08-28, and this module's `PHONE_ROOT` went with it. The root const pointed at the
/// phone's workspace root because the `SwiftUI` root's TOOLBAR held the panel strip, so "minted,
/// not hand-listed" was a fact about the root. Stage H gave the panel its own bar and the control
/// left the root; `PhonePanelTabGroup` builds the plates in its initializer, which is where that
/// fact is true or false today. The root const was kept for one pass on the belief that other
/// claims still named it — they do not, this was its only reader, so it is gone rather than kept
/// alive by an `allow`. `chrome_split`'s own `PHONE_ROOT` is a different const about the split
/// controller's composition, and it is still read.
const PHONE_TAB_GROUP: &str = "Sources/SlopDeskPhoneUI/Panel/PhonePanelTabGroup.swift";
/// The phone's panel subtree, where the device surfaces live.
const PHONE_PANEL: &[&str] = &["Sources/SlopDeskPhoneUI/Panel/"];
/// The one file allowed to draw a clear key — `PhoneDevicePanelChrome`'s home under `UIKit`.
///
/// It was `Panel/DevicePanelChrome.swift` and that file is DELETED: the `UIKit` crossing folded the
/// chrome and the parts that use it into one file, and `PhoneDevicePanelParts`' own header says why
/// they are together. The exemption kept naming the old path, which exempted nothing — and nothing
/// went red, because the ban below had gone blind at the same time.
const PANEL_CHROME: &str = "Sources/SlopDeskPhoneUI/Panel/PhoneDevicePanelParts.swift";
/// The two device consoles.
const CONSOLES: &[&str] = &[
    "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorConsoleView.swift",
    "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidConsoleView.swift",
];
/// The two device mirrors.
const MIRRORS: &[&str] = &[
    "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorScreenView.swift",
    "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidScreenView.swift",
];
/// The two device stages.
const STAGES: &[&str] = &[
    "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorStageView.swift",
    "Sources/SlopDeskPhoneUI/Panel/Android/PhoneAndroidStageView.swift",
];
/// The terminal renderer both shells embed.
const RENDERER: &str = "ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift";
/// The phone's remote-GUI pane leaf.
const PHONE_GUI_LEAF: &str = "Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift";
/// The phone's video surface.
const PHONE_VIDEO: &str = "Sources/SlopDeskVideoClientPhone/MetalLayerBackedView.swift";
/// Its Mac twin.
const MAC_VIDEO: &str = "Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift";
/// Both video renderers.
const RENDERERS: &[&str] = &[MAC_VIDEO, PHONE_VIDEO];

/// The phone dispatches a chord from the END of the responder chain
///
/// The phone's whole chord dispatcher used to be the focused TERMINAL pane's responder, so ⌘⇧P, ⌘T,
/// ⌘D, ⌘1–9, ⌃⇥ and ⌘⇧O were dead over a desktop/GUI pane, dead with no pane focused, and dead
/// under the panel's cover — every one of them live on the Mac, whose `NSEvent` monitor is
/// application-wide. The rung that fixed it can only be at the END of the chain, and on this
/// platform the app DELEGATE is the only object that is there for every window: a `UIView` mounted
/// by a `SwiftUI` `.background` is a SIBLING of the content, absent from the chain a focused
/// terminal walks. So being the delegate is the rule. Losing it is silent — no build error, no test
/// failure, just chords that stop working outside a terminal, which is exactly the state this
/// replaced.
///
/// It used to be mounted by `@UIApplicationDelegateAdaptor`, which is the bridge a `SwiftUI` `App`
/// needs to have a delegate at all. There is no `App` any more (docs/62 stage A), so the claim
/// moved to the two halves the adaptor was standing in for: the `@main` shell names this class to
/// `UIApplicationMain`, and this class is a `UIResponder` that overrides `pressesBegan`. Both are
/// pinned, because either one alone is a delegate that never sees a key.
///
/// Which rung a press lands on — workspace, panel-escape, yield — is a DECISION, and the split's
/// rule is that a decision lives below the UI targets. `PhoneRootKeyPolicy` is that decision; the
/// responder is allowed to know `UIKit` and nothing else.
///
/// BREAK-TEST: `PhoneAppDelegate.main()` → `SomeOtherDelegate.main()` ⇒ FAIL "the phone's root key
/// rung is not the app's delegate". Separately dropped the `override public func pressesBegan` ⇒
/// FAIL "the phone's root key rung takes no key". Separately replaced the
/// `PhoneRootKeyPolicy.rung(…)` call with an inline `if panelPresented …` chain ⇒ FAIL "the phone's
/// root key rung re-spells its own precedence". All three restored; PASS.
#[must_use]
pub fn the_phone_dispatches_chords_at_the_root(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: PHONE_MAIN,
            pattern: r"PhoneAppDelegate\.main\(\)",
            message: "the phone's root key rung is not the app's delegate — AppMain must hand the process \
                      to PhoneAppDelegate.main(), or every workspace chord dies outside a terminal pane \
                      (docs/62 stage A)",
        },
        Claim::Matches {
            path: PHONE_APP,
            pattern: r"override public func pressesBegan",
            message: "the phone's root key rung takes no key — PhoneAppDelegate must override pressesBegan, \
                      which is the chain's tail and the only place every first responder walks past \
                      (docs/62 stage A)",
        },
        Claim::Matches {
            path: PHONE_APP,
            pattern: r"PhoneRootKeyPolicy\.rung",
            message: "the phone's root key rung re-spells its own precedence — it must ask \
                      PhoneRootKeyPolicy.rung, which is the shared decision (docs/56 §3)",
        },
    ])
}

/// ⌘C / ⌘X / ⌘V / ⌘A reach the phone's terminal, and reach something once they do
///
/// The binding table deliberately does not claim C/X/V/A — "handled by the terminal's own copy
/// responder" — which is true on a Mac, because `AppKit`'s standard editing selectors land on the
/// terminal view: it IS the window's first responder. On the phone the pane's first responder is a
/// zero-sized sibling of the renderer, so the four chords resolved to nothing at all and a ⌘
/// combination encodes to no bytes: they died in silence. `keyCommands` is what puts them back, and
/// it must stay in the pane's responder rather than becoming a second implementation of copy and
/// paste somewhere.
///
/// The other half is the general shape, and it bit this very change: `keyCommands` declared the
/// four, the phone swallowed all four, and the sink they were handed to —
/// `TerminalViewModel.onRequestMenuItem` — was bound by nobody, so the four went from "fall through
/// to the system" to "consumed and dropped". A registered chord that reaches nothing is worse than
/// an absent one, because the absent one at least lets the default behaviour happen. So the
/// PRODUCER must exist, and the registration must be gated on it, or the runtime gets ahead of the
/// wiring from the other side.
///
/// BREAK-TEST: deleted the `override var keyCommands` block ⇒ FAIL "the phone's terminal has no
/// editing chords". Separately deleted the `model.onRequestMenuItem = { … }` line from the
/// renderer's iOS `attach(model:)` ⇒ FAIL "handed to nobody". Separately changed the guard back to
/// `live?.terminalModel != nil` ⇒ FAIL "registers its editing chords unconditionally". All restored
/// from /tmp; PASS.
#[must_use]
pub fn the_phones_terminal_takes_editing_chords(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: INPUT_HOST,
            pattern: "override var keyCommands",
            message: "the phone's terminal has no editing chords — TerminalInputHost must declare \
                      keyCommands for ⌘C/⌘X/⌘V/⌘A, which no other rung can carry (the table leaves C/X/V/A \
                      to the terminal)",
        },
        Claim::Matches {
            path: RENDERER,
            pattern: r"onRequestMenuItem = \{",
            message: "the phone's editing chords are handed to nobody — the renderer must bind \
                      TerminalViewModel.onRequestMenuItem when it attaches, or ⌘C/⌘X/⌘V/⌘A are swallowed \
                      and dropped",
        },
        Claim::Matches {
            path: INPUT_HOST,
            pattern: r"guard live\?\.terminalModel\?\.onRequestMenuItem != nil",
            message: "TerminalInputHost registers its editing chords unconditionally — a UIKeyCommand \
                      swallows its chord, so it must be offered only while its sink is bound",
        },
    ])
}

/// One config file produces one behaviour on both shells
///
/// `keybind = cmd+shift+h=text:hello` is ONE config file read by both clients. It sent bytes on the
/// Mac, through `WorkspaceKeyDispatcher`, and did nothing whatever on the phone — which is one
/// config producing two behaviours, the worst shape a shared setting can take, because the user has
/// no way to tell that the phone even read the line. The phone answers it on the PANE's rung, where
/// the keyboard actually is.
///
/// `unbind:` is the same defect from the other end. The Mac's dispatcher has always honoured it;
/// the shared interceptor did not, so an unbound chord still fired its default action wherever the
/// interceptor is the resolver — both of the phone's rungs, and the Mac's own terminal surface
/// whenever a press reached it rather than the monitor. Asked inside `makeKeyInterceptor`, which is
/// the one resolve all of them share.
///
/// BREAK-TEST: removed the `WorkspaceBindingRegistry.textBinding(for: chord)` arm from
/// `swallowsAsWorkspaceChord` ⇒ FAIL "a `text:`/`csi:`/`esc:` binding is Mac-only again".
/// Separately deleted the `!WorkspaceBindingRegistry.isUnbound(chord)` clause from the factory's
/// `resolveChord` ⇒ FAIL "the shared key interceptor ignores unbind:". Both restored; PASS.
#[must_use]
pub fn one_config_file_produces_one_behaviour(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: INPUT_HOST,
            pattern: r"WorkspaceBindingRegistry\.textBinding",
            message: "a `text:`/`csi:`/`esc:` binding is Mac-only again — the phone's pane responder must \
                      consult WorkspaceBindingRegistry.textBinding, or one shared config file produces two \
                      behaviours",
        },
        Claim::Matches {
            path: INTERCEPTOR,
            pattern: r"WorkspaceBindingRegistry\.isUnbound",
            message: "the shared key interceptor ignores unbind: — makeKeyInterceptor must drop an unbound \
                      chord's action, or the same config file unbinds a chord on one shell only",
        },
    ])
}

/// The code panel does not re-ensure a project it has already settled
///
/// The Mac's panel is faded when collapsed, so its poll task is never cancelled and never
/// re-entered. The phone's is a `.fullScreenCover`, so every dismissal cancels it and every re-open
/// re-enters — and an unguarded `poll` opens by writing `.starting`, which flashed the spinner over
/// a workbench that was already loaded and re-ensured a project the host had long since brought up.
///
/// The guard is what makes the two shells one behaviour; `requestReload()` unsettling is its other
/// half, without which the reload button would cancel a finished loop and start one that returns on
/// its first line.
///
/// BREAK-TEST: deleted the `if case let .ready(settledRoot, _) = phase` guard ⇒ FAIL "the code
/// panel re-ensures a settled project". Separately deleted `phase = .starting` from
/// `requestReload()` ⇒ FAIL "the code panel's reload cannot unsettle". Both restored; PASS.
#[must_use]
pub fn the_code_panel_settles_once(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: CODE_SIDEBAR,
            pattern: r"case let \.ready\(settledRoot, _\) = phase",
            message: "the code panel re-ensures a settled project — CodeSidebarModel.poll must return early \
                      on a root it has already settled, or the phone's cover flashes its spinner on every \
                      re-open",
        },
        Claim::Within {
            path: CODE_SIDEBAR,
            start: r"func requestReload\(\) \{",
            end: r"^    \}",
            pattern: r"phase = \.starting",
            message: "the code panel's reload cannot unsettle — requestReload() must clear the settled \
                      phase, or the reload button restarts a loop that returns on its first line",
        },
    ])
}

/// The phone can open the panel on a named surface, and hears the surface's NAME
///
/// The Mac's collapsed panel leaves a RAIL: four named plates, any of which opens the panel ON that
/// surface in one click. The phone had a bare toggle that reopened on whatever was last selected,
/// so reaching Emulators from closed was two taps with nothing on screen naming the second. The
/// phone's answer is a menu over the same four readings — same words, same order, one gesture — and
/// it has to be over `PanelTabs.all` rather than a list written out here, which is the whole reason
/// that reading exists.
///
/// The second half is the drift that had reached opposite answers: the Mac's plate set its
/// accessibility label from `tab.label` and the phone's from `tab.help`, so a screen-reader user on
/// the phone heard a whole explanatory sentence every time focus moved across four tabs. The
/// label/hint split is cut once in `PanelTabReading`; a renderer reaching for `help` as a LABEL is
/// that drift coming back.
///
/// BREAK-TEST: replaced the `ForEach(PanelTabs.all…)` menu with the old bare `Button { toggle() }`
/// ⇒ FAIL "the phone cannot open the panel on a named surface". Separately
/// `.accessibilityLabel(tab.accessibilityLabel)` → `.accessibilityLabel(tab.help)` in
/// PhonePanelSheet.swift ⇒ FAIL "a panel tab reads its help text as its name". Both restored; PASS.
///
/// ## ⚠️ RE-SPELLED AND FLOORED 2026-08-28
/// The first claim was `ForEach\(PanelTabs\.all` on `WorkspaceRootView.swift`. Both halves of that
/// died at once: `3f11c6e6` deleted the file, and `ForEach` is `SwiftUI` vocabulary with no `UIKit`
/// spelling (docs/62 §4.8's list names this rule). Re-aiming the PATH while keeping the NEEDLE
/// would have produced a claim that can never pass, so the needle drops to `PanelTabs.all` — which
/// is what the law was about all along. The tab strip is MINTED from `PanelTabs`, not hand-listed;
/// whether that minting is a `ForEach` or a `UIStackView` loop was never the invariant, and pinning
/// the loop's spelling was pinning an ARRANGEMENT instead of a behaviour.
///
/// The second claim is a `NoneUnder` over `Panel/`, a directory the demolition emptied and stage H
/// refills. It passed through the whole demolition without a word, so a `Populated` floor now runs
/// first. That floor is RED today on purpose: the ban it guards is not checking anything until the
/// panel comes back, and the honest report of that is a failure, not a silent pass.
///
/// ## ⚠️ AND RE-AIMED AGAIN, ONE CLAIM ONLY — the control moved, not the law
/// The `PanelTabs.all` claim rode on a `PHONE_ROOT` const because the `SwiftUI` root's toolbar HELD
/// the panel menu. Stage H landed the panel as its own bar, and the minting is now
/// `PhonePanelTabGroup`'s initializer — `plates =
/// PanelTabs.all.map(PhonePanelTabPlate.init(tab:))`, one plate per reading, in the reading's
/// order. So this claim moves to [`PHONE_TAB_GROUP`], a const of its own rather than a re-pointed
/// root: a name that means "wherever the thing I want happens to be this week" cannot go stale
/// visibly, and the root's name has to keep meaning the root. It turned out to be this module's
/// ONLY reader of that root, so the const went with the claim — see [`PHONE_TAB_GROUP`]. Both the
/// floor and the ban below stay on `Panel/`, unchanged: the directory they read is the one that now
/// holds the control too.
#[must_use]
pub fn the_panel_opens_on_a_named_surface(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: PHONE_TAB_GROUP,
            pattern: r"PanelTabs\.all",
            message: "the phone cannot open the panel on a named surface — the panel bar's tab group must \
                      mint its plates from PanelTabs.all, which is the Mac rail's capability on a device \
                      with no rail",
        },
        // ⚠️ THE FLOOR BEFORE THE BAN — see the header. `Panel/` is empty until docs/62 stage H,
        // and a `NoneUnder` over an empty root passes while checking nothing.
        Claim::Populated {
            roots: PHONE_PANEL,
            extensions: SWIFT,
            minimum: 2,
            message: "only {found} Swift files under Sources/SlopDeskPhoneUI/Panel — the help-text ban \
                      below reads an empty tree and passes (docs/62 stage H)",
        },
        Claim::NoneUnder {
            roots: PHONE_PANEL,
            extensions: SWIFT,
            pattern: r"accessibilityLabel\(tab\.help\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a panel tab reads its help text as its name ({files}) — the label is the WORD \
                      (PanelTabReading.accessibilityLabel); the sentence is the HINT",
        },
    ])
}

/// One clear key for every filter field in the device panels
///
/// `SlateSearchField` hands the plate — and with it the trailing clear affordance — to its caller,
/// and four callers took that four different distances: both device LISTS drew the key and neither
/// CONSOLE drew anything, so a typed filter over a log could only be undone by backspacing it. Cut
/// once into `DevicePanelChrome.clearKey`. The ban is on drawing it inline again, which is how the
/// four copies happened the first time.
///
/// The one file allowed to spell it is EXEMPTED from the corpus rather than compared against the
/// answer. The shell's `spells` returned the FIRST file that matched and stopped, so an exemption
/// written as `if [[ "$leak" != "…/DevicePanelChrome.swift" ]]` passed for every corpus containing
/// the exempt file — it is the first hit, and the real leak behind it was never looked at. That is
/// not hypothetical: the first draft was written that way and its break-test PASSED the banned
/// shape. [`Claim::NoneUnder`] cannot be written that way, because it names every offender rather
/// than the first.
///
/// The positive half is the other direction: a list that clears in a tap beside a console that does
/// not is the inconsistency this closed, and it is invisible until someone types in the console.
///
/// BREAK-TEST: pasted the old inline `Button { query = "" } label: { Image(systemSymbol:
/// .xmarkCircleFill) … }` back into PhoneSimulatorDeviceList.swift ⇒ FAIL naming that file.
/// Restored from /tmp; PASS.
///
/// ## ⚠️ FLOORED AND RE-SPELLED 2026-08-28
/// [`Claim::NoneUnder`] naming every offender rather than the first is the fix for ONE of the two
/// ways this rule lies. The other is the corpus itself: `3f11c6e6` deleted `Panel/` outright, and a
/// ban over a root with no files in it names no offenders and reports clean. The `Populated` floor
/// above the ban is the tripwire for that, and it is RED until stage H refills the directory —
/// which is the truth this rule owed and did not tell for one commit.
///
/// The needle grew a `(UI)?` prefix in the same pass. `Image(systemSymbol:)` is `SwiftUI`; the
/// `UIKit` clear key is `UIImage(systemSymbol:)`, so the old needle would have been un-typeable
/// drift the day the panel came back — vacuous a second time, over a corpus that was no longer
/// empty. The law is "one clear affordance, spelled in the panel's chrome", and it is indifferent
/// to which framework draws the glyph.
///
/// ## ⚠️ VACUOUS A THIRD TIME, AND RE-SPELLED FOR THE LAST TIME 2026-08-30
/// The paragraph above guessed the `UIKit` spelling and guessed wrong. Stage H did not write
/// `UIImage(systemSymbol:)`; it wrote `UIImage(systemName: SFSymbol.xmarkCircleFill.rawValue,` —
/// over two lines, through the symbol ENUM, with the initialiser and the glyph no longer adjacent.
/// `(UI)?Image\(systemSymbol: \.xmarkCircleFill\)` matched nothing in the tree, so the ban passed
/// over a full corpus while checking nothing, and the `Populated` floor cannot see that: the floor
/// proves there are files, never that the needle is still typeable. The exemption had rotted in the
/// same window — `DevicePanelChrome.swift` was deleted into `PhoneDevicePanelParts.swift` — and one
/// dead half hid the other, which is why nothing was red for either.
///
/// The needle is now the SYMBOL alone. Three respellings in three passes is the evidence: every
/// version that named the call site was drift waiting to happen, because the call site is exactly
/// what a framework crossing rewrites. `xmarkCircleFill` is the affordance — a phone panel file
/// naming it at all is drawing a clear key, whatever the surrounding syntax is that year — and the
/// one file allowed to name it is exempt. That also survives the next crossing without an edit.
///
/// BREAK-TEST (this pass): pasted `UIImage(systemName: SFSymbol.xmarkCircleFill.rawValue)` into
/// PhoneSimulatorDeviceList.swift ⇒ FAIL naming that file; removed ⇒ PASS. And with the needle
/// restored to its old `systemSymbol:` spelling the live tree passes while `PhoneDevicePanelParts`
/// draws the key, which is the vacuity this section is about.
#[must_use]
pub fn one_clear_key_per_filter_field(tree: &Tree) -> Report {
    let mut report = check_all(tree, &[
        // ⚠️ THE FLOOR BEFORE THE BAN, and it only catches ONE of the two vacuities. `3f11c6e6`
        // emptied the corpus, which this floor now sees. It cannot see the other: a needle no file
        // could type any more, over a corpus that is full. That one happened too (docs/62 §4.8, and
        // the section on it above), and the answer is below — the needle names the SYMBOL, not the
        // call that draws it, because the call is what a framework crossing rewrites.
        Claim::Populated {
            roots: PHONE_PANEL,
            extensions: SWIFT,
            minimum: 2,
            message: "only {found} Swift files under Sources/SlopDeskPhoneUI/Panel — the inline clear-key \
                      ban below reads an empty tree and passes (docs/62 stage H)",
        },
        Claim::NoneUnder {
            roots: PHONE_PANEL,
            extensions: SWIFT,
            pattern: "xmarkCircleFill",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[PANEL_CHROME],
            message: "a device panel spells its own clear key ({files}) — PhoneDevicePanelChrome.clearKey \
                      is the one affordance, and four copies of it is how two of them ended up missing",
        },
    ]);
    for console in CONSOLES {
        report.absorb(check_all(tree, &[Claim::Matches {
            path: console,
            pattern: r"PhoneDevicePanelChrome\.clearKey",
            message: "a device console has no way to clear its filter — its own device list clears in a \
                      tap, and the two sit one scroll apart",
        }]));
    }
    report
}

/// A mirrored device can be typed into, and forwards the press it does not want
///
/// Both mirrors have always typed from a `UIKey`, which is the whole story on a Mac because a Mac
/// has a keyboard. The phone this ships on most often has none, and on that phone the mirrored
/// device could be tapped, swiped, rotated and screenshotted while remaining impossible to put one
/// character into. The soft-keyboard host is the capability; the stage's plate is how it is
/// reached. Both halves are pinned, because either one alone is dead code.
///
/// The forwarding is a separate failure. Both mirrors take first responder on TOUCH, so a hardware
/// keyboard follows the last device tapped — which makes them the first rung for every subsequent
/// press, and both used to DROP the ones they could not use (`case .none: break`; a ⌘-chord with no
/// device mapping). Every workspace chord died the moment anyone tapped the picture. The shared
/// rule already calls those presses "a chord the client keeps for itself"; keeping one means
/// walking it up the chain, not eating it.
///
/// COUNTED, not merely present: each mirror has one forward in its early guard and one in the arm
/// that used to drop the press, so a rule that only asked for the string would have passed the bug.
///
/// BREAK-TEST: deleted the `DeviceSoftKeyboard.shared.register(self)` call ⇒ FAIL "cannot take
/// typed text". Separately deleted the `keyboard` plate from `PhoneSimulatorStageView` ⇒ FAIL "has
/// no way to raise the keyboard". Separately `super.pressesBegan(presses, with: event)` → `break`
/// in the `.none` arm ⇒ FAIL "eats the chords it cannot use". All restored from /tmp; PASS.
#[must_use]
pub fn a_mirrored_device_takes_typed_text(tree: &Tree) -> Report {
    let mut report = Report::new();
    for mirror in MIRRORS {
        report.absorb(check_all(tree, &[
            Claim::Matches {
                path: mirror,
                pattern: r"DeviceSoftKeyboard\.shared\.register",
                message: "a mirror cannot take typed text — it must register with DeviceSoftKeyboard, or a \
                          phone with no keys cannot type into the device at all",
            },
            Claim::AtLeast {
                path: mirror,
                pattern: r"super\.pressesBegan\(presses, with: event\)",
                minimum: 2,
                message: "a mirror eats the chords it cannot use ({found} forwards, 2 needed) — an unmapped \
                          press must reach super, or tapping the mirror kills every workspace chord until \
                          focus moves",
            },
        ]));
    }
    for stage in STAGES {
        report.absorb(check_all(tree, &[Claim::Matches {
            path: stage,
            pattern: r"DeviceSoftKeyboard\.shared\.toggle",
            message: "a device stage has no way to raise the keyboard — the soft-keyboard host is \
                      unreachable without the stage's plate",
        }]));
    }
    report
}

/// The phone's paste plate asks the board a question it can answer in silence
///
/// Since iOS 16 a read of `UIPasteboard.string` for content this app did not write raises the modal
/// "Allow Paste?" alert. `GuiPastePlateMenu.canPasteCurrent` is read from `body`, so while it
/// called `currentLocalClipboard()` every render of a remote-GUI pane's footer could put that alert
/// on screen unprompted. The fix is a DIFFERENT QUESTION, not a different call site: `hasText`
/// discloses nothing, so the platform answers it without asking anyone. The Mac's twin may read
/// content because it builds its menu in `onClick`; `SwiftUI` has no equivalent moment, which is
/// why this rule is the phone's alone.
///
/// Both halves are pinned, because either one alone lets the defect back: the probe must be what
/// enablement asks, AND the content read must not reappear in that property. The CONTENT read
/// inside the `Button`'s action is correct and deliberately untouched — the tap IS the paste, which
/// is why both claims are scoped to the property rather than to the file.
///
/// BREAK-TEST: `clipboardHasText: store.localClipboardHasText()` →
/// `clipboardHasText: ClipboardPasteMenu.isPastable(store.currentLocalClipboard())` ⇒ FAIL both
/// arms. Restored from /tmp; PASS.
#[must_use]
pub fn the_paste_plate_asks_a_silent_question(tree: &Tree) -> Report {
    /// The property, which is evaluated with `body`.
    const GATE: (&str, &str) = (r"var canPasteCurrent: Bool \{", r"^    \}");

    check_all(tree, &[
        Claim::Within {
            path: PHONE_GUI_LEAF,
            start: GATE.0,
            end: GATE.1,
            pattern: r"localClipboardHasText\(\)",
            message: "the phone's paste plate does not ask the silent probe — canPasteCurrent must gate on \
                      WorkspaceStore.localClipboardHasText(), which discloses nothing and so raises no iOS \
                      paste alert (docs/56 increment 78)",
        },
        Claim::LacksWithin {
            path: PHONE_GUI_LEAF,
            start: GATE.0,
            end: GATE.1,
            pattern: r"currentLocalClipboard\(",
            view: View::Code,
            message: "the phone's paste plate reads clipboard content from a render — canPasteCurrent is \
                      evaluated with body, so a content read there puts iOS's \"Allow Paste?\" alert on \
                      screen unprompted (docs/56 increment 78)",
        },
    ])
}

/// The swipe-peel chip has a driver on both halves
///
/// The chip was MOUNTED on the phone and DRIVEN only on the Mac for most of a year, on a premise
/// that was false in the file that stated it: "the planner arms on trackpad scroll PHASES, which a
/// touch does not produce". A two-finger pair routed to `.scroll` produces exactly them — the phone
/// sends Began on the first move and Ended on the lift, because the host needs a native gesture
/// rather than a train of wheel ticks — so the mirror had a stream to read the whole time. A
/// mounted renderer with no producer is the worst shape a parity gap takes: it looks finished from
/// the drawing's side.
///
/// Three things are pinned, because the gap could return through any of them: each half FEEDS the
/// planner, each half ADOPTS the host's status push — without which the mirror never arms and the
/// chip is dark again with no code missing — and the verdict-to-chip state machine stays SHARED.
/// The haptic's rising edge, the confirm hold and the swallowed retracts are one law, and two
/// renderers each keeping their own would drift the moment one is edited.
///
/// The hold is the door's number, never a literal in either renderer. 520 ms typed on one half and
/// 500 on the other is two answers to "how long does a fire stay acknowledged", and nothing goes
/// red when they disagree.
///
/// BREAK-TEST: deleted the `feedSwipePeel(dx:dy:scrollPhase:)` call from the phone's
/// `applyPairScroll` ⇒ FAIL "has no swipe-peel driver". Separately deleted the
/// `pipeline.onSwipeNavStatusChanged` line ⇒ FAIL "never learns the host's swipe-nav operating
/// point". Separately inlined the driver's `switch` back into the Mac's `applySwipePeel` ⇒ FAIL
/// "spells the swipe-peel chip's state machine itself". All restored from /tmp; PASS.
#[must_use]
pub fn the_swipe_peel_chip_has_two_drivers(tree: &Tree) -> Report {
    /// Each call a renderer must make, and what its absence means.
    const FED: &[(&str, &str)] = &[
        (
            r"feedSwipePeel\(",
            "a video renderer has no swipe-peel driver — the chip is mounted on both halves, and a renderer \
             with no producer is a parity gap that looks finished from the drawing's side",
        ),
        (
            r"pipeline\.onSwipeNavStatusChanged",
            "a video renderer never learns the host's swipe-nav operating point — without the status push \
             the mirror never arms and the chip stays dark with no code missing",
        ),
        (
            r"peelDriver\.step\(",
            "a video renderer spells the swipe-peel chip's state machine itself — the haptic's rising edge, \
             the confirm hold and the swallowed retracts are SwipePeelChipDriver's, once, or the two \
             renderers drift",
        ),
    ];

    let mut report = Report::new();
    for renderer in RENDERERS {
        for (pattern, message) in FED {
            report.absorb(check_all(tree, &[Claim::Matches {
                path: renderer,
                pattern,
                message,
            }]));
        }
    }
    report.absorb(check_all(tree, &[Claim::NoneOf {
        paths: RENDERERS,
        pattern: r"nanoseconds: 5[0-9]{2}_000_000",
        view: View::Code,
        message: "a swipe-peel confirm hold is spelled in a renderer — the length is \
                  slopdesk_peel_constants().confirm_hold_seconds, reached through \
                  SwipePeelChipDriver.confirmHold",
    }]));
    report
}

/// An iPad with a trackpad is a pointer, and the phone half can see it
///
/// `TARGETED_DEVICE_FAMILY` is "1,2" and always was, so an iPad with a trackpad or a mouse has
/// always driven the phone's video surface — and for most of the project that surface had ZERO
/// `UIPointerInteraction`, ZERO `UIHoverGestureRecognizer` and no reading of `buttonMask` anywhere
/// in the tree. Not a layout difference: a whole input modality missing on a first-class device,
/// which is the exact thing docs/56 §3 says the split may never produce. Every one of these is a
/// capability the Mac half has had since it existed, so each is pinned as a POSITIVE rather than
/// left in the absent-sinks ledger, which only ever recorded what the phone did NOT do.
///
/// The five are independent failure modes, not one feature in five spellings:
/// hover — a pointer moving with nothing held produces no `UITouch` at all, so without the
/// recogniser every piece of hover-only remote UI is unreachable from this half; buttons — `UIKit`
/// reports the LEVEL on every event, and a client that forwarded it rather than the edge either
/// never presses or never releases, stranding a button down on a host whose event source is
/// process-global; scroll — a trackpad's wheel arrives only through a pan with
/// `allowedScrollTypesMask`, and the two-finger swipe an iPad user makes on it is the same gesture
/// the host's swipe-nav recogniser fires on; the cursor — the pane composites the host's pointer,
/// so the local one has to go or there are visibly two; and the button DIFF, whose bit indices ARE
/// the wire's `MouseButton` ordinals, which is why a hand-rolled one is where a right click quietly
/// becomes a left one on one device only.
///
/// BREAK-TEST: deleted the `UIHoverGestureRecognizer` line ⇒ FAIL "cannot see a pointer that
/// hovers". Separately deleted `allowedScrollTypesMask` ⇒ FAIL "a trackpad's scroll". Separately
/// replaced the `buttonMask` read with a hardcoded primary ⇒ FAIL "synthesizes an indirect
/// pointer's press". Separately dropped the `UIPointerInteraction` ⇒ FAIL "shows two pointers". All
/// restored from /tmp; PASS.
#[must_use]
pub fn an_ipad_trackpad_is_a_pointer(tree: &Tree) -> Report {
    /// Each capability the Mac half has always had, and what its absence costs the phone half.
    const SEEN: &[(&str, &str)] = &[
        (
            "UIHoverGestureRecognizer",
            "the phone's video surface cannot see a pointer that hovers — a hover produces no UITouch, so \
             without UIHoverGestureRecognizer every hover-only remote surface is unreachable from the phone \
             half (docs/56 §3)",
        ),
        (
            "allowedScrollTypesMask",
            "the phone's video surface cannot see a trackpad's scroll — an iPad's wheel arrives only \
             through a pan recogniser with allowedScrollTypesMask, and that swipe is what the host's \
             swipe-nav fires on (docs/56 §3)",
        ),
        (
            "buttonMask",
            "the phone's video surface synthesizes an indirect pointer's press instead of reading \
             UIEvent.buttonMask — a pointer has real buttons, and forwarding the level rather than the edge \
             strands one down on a process-global host event source (docs/56 §3)",
        ),
        (
            "UIPointerInteraction",
            "the phone's video surface shows two pointers on an iPad — the pane composites the host's \
             cursor, so the LOCAL one must be hidden while it is visible (the Mac's applyLocalCursor, \
             halves swapped)",
        ),
        (
            r"IndirectPointerPlan\.buttonTransitions\(",
            "the phone's video surface diffs an indirect pointer's buttons itself — the edge is \
             IndirectPointerPlan.buttonTransitions(held:mask:), whose bit indices ARE the wire's \
             MouseButton ordinals (docs/55 §6)",
        ),
    ];

    let claims: Vec<Claim> = SEEN
        .iter()
        .map(|(pattern, message)| {
            Claim::Matches {
                path: PHONE_VIDEO,
                pattern,
                message,
            }
        })
        .collect();
    check_all(tree, &claims)
}

/// The pane-move drop is one rule, and both halves only draw what it answers
///
/// `PaneDropGeometry` already stopped the RESOLUTION from having two answers — the canvas's live
/// in-tab hit test and the cross-window INSERT resolution read one gutter. What it did not stop is
/// the other half of the round trip: the preview's rects were `static func`s on a `View`, and BOTH
/// halves had written that math themselves before arriving at the shared file, each under a banner
/// calling it pure. A slab is not layout. It is an assertion about what the commit will do, and two
/// renderers deriving it independently is how one half draws a promise the resolver never keeps.
///
/// So the rules are `slopdesk_workspace::pane_drop` and the Swift is a face over 8 doors. Three
/// things are pinned, because each is a different way for the port to come undone: the doors exist
/// — a face over a deleted door does not compile, but a face that quietly grew its own arithmetic
/// beside them does; the metrics cross — six numbers behind `slopdesk_pane_drop_metric`, never
/// re-declared as Swift literals, because a `static let 0.30` here is a SECOND place the affordance
/// lives, free to drift from the Rust the resolver runs, silently; and both halves read — the Mac's
/// `AppKit` affordance and the phone's `SwiftUI` one each call the face for the slab and the rail,
/// so a half that computes `rect.width / 2` itself is the original bug returning in one framework
/// only, invisible from the other.
///
/// `leaf(at:in:excluding:)` is deliberately NOT pinned as ported: it answers a `PaneID` from
/// `PlacedLeaf`s, so porting it would carry an identity across the ABI only to compare it with the
/// one it came from — `rust/slopdesk-devicepanel`'s charter, and the reason it stayed Swift.
///
/// BREAK-TEST: re-declared `edgeBandFraction` as `0.30` in the Swift face ⇒ FAIL "writes a drop
/// metric down a second time". Separately replaced the phone affordance's `slabRect` call with
/// `rect.width / 2` ⇒ FAIL "draws a re-split preview it computed itself". Separately deleted the
/// Rust module ⇒ FAIL "has no Rust behind it". All restored from /tmp; PASS.
#[must_use]
pub fn the_pane_move_drop_is_one_rule(tree: &Tree) -> Report {
    /// The Swift face over the doors.
    const FACE: &str = "Sources/SlopDeskClientCore/Pane/PaneDropGeometry.swift";
    /// The two affordances that draw the preview.
    ///
    /// ⚠️ THE PHONE ROW RE-AIMED 2026-08-28. `3f11c6e6` took `PaneMoveAffordance.swift` with the
    /// rest of the `SwiftUI` client; docs/62 stage E.2 rebuilds the same drawing as
    /// `PaneMoveAffordanceView.swift`, `UIKit`, in the same directory. Naming the new path leaves
    /// this row RED until that file lands, which is what it should say: a half that is not there
    /// cannot be shown to read the shared answer, and a row pointed at the dead name would report
    /// "is gone" about a subject that was rewritten rather than withdrawn.
    const AFFORDANCES: &[&str] = &[
        "Sources/SlopDeskMacUI/Pane/MacPaneMoveAffordance.swift",
        "Sources/SlopDeskPhoneUI/Pane/PaneMoveAffordanceView.swift",
    ];

    let mut report = check_all(tree, &[
        Claim::Exists {
            path: "rust/slopdesk-workspace/src/pane_drop.rs",
            message: "PaneDropGeometry has no Rust behind it — the pane-move drop is one rule shared by two \
                      resolvers and two renderers (docs/56 increment 82)",
        },
        Claim::Exists {
            path: "rust/slopdesk-ffi/src/pane_drop.rs",
            message: "PaneDropGeometry has no door behind it — the pane-move drop is one rule shared by two \
                      resolvers and two renderers (docs/56 increment 82)",
        },
        Claim::Lacks {
            path: FACE,
            pattern: r"(let|var) +(edgeBandFraction|containerGutterFraction|containerGutterMax|dockRailFraction|dockRailMax|resplitSeamThickness)[^=]*= *[0-9]",
            view: View::Code,
            message: "PaneDropGeometry writes a drop metric down a second time — the six tuned numbers come \
                      through slopdesk_pane_drop_metric, so a literal here is free to drift from the Rust \
                      the resolver runs (docs/56 increment 82)",
        },
        Claim::Matches {
            path: FACE,
            pattern: "slopdesk_pane_drop_metric",
            message: "PaneDropGeometry stopped reading the metrics through their door (docs/56 increment 82)",
        },
    ]);
    for affordance in AFFORDANCES {
        for verb in ["slabRect", "railRect"] {
            report.absorb(check_all(tree, &[Claim::Names {
                path: affordance,
                needle: text::intern(format!("PaneDropGeometry.{verb}")),
                message: "a pane-move affordance draws a re-split preview it computed itself — \
                          PaneDropGeometry.slabRect and .railRect are the shared answer, and a half that \
                          derives its own is the two-frameworks bug returning in one of them only (docs/56 \
                          increment 82)",
            }]));
        }
    }
    report
}

/// The link island is one reading, and nobody keeps a second copy of it
///
/// Four surfaces draw the connection: the Mac's navigator foot and titlebar band in `AppKit`, the
/// phone's navigation toolbar in `SwiftUI`, and the gate card that appears when the link is down.
/// Before this they read a Swift `enum ConnectionReading` and a Swift `enum ConnectionPresenter`,
/// which is one copy — but the copy sat ABOVE the rules crate every other reading had already moved
/// into, and three of the numbers in it (the two ping thresholds, the disk floor) had been written
/// twice already.
///
/// So the rules are `slopdesk_workspace::connection` and both Swift enums are faces. What is pinned
/// is what would let a second copy back in: the doors exist; no threshold literal, because the ping
/// bounds, the disk floor and the megabit switch are `pub const`s in the rules crate and a
/// `static let 80` in either face is a SECOND place the ladder lives; the ceiling ARGUES, because
/// `slopdesk_connection_words` takes `max_attempts` and `ReconnectManager` owns that number in the
/// module that runs the campaign — a Rust `const` beside it would be the "of 20 while the campaign
/// runs to 30" bug with a new place to hide; the words are ONE run, because
/// `ConnectionStatus.label` reads the door's third register rather than switching over the same six
/// states again, and two switches over one enum is how a state comes to be named one thing by the
/// model and another by the toolbar; and both halves read, because a half that formats `"\(ms) ms"`
/// itself is the two-frameworks bug in one of them only, invisible from the other.
///
/// The HOST NAME and the raw failure payload deliberately never cross: the help line is
/// `"Connection: {host} — "` plus what the doors answer, and `has_raw_detail` is a yes/no about the
/// string the caller is already holding — `rust/slopdesk-devicepanel`'s charter, "answers, not
/// identities".
///
/// BREAK-TEST: re-declared `pingGoodMS = 80` in `ConnectionReading` ⇒ FAIL "writes a link threshold
/// down a second time". Separately restored ConnectionStatus.label's own switch ⇒ FAIL "names its
/// states a second time". Separately deleted the Rust module ⇒ FAIL "has no Rust behind it".
/// Separately renamed the `maxReconnectAttempts` argument away ⇒ FAIL "stopped handing the door the
/// supervisor's ceiling". Separately wrote `"\(ms) ms"` into the Mac island ⇒ FAIL "formats a link
/// figure itself". All five restored from /tmp; PASS.
#[must_use]
pub fn the_link_island_is_one_reading(tree: &Tree) -> Report {
    /// The reading's face.
    const READING: &str = "Sources/SlopDeskClientCore/Chrome/ConnectionReading.swift";
    /// The presenter's.
    const PRESENTER: &str = "Sources/SlopDeskWorkspaceCore/Connection/ConnectionPresenter.swift";
    /// The state enum whose `label` is the door's third register.
    const STATUS: &str = "Sources/SlopDeskWorkspaceCore/Connection/ConnectionStatus.swift";
    /// The two shells' islands.
    ///
    /// ⚠️ THE PHONE ROW RE-AIMED 2026-08-28, and the file naming settled with it: the phone's link
    /// island returns as `ConnectionIslandView.swift` (`UIKit`), which is the Mac's own noun rather
    /// than the `SwiftUI` half's "pill". Red until it lands. That is the correct verdict for a rule
    /// whose whole subject is *both* halves reading one ladder — with one half absent there is no
    /// second reading to compare, and saying so beats a green over a list of one.
    const ISLANDS: &[&str] = &[
        "Sources/SlopDeskMacUI/Chrome/MacConnectionIsland.swift",
        "Sources/SlopDeskPhoneUI/Chrome/ConnectionIslandView.swift",
    ];

    let mut report = check_all(tree, &[
        Claim::Exists {
            path: "rust/slopdesk-workspace/src/connection.rs",
            message: "ConnectionReading has no Rust behind it — the link island is one reading drawn by \
                      four surfaces (docs/56 increment 83)",
        },
        Claim::Exists {
            path: "rust/slopdesk-ffi/src/connection.rs",
            message: "ConnectionReading has no door behind it — the link island is one reading drawn by \
                      four surfaces (docs/56 increment 83)",
        },
        Claim::NoneOf {
            paths: &[READING, PRESENTER],
            pattern: r"(let|var) +(pingGoodMS|pingSlowMS|diskWarnMiB|diskCriticalMiB|mbpsThreshold[A-Za-z]*)[^=]*= *[0-9]",
            view: View::Code,
            message: "a link face writes a threshold down a second time — the ping bounds, the disk floor \
                      and the megabit switch are consts in slopdesk_workspace::connection, so a literal \
                      here is free to drift from the Rust that classifies with it (docs/56 increment 83)",
        },
        Claim::Matches {
            path: PRESENTER,
            pattern: "maxReconnectAttempts",
            message: "ConnectionPresenter stopped handing the door the supervisor's ceiling — \
                      ReconnectManager owns that number, and a Rust const beside it is the \"of 20 while \
                      the campaign runs to 30\" bug with a new place to hide (docs/56 increment 83)",
        },
        Claim::Lacks {
            path: STATUS,
            pattern: r#"case \.connecting: "connecting""#,
            view: View::Code,
            message: "ConnectionStatus names its states a second time — .label is \
                      slopdesk_connection_words' third register, and two switches over one enum is how a \
                      state gets named one thing by the model and another by the toolbar (docs/56 increment \
                      83)",
        },
    ]);
    for island in ISLANDS {
        report.absorb(check_all(tree, &[
            Claim::Matches {
                path: island,
                pattern: r"ConnectionReading\.",
                message: "a link island stopped reading through ConnectionReading — a shell that formats \
                          its own ping or status word is the two-frameworks bug in one of them only \
                          (docs/56 increment 83)",
            },
            Claim::Lacks {
                path: island,
                pattern: r#""\\\(.*\) ms"|Mbps""#,
                view: View::Code,
                message: "a link island formats a link figure itself — the ping and the bitrate are \
                          slopdesk_workspace::connection's, so one shell writing its own is a reading the \
                          other cannot see change (docs/56 increment 83)",
            },
        ]));
    }
    report
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A mirror with `forwards` calls to `super.pressesBegan`.
    fn mirror(fixture: &Fixture, forwards: usize) {
        let mut body = String::from(
            "final class PhoneAndroidScreenView: UIView {\n\x20   func attach() { \
             DeviceSoftKeyboard.shared.register(self) }\n",
        );
        for _ in 0..forwards {
            body.push_str("        super.pressesBegan(presses, with: event)\n");
        }
        body.push_str("}\n");
        for path in super::MIRRORS {
            fixture.write(path, &body);
        }
        for path in super::STAGES {
            fixture.write(path, "Button { DeviceSoftKeyboard.shared.toggle() }\n");
        }
    }

    #[test]
    fn a_mirror_that_forwards_once_is_red() {
        let fixture = Fixture::new("mirror-forwards");
        // Two forwards: one in the early guard, one in the arm that used to drop the press.
        mirror(&fixture, 2);
        assert!(super::a_mirrored_device_takes_typed_text(&fixture.tree()).is_clean());

        // The bug a present-or-absent rule would have passed: the early guard still forwards, and
        // the unmapped arm went back to `break`.
        mirror(&fixture, 1);
        assert!(!super::a_mirrored_device_takes_typed_text(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_mirror_that_cannot_be_typed_into_is_red() {
        // Its own fixture, because writes accumulate and this case drops a whole call.
        let fixture = Fixture::new("mirror-keyboard");
        mirror(&fixture, 2);
        for path in super::STAGES {
            fixture.write(path, "Button { model.rotate() }\n");
        }
        assert!(!super::a_mirrored_device_takes_typed_text(&fixture.tree()).is_clean());
    }

    /// The paste plate's property, with whatever `body` reads inside it.
    fn paste_plate(fixture: &Fixture, inside: &str) {
        fixture.write(
            super::PHONE_GUI_LEAF,
            &format!(
                "struct GuiPastePlateMenu: View {{\n    var canPasteCurrent: Bool {{\n\
                 \x20       {inside}\n    }}\n\n\
                 \x20   var body: some View {{\n\
                 \x20       Button(\"Paste\") {{ store.currentLocalClipboard() }}\n    }}\n}}\n"
            ),
        );
    }

    #[test]
    fn a_paste_plate_that_reads_content_from_a_render_is_red() {
        let fixture = Fixture::new("paste-plate");
        paste_plate(
            &fixture,
            "ClipboardPasteMenu.canPaste(clipboardHasText: store.localClipboardHasText())",
        );
        // The content read inside the Button's action is correct and deliberately untouched — the
        // tap IS the paste — which is why both claims are scoped to the property.
        assert!(super::the_paste_plate_asks_a_silent_question(&fixture.tree()).is_clean());

        // The revert: enablement asks the board for its contents, once per render.
        paste_plate(
            &fixture,
            "ClipboardPasteMenu.isPastable(store.currentLocalClipboard())",
        );
        assert!(!super::the_paste_plate_asks_a_silent_question(&fixture.tree()).is_clean());
    }

    /// The tab strip is minted from `PanelTabs`, in either framework, over a corpus that exists.
    ///
    /// The break-test for the 2026-08-28 re-aim. Three things it has to hold: the `UIKit` minting
    /// passes where the old `ForEach` needle would have failed it, a hand-listed strip is still
    /// red, and a DRAINED `Panel/` is red rather than silently unchecked.
    ///
    /// The subject moved with the second re-aim, and the fixture with it: the minting is the tab
    /// GROUP's, not the root's. A fixture that kept writing `PHONE_ROOT` would have proved the rule
    /// against a file the claim no longer reads — a green over nothing, which is the exact failure
    /// this module's header is about.
    #[test]
    fn a_hand_listed_panel_strip_is_red_in_either_framework() {
        let fixture = Fixture::new("panel-named-surface");
        fixture
            .write(
                super::PHONE_TAB_GROUP,
                "plates = PanelTabs.all.map(PhonePanelTabPlate.init(tab:))\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhonePanelViewController.swift",
                "label.accessibilityLabel = tab.accessibilityLabel\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/DevicePanelChrome.swift",
                "enum DevicePanelChrome {}\n",
            );
        assert!(super::the_panel_opens_on_a_named_surface(&fixture.tree()).is_clean());

        // Hand-listed instead of minted — the capability the Mac rail has and the phone would lose.
        fixture.write(
            super::PHONE_TAB_GROUP,
            "plates = [PanelTab.code, PanelTab.simulator].map(PhonePanelTabPlate.init(tab:))\n",
        );
        assert!(!super::the_panel_opens_on_a_named_surface(&fixture.tree()).is_clean());

        // The demolition's own shape: the ban's corpus drains and nothing is checked.
        fixture.write(
            super::PHONE_TAB_GROUP,
            "plates = PanelTabs.all.map(PhonePanelTabPlate.init(tab:))\n",
        );
        fixture.remove("Sources/SlopDeskPhoneUI/Panel/PhonePanelViewController.swift");
        fixture.remove("Sources/SlopDeskPhoneUI/Panel/DevicePanelChrome.swift");
        let report = super::the_panel_opens_on_a_named_surface(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|line| line.contains("reads an empty tree and passes"))
        );
    }

    #[test]
    fn an_inline_clear_key_is_red_and_the_chrome_is_not() {
        let fixture = Fixture::new("clear-key");
        fixture
            .write(
                super::PANEL_CHROME,
                "enum PhoneDevicePanelChrome {\n    static func clearKey() -> UIControl {\n\x20       \
                 UIImage(systemName: SFSymbol.xmarkCircleFill.rawValue)\n    }\n}\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorDeviceList.swift",
                "clear = PhoneDevicePanelChrome.clearKey(ink: .icon) { clearAction?() }\n",
            );
        for console in super::CONSOLES {
            fixture.write(
                console,
                "clear = PhoneDevicePanelChrome.clearKey(ink: .icon) { clearAction?() }\n",
            );
        }
        assert!(super::one_clear_key_per_filter_field(&fixture.tree()).is_clean());

        // The copy that made two of the four go missing. The exemption is on the CORPUS, so the
        // chrome's own spelling cannot hide a leak behind it.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorDeviceList.swift",
            "Button { query = \"\" } label: { Image(systemSymbol: .xmarkCircleFill) }\n",
        );
        let found = super::one_clear_key_per_filter_field(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("PhoneSimulatorDeviceList"))
        );

        // The SHIPPED UIKit spelling, which neither earlier needle could see: the initialiser is
        // `systemName:`, the glyph arrives through the symbol enum, and the two are not adjacent.
        // A needle written against the call site would go blind here for a third time.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorDeviceList.swift",
            "clear.setImage(\n    UIImage(\n        systemName: SFSymbol.xmarkCircleFill.rawValue,\n\x20   \
             ),\n    for: .normal,\n)\n",
        );
        let found = super::one_clear_key_per_filter_field(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("PhoneSimulatorDeviceList"))
        );
    }

    /// A drained panel target fails the clear-key ban rather than satisfying it.
    ///
    /// The break-test for the demolition: with `Panel/` empty, `NoneUnder` names no offender and
    /// the rule reads clean while checking nothing.
    #[test]
    fn a_drained_panel_target_fails_the_clear_key_ban() {
        let fixture = Fixture::new("clear-key-drained");
        fixture.write(
            super::PANEL_CHROME,
            "enum PhoneDevicePanelChrome {\n    static func clearKey() {}\n}\n",
        );
        for console in super::CONSOLES {
            fixture.write(console, "PhoneDevicePanelChrome.clearKey\n");
        }
        assert!(super::one_clear_key_per_filter_field(&fixture.tree()).is_clean());

        fixture.remove(super::PANEL_CHROME);
        for console in super::CONSOLES {
            fixture.remove(console);
        }
        let report = super::one_clear_key_per_filter_field(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|line| line.contains("reads an empty tree and passes"))
        );
    }

    #[test]
    fn a_console_that_cannot_clear_its_filter_is_red() {
        // Its own fixture: a console with no clear key at all, beside a list that has one.
        let fixture = Fixture::new("clear-key-console");
        fixture.write(
            super::PANEL_CHROME,
            "enum DevicePanelChrome {\n    static func clearKey() -> some View { EmptyView() }\n}\n",
        );
        for console in super::CONSOLES {
            fixture.write(console, "SlateSearchField(text: $filter)\n");
        }
        assert!(!super::one_clear_key_per_filter_field(&fixture.tree()).is_clean());
    }
}
