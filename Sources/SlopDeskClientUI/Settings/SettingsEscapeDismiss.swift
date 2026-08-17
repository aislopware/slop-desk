// SettingsEscapeDismiss — Esc closes the Settings window.
//
// The macOS Settings surface is a STOCK SwiftUI `Settings` scene (`SlopDeskSettingsScene`), i.e. a plain
// `NSWindow`. AppKit gives such a window no Esc behaviour: `cancelOperation:` unwinds to nothing, so ⌘, opened
// a window the keyboard could not close. Every OTHER dismissable surface in the app answers Esc
// (`PaletteView` / `GlobalSearchView` / `TerminalFindBar` via `onExitCommand`), so Settings was the one
// keyboard dead-end.
//
// WHY NOT `.onExitCommand`: it resolves against the FOCUSED view branch. A freshly-opened Settings window has
// no SwiftUI focus (the navigator `List` owns the responder), and the branch that receives `cancelOperation:`
// is not the one carrying the modifier — the Esc simply vanished. A window-scoped local `NSEvent` monitor
// fires regardless of which subview holds focus, which is the whole point here.
//
// TEXT FIELDS DO NOT GET A VETO, and that took two HW rounds to settle. Esc in a field editor is macOS's
// leave-the-field key, so the first two designs tried to respect that: (1) pass Esc THROUGH while a field editor
// is up — but SwiftUI's `.searchable` pill silently ignores it, so with the pill focused Esc did nothing at all,
// forever, which is the exact bug this file exists to fix; (2) resign first responder on the first Esc and close
// on the second — but `makeFirstResponder(nil)` does not stick against `.searchable` (it re-takes focus, ring
// and caret intact on HW), so Esc STILL never closed. Both were dead ends, verified on hardware, not reasoned
// away.
//
// So Esc closes the window from ANY focus state. Nothing is lost by that here: every text surface in Settings
// commits continuously — `Defaults`-backed fields on change, the raw `SLOPDESK_*` editor in its `onChange`, the
// font-family combobox through `DraftCommitDebouncer` — so there is no pending edit for an Esc to revert. The
// window's field editors are still ENDED before the close so any in-flight commit lands through its normal path.
// The cost is that Esc-to-clear-the-search-pill instead dismisses; that is the trade the reported bug asks for.
//
// THE ONE REAL VETO is the Key Bindings chord recorder, where Esc already MEANS "cancel this capture"
// (`KeybindingsEditorModel` maps keyCode 53 → `.cancel`). Two local `.keyDown` monitors would otherwise race for
// that Esc — AppKit does not document their order — and losing the race would close the window instead of
// cancelling the capture. So the recorder publishes ``SettingsChordCapture/isCapturing`` and this monitor stands
// down while it is armed, making the outcome independent of monitor ordering.
//
// The decision itself is the pure, headless-pinned ``SettingsEscapePolicy`` (`SettingsEscapePolicyTests`); this
// file's AppKit half only measures the inputs and performs the action.
//
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - SettingsEscapePolicy (pure — no AppKit, so it is unit-pinned headlessly)

/// What a key-down should do to the Settings window.
enum SettingsEscapeDecision: Equatable {
    /// Close the Settings window and SWALLOW the event (nothing else should see this Esc).
    case closeWindow
    /// Leave the event alone — it isn't Esc, it carries a modifier, or a chord capture owns this Esc.
    case passThrough
}

// MARK: - SettingsChordCapture (the recorder's claim on Esc)

/// Whether a Key Bindings row is currently recording a replacement chord. Published by
/// `KeybindingsEditorView` (the only writer) and read by the Esc monitor, which stands down while it is armed —
/// there Esc already means "cancel this capture" (`KeybindingCapture.cancel`), and two local `.keyDown` monitors
/// racing for the same key would otherwise resolve in AppKit's undocumented install order.
///
/// A plain `@MainActor` flag, not `@Observable`: nothing RENDERS from it (the recorder drives its own UI off
/// `recordingID`); it exists only so the key monitor can ask "is the recorder armed?".
@MainActor
final class SettingsChordCapture {
    static let shared = SettingsChordCapture()

