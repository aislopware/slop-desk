// DispatcherTextBindingTests — the ClientUI half of the dispatcher's text-binding / unbind branch:
// the `KeyChordNormalizer` → `WorkspaceBindingRegistry.textBinding(for:)` / `isUnbound(_:)` chain the live
// `WorkspaceKeyDispatcher.handle` walks BEFORE the action table. Exercised headlessly — the normalizer is
// AppKit-free (takes the destructured NSEvent fields), so no `NSEvent` / monitor is constructed and the
// resolution is provable without a window server. This pins that a keystroke the dispatcher would see
// (normalized from raw NSEvent fields) resolves the SAME persisted-chord-keyed text binding / unbind the
// config parser stored — i.e. the reverse chord bridge lines up end to end at the ClientUI boundary.
//
// FAILS without `textBinding(for:)` / `isUnbound(_:)` (the dispatcher would have no
// literal-byte / unbind branch).

#if os(macOS)
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DispatcherTextBindingTests: XCTestCase {
    override func tearDown() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        super.tearDown()
    }

    private func mods(
        shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false,
    ) -> KeyChordNormalizer.Modifiers {
        .init(shift: shift, control: control, option: option, command: command)
    }

    /// A ⌘⇧H keystroke (normalized exactly as the dispatcher normalizes it, from the raw NSEvent fields)
    /// resolves the `text:hi` config binding stored on that chord — so the dispatcher would inject `[h, i]`
    /// via `sendBytes`. This proves the `KeyChordNormalizer` → reverse-bridge → `textBindings` lookup the
    /// dispatcher's passthrough branch performs lines up with what `KeybindGrammar` persisted.
    func testNormalizedKeystrokeResolvesTextBinding() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            textBindings: [
                .init(key: "h", command: true, shift: true): .init(kind: .text, payload: [0x68, 0x69]),
            ],
        )
        guard let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "H", keyCode: 4, modifierFlags: mods(shift: true, command: true),
        ) else {
            XCTFail("⌘⇧H should normalize to a chord")
            return
        }
        XCTAssertEqual(WorkspaceBindingRegistry.textBinding(for: chord)?.payload, [0x68, 0x69])
    }

    /// A named-key keystroke (⇧PageUp, normalized from keyCode 116) resolves a `csi:` binding stored under
    /// the `pageup` token — the named-key bridge (registry `.pageUp` → persisted `"pageup"`) round-trips, so
    /// a config binding on a named key reaches the dispatcher's injection branch.
    func testNamedKeyKeystrokeResolvesCSIBinding() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            textBindings: [
                .init(key: "pageup", shift: true): .init(kind: .csi, payload: [0x1B, 0x5B, 0x35, 0x7E]),
            ],
        )
        guard let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: nil, keyCode: 116, modifierFlags: mods(shift: true),
        ) else {
            XCTFail("⇧PageUp should normalize to a chord")
            return
        }
        XCTAssertEqual(WorkspaceBindingRegistry.textBinding(for: chord)?.payload, [0x1B, 0x5B, 0x35, 0x7E])
    }

    /// A ⌘D keystroke that the user `unbind:`'d reports `isUnbound == true` at the normalized chord — so the
    /// dispatcher passes the event through (suppressing the split-right default) instead of firing it.
    func testNormalizedKeystrokeIsRecognisedAsUnbound() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            unbinds: [.init(key: "d", command: true)],
        )
        guard let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "d", keyCode: 2, modifierFlags: mods(command: true),
        ) else {
            XCTFail("⌘D should normalize to a chord")
            return
        }
        XCTAssertTrue(WorkspaceBindingRegistry.isUnbound(chord))
    }

    /// With no overrides set, a normalized keystroke is neither a text binding nor an unbind — the dispatcher
    /// then falls through to the action table / passthrough exactly as before (no behaviour change at rest).
    func testNoOverridesIsACleanMiss() {
        guard let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: "h", keyCode: 4, modifierFlags: mods(shift: true, command: true),
        ) else {
            XCTFail("⌘⇧H should normalize to a chord")
            return
        }
        XCTAssertNil(WorkspaceBindingRegistry.textBinding(for: chord))
        XCTAssertFalse(WorkspaceBindingRegistry.isUnbound(chord))
    }
}
#endif
