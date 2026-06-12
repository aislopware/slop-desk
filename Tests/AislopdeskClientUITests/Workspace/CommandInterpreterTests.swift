import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The ``CommandInterpreter`` is the pure chord → ``WorkspaceCommand`` mapping (docs/22 §5): the
/// single tested core that the macOS menu bar, the iPad `UIKeyCommand` layer, and the compact
/// on-screen affordances all funnel through. These tests pin:
///
/// - **Every shipped default binding** resolves to the exact command (the load-bearing fact that
///   ⌘T adds a pane, ⌥⌘← moves focus, ⌃⌘G makes a group, etc.).
/// - **The case-insensitivity convention** — `KeyChord(character:)` lower-cases the base key, so
///   ⇧ is carried only by `.shift`; `"D"` and `"d"` are the same chord, and ⇧⌘D needs an explicit
///   `.shift` rather than an upper-case letter.
/// - **Unbound chords fall through** (`feed` returns `nil`) — the §5 conflict rule that lets plain
///   keys reach the focused terminal untouched.
/// - **Rebinding works** — both by mutating `bindings` and by injecting a custom table at init.
/// - **The SwiftUI bridge round-trips** — every default chord derives the native
///   `KeyboardShortcut` the menu bar applies (`KeyChord+SwiftUI`), so the menu and the interpreter
///   share one source of truth and the §5 ⌘/⌥-prefix conflict rule survives the translation.
///
/// `CommandInterpreter` is `@MainActor`, so the whole suite is `@MainActor` (still synchronous —
/// no async, no client, no store).
@MainActor
final class CommandInterpreterTests: XCTestCase {

    // MARK: - Every default binding maps to the expected command

    /// Table-driven assertion over the entire shipped default binding set. If a default chord is
    /// renamed, retargeted, or dropped, this fails on the exact entry — the bindings are a public
    /// contract (menu shortcuts, muscle memory), so they are pinned individually.
    func testDefaultBindingsMapToExpectedCommands() {
        let interpreter = CommandInterpreter()

        let expected: [(KeyChord, WorkspaceCommand)] = [
            // Canvas: new pane / tidy.
            (KeyChord(character: "t", [.command]),                 .newPane(.terminal)),
            (KeyChord(character: "d", [.command, .shift]),         .tidy),
            // Centre camera on the focused pane / on all panes.
            (KeyChord(character: "c", [.option, .command]),        .centerFocusedPane),
            (KeyChord(character: "c", [.option, .command, .shift]), .centerAll),
            // Close the focused pane.
            (KeyChord(character: "w", [.command]),                 .closePane),
            // New group.
            (KeyChord(character: "g", [.control, .command]),       .newGroup),
            // Geometric focus.
            (KeyChord(.leftArrow, [.option, .command]),            .focus(.left)),
            (KeyChord(.rightArrow, [.option, .command]),           .focus(.right)),
            (KeyChord(.upArrow, [.option, .command]),              .focus(.up)),
            (KeyChord(.downArrow, [.option, .command]),            .focus(.down)),
            // Cycle focus.
            (KeyChord(character: "]", [.command]),                 .cycleFocus(forward: true)),
            (KeyChord(character: "[", [.command]),                 .cycleFocus(forward: false)),
            // Zoom + rename.
            (KeyChord(.return, [.command, .shift]),                .toggleZoom),
            (KeyChord(character: "r", [.command]),                 .renamePane),
            // Reconnect the focused pane (primary failure recovery) — ⇧⌘R, distinct from ⌘R rename.
            (KeyChord(character: "r", [.command, .shift]),         .reconnectPane)
        ]

        for (chord, command) in expected {
            XCTAssertEqual(interpreter.feed(chord), command, "chord \(chord) must map to \(command)")
        }
    }

    // MARK: - Case-insensitivity convention (⇧ is in modifiers, not the char)

    /// `KeyChord(character:)` lower-cases the base key, so an upper-case letter without `.shift` is
    /// the same chord as the lower-case one — `⌘T` (typed with caps) still maps to `.newPane`,
    /// it is NOT mistaken for ⇧⌘T.
    func testUpperCaseCharIsNormalizedToLowerCaseBaseKey() {
        let interpreter = CommandInterpreter()
        XCTAssertEqual(
            KeyChord(character: "T", [.command]),
            KeyChord(character: "t", [.command]),
            "the convenience init lower-cases the base key — case is not part of identity"
        )
        XCTAssertEqual(interpreter.feed(KeyChord(character: "T", [.command])), .newPane(.terminal))
        // Tidy requires an EXPLICIT .shift, not an upper-case char.
        XCTAssertEqual(interpreter.feed(KeyChord(character: "D", [.command, .shift])), .tidy)
        XCTAssertEqual(
            interpreter.feed(KeyChord(character: "d", [.command, .shift])),
            .tidy,
            "shift is carried by the modifier set, identically for 'd' and 'D'"
        )
    }