    /// True from the moment a chord row starts recording until it commits or cancels.
    var isCapturing = false

    private init() {}
}

/// The pure Esc-in-Settings decision. Kept AppKit-free (plain `UInt16` / `Bool` inputs) so it pins headlessly
/// on the `swift test` host and compiles on iOS, where the Settings surface is a sheet with its own dismiss.
enum SettingsEscapePolicy {
    /// The `keyCode` AppKit reports for Esc. Mirrors `KeybindingsEditorModel`'s `keyCode == 53` cancel check —
    /// the same physical key, named here so the intent reads at the call site.
    static let escapeKeyCode: UInt16 = 53

    /// What this key-down does to the Settings window.
    ///
    /// - Parameters:
    ///   - keyCode: the AppKit `NSEvent.keyCode`. Anything but ``escapeKeyCode`` passes through.
    ///   - hasModifiers: whether any of ⌘ / ⌥ / ⌃ / ⇧ is held. A MODIFIED Esc is somebody else's chord (⌥Esc is
    ///     macOS's own Speak-Selection binding), so it is never read as a plain dismiss.
    ///   - isCapturingChord: whether a Key Bindings row is recording a replacement chord. There Esc already
    ///     means "cancel the capture", so it passes through — the ONE surface that outranks the dismiss.
    static func decide(
        keyCode: UInt16,
        hasModifiers: Bool,
        isCapturingChord: Bool,
    ) -> SettingsEscapeDecision {
        guard keyCode == escapeKeyCode, !hasModifiers, !isCapturingChord else { return .passThrough }
        return .closeWindow
    }
}

// MARK: - SettingsEscapeDismisser (macOS — the window-scoped monitor)

#if os(macOS)
/// Installs a local key-down monitor scoped to the window this view lands in, so Esc closes the Settings
/// window from anywhere inside it. Mounted as a zero-size `.background` of `SettingsView`, alongside
/// `SettingsWindowAppearancePinner`.
///
/// SCOPING: the monitor is process-wide (AppKit offers no per-window monitor), so it compares
/// `event.window` against ITS OWN window and ignores everything else — a workspace-window Esc (hint mode,
/// find bar, copy mode) is untouched. `dismantleNSView` removes it (the same teardown seam
/// `KeyCaptureMonitor` uses), so a closed Settings window leaves nothing behind.
struct SettingsEscapeDismisser: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    /// The window is only known after the view joins a hierarchy, and a Settings window can be closed and
    /// re-opened onto a NEW `NSWindow`, so re-point the coordinator's host on every update.
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.host = nsView
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Owns the monitor token so it is removed exactly once, when SwiftUI dismantles the representable.
    @MainActor
    final class Coordinator {
        /// The view whose `window` scopes the monitor. Weak — the coordinator must not keep a torn-down
        /// view tree (or its window) alive.
        weak var host: NSView?
        private var monitor: Any?

        func install(for view: NSView) {
            host = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, handle(event) != .passThrough else { return event }
                return nil // swallowed — this Esc was ours (closed the window / left the field)
            }
        }

        /// Measure the event against this coordinator's own window and act on the pure policy's verdict.
        private func handle(_ event: NSEvent) -> SettingsEscapeDecision {
            guard let window = host?.window, event.window === window else { return .passThrough }
            let decision = SettingsEscapePolicy.decide(
                keyCode: event.keyCode,
                hasModifiers: !event.modifierFlags
                    .isDisjoint(with: [.command, .option, .control, .shift]),
                isCapturingChord: SettingsChordCapture.shared.isCapturing,
            )
            if decision == .closeWindow {
                // End any field editing FIRST so an in-flight edit commits through its normal path (the fields
                // here commit on change / via the draft debouncer) rather than dying with the window.
                window.endEditing(for: nil)
                window.performClose(nil)
            }
            return decision
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
#endif
