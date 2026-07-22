import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// WS-D / D6 — the keybindings-editor LOGIC seam (headless; no SwiftUI instantiation). The editor view is
/// a thin shell over `PreferencesStore.keybindings`; these prove the store/registry behaviour the editor
/// relies on: a write to `store.keybindings` republishes to `WorkspaceBindingRegistry.activeOverrides` and
/// the process-wide `resolvedChordTable` routes the NEW chord while FREEING the old default; conflicts
/// surface through `store.keybindingConflicts()`; a malformed override falls back to the registry default.
@MainActor
final class KeybindingsEditorLogicTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "KeybindingsEditorLogicTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    override func tearDown() {
        // The store's apply path mutates the process-wide registry overrides; restore so a later test is clean.
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    /// Writing an override into `store.keybindings` republishes it to the live registry AND the live
    /// `resolvedChordTable` routes the new chord while the old default chord is freed — the end-to-end path
    /// the editor depends on (it never touches `activeOverrides` itself).
    func testEditorWriteRepublishesAndRoutesLiveResolvedChordTable() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)

        // Pre-condition: default split-right is ⌘D and the live table routes it.
        XCTAssertEqual(WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])], .splitRight)

        // The editor's only mutation: assign a fresh KeybindingPreferences to the store (rebinds ⌘E).
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true),
        ])

        // 1) Republished to the process-wide live registry overrides.
        XCTAssertEqual(
            WorkspaceBindingRegistry.activeOverrides.chord(for: "pane.splitRight")?.canonical, "cmd+e",
        )
        // 2) The LIVE resolvedChordTable (reads activeOverrides) now routes ⌘E …
        XCTAssertEqual(WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "e", [.command])], .splitRight)
        // 3) … and the OLD default ⌘D no longer routes to split-right (it is freed).
        XCTAssertNil(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])],
            "the old default chord is freed by the override on the LIVE table",
        )
    }

    /// `store.keybindingConflicts()` surfaces the two binding ids that collide on ONE chord (the banner +
    /// per-row warning the editor renders). Two DISTINCT ids overridden to the same chord ⇒ one conflict
    /// entry naming both ids.
    func testKeybindingConflictsSurfacesTwoIdsOnOneChord() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "g", command: true),
            "pane.close": .init(key: "g", command: true),
        ])

        let conflicts = store.keybindingConflicts()
        XCTAssertEqual(conflicts.count, 1, "exactly one chord collides")
        let colliding = conflicts["cmd+g"]
        XCTAssertEqual(colliding.map(Set.init), Set(["pane.splitRight", "pane.close"]))
    }

    /// A malformed override (an unmappable key) is ignored on the LIVE table — the binding keeps its
    /// registry default (validate-then-default, never traps). Proves the editor can't brick a chord by
    /// storing garbage.
    func testMalformedOverrideFallsBackToDefaultOnLiveTable() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "", command: true), // empty key → unmappable
        ])
        // The default ⌘D still routes split-right on the LIVE table (the bad override is dropped).
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])], .splitRight,
            "an unmappable override leaves the registry default routing on the live table",
        )
    }

    // MARK: - Capture (Rebind / Unbind / cancel)

    /// Click the row then press Backspace to clear the binding. The capture resolver MUST map
    /// Backspace (keyCode 51) to `.clear`, NOT record the DEL scalar `"\u{7F}"` as a junk chord. Revert
    /// (drop the keyCode-51 branch) ⇒ the outcome becomes `.bind(key: "\u{7f}")` and this fails.
    func testBackspaceCaptureClearsRatherThanRecordingDEL() {
        // Backspace as AppKit delivers it: keyCode 51, charactersIgnoringModifiers = DEL (U+007F).
        let outcome = KeybindingCapture.outcome(
            keyCode: 51, charactersIgnoringModifiers: "\u{7F}",
            command: false, shift: false, option: false, control: false,
        )
        XCTAssertEqual(outcome, .clear, "Backspace clears the binding (unbind)")

        // The DEL scalar must NEVER be accepted as a base key, even via some other keyCode.
        XCTAssertNil(
            KeybindingCapture.baseKey(keyCode: 999, charactersIgnoringModifiers: "\u{7F}"),
            "DEL is a control scalar — never a recordable base key",
        )
        // Forward-Delete (keyCode 117) also clears.
        XCTAssertEqual(
            KeybindingCapture.outcome(
                keyCode: 117, charactersIgnoringModifiers: nil,
                command: false, shift: false, option: false, control: false,
            ),
            .clear, "Forward-Delete clears too",
        )
    }

    /// The non-Delete capture paths: Escape cancels, a usable chord records, a pure modifier is ignored.
    func testCaptureCancelBindAndIgnorePaths() {
        // Escape (53) cancels with no write.
        XCTAssertEqual(
            KeybindingCapture.outcome(
                keyCode: 53, charactersIgnoringModifiers: "\u{1B}",
                command: false, shift: false, option: false, control: false,
            ),
            .cancel,
        )
        // ⌘T records cmd+t.
        XCTAssertEqual(
            KeybindingCapture.outcome(
                keyCode: 17, charactersIgnoringModifiers: "t",
                command: true, shift: false, option: false, control: false,
            ),
            .bind(KeybindingPreferences.KeyChord(key: "t", command: true)),
        )
        // A pure modifier (no usable base key) is ignored — keep recording.
        XCTAssertEqual(
            KeybindingCapture.outcome(
                keyCode: 999, charactersIgnoringModifiers: nil,
                command: true, shift: false, option: false, control: false,
            ),
            .ignore,
        )
    }

    // MARK: - Single-row edit preserves config-file bindings (setOverride / clearOverride)

    /// A base model carrying a config.toml-sourced literal-byte binding and an `unbind:` directive — the
    /// collections `KeybindingPreferences(overrides:)` defaults to empty, so a rebuild-on-edit would wipe
    /// them.
    private func modelWithConfigBindings() -> KeybindingPreferences {
        let textChord = KeybindingPreferences.KeyChord(key: "k", command: true)
        let unbindChord = KeybindingPreferences.KeyChord(key: "d", command: true)
        return KeybindingPreferences(
            overrides: ["pane.close": .init(key: "w", command: true)],
            textBindings: [textChord: .init(kind: .text, payload: Array("clear\n".utf8))],
            unbinds: [unbindChord],
        )
    }

    /// THE audit fix (Bug 2): recording a replacement chord for ONE action must PRESERVE the config.toml
    /// literal-byte bindings and unbind directives. The old editor rebuilt the model as
    /// `KeybindingPreferences(overrides:)`, whose initializer defaults those collections to empty —
    /// silently wiping them on every single-row rebind. REVERT-TO-CONFIRM-FAIL: point `settingOverride` back
    /// to `KeybindingPreferences(overrides:)` and every preservation assertion below trips.
    func testSettingOverridePreservesTextAndUnbindBindings() {
        let base = modelWithConfigBindings()
        let newChord = KeybindingPreferences.KeyChord(key: "x", command: true, shift: true)

        let next = KeybindingsEditorModel.settingOverride(newChord, for: "pane.splitRight", in: base)

        // The new override landed…
        XCTAssertEqual(next.chord(for: "pane.splitRight"), newChord, "the recorded chord is written")
        XCTAssertEqual(next.chord(for: "pane.close")?.canonical, "cmd+w", "the pre-existing override survives")
        // …and NONE of the config-sourced collections were dropped.
        XCTAssertEqual(next.textBindings, base.textBindings, "text: literal-byte bindings are preserved")
        XCTAssertEqual(next.unbinds, base.unbinds, "unbind: directives are preserved")
    }

    /// The clear-one-row counterpart (Backspace-to-clear): removing a single override must likewise preserve
    /// the text / unbind collections. Same rebuild-wipes-them bug, same fix.
    func testClearingOverridePreservesTextAndUnbindBindings() {
        let base = modelWithConfigBindings()

        let next = KeybindingsEditorModel.clearingOverride(for: "pane.close", in: base)

        XCTAssertNil(next.chord(for: "pane.close"), "the cleared override is removed (registry default restored)")
        XCTAssertEqual(next.textBindings, base.textBindings, "text: literal-byte bindings are preserved")
        XCTAssertEqual(next.unbinds, base.unbinds, "unbind: directives are preserved")
    }

    // MARK: - Search filter ("Search key bindings")

    /// The search box filters by action NAME and by CHORD. `KeybindingsEditorModel.matches` must match a
    /// row by its title substring AND by its chord typed either as a glyph (`⌘`) or canonically (`cmd+d`);
    /// an unrelated query excludes it. Pins the filter the new search field drives.
    func testSearchMatchesByNameAndByChord() throws {
        let split = try XCTUnwrap(WorkspaceBindingRegistry.binding(for: .splitRight))
        let defaultChord = KeyChord(character: "d", [.command]) // ⌘D

        // By action name (case-insensitive substring of the title "Split Right").
        XCTAssertTrue(KeybindingsEditorModel.matches(split, effectiveChord: defaultChord, query: "split"))
        // By canonical chord string (typing "cmd+d" finds what's bound to that combo).
        XCTAssertTrue(KeybindingsEditorModel.matches(split, effectiveChord: defaultChord, query: "cmd+d"))
        // A blank query matches everything.
        XCTAssertTrue(KeybindingsEditorModel.matches(split, effectiveChord: defaultChord, query: "   "))
        // An unrelated query (not in title / keywords / chord) excludes the row.
        XCTAssertFalse(KeybindingsEditorModel.matches(split, effectiveChord: defaultChord, query: "zzznope"))
        // Searching by a DIFFERENT chord does not match this row.
        XCTAssertFalse(KeybindingsEditorModel.matches(split, effectiveChord: defaultChord, query: "cmd+q"))
    }

    // MARK: - Global reset ("Reset to Default", no per-row revert)

    /// The header's "Reset to Default" button is gated on `hasCustomizations` (it appears only after a
    /// binding is customized) and the reset clears ALL overrides — restoring the default chord on the LIVE
    /// table. Pins the gate + the clear-all semantics the button drives (no per-row revert path tested
    /// because there is none).
    func testGlobalResetGateAndClearAllRestoresDefaults() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)

        // No customization yet ⇒ the reset button is hidden.
        XCTAssertFalse(KeybindingsEditorModel.hasCustomizations(store.keybindings))

        // Customize split-right to ⌘E (the editor's write).
        store.keybindings = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "e", command: true)])
        XCTAssertTrue(KeybindingsEditorModel.hasCustomizations(store.keybindings), "button now appears")
        XCTAssertNil(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])],
            "the default ⌘D is freed while the override stands",
        )

        // The reset action: assign a fresh empty model (what `resetAllOverrides` does).
        store.keybindings = KeybindingPreferences()

        XCTAssertFalse(KeybindingsEditorModel.hasCustomizations(store.keybindings), "button hides again")
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])], .splitRight,
            "reset restores the default ⌘D on the LIVE table",
        )
    }
}