    // MARK: - Unbound chords fall through (nil)

    /// A chord that is not in the table returns `nil` — the interpreter consumes nothing it does
    /// not own, so plain keys reach the focused terminal (the §5 terminal-conflict rule).
    func testUnboundChordReturnsNil() {
        let interpreter = CommandInterpreter()
        // A bare letter (no ⌘/⌥) is never a workspace chord — it belongs to the terminal.
        XCTAssertNil(interpreter.feed(KeyChord(character: "a")))
        // A bound base key with the WRONG modifiers is also unbound.
        XCTAssertNil(interpreter.feed(KeyChord(character: "t")), "⌘ is required — bare 't' falls through")
        XCTAssertNil(interpreter.feed(KeyChord(character: "t", [.control])), "⌃T is not a workspace chord")
        // A named key with no binding.
        XCTAssertNil(interpreter.feed(KeyChord(.return)))
        // A digit chord is not bound (⌘1…⌘9 tab-select is gone).
        XCTAssertNil(interpreter.feed(KeyChord(character: "1", [.command])))
    }

    // MARK: - Rebinding

    /// Mutating `bindings` at runtime takes effect on the next `feed` (a settings screen can rebind
    /// live); the old chord stops resolving and the new chord resolves to the remapped command.
    func testRebindingViaMutableBindingsTakesEffect() {
        let interpreter = CommandInterpreter()
        XCTAssertEqual(interpreter.feed(KeyChord(character: "t", [.command])), .newPane(.terminal))

        // Remap ⌘T to newGroup and drop the old meaning.
        interpreter.bindings[KeyChord(character: "t", [.command])] = .newGroup
        XCTAssertEqual(interpreter.feed(KeyChord(character: "t", [.command])), .newGroup, "rebind takes effect")

        // Remove a binding entirely → it falls through.
        interpreter.bindings[KeyChord(character: "w", [.command])] = nil
        XCTAssertNil(interpreter.feed(KeyChord(character: "w", [.command])), "removed binding falls through")
    }

    /// A fully custom table injected at init replaces the defaults wholesale — only the supplied
    /// chords resolve, everything else falls through.
    func testCustomBindingsAtInitReplaceDefaults() {
        let custom: [KeyChord: WorkspaceCommand] = [
            KeyChord(character: "x", [.command]): .closePane
        ]
        let interpreter = CommandInterpreter(bindings: custom)
        XCTAssertEqual(interpreter.feed(KeyChord(character: "x", [.command])), .closePane)
        // A DEFAULT chord is NOT present because the custom table replaced the defaults.
        XCTAssertNil(interpreter.feed(KeyChord(character: "t", [.command])), "custom table replaces, not merges")
    }

    /// `defaultBindings` is a COMPUTED property — each access rebuilds a fresh, equal table. Pin
    /// that (a) it is non-empty, (b) two accesses are equal, and (c) mutating an interpreter's copy
    /// does not leak back into the static default.
    func testDefaultBindingsIsFreshlyRebuiltAndIsolated() {
        let a = CommandInterpreter.defaultBindings
        let b = CommandInterpreter.defaultBindings
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b, "defaultBindings is deterministic across accesses")

