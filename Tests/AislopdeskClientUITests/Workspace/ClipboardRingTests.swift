import XCTest
@testable import AislopdeskClientUI
#if os(macOS)
import AppKit
#endif

/// Pins the clipboard history ring: the store's dedup/cap/skip-empty ring bookkeeping and (macOS) the
/// monitor's changeCount-gated poll into it.
@MainActor
final class ClipboardRingTests: XCTestCase {

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) })
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
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }   // restore default (ON) for other tests
        store.recordClip("a copied secret")
        XCTAssertTrue(store.clipboardRing.isEmpty, "recording disabled → nothing is retained")
        UserDefaults.standard.set(true, forKey: key)
        store.recordClip("ok")
        XCTAssertEqual(store.clipboardRing, ["ok"], "re-enabling resumes recording")
    }

    func testClipPreviewMasksSecretsWhenRedacting() {
        // The pill's "Paste Recent" rows must not display a copied credential in plaintext.
        let secret = "PASSWORD=hunter2secretvalue"
        let masked = PaneMenuView.clipPreview(secret, redact: true)
        XCTAssertTrue(masked.contains(SecretRedactor.mask), "the secret value is masked in the preview")
        XCTAssertFalse(masked.contains("hunter2secretvalue"), "the raw secret never reaches the menu row")
        // With redaction off the preview is the raw (truncated) text — the stored clip is unchanged either way.
        let raw = PaneMenuView.clipPreview(secret, redact: false)
        XCTAssertTrue(raw.contains("hunter2secretvalue"))
    }

    #if os(macOS)
    func testMonitorPollCapturesNewClipsOnly() {
        let store = makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("aislopdesk-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("seed", forType: .string)
        let monitor = ClipboardMonitor(store: store, pasteboard: pb)
        // The seed predates the monitor → not retro-captured.
        monitor.poll()
        XCTAssertTrue(store.clipboardRing.isEmpty, "the clip present at init is not retro-captured")
        // A new copy advances changeCount → captured.
        pb.clearContents(); pb.setString("fresh", forType: .string)
        monitor.poll()
        XCTAssertEqual(store.clipboardRing, ["fresh"])
        // Polling again with no change is a no-op (no duplicate).
        monitor.poll()
        XCTAssertEqual(store.clipboardRing, ["fresh"])
    }
    #endif
}
