#if os(macOS)
import AppKit
import Foundation
import SlopDeskPasteboard
import SlopDeskProtocol

/// The macOS shim that actuates the TWO clipboard-sync metadata verbs
/// (``MetadataVerb/setClipboard`` = 15 / ``MetadataVerb/readClipboard`` = 16) against the HOST's
/// general pasteboard. ``MuxChannelSession/serveMetadata`` routes a `metadataRequest` whose verb is
/// 15/16 HERE (BEFORE the pure ``MetadataResponseBuilder``, which performs NO side effects and never
/// sees these verbs in production), and forwards every OTHER verb to the builder.
///
/// **Host-global, not pane-scoped.** The pasteboard is machine state: whichever connected pane's mux
/// channel carries the request, the effect and the answer are the same. The cross-pane echo guard
/// (``SyncState``) is therefore a process-wide singleton, not per-session state.
///
/// **Echo suppression (the loop-safety half of the sync contract).** After a successful
/// `setClipboard` the resulting pasteboard `changeCount` is remembered in ``SyncState``; a
/// `readClipboard` that finds the pasteboard still at that count answers "unchanged" (kind `0`)
/// instead of shipping the client's own clip straight back. The client holds the mirror-image guard
/// (content compare in `ClipboardSyncEngine`), so a bounce needs BOTH ends to fail.
///
/// **Baseline probe.** A `readClipboard` whose `lastSeenChangeCount` is
/// ``MetadataCodec/clipboardBaselineProbe`` (`-1`) answers count-only: a freshly connected client
/// learns where the host clipboard stands WITHOUT pulling (and applying) whatever stale clip predates
/// the connection.
///
/// **Validate-then-drop everywhere.** A malformed / over-cap / unknown-kind `setClipboard` payload
/// and a truncated `readClipboard` request all map to ``MetadataStatus/error`` — never a trap, and
/// the host ALWAYS replies so the client's pending-request registry never hangs. Unlike
/// ``HostPathActionPerformer`` this shim IS unit-tested — against a NAMED `NSPasteboard` (the
/// `ClientPasteboard` test idiom; the pasteboard server needs no window-server session), with the
/// production entry point defaulting to `.general` + the shared ``SyncState``.
enum HostClipboardPerformer {
    /// The process-wide echo guard: the host pasteboard `changeCount` produced by the LAST
    /// client-pushed clip. Lock-protected — `serveMetadata` runs on per-session metadata queues, so
    /// two panes' requests can race.
    final class SyncState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastClientSetChangeCount: Int?

        /// Records the pasteboard count a client push produced (called after a successful set).
        func recordClientSet(changeCount: Int) {
            lock.lock()
            lastClientSetChangeCount = changeCount
            lock.unlock()
        }

        /// Whether `changeCount` is the client's own last push (→ answer "unchanged", never echo).
        func isClientSet(changeCount: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return lastClientSetChangeCount == changeCount
        }
    }

    /// The production echo-guard singleton (one host pasteboard → one guard).
    static let sharedState = SyncState()

    /// Routes one `metadataRequest`. If `verb` is a clipboard-sync verb (15/16), actuates it against
    /// `pasteboard` and returns the `metadataResponse`. Returns `nil` for EVERY other verb (incl. an
    /// unknown future byte) so the caller falls through to the read-only ``MetadataResponseBuilder``
    /// unchanged.
    static func response(
        requestID: UInt32, verb: UInt8, payload: Data,
        pasteboard: NSPasteboard = .general, state: SyncState = sharedState,
    ) -> WireMessage {
        switch MetadataVerb(rawValue: verb) {
        case .setClipboard:
            let status = applyClientClip(payload, to: pasteboard, state: state)
            return .metadataResponse(requestID: requestID, status: status.rawValue, payload: Data())
        case .readClipboard:
            guard let lastSeen = try? MetadataCodec.decodeClipboardReadRequest(payload) else {
                return .metadataResponse(
                    requestID: requestID, status: MetadataStatus.error.rawValue, payload: Data(),
                )
            }
            let body = readResponse(lastSeen: lastSeen, pasteboard: pasteboard, state: state)
            return .metadataResponse(
                requestID: requestID, status: MetadataStatus.ok.rawValue, payload: body,
            )
        default:
            // Unreachable: which verbs reach here is ``MetadataAdmission/performer(for:)``'s
            // answer. `.error` rather than a second opinion about who owns a verb.
            return .metadataResponse(
                requestID: requestID, status: MetadataStatus.error.rawValue, payload: Data(),
            )
        }
    }

    /// Decodes + writes one client-pushed clip onto `pasteboard` (verb 15). `.error` on a
    /// malformed/over-cap payload, an unknown kind byte, non-UTF-8 text, or undecodable PNG bytes;
    /// `.ok` after the write, with the new `changeCount` recorded in `state` (echo guard).
    static func applyClientClip(
        _ payload: Data, to pasteboard: NSPasteboard, state: SyncState,
    ) -> MetadataStatus {
        guard let clip = try? MetadataCodec.decodeClipboardSet(payload) else { return .error }
        // The write validates before it clears, so a garbage clip cannot destroy the host's current
        // one; a refusal here is non-UTF-8/empty text, undecodable PNG bytes, or an unknown kind.
        guard PasteboardClip.write(clip, to: pasteboard) else { return .error }
        state.recordClientSet(changeCount: pasteboard.changeCount)
        return .ok
    }

    /// Builds the verb-16 response body for `lastSeen`. Count-only (kind `0`) when the pasteboard is
    /// unchanged since `lastSeen`, is the client's own last push, is a baseline probe, or holds
    /// nothing shippable; otherwise the current clip (image preferred over text — the image is the
    /// clip's fidelity ceiling, the text flavor is usually its caption/URL).
    static func readResponse(lastSeen: Int64, pasteboard: NSPasteboard, state: SyncState) -> Data {
        let count = pasteboard.changeCount
        let unchanged = Int64(count) == lastSeen
            || lastSeen == MetadataCodec.clipboardBaselineProbe
            || state.isClientSet(changeCount: count)
        let clip = unchanged ? nil : currentClip(pasteboard)
        return MetadataCodec.encodeClipboardReadResponse(changeCount: Int64(count), clip: clip)
    }

    /// The pasteboard's current shippable clip: PNG data as-is, else TIFF transcoded to PNG, else a
    /// non-empty string as UTF-8 text. `nil` (→ kind 0) for an empty board, an over-cap clip, a
    /// file-copy (a host file path is meaningless on the client), or an untranscodable image.
    ///
    /// `skippingConcealed: false` — the HOST ships a concealed clip (what a password manager marks)
    /// where the client refuses to push one. That asymmetry predates the shared reader and is left
    /// as it was; it is now one word rather than a difference between two function bodies.
    static func currentClip(_ pasteboard: NSPasteboard) -> MetadataCodec.ClipboardClip? {
        PasteboardClip.read(pasteboard, skippingConcealed: false)
    }
}
#endif