        let interpreter = CommandInterpreter()
        interpreter.bindings.removeAll()
        XCTAssertTrue(interpreter.bindings.isEmpty)
        XCTAssertFalse(CommandInterpreter.defaultBindings.isEmpty, "mutating an instance does not corrupt the static default")
    }

    // MARK: - SwiftUI bridge (KeyChord → KeyboardShortcut) — one source of truth

    #if canImport(SwiftUI)
    /// Every shipped default chord derives a native `KeyboardShortcut` whose key + modifiers match
    /// the chord exactly. This is the load-bearing fact behind ``WorkspaceCommands`` deriving its
    /// menu shortcuts from ``CommandInterpreter/defaultBindings`` instead of re-declaring them: if
    /// the adapter dropped or garbled any chord, the menu would silently lose / misbind a shortcut.
    func testKeyChordAdapterRoundTripsEveryDefaultBinding() {
        for (chord, _) in CommandInterpreter.defaultBindings {
            let shortcut = chord.shortcut
            XCTAssertEqual(
                shortcut.key, chord.key.keyEquivalent,
                "chord \(chord) must derive a shortcut with the matching key equivalent"
            )
            XCTAssertEqual(
                shortcut.modifiers, chord.modifiers.eventModifiers,
                "chord \(chord) must derive a shortcut with the matching modifiers"
            )
        }
    }

    /// Each ``KeyChord/Modifiers`` flag maps to its native `EventModifiers` counterpart, and the set
    /// is the union of present flags — a composed chord (⌥⌘) yields both, an empty set yields none.
    func testAdapterModifierMapMatchesEachFlag() {
        XCTAssertEqual(KeyChord.Modifiers([]).eventModifiers, [])
        XCTAssertEqual(KeyChord.Modifiers([.shift]).eventModifiers, .shift)
        XCTAssertEqual(KeyChord.Modifiers([.control]).eventModifiers, .control)
        XCTAssertEqual(KeyChord.Modifiers([.option]).eventModifiers, .option)
        XCTAssertEqual(KeyChord.Modifiers([.command]).eventModifiers, .command)
        XCTAssertEqual(
            KeyChord.Modifiers([.option, .command]).eventModifiers,
            [.option, .command],
            "composed modifier sets union their native flags"
        )
        XCTAssertEqual(
            KeyChord.Modifiers([.shift, .control, .option, .command]).eventModifiers,
            [.shift, .control, .option, .command]
        )
    }

    /// The named (non-printable) keys the workspace binds map to their SwiftUI `KeyEquivalent`
    /// constants, and a printable character passes through unchanged.
    func testAdapterNamedKeysMapToNativeEquivalents() {
        XCTAssertEqual(KeyChord.Key.tab.keyEquivalent, .tab)
        XCTAssertEqual(KeyChord.Key.return.keyEquivalent, .return)
        XCTAssertEqual(KeyChord.Key.leftArrow.keyEquivalent, .leftArrow)
        XCTAssertEqual(KeyChord.Key.rightArrow.keyEquivalent, .rightArrow)
        XCTAssertEqual(KeyChord.Key.upArrow.keyEquivalent, .upArrow)
        XCTAssertEqual(KeyChord.Key.downArrow.keyEquivalent, .downArrow)
        XCTAssertEqual(KeyChord.Key.character("t").keyEquivalent, KeyEquivalent("t"))
        XCTAssertEqual(KeyChord.Key.character("]").keyEquivalent, KeyEquivalent("]"))
    }

    /// The §5 conflict rule, expressed through the adapter (docs/22 §5, lines 431–434): the focused
    /// terminal must keep receiving raw bytes, so no derived shortcut may steal a key the shell
    /// needs. Pinned against the DERIVED (native) shortcuts, not just the chords, because the menu
    /// bar binds the translated `KeyboardShortcut`:
    ///
    ///  1. **No bare key.** Every shortcut carries at least one modifier — a plain key is never a
    ///     workspace chord, so it always reaches the terminal.
    ///  2. **No Ctrl-letter.** Any shortcut on a *printable character* carries ⌘ or ⌥ (never
    ///     Ctrl-only), because Ctrl+letter is a terminal control code (`^C`, `^D`, …) the shell
    ///     owns. The one Ctrl-prefixed binding the table does ship (⌃⌘G new-group) also carries ⌘,
    ///     so it never collides with terminal control input.
    func testAdapterPreservesConflictRule() {
        for (chord, _) in CommandInterpreter.defaultBindings {
            let mods = chord.shortcut.modifiers
            XCTAssertFalse(
                mods.isEmpty,
                "no workspace shortcut may be a bare key (chord \(chord)) — plain keys belong to the terminal"
            )
            if case .character = chord.key {
                XCTAssertTrue(
                    mods.contains(.command) || mods.contains(.option),
                    "a character shortcut must carry ⌘ or ⌥ (chord \(chord)) so Ctrl-letters reach the terminal as control codes"
                )
            }
        }
    }
    #endif

    // MARK: - WorkspaceCommand value semantics (associated values compare)

    /// `WorkspaceCommand` is `Equatable` with its associated values significant — `focus(.left)` is
    /// not `focus(.right)`, `cycleFocus(forward:)` is direction-sensitive. The whole
    /// binding-assertion strategy above relies on this; pin it.
    func testWorkspaceCommandEqualityIsAssociatedValueSensitive() {
        XCTAssertNotEqual(WorkspaceCommand.focus(.left), .focus(.right))
        XCTAssertEqual(WorkspaceCommand.focus(.up), .focus(.up))
        XCTAssertNotEqual(WorkspaceCommand.cycleFocus(forward: true), .cycleFocus(forward: false))
        XCTAssertEqual(WorkspaceCommand.toggleZoom, .toggleZoom)
    }
}
