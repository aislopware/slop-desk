import Foundation
import SlopDeskPasteboard
import SlopDeskProtocol

/// Bidirectional clipboard sync between the client and the host, over the metadata RPC
/// (``MetadataVerb/setClipboard`` / ``MetadataVerb/readClipboard``). One engine per app, running the
/// ``ClipboardMonitor`` pattern: the scene owns a `.task { await engine.run() }`, one tick per second,
/// the loop ends on cancel.
///
/// **Push (copy on the client → paste on the host).** Each tick compares
/// ``SystemPasteboard/changeCount`` (one integer read); on a new LOCAL clip it snapshots the content
/// (image preferred — PNG as-is or TIFF transcoded — else non-empty text) and pushes it to the host,
/// which writes its general pasteboard. This is what makes Claude Code's Ctrl+V see a client-copied
/// image, and a plain ⌘V
/// inside a remote-desktop pane paste client content with no manual step. A failed push (host down,
/// no connected pane) stays PENDING and retries every tick until a newer local clip replaces it.
///
/// **Pull (copy on the host → paste on the client).** The same tick polls the host's clipboard via
/// `readClipboard` with the last-seen host `changeCount`; a changed host clip is applied to the local
/// pasteboard. The FIRST pull is a baseline probe (``MetadataCodec/clipboardBaselineProbe``) — it
/// learns the host's count without applying, so connecting never overwrites the client clipboard with
/// stale pre-connection host state. The baseline resets whenever the pull seam fails (disconnect), so
/// every REconnect is also baseline-first.
///
/// **Loop safety — both directions remember the last synced content.** `lastSynced` holds the clip
/// most recently pushed OR applied; a local pasteboard change whose content equals it is NOT pushed
/// (it is our own apply), and a pulled host clip that equals it is NOT re-applied. The host holds the
/// mirror-image guard (its `changeCount` echo suppression), so a ping-pong needs both ends to fail.
///
/// **Skips (validate-then-drop, privacy).** Concealed clips (`org.nspasteboard.ConcealedType` —
/// password managers) are never pushed; file-copy clips (`.fileURL` — a local path is meaningless on
/// the other machine) and over-cap clips (> ``MetadataCodec/maxClipboardContentBytes``) are skipped;
/// the pasteboard is left untouched in every skip case.
///
/// **The one direction the phone cannot have on a timer, and why.** The engine used to carry a
/// whole-file `#if os(macOS)`; the board is ``SystemPasteboard`` now and both halves run the same tick.
/// PULL is whole on iOS — writing `UIPasteboard` asks no permission, so a copy on the host lands on the
/// phone within a tick, which is the direction a phone actually wants. PUSH is not, and that IS
/// necessity rather than scope: since iOS 16, reading pasteboard content the app did not write, with no
/// system paste gesture behind it, raises a modal "Allow Paste?" alert, and this tick runs once a
/// second. So ``captureLocalChange()`` consumes the count on every platform and snapshots the CONTENT
/// only where ``SystemPasteboard/unattendedContentReadIsPermitted``. On iOS the local clip reaches the
/// host through the paths the user asked to paste on instead of through the timer.
///
/// Seams (`push`/`pull` closures + injected pasteboard) keep the tick logic unit-testable against a
/// NAMED pasteboard with no live socket.
@preconcurrency
@MainActor
public final class ClipboardSyncEngine {
    /// Pushes one clip to the host; `true` on the host's `.ok`. Production wires it to
    /// ``MetadataClient/setClipboard(_:)`` on whichever pane is connected; `false` (incl. "no
    /// connected pane") keeps the clip pending for retry.
    public typealias Push = @MainActor (MetadataCodec.ClipboardClip) async -> Bool
    /// Pulls the host clipboard state for a last-seen count; `nil` on failure/disconnect.
    /// Production wires it to ``MetadataClient/readClipboard(lastSeenChangeCount:)``.
    public typealias Pull = @MainActor (Int64) async -> (
        changeCount: Int64, clip: MetadataCodec.ClipboardClip?,
    )?

    private let pasteboard: SystemPasteboard
    private let pollGap: Duration
    private let push: Push
    private let pull: Pull

