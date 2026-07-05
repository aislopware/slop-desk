import XCTest
@testable import SlopDeskWorkspaceCore
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
            (KeyChord(character: "t", [.command]), .newPane(.terminal)),
            (KeyChord(character: "d", [.command, .shift]), .tidy),
            // Centre camera on the focused pane / on all panes.
            (KeyChord(character: "c", [.option, .command]), .centerFocusedPane),
            (KeyChord(character: "c", [.option, .command, .shift]), .centerAll),
            // Close the focused pane.
            (KeyChord(character: "w", [.command]), .closePane),
            // New group.
            (KeyChord(character: "g", [.control, .command]), .newGroup),
            // Geometric focus — ⌃⌘arrows (default chord).
            (KeyChord(.leftArrow, [.control, .command]), .focus(.left)),
            (KeyChord(.rightArrow, [.control, .command]), .focus(.right)),
            (KeyChord(.upArrow, [.control, .command]), .focus(.up)),
            (KeyChord(.downArrow, [.control, .command]), .focus(.down)),
            // Cycle focus.
            (KeyChord(character: "]", [.command]), .cycleFocus(forward: true)),
            (KeyChord(character: "[", [.command]), .cycleFocus(forward: false)),
            // Zoom + rename.
            (KeyChord(.return, [.command, .shift]), .toggleZoom),
            (KeyChord(character: "r", [.command]), .renamePane),
            // Reconnect the focused pane (primary failure recovery) — ⇧⌘R, distinct from ⌘R rename.
            (KeyChord(character: "r", [.command, .shift]), .reconnectPane),
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
            "the convenience init lower-cases the base key — case is not part of identity",
        )
        XCTAssertEqual(interpreter.feed(KeyChord(character: "T", [.command])), .newPane(.terminal))
        // Tidy requires an EXPLICIT .shift, not an upper-case char.
        XCTAssertEqual(interpreter.feed(KeyChord(character: "D", [.command, .shift])), .tidy)
        XCTAssertEqual(
            interpreter.feed(KeyChord(character: "d", [.command, .shift])),
            .tidy,
            "shift is carried by the modifier set, identically for 'd' and 'D'",
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
        // ⌘1…⌘9 now recall viewport bookmarks (tab-select is gone; BookmarkTests pins all nine
        // slots) — a digit with the WRONG modifiers stays unbound.
        XCTAssertEqual(interpreter.feed(KeyChord(character: "1", [.command])), .recallBookmark(1))
        XCTAssertNil(interpreter.feed(KeyChord(character: "1", [.control])))
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
            KeyChord(character: "x", [.command]): .closePane,
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
        XCTAssertFalse(
            CommandInterpreter.defaultBindings.isEmpty,
            "mutating an instance does not corrupt the static default",
        )
    }

    // L0: the "SwiftUI bridge (KeyChord → KeyboardShortcut)" test section was DELETED — it exercised the
    // `KeyChord.shortcut` / `.keyEquivalent` / `.eventModifiers` SwiftUI adapter that lived in the deleted
    // `KeyChord+SwiftUI.swift` view glue. The rebuilt menu/command UI (L2+) re-derives + re-pins those.

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
