import SlopDeskClient
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``ConnectionViewModel/onTitleChanged`` (Goal A).
/// Uses `foldEventForTesting` — the DEBUG hook exposed for synchronous unit testing — so no
/// async event loop or network is needed.  No `GhosttySurface`/`SCStream`/`VT`/Metal instantiation.
@MainActor
final class ConnectionViewModelTitleTests: XCTestCase {
    // MARK: - Helpers

    private func makeVM() -> ConnectionViewModel {
        ConnectionViewModel(
            terminal: TerminalViewModel(),
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used in title tests") }) },
        )
    }

    // MARK: - Tests

    /// A non-empty `.title` event fires `onTitleChanged` with the exact text.
    func testTitleEventFiresOnTitleChanged() {
        let vm = makeVM()
        var received: [String] = []
        vm.onTitleChanged = { received.append($0) }

        vm.foldEventForTesting(.title("~/proj — zsh"))

        XCTAssertEqual(received, ["~/proj — zsh"], "onTitleChanged must fire with the exact title text")
    }

    /// An empty `.title("")` must NOT fire `onTitleChanged` (the host emits "" on connect before
    /// the shell sets a real title — suppressing it avoids clobbering the persisted last-known title).
    func testEmptyTitleDoesNotFireOnTitleChanged() {
        let vm = makeVM()
        var received: [String] = []
        vm.onTitleChanged = { received.append($0) }

        vm.foldEventForTesting(.title(""))

        XCTAssertTrue(received.isEmpty, "empty title must not trigger onTitleChanged")
    }

    /// `onTitleChanged` is NOT fired for unrelated events (`.bell`, `.rtt`, `.exit` etc.).
    func testUnrelatedEventsDoNotFireOnTitleChanged() {
        let vm = makeVM()
        var received: [String] = []
        vm.onTitleChanged = { received.append($0) }

        vm.foldEventForTesting(.bell)
        vm.foldEventForTesting(.rtt(milliseconds: 12.5))
        vm.foldEventForTesting(.exit(code: 0))

        XCTAssertTrue(received.isEmpty, "unrelated events must not trigger onTitleChanged")
    }

    /// Multiple non-empty title events each fire `onTitleChanged` with the respective text, in order.
    func testMultipleTitleEventsEachFire() {
        let vm = makeVM()
        var received: [String] = []
        vm.onTitleChanged = { received.append($0) }

        vm.foldEventForTesting(.title("vim main.swift"))
        vm.foldEventForTesting(.title("~/project — zsh"))

        XCTAssertEqual(received, ["vim main.swift", "~/project — zsh"])
    }

    /// M4 (E14/K11): "Title — Shell Controlled" OFF must also gate the PERSISTENCE path. The same fire-time gate
    /// the VM applies to the DISPLAY title (`TerminalViewModel.handle(.title)`) must gate `onTitleChanged` here —
    /// otherwise a remote OSC 0/2 title still writes `spec.lastKnownTitle` and leaks onto the sidebar rail (which
    /// sources its row from `lastKnownTitle`). Revert-to-confirm-fail: the un-gated fold fires `onTitleChanged`
    /// regardless of the toggle, so the "OFF must not persist" assert fails on it.
    func testTitleShellControlledOffSuppressesPersistence() {
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.titleShellControlled) }
        let vm = makeVM()
        var received: [String] = []
        vm.onTitleChanged = { received.append($0) }

        // Default ON → the title persists.
        vm.foldEventForTesting(.title("real-title"))
        XCTAssertEqual(received, ["real-title"], "default ON persists the shell title")

        // Gate OFF → a remote title must NOT reach the persistence sink (no rail leak).
        SettingsKey.store.set(false, forKey: SettingsKey.titleShellControlled)
        vm.foldEventForTesting(.title("hijacked"))
        XCTAssertEqual(received, ["real-title"], "Title — Shell Controlled OFF must not persist a remote title")

        // Gate ON again → persistence resumes.
        SettingsKey.store.set(true, forKey: SettingsKey.titleShellControlled)
        vm.foldEventForTesting(.title("second"))
        XCTAssertEqual(received, ["real-title", "second"], "re-enabling resumes persistence")
    }

    /// When `onTitleChanged` is nil, a non-empty title event does not crash (no observer, side-effect dropped).
    func testTitleEventWithNoObserverIsDropped() {
        let vm = makeVM()
        vm.onTitleChanged = nil
        // Must not crash.
        vm.foldEventForTesting(.title("~/proj"))
    }

    /// The `TerminalViewModel` title still updates after a `.title` event even when `onTitleChanged`
    /// is wired (the unconditional `terminal.handle(event)` must still run — the split must not
    /// accidentally drop the forward).
    func testTerminalTitleStillUpdatesWhenOnTitleChangedIsWired() {
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal,
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used") }) },
        )
        vm.onTitleChanged = { _ in } // wired to something

        vm.foldEventForTesting(.title("vim slopdesk.swift"))

        XCTAssertEqual(
            terminal.title,
            "vim slopdesk.swift",
            "terminal.handle(event) must still run after onTitleChanged fires",
        )
    }
}
