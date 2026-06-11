#if canImport(SwiftUI)
import SwiftUI

// MARK: - KeyChord → SwiftUI bridge

/// Pure adapters from the framework-neutral ``KeyChord`` to SwiftUI's `KeyboardShortcut` family.
/// This file is the ONLY place that depends on SwiftUI — ``KeyChord`` itself stays SwiftUI-free
/// (`KeyChord.swift` deliberately imports no UI framework so it is `Hashable`-keyable and unit-
/// testable with no view). Keeping the bridge `nonisolated` means the menu builders can derive a
/// shortcut from ``CommandInterpreter/defaultBindings`` without re-declaring chords by hand, so the
/// keyboard mapping has a single source of truth (docs/22 §5).
extension KeyChord.Key {
    /// The native `KeyEquivalent` for this key token. Printable characters map straight through (the
    /// chord already carries case via ``KeyChord/Modifiers/shift``, so the lower-cased base char is
    /// correct); named keys map to their SwiftUI constants.
    nonisolated var keyEquivalent: KeyEquivalent {
        switch self {
        case let .character(c): return KeyEquivalent(c)
        case .tab:        return .tab
        case .return:     return .return
        case .leftArrow:  return .leftArrow
        case .rightArrow: return .rightArrow
        case .upArrow:    return .upArrow
        case .downArrow:  return .downArrow
        }
    }
}

extension KeyChord.Modifiers {
    /// The native `EventModifiers` for this modifier set — the union of the flags that are present.
    nonisolated var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.shift)   { out.insert(.shift) }
        if contains(.control) { out.insert(.control) }
        if contains(.option)  { out.insert(.option) }
        if contains(.command) { out.insert(.command) }
        return out
    }
}

extension KeyChord {
    /// The native `KeyboardShortcut` for this chord — the key equivalent plus its modifier set.
    nonisolated var shortcut: KeyboardShortcut {
        KeyboardShortcut(key.keyEquivalent, modifiers: modifiers.eventModifiers)
    }
}
#endif
