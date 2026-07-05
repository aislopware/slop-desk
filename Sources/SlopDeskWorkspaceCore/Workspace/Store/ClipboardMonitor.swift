#if os(macOS)
import AppKit
import Foundation

/// Polls the macOS general pasteboard while the app is active and pushes each NEW string clip into the
/// store's ``WorkspaceStore/clipboardRing`` — so "Paste Recent" can replay something you copied a few
/// clips ago into a remote pane (the clipboard ring the round-2 research asked for).
///
/// Polling (not a notification — AppKit has no pasteboard-change notification) keyed off
/// `NSPasteboard.changeCount` is cheap: a single integer read per tick, and the string is fetched only
/// when the count actually advances. Modeled on ``SystemDialogMonitor``: the app scene owns a
/// `.task { await monitor.run() }`; the loop ends when that task is cancelled.
@preconcurrency
@MainActor
public final class ClipboardMonitor {
    private weak var store: WorkspaceStore?
    private let pollGap: Duration
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int

    public init(
        store: WorkspaceStore,
        pollGap: Duration = .seconds(1),
        pasteboard: NSPasteboard = .general,
    ) {
        self.store = store
        self.pollGap = pollGap
        self.pasteboard = pasteboard
        // Seed with the CURRENT count so the clip already on the board at launch isn't retro-captured
        // (the ring is "what you copied while the app watched", not a one-shot snapshot).
        lastChangeCount = pasteboard.changeCount
    }

    /// Polls until the owning Task is cancelled. Each tick, if the pasteboard advanced, records its
    /// string contents into the ring (a non-string clip — an image / file — advances the count but
    /// yields no string, so it is skipped).
    public func run() async {
        while !Task.isCancelled {
            poll()
            try? await Task.sleep(for: pollGap)
        }
    }

    /// One poll step — exposed for deterministic tests (the production caller is ``run()``).
    func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            store?.recordClip(text)
        }
    }
}
#endif
