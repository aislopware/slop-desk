import Foundation
import SlopDeskScreen

/// Cold-reattach state transfer: reproduce a pane's SCREEN instead of replaying its byte history.
///
/// ## What is here, and what is in screend
/// The parse, the render, the input-mode reassert and — since stage 25 — holding back the half of a
/// chunk-cut escape sequence or UTF-8 scalar all happen in `rust/slopdesk-screend`
/// (``ScreenClient/compose(raw:rows:cols:reassertInputModes:)`` and ``ScreenClient/transcript(raw:rows:cols:)``).
/// The two verbs differ in what they do with the dangling half, and that difference is now theirs to
/// keep: `compose` re-attaches it after the reassert, so it stays adjacent to the live tail's
/// continuation bytes, while `transcript` DROPS it, because that stream ended with the process that
/// wrote it and no continuation will ever arrive.
///
/// What is left here is the choice between the two and the fallback.
///
/// ## When screend is not there
/// Every entry point falls back to the raw bytes, which is precisely the behaviour a disabled
/// ``MuxChannelSession/SnapshotReplayPolicy`` already produces: the client replays history instead
/// of a rendered screen — slower and less tidy, never wrong. The fallback is passthrough on
/// purpose. A Swift renderer standing by would be the cross-language mirror this tree forbids, and
/// it is exactly what the daemon was built to delete.
///
/// Accepted gaps (docs/DECISIONS.md 2026-07-25): OSC 8 hyperlinks and app-set palette colors are
/// not modeled; `REP` across the snapshot boundary repeats nothing; the saved-cursor slot restores
/// position, not its saved SGR/charset.
public enum TerminalReplaySnapshot {
    /// The reattach composer: render `raw` as the minimal stream that reproduces its screen, with
    /// the net input modes re-asserted and the held-back tail re-attached after them.
    public static func compose(raw: Data, rows: Int, cols: Int) -> Data {
        (try? ScreenClient.shared.compose(
            raw: raw,
            rows: rows,
            cols: cols,
            reassertInputModes: true,
        )) ?? raw
    }

    /// The fresh-spawn (PATH B) variant: render the DEAD prior life's journal as a plain transcript.
    ///
    /// No input modes are re-asserted — the restored bytes front a NEW shell that must start with
    /// every TUI mode off. `rows`/`cols` are the prior life's LAST PTY size (the journal sidecar):
    /// the size the bytes were emitted for is the size that parses them faithfully.
    public static func composeTranscript(raw: Data, rows: Int, cols: Int) -> Data {
        (try? ScreenClient.shared.transcript(raw: raw, rows: rows, cols: cols)) ?? raw
    }
}
