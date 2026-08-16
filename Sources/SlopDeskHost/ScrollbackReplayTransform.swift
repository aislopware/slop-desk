import Foundation
import SlopDeskTransport

/// Builds the transform applied to replayed history — the scrollback ring's cold-reattach pass
/// (``MuxChannelSession/makeReplayBuffer()``) and the disk journal's restore
/// (``ScrollbackTranscripts``) — so both replay paths stay behaviour-identical.
///
/// ## What is here, and what is in screend
/// Nothing about the bytes is here any more. The seven passes are `rust/slopdesk-screend`'s
/// `sanitize` verb (``ScreenClient/sanitize(_:reassertInputModes:distill:)``), and the Swift
/// originals were DELETED when they moved: `TerminalInputModeStripper`, `AltScreenSegmentStripper`,
/// `SyncUpdateFrameCollapser`, `ScrollbackDistiller`, `TerminalQueryStripper`,
/// `PromptEOLMarkStripper`. Holding back the trailing half of a chunk-cut escape sequence went with
/// them in stage 26 (`docs/DECISIONS.md`): it was kept here on the theory that the ring boundary is
/// the host's bookkeeping, but every rule it applies is read out of the bytes, and leaving it here
/// made "append the reassert BEFORE the dangling half" a convention two call sites had to remember
/// instead of an invariant of the reply.
///
/// What is left is which of the two options the caller wants, and one env flag.
///
/// ## The passes, and why they are in that order
/// 1. Input modes — mouse / kitty-keyboard / in-band-resize changes are removed, so replayed
///    history can never transiently arm the client's input reporting (the reattach
///    `zsh: command not found: 18M65…` garbage fix). With `reassertInputModes` the NET final state
///    is re-appended AFTER every pass, so a session still inside a TUI keeps that TUI's modes across
///    a cold reattach. The ring path (live session) re-asserts; the journal path (a fresh shell
///    after a daemon restart) must NOT — there is no TUI to serve, and
///    ``ScrollbackTranscripts/sanitizeSuffix`` wants all-off. Runs FIRST, on the RAW stream: the
///    net state must be computed in true chronological order, and the distiller reorders it.
/// 2. Closed alt-screen segments (`?1049h…?1049l`) — a TUI's drawing contributes nothing to the
///    final display and costs tens of MiB that render as a pane "stuck inside vim". A segment still
///    open at end-of-stream (live TUI) is kept verbatim: that IS the repaint.
/// 3. Synchronized-output frames (`?2026h…?2026l`) that repaint in place — the INLINE-TUI (Claude
///    Code) counterpart of pass 2, which cannot see churn that never enters the alt screen.
/// 4. The line-overprint collapse — superseded revisions of a line a progress reporter overprints
///    with `CR` (`git push`, `swift build`, `npm`, `docker pull`). The third churn pass, for output
///    that is neither alt-screen nor sync-framed and so invisible to both siblings.
/// 5. `SLOPDESK_SCROLLBACK_DISTILL` — the B→C line-editor collapse, the ONE remaining opt-out.
///    Six env opt-outs used to exist; nobody wants the garbage back, and six flags for "do not show
///    garbage" is six ways to break a reattach with no way to notice.
/// 6. Terminal queries / echoed responses / stale colour state (the reattach "garbage input" fix).
/// 7. zsh `PROMPT_SP` mark+fill clusters, whose width-dependent overprint trick surfaces stray `%`
///    lines when history is replayed at a different grid width. Runs LAST: the earlier passes only
///    improve its cluster→`133;D`/`133;A` adjacency anchor.
///
/// ## There is no longer a "when screend is not there"
/// The passes used to be a screend verb, so an absent daemon meant the transform was the IDENTITY
/// and replayed history arrived RAW — uglier, and able to transiently arm the client's input
/// reporting until the shell's next prompt. That was the documented policy for every screend verb
/// (`docs/52`), and the alternative was believed to be a second implementation of six byte machines
/// in Swift.
///
/// It was neither. `sanitize` is a pure function — bytes in, bytes out, nothing remembered, nothing
/// that must outlive its caller — so `CLAUDE.md`'s own rule says it ships as a linked library, and
/// living behind a daemon was what cost it an `AF_UNIX` round trip over the whole retained history
/// in each direction plus a C function pointer back into Swift. It is `rust/slopdesk-sanitize` now,
/// linked by both screend and the app: one implementation, no socket, and no degraded path to
/// document.
enum ScrollbackReplayTransform {
    /// Whether the line-editor collapse runs — the ONE remaining opt-out.
    static func distills(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["SLOPDESK_SCROLLBACK_DISTILL"] != "0"
    }

    /// The transform itself, for the callers that hold bytes rather than a replay handle.
    static func make(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        reassertInputModes: Bool = false,
    ) -> (@Sendable (Data) -> Data) {
        let distill = distills(environment: env)
        return { @Sendable data in
            ReplayBuffer.sanitize(data, distill: distill, reassertInputModes: reassertInputModes)
        }
    }
}
