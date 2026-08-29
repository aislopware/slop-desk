import Foundation

/// Polls the system pasteboard while the app is active and pushes each NEW string clip into the store's
/// ``WorkspaceStore/clipboardRing`` — so "Paste Recent" can replay something you copied a few clips ago
/// into a remote pane (the clipboard ring the round-2 research asked for).
///
/// Polling (not a notification — neither AppKit nor UIKit has a pasteboard-change notification) keyed
/// off ``ClientPasteboard/changeCount`` is cheap: a single integer read per tick, and the string is
/// fetched only when the count actually advances. The app scene owns a `.task { await monitor.run() }`;
/// the loop ends when that task is cancelled.
///
/// **What the phone gets out of it, and what it does not.** The type used to carry a whole-file
/// `#if os(macOS)` and the gate was SCOPE, not necessity — the count and the string read map 1:1 onto
/// `UIPasteboard`. What IS necessity is that iOS refuses an unattended CONTENT read: since iOS 16, a
/// read of pasteboard content the app did not write, with no system paste gesture behind it, raises a
/// modal "Allow Paste?" alert, and a one-second poll would raise it once per new clip, unprompted. So
/// the tick is honest about which half it may do: it tracks the count everywhere (free of the alert)
/// and reads the CONTENT only where ``ClientPasteboard/unattendedContentReadIsPermitted``. The phone's
/// ring is filled instead by ``WorkspaceStore/currentLocalClipboard()`` — every read there is a paste
/// the user just asked for, so the alert, if it appears at all, is the one they were expecting.
@preconcurrency
@MainActor
public final class ClipboardMonitor {
    private weak var store: WorkspaceStore?
    private let pollGap: Duration
    private let board: ClientPasteboard
    private var lastChangeCount: Int

    public init(
        store: WorkspaceStore,
        pollGap: Duration = .seconds(1),
        board: ClientPasteboard = .shared,
    ) {
        self.store = store
        self.pollGap = pollGap
        self.board = board
        // Seed with the CURRENT count so the clip already on the board at launch isn't retro-captured
        // (the ring is "what you copied while the app watched", not a one-shot snapshot).
        lastChangeCount = board.changeCount
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
    ///
    /// The count is consumed on EVERY platform: a tick that skipped the bookkeeping would leave the
    /// seen count stale, and the next legitimate read would then have to guess how far behind it was.
    /// Only the content read is conditional, for the reason the type docs give.
    func poll() {
        let count = board.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard ClientPasteboard.unattendedContentReadIsPermitted else { return }
        if let text = board.plainText, !text.isEmpty {
            store?.recordClip(text)
        }
    }
}
