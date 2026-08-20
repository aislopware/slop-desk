// OverlayKeyRepeat — which keys AUTO-REPEAT while held on a floating card, and which fire once per press.
//
// SwiftUI's `.onKeyPress` listens to the `.down` phase only unless a view asks for more, so every list on
// these cards moved its selection exactly once no matter how long the arrow was held: to walk ten rows you
// pressed ↓ ten times. Every other list on the platform — and every palette the user compares this one to —
// walks while you hold the key.
//
// Admitting `.repeat` wholesale is not the fix, because the pickers route their WHOLE keyboard through one
// catch-all handler (``OpenQuicklyView`` owns ⌘1–9, ⌘K, ⌘W/⌘R/⌘Z…, Tab there). A held ⌘3 would then open the
// third row again every 30ms. So repeat is a WHITELIST: the keys that MOVE a selection repeat, and everything
// else is a one-shot whose repeats are swallowed (swallowed, not ignored — an ignored press walks on to the
// responder chain and gets an alert beep).
//
// Pure and view-free, so ``OverlayKeyRepeatTests`` pins the policy without a card or an NSEvent.

#if os(iOS)
import SwiftUI

enum OverlayKeyRepeat {
    /// The phases a card's key handler should subscribe to: a press, and the repeats the system sends while
    /// it is held.
    static let phases: KeyPress.Phases = [.down, .repeat]

    /// Whether `key` may act again on each auto-repeat. Movement keys do (they are how a held arrow walks
    /// a list); everything else — a chord that opens something, a toggle, Tab — acts once per press.
    static func repeatsWhileHeld(_ key: KeyEquivalent) -> Bool {
        switch key.character {
        case KeyEquivalent.upArrow.character,
             KeyEquivalent.downArrow.character,
             KeyEquivalent.pageUp.character,
             KeyEquivalent.pageDown.character:
            true
        default:
            false
        }
    }

    /// Whether a press should be ACTED ON: a first `.down` always is; a `.repeat` only for a movement key.
    /// A caller that gets `false` should return `.handled` (swallow), not `.ignored`.
    static func admits(key: KeyEquivalent, isRepeat: Bool) -> Bool {
        !isRepeat || repeatsWhileHeld(key)
    }

    /// The live-`KeyPress` spelling of ``admits(key:isRepeat:)``.
    static func admits(_ press: KeyPress) -> Bool {
        admits(key: press.key, isRepeat: press.phase.contains(.repeat))
    }
}
#endif