    private var lastChangeCount: Int
    /// The clip most recently PUSHED to or APPLIED from the host — the content half of the
    /// echo-suppression contract (see the type docs).
    private var lastSynced: MetadataCodec.ClipboardClip?
    /// A local clip awaiting a successful push (host down / no pane connected → retry every tick).
    private var pendingPush: MetadataCodec.ClipboardClip?
    /// The host `changeCount` from the last successful pull; baseline-probe sentinel after init and
    /// after any pull failure (reconnects re-baseline, never apply stale state).
    private var hostLastSeen: Int64 = MetadataCodec.clipboardBaselineProbe

    public init(
        pasteboard: SystemPasteboard = ClientPasteboard.board,
        pollGap: Duration = .seconds(1),
        push: @escaping Push,
        pull: @escaping Pull,
    ) {
        self.pasteboard = pasteboard
        self.pollGap = pollGap
        self.push = push
        self.pull = pull
        // Seed with the CURRENT count: the clip already on the board at launch is not pushed
        // (sync covers what you copy while the app watches — the ClipboardMonitor convention).
        lastChangeCount = pasteboard.changeCount
    }

    /// Ticks until the owning Task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: pollGap)
        }
    }

    /// One poll step — exposed for deterministic tests (the production caller is ``run()``).
    func tick() async {
        captureLocalChange()
        await pushPending()
        // No pull while a push is outstanding: the host would answer with its pre-push clip and
        // the stale content could overwrite the newer local one.
        guard pendingPush == nil else { return }
        await pullFromHost()
    }

    /// Folds a local pasteboard change into ``pendingPush`` (content-compared against
    /// ``lastSynced`` so our own applies never bounce back to the host).
    private func captureLocalChange() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // The count is consumed on EVERY platform — a tick that skipped the bookkeeping would leave
        // the seen count stale. Only the CONTENT snapshot is conditional: see the type docs for the
        // iOS paste alert this refuses to raise once a second.
        guard SystemPasteboard.unattendedContentReadIsPermitted else { return }
        guard let clip = Self.currentClip(pasteboard), clip != lastSynced else { return }
        pendingPush = clip
    }

    /// Retries the pending push until the host accepts it. On success the clip becomes the synced
    /// truth; on failure it stays pending (a NEWER local copy replaces it via `captureLocalChange`).
    private func pushPending() async {
        guard let clip = pendingPush else { return }
        guard await push(clip) else { return }
        // Only clear if no newer local clip raced in while the push was in flight.
        if pendingPush == clip {
            pendingPush = nil
        }
        lastSynced = clip
    }

    /// Polls the host clipboard and applies a changed clip locally. A pull failure (disconnect /
    /// old host) resets the baseline so the next successful pull is count-only again.
    private func pullFromHost() async {
        guard let (changeCount, clip) = await pull(hostLastSeen) else {
            hostLastSeen = MetadataCodec.clipboardBaselineProbe
            return
        }
        hostLastSeen = changeCount
        guard let clip, clip != lastSynced else { return }
        apply(clip)
    }

    /// Writes a host clip onto the local pasteboard (image → PNG + TIFF twin so every app can
    /// paste it; text → string), recording it as the synced truth and pre-advancing
    /// ``lastChangeCount`` so the very next tick does not even snapshot our own write.
    private func apply(_ clip: MetadataCodec.ClipboardClip) {
        // Validate-then-drop: the write refuses non-UTF-8/empty text, undecodable PNG bytes and an
        // unknown future kind WITHOUT touching the board, so a bad host clip is a no-op rather than
        // a cleared local clipboard.
        guard PasteboardClip.write(clip, to: pasteboard) else { return }
        lastSynced = clip
        lastChangeCount = pasteboard.changeCount
    }

    /// The pasteboard's current syncable clip: PNG as-is, else an image transcoded to PNG, else a
    /// non-empty string. `nil` for concealed (password-manager) clips, file copies, over-cap
    /// content, an untranscodable image, or an empty board.
    static func currentClip(_ pasteboard: SystemPasteboard) -> MetadataCodec.ClipboardClip? {
        PasteboardClip.read(pasteboard, skippingConcealed: true)
    }
}
