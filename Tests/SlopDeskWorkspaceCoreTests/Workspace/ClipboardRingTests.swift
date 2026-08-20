import SlopDeskPasteboard
import XCTest
@testable import SlopDeskWorkspaceCore
#if os(macOS)
import AppKit
#endif

/// Pins the clipboard history ring: the store's dedup/cap/skip-empty ring bookkeeping and (macOS) the
/// monitor's changeCount-gated poll into it.
@MainActor
final class ClipboardRingTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
    }

    func testRecordPrependsDedupsAndCaps() {
        let store = makeStore()
        store.recordClip("a")
        store.recordClip("b")
        XCTAssertEqual(store.clipboardRing, ["b", "a"], "newest first")
        store.recordClip("a")
        XCTAssertEqual(store.clipboardRing, ["a", "b"], "a repeat moves to front, not duplicated")
        // Cap.
        for i in 0..<WorkspaceStore.clipboardRingCap + 5 { store.recordClip("clip\(i)") }
        XCTAssertEqual(store.clipboardRing.count, WorkspaceStore.clipboardRingCap)
        XCTAssertEqual(store.clipboardRing.first, "clip\(WorkspaceStore.clipboardRingCap + 4)")
    }

    func testRecordSkipsEmptyAndWhitespace() {
        let store = makeStore()
        store.recordClip("")
        store.recordClip("   \n  ")
        XCTAssertTrue(store.clipboardRing.isEmpty)
        store.recordClip("real")
        XCTAssertEqual(store.clipboardRing, ["real"])
    }

    func testClearRing() {
        let store = makeStore()
        store.recordClip("x")
        store.clearClipboardRing()
        XCTAssertTrue(store.clipboardRing.isEmpty)
    }

    // MARK: - Privacy: don't-record toggle + redacted previews

    func testRecordClipRespectsTheHistoryToggle() {
        let store = makeStore()
        let key = SettingsKey.recordClipboardHistory
        SettingsKey.store.set(false, forKey: key)
        defer { SettingsKey.store.removeObject(forKey: key) } // restore default (ON) for other tests
        store.recordClip("a copied secret")
        XCTAssertTrue(store.clipboardRing.isEmpty, "recording disabled → nothing is retained")
        SettingsKey.store.set(true, forKey: key)
        store.recordClip("ok")
        XCTAssertEqual(store.clipboardRing, ["ok"], "re-enabling resumes recording")
    }

    // L0: testClipPreviewMasksSecretsWhenRedacting was DELETED — it asserted on `PaneMenuView.clipPreview`,
    // a static on the deleted SwiftUI pane menu view. (SecretRedactor itself is still tested directly in
    // SecretRedactorTests.) The rebuilt pane menu (L3) re-pins its own preview redaction.

    // MARK: - The live read IS the recording (the only door the phone has)

    /// A read through ``WorkspaceStore/currentLocalClipboard()`` records what it read. This is what
    /// gives iOS a clipboard history at all: an unattended poll may not read `UIPasteboard` content
    /// there, so the ring is filled by the paste the user actually asked for.
    func testLiveClipboardReadRecordsIntoTheRing() {
        let store = makeStore()
        store.clipboardTextProvider = { "read-live" }
        XCTAssertEqual(store.currentLocalClipboard(), "read-live")
        XCTAssertEqual(store.clipboardRing, ["read-live"], "the read the user asked for fills the ring")
        _ = store.currentLocalClipboard()
        XCTAssertEqual(store.clipboardRing, ["read-live"], "re-reading the same clip does not duplicate it")
    }

    /// The privacy toggle still owns the ring: a live read pastes, and retains nothing.
    func testLiveClipboardReadRespectsTheHistoryToggle() {
        let store = makeStore()
        let key = SettingsKey.recordClipboardHistory
        SettingsKey.store.set(false, forKey: key)
        defer { SettingsKey.store.removeObject(forKey: key) }
        store.clipboardTextProvider = { "a copied secret" }
        XCTAssertEqual(store.currentLocalClipboard(), "a copied secret", "the paste still works")
        XCTAssertTrue(store.clipboardRing.isEmpty, "recording disabled → the read retains nothing")
    }

    // MARK: - The PROBE: enablement without a content read

    /// ``WorkspaceStore/localClipboardHasText()`` answers the enablement question WITHOUT ever calling
    /// the content provider. This is the whole reason it exists: on iOS the content read raises the modal
    /// "Allow Paste?" alert, and the paste plate asks this one from a SwiftUI `body` (increment 78).
    func testProbeNeverReadsTheClipboardContent() {
        let store = makeStore()
        var contentReads = 0
        store.clipboardTextProvider = {
            contentReads += 1
            return "live-clipboard"
        }
        store.clipboardHasTextProbe = { true }
        XCTAssertTrue(store.localClipboardHasText())
        XCTAssertEqual(contentReads, 0, "the probe must not read content — that read is the alert")
        XCTAssertTrue(store.clipboardRing.isEmpty, "and so it records nothing either")
    }

    /// The probe answers TRUE in exactly the cases the paste would type something — RING FALLBACK
    /// INCLUDED. `currentLocalClipboard()` falls back to the ring head when the live read comes back
    /// `nil`, so a probe that consulted only the board would grey out a paste that would have worked.
    func testProbeAgreesWithWhatThePasteWouldFind() {
        let store = makeStore()
        // No probe, no ring: nothing to paste, and nothing claims otherwise.
        XCTAssertFalse(store.localClipboardHasText())
        XCTAssertNil(store.currentLocalClipboard())
        // Ring head only (a headless store, or a board the platform will not read): both say yes.
        store.recordClip("ring-head")
        XCTAssertTrue(store.localClipboardHasText(), "the ring head is what the paste would type")
        XCTAssertEqual(store.currentLocalClipboard(), "ring-head")
        // A live board with text: still yes, now from the probe.
        store.clipboardHasTextProbe = { true }
        store.clipboardTextProvider = { "live-clipboard" }
        XCTAssertTrue(store.localClipboardHasText())
        XCTAssertEqual(store.currentLocalClipboard(), "live-clipboard")
        // An EMPTY board over a non-empty ring: the live read returns nil and the paste falls back to
        // the ring — so the probe must not report the board's emptiness as "nothing to paste".
        store.clipboardHasTextProbe = { false }
        store.clipboardTextProvider = { nil }
        XCTAssertTrue(store.localClipboardHasText(), "a false probe hands the question to the ring")
        XCTAssertEqual(store.currentLocalClipboard(), "live-clipboard", "which is what the paste types")
        // An empty board over an empty ring: nothing, on both sides.
        store.clearClipboardRing()
        XCTAssertFalse(store.localClipboardHasText())
        XCTAssertNil(store.currentLocalClipboard())
    }

    /// A whitespace-only RING head is not "text to paste" — the ring's own recorder skips whitespace, so
    /// this can only arrive through the probe's board, and the tap's `isPastable` guard is what catches it.
    func testProbeTreatsAWhitespaceRingHeadAsNothingToPaste() {
        let store = makeStore()
        store.recordClip("   \n\t ")
        XCTAssertTrue(store.clipboardRing.isEmpty, "the recorder never retained it in the first place")
        XCTAssertFalse(store.localClipboardHasText())
    }

    #if os(macOS)
    /// The board-level probe itself: it reports the DECLARED type, and it is what the injected
    /// `clipboardHasTextProbe` is wired to (`ClientPasteboard.hasText()`).
    func testSystemPasteboardProbeSeesTextWithoutReadingIt() {
        let pb = NSPasteboard(name: NSPasteboard.Name("slopdesk-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        XCTAssertFalse(SystemPasteboard(pb).hasPlainText, "an empty board holds no text")
        pb.setString("copied", forType: .string)
        XCTAssertTrue(SystemPasteboard(pb).hasPlainText)
        XCTAssertEqual(SystemPasteboard(pb).plainText, "copied", "the content read agrees with the probe")
    }

    func testMonitorPollCapturesNewClipsOnly() {
        let store = makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("slopdesk-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("seed", forType: .string)
        let monitor = ClipboardMonitor(store: store, pasteboard: SystemPasteboard(pb))
        // The seed predates the monitor → not retro-captured.
        monitor.poll()
        XCTAssertTrue(store.clipboardRing.isEmpty, "the clip present at init is not retro-captured")
        // A new copy advances changeCount → captured.
        pb.clearContents()
        pb.setString("fresh", forType: .string)
        monitor.poll()
        XCTAssertEqual(store.clipboardRing, ["fresh"])
        // Polling again with no change is a no-op (no duplicate).
        monitor.poll()
        XCTAssertEqual(store.clipboardRing, ["fresh"])
    }
    #endif
}
