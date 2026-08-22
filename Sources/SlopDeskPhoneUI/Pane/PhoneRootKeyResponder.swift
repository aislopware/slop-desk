// PhoneRootKeyResponder — the phone's workspace chords, at the END of the responder chain.
//
// It is the other rung of the key path whose near end is ``TerminalInputHost``, which is why it sits
// beside it. That one is the FOCUSED PANE's responder and it resolves a bound chord off the pane's
// own ``TerminalKeyInterceptor``; this one is the chain's LAST responder and resolves the same table
// when nothing in front of it wanted the press. Between them the phone answers ⌘⇧P, ⌘T, ⌘D, ⌘1–9,
// ⌃⇥ and ⌘⇧O wherever the keyboard happens to be — over a desktop/GUI pane, with no pane focused at
// all, under the panel's cover — instead of only while a terminal pane holds it.
//
// ## Why the app DELEGATE, and not a view
//
// The rung has to be an ANCESTOR of every first responder the workspace can have, and on this
// platform there is exactly one such place. A SwiftUI `.background`/`.overlay` representable is a
// SIBLING of the content in the UIKit tree, not an ancestor, so a `UIView` mounted at the root is
// simply absent from the chain a focused terminal walks. `UIApplication` and then the app delegate
// ARE that chain's tail by construction, for every window and every responder in the process.
//
// That shape is also what keeps the rule small (``PhoneRootKeyPolicy``): the Mac's `NSEvent` monitor
// PREEMPTS the chain and pays for it with one hand-written yield per surface it would otherwise
// steal keys from, while a tail rung yields to every one of them by simply being last. Two surfaces
// the chain cannot speak for keep a gate — a summoned overlay whose focused field walks ⌘-chords
// past itself, and the panel's full-screen cover — and nothing else needs one.
//
// ## What it deliberately does NOT do
//
// It never touches a BARE key. A press that resolves to no chord in the table is forwarded, so
// typing that arrives here (a text field that declined it, a pane with no responder) is still the
// system's. It does not repeat: a held ⌘D that split twenty times a second is not what holding ⌘D
// means, which is the same argument ``TerminalInputHostView/swallowsAsWorkspaceChord(_:)`` makes.
// And it sends no literal-byte `text:` binding — those are terminal INPUT and belong to the pane
// that has the keyboard, not to a rung that runs when no pane does.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import UIKit

/// The app delegate, which exists only to be the responder chain's tail.
///
/// `SlopDeskPhoneApp` names it in its `@UIApplicationDelegateAdaptor`, and that is the whole of its
/// lifecycle: SwiftUI builds it, the scene points it at the live composition on appear, and it holds
/// nothing else. Every application-lifecycle callback is deliberately absent — the phone's
/// foreground/background fan-out is `scenePhase`'s in ``SlopDeskPhoneApp`` and must stay there,
/// where it can await the previous phase's task.
@MainActor
final class PhoneRootKeyResponder: UIResponder, UIApplicationDelegate {
    /// The live workspace. Weak: the composition owns it for the process's life, and a delegate that
    /// outlived a scene must go inert rather than drive a workspace nothing is showing.
    private weak var store: WorkspaceStore?
    /// The overlay coordinator, read for ONE question — whether a summoned card owns the keyboard.
    private weak var overlay: OverlayCoordinator?
    /// The chrome flags, read for ONE question — whether the panel's cover is up.
    private weak var chrome: WorkspaceChromeState?

    /// The pane's own interceptor, at root scope: the same override-aware table, the same `route`
    /// sink, minted by the store so there is one resolve-and-dispatch in the app rather than two.
    /// Built on first attach because it needs the store.
    private var interceptor: TerminalKeyInterceptor?

    /// The rung THIS press landed on, resolved once at the top of ``take(_:)`` and read back by the
    /// interceptor's filter. A stored beat rather than a second derivation: the rung's third input
    /// walks every connected scene's windows, and asking it twice per keystroke is a walk this rung
    /// has no reason to pay for.
    private var pressRung: PhoneRootKeyRung = .workspace

    override init() { super.init() }

    /// Point the rung at the live composition. Idempotent — the scene calls it on appear, and a
    /// second call with the same store re-uses the interceptor rather than minting another.
    func attach(store: WorkspaceStore, overlay: OverlayCoordinator, chrome: WorkspaceChromeState) {
        let changed = self.store !== store
        self.store = store
        self.overlay = overlay
        self.chrome = chrome
        guard changed || interceptor == nil else { return }
        // The FILTER is read at resolve time, so one interceptor serves both rungs the policy can
        // put this responder on: under the cover it spends only what gives the keyboard back.
        interceptor = store.makeKeyInterceptor(allowing: { [weak self] action in
            self?.pressRung != .panelEscape || CodePanelKeyYield.survives(action)
        })
    }

    // MARK: The tail of the chain

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, take(PhoneKey.Press(key)) else {
                unhandled.insert(press)
                continue
            }
        }
        // Anything this rung did not spend still belongs to whatever is behind it (nothing, here) —
        // forwarded rather than dropped, so the chain's contract is unchanged for every other key.
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    /// Takes the press, or reports that it was never ours.
    private func take(_ press: PhoneKey.Press) -> Bool {
        guard let store else { return false }
        pressRung = rung
        switch pressRung {
        case .yield:
            return false
        case .panelEscape:
            // No ⌃⇥ walk under the cover: the card it draws is over the workspace the cover is
            // covering, and stepping it would move a focus the reader cannot see land.
            return swallowsAsWorkspaceChord(press)
        case .workspace:
            // The walk is asked FIRST, exactly as it is in the pane's responder and in the Mac's
            // monitor: one key means open, step or commit depending on whether the walk is already
            // up, which no table row can say.
            if store.takePaneSwitcherKey(press) { return true }
            return swallowsAsWorkspaceChord(press)
        }
    }

    /// Which rung the live state puts this press on. Read per press — a cover can be dismissed and a
    /// card raised between two keystrokes, and a remembered copy would answer for a screen that is
    /// gone.
    private var rung: PhoneRootKeyRung {
        PhoneRootKeyPolicy.rung(
            panelPresented: chrome.map { !$0.codeSidebarCollapsed } ?? false,
            overlayCapturesKeyboard: overlay?.capturesKeyboardWhileVisible ?? false,
            systemPresentationUp: Self.systemPresentationUp(),
        )
    }

    /// Whether the workspace's binding table claims this press, through the interceptor the store
    /// minted. A refused chord forwards; a claimed one has already been routed by the time this
    /// returns.
    private func swallowsAsWorkspaceChord(_ press: PhoneKey.Press) -> Bool {
        guard let chord = PhoneKey.keyChord(for: press),
              let interceptor,
              case .swallow = interceptor.intercept(chord)
        else { return false }
        return true
    }

    /// Whether anything is presented over the workspace — Settings, the first-launch checklist, the
    /// cheat sheet.
    ///
    /// Asked of UIKit rather than of three `@State` flags, and that is the honest source: they are
    /// PRESENTATIONS, so the presenter already records them, and a flag threaded up here would be a
    /// second copy of a fact the window manager keeps. It reports the panel's cover too — which is
    /// why ``PhoneRootKeyPolicy`` asks about the cover first.
    private static func systemPresentationUp() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }
}
#endif
