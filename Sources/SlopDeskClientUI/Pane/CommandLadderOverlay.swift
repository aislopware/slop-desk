// CommandLadderOverlay — the pane's command LADDER (round 14, user-directed 2026-08-08): a thin
// instrument rail down the terminal's trailing edge, one tick per OSC-133 ``CommandBlock``,
// oldest at the top, newest at the bottom (the scrollback's own direction). Each tick speaks the
// block's OUTCOME in the GLASS's own status inks (running = the profile accent, clean = its green,
// failed = its red — never a new hue); a click jumps the pane's scrollback to that block through the
// SAME absolute re-anchor engine the Command Navigator uses
// (``WorkspaceStore/jumpToBlock(index:pane:)``), and the existing prompt-jump flash anchors the eye
// where it lands.
//
// IT STANDS IN THE PANE'S GUTTER, NOT ON THE TERMINAL (user-reported 2026-08-09: the rail was
// cutting into the content). ``TerminalLeafView`` already holds the terminal
// surface a ``Slate/Metric/paneGutter`` off the pane's sides; the ladder is mounted OUTSIDE that padding
// and is exactly that wide, so the whole instrument — marks and hit area alike — lives in ground the
// pane had already cleared. Two things follow, and both were bugs before: no tick can be drawn over
// a cell, and no click near the trailing edge is taken from the terminal (the rail used to hit-test a
// ``Slate/Metric/plate``-wide column straight through the last two text columns). Everything the
// ladder draws is measured from the rail's CENTRE LINE, so even the hover growth stays inside it.
//
// A DECORATION overlay at the ``TerminalLeafView`` seam the file reserved for block chrome (never
// a content branch — the libghostty-freeze guardrail).
//
// IT ENDS IN THE LIVE PROMPT (user-reported 2026-08-09: the rail indexed every command but had no
// rung for the prompt you are typing at). A block only exists once its command has RUN — the
// segmenter surfaces one at its `C` mark and explicitly discards a prompt still awaiting input
// (``CommandBlockSegmenter/peekOpenBlock()``), because a prompt is not a command — so while a pane
// sits idle the ladder's last tick is the PREVIOUS command and nothing on the rail points at the
// cursor. The foot rung (``LadderHomeMark``) is that pointer, one blank band below the ticks. It
// scrolls to the bottom rather than jumping to an ordinal: the live prompt has no block, and the
// bottom is where it lives.
//
// HONEST CEILING — ticks are EVENLY PITCHED, not scroll-proportional: a block carries its prompt
// ORDINAL (a 1-based prompt-cycle count), never a scrollback row, and the row math lives inside
// libghostty. A proportional minimap would therefore be a drawing of a guess; the even ladder is
// the truth we have (command N of M), in the "absent, never wrong" tradition of the other
// viewport overlays. Blocks whose ordinal is unknown (a mid-stream join) render dimmed and inert
// — a tick that cannot jump must not look like one that can.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The evenly-pitched ladder geometry — pure + static so the fit rule is unit-pinned headlessly.
enum CommandLadderLayout {
    /// What the rail resolved to for a given block count and height: how many command ticks it
    /// draws, at what pitch, and whether the foot's live-prompt mark and the blank band above it
    /// are there.
    struct Fit: Equatable {
        /// Command ticks drawn — the NEWEST this many blocks.
        var shown: Int
        /// The centre-to-centre spacing, always a rung of ``pitchLadder``.
        var pitch: CGFloat
        /// Whether the LIVE-PROMPT mark stands at the ladder's foot.
        var home: Bool
        /// Whether the blank band that sets the foot mark apart from the ticks is there — it is
        /// not, when there are no ticks for it to separate the mark from.
        var gapBand: Bool

        /// The rungs the whole instrument occupies, ticks + blank band + foot mark. The ladder's
        /// drawn height is this times ``pitch``, and the peek card's anchor is measured from it.
        var rungs: Int { shown + (gapBand ? 1 : 0) + (home ? 1 : 0) }
    }

    /// What the LIVE-PROMPT mark costs the ladder: its own rung plus ONE BLANK BAND above it.
    ///
    /// The blank band is what sets the foot mark apart, and it is a BAND rather than a fixed gap
    /// because the ticks' own visual spacing is `pitch - weight` — a constant gap tuned to read as
    /// a break at the preferred pitch (12pt of clear rail between dashes) would read as no break at
    /// all at the floor (4pt). One empty rung is a break at every rung of the ladder.
    static let homeRungs = 2

    /// The PITCH LADDER — the only centre-to-centre spacings the rail is allowed to run at, widest
    /// first. A CLOSED scale, and that is the stability fix (user-reported 2026-08-09: the rail read
    /// as unsettled): the pitch used to be `available / count`, so in any pane too short for the
    /// preferred spacing EVERY tick shifted by a fraction of a point each time a command ran — a
    /// ladder that re-drew itself continuously while nothing about the old commands had changed.
    /// Quantized, the whole rail holds still until a rung is genuinely outgrown, and then moves once.
    ///
    /// The rungs were stepped UP a notch (user-directed 2026-08-09): the pitch is also the tick's hit
    /// HEIGHT, so a roomier ladder is a bigger target as much as it is a calmer drawing — with the
    /// wider rail it takes a tick's band from 8 × 10 to 12 × 14 points, a bit over twice the area.
    static let pitchLadder: [CGFloat] = [14, 12, 10, 8, 6]

    /// The preferred centre-to-centre tick pitch — roomy enough to pick one tick with a pointer.
    static var preferredPitch: CGFloat { pitchLadder[0] }
    /// The floor pitch — below this the ticks fuse and the rail stops being an instrument, so the
    /// ladder DROPS oldest ticks instead of compressing further.
    static var minPitch: CGFloat { pitchLadder[pitchLadder.count - 1] }

    /// How the rail resolves `count` blocks into `available` points, with the foot's live-prompt
    /// mark ALWAYS reserved for. The pitch steps down the ladder from ``preferredPitch`` to
    /// ``minPitch`` before any tick is dropped; a degenerate height (zero / negative / not a number)
    /// draws nothing at all, foot mark included.
    ///
    /// The foot mark is the LAST thing the ladder gives up: past the floor pitch it drops OLDEST
    /// commands to make room, because a rail with room for one rung should spend it on the way back
    /// to the cursor rather than on the oldest command in the scrollback.
    static func fit(count: Int, available: CGFloat) -> Fit {
        let rungs = rungFit(count: count + homeRungs, available: available)
        guard rungs.shown > 0 else {
            return Fit(shown: 0, pitch: rungs.pitch, home: false, gapBand: false)
        }
        let shown = max(0, rungs.shown - homeRungs)
        return Fit(shown: shown, pitch: rungs.pitch, home: true, gapBand: shown > 0)
    }

    /// How many of `count` evenly-pitched RUNGS fit in `available` points, and at what pitch — the
    /// bare spacing rule, blind to what any rung carries.
    private static func rungFit(count: Int, available: CGFloat) -> (shown: Int, pitch: CGFloat) {
        guard count > 0, available.isFinite, available >= minPitch else { return (0, preferredPitch) }
        // The widest rung the WHOLE set fits at — nothing is dropped while any rung still holds it.
        for pitch in pitchLadder where CGFloat(count) * pitch <= available {
            return (count, pitch)
        }
        // Past the floor: keep the floor pitch and show the newest rungs that fit in it.
        let shown = min(count, Int(available / minPitch))
        guard shown > 0 else { return (0, preferredPitch) }
        return (shown, minPitch)
    }
}

struct CommandLadderOverlay: View {
    /// The pane's terminal model — read for its OBSERVABLE block list.
    let model: TerminalViewModel
    /// The per-tick jump, wired to ``WorkspaceStore/jumpToBlock(index:pane:)`` by the leaf.
    let onJump: (UInt32) -> Void
    /// The FOOT rung's jump — back to the live prompt, wired to
    /// ``WorkspaceStore/scrollPaneToLivePrompt(pane:)`` by the leaf.
    let onJumpToLivePrompt: () -> Void

    /// Whether the pointer is over the rail strip — the ladder brightens from its resting
    /// presence (progressive disclosure: at rest it reads as texture, under the pointer as
    /// an instrument).
    @State private var railHover = false

    /// The tick the pointer is currently ON, if any. Drives the DWELL: `.task(id:)` keyed on it
    /// restarts (and cancels) the wait every time the pointer moves to another tick.
    @State private var hoveredIndex: UInt32?

    /// The block whose peek card is open, or `nil` when none is. Kept separate from
    /// ``hoveredIndex`` so the card SURVIVES the pointer sliding into the gap between two ticks —
    /// it closes when the rail is left, not when a tick is.
    @State private var peekedIndex: UInt32?

    /// Whether the peek is ARMED — the mode the dwell buys. While armed, moving to another tick
    /// opens its card at once; reading back through a session is then one gesture rather than a
    /// second per command.
    @State private var peekArmed = false

    /// The per-block excerpts, keyed by block index — one wire fetch per block, ever. Pruned to the
    /// live block set on each load so it can never outgrow the ring the blocks themselves live in.
    @State private var peeks: [UInt32: CommandLadderPeekEntry] = [:]

    var body: some View {
        let blocks = model.blocks.blocks
        if !blocks.isEmpty {
            GeometryReader { proxy in
                let inset = Slate.Metric.ladderInset
                let fit = CommandLadderLayout.fit(
                    count: blocks.count, available: proxy.size.height - inset * 2,
                )
                if fit.rungs > 0 {
                    // The NEWEST `shown` blocks, oldest-first — the same slice the eye reads
                    // top→down in the scrollback itself.
                    let shown = Array(blocks.suffix(fit.shown))
                    ZStack(alignment: .bottom) {
                        track(height: CGFloat(fit.rungs) * fit.pitch)
                        VStack(spacing: 0) {
                            ForEach(shown, id: \.index) { block in
                                LadderTick(
                                    block: block,
                                    onJump: onJump,
                                    onHover: { over in hoveredIndex = over ? block.index : nil },
                                )
                                .frame(height: fit.pitch)
                            }
                            if fit.gapBand {
                                // The break. An EMPTY rung, not a fixed gap — see
                                // ``CommandLadderLayout/homeRungs``.
                                Color.clear.frame(height: fit.pitch).allowsHitTesting(false)
                            }
                            if fit.home {
                                LadderHomeMark(
                                    onJump: onJumpToLivePrompt,
                                    // Entering the foot rung closes any open card WITHOUT disarming
                                    // the mode: the prompt is not a command and has no excerpt, and
                                    // leaving a command's card up while the pointer sits on the way
                                    // home would label the wrong rung.
                                    onHover: { over in
                                        if over {
                                            hoveredIndex = nil
                                            peekedIndex = nil
                                        }
                                    },
                                )
                                .frame(height: fit.pitch)
                            }
                        }
                    }
                    .padding(.vertical, inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(railHover ? 1 : Slate.Opacity.muted)
                    .onHover { railHover = $0 }
                    .animation(Slate.Anim.smallFade, value: railHover)
                    // AFTER the opacity, so the card reads at full strength while the rail behind it
                    // is still only as bright as the pointer has earned.
                    .overlay(alignment: .topLeading) {
                        peekCard(shown: shown, fit: fit, available: proxy.size.height)
                    }
                    // The DWELL. `.task(id:)` cancels on every change of the hovered tick, so a
                    // pointer sweeping across the rail on its way somewhere else arms nothing; once
                    // armed, the wait is skipped and the card follows the pointer immediately.
                    .task(id: hoveredIndex) {
                        guard let hoveredIndex else { return }
                        if !peekArmed {
                            try? await Task.sleep(for: CommandLadderPeekLayout.dwell)
                            guard !Task.isCancelled else { return }
                            peekArmed = true
                        }
                        peekedIndex = hoveredIndex
                        if let block = shown.first(where: { $0.index == hoveredIndex }) {
                            load(block, live: blocks)
                        }
                    }
                    // Leaving the rail ends the mode — after a grace, so crossing the gap at the
                    // rail's edge or a jittery exit does not close a card being read.
                    .task(id: railHover) {
                        guard !railHover else { return }
                        try? await Task.sleep(for: CommandLadderPeekLayout.grace)
                        guard !Task.isCancelled else { return }
                        peekArmed = false
                        peekedIndex = nil
                    }
                }
            }
            // The rail's OWN strip — the pane's inner gutter, and the ONLY thing this view occupies.
            // Fixed here rather than inside the geometry so the hit column is the same width whether
            // or not the ladder has anything to draw.
            .frame(width: Slate.Metric.ladderRail)
        }
    }

    /// The open peek card, hung off the rail beside its tick — nothing when the peek is closed or
    /// the peeked block has scrolled out of the shown slice.
    @ViewBuilder
    private func peekCard(
        shown: [CommandBlock], fit: CommandLadderLayout.Fit, available: CGFloat,
    ) -> some View {
        if let peekedIndex, let row = shown.firstIndex(where: { $0.index == peekedIndex }) {
            let entry = peeks[peekedIndex] ?? .unavailable
            let inset = Slate.Metric.ladderInset
            // The rungs are bottom-aligned inside the inset, so the ladder's top is measured back
            // from the pane's bottom — never from its top, which moves with the pane's height. It
            // is measured over ALL the rungs (`rungs`, not `shown`): the foot mark and its blank
            // band stand below the last tick, so a card anchored on the tick count alone would hang
            // two bands too low.
            let ladderTop = available - inset - CGFloat(fit.rungs) * fit.pitch
            let center = ladderTop + (CGFloat(row) + 0.5) * fit.pitch
            let height = CommandLadderPeekLayout.cardHeight(
                lineCount: entry.lineCount, hasFooter: entry.hasFooter,
            )
            CommandLadderPeekCard(block: shown[row], entry: entry)
                .offset(
                    x: -(Slate.Metric.ladderPeekWidth + Slate.Metric.ladderPeekGap),
                    y: CommandLadderPeekLayout.cardTop(
                        tickCenterY: center, cardHeight: height, available: available,
                    ),
                )
                .transition(.opacity)
                .animation(Slate.Anim.reveal, value: peekedIndex)
        }
    }

    /// Fetches `block`'s output excerpt ONCE and caches it (wire type 15 → 29 through
    /// ``TerminalViewModel/requestBlockOutputBytes(index:onResult:)``, which already coalesces a
    /// duplicate request and times out a lost reply). The RAW bytes, not the clipboard's stripped
    /// text: the excerpt keeps the colours the terminal drew it in, so the SGR runs must survive the
    /// trip. A RUNNING block is never fetched and never cached — the
    /// host retains a block's output only once it completes, so the request would come back empty
    /// and then be remembered as "unavailable" for a command that is about to have output.
    private func load(_ block: CommandBlock, live: [CommandBlock]) {
        guard block.status != .running, peeks[block.index] == nil else { return }
        // Prune to the blocks that still exist — the ring evicts, and a cache that does not follow
        // it would hold excerpts for commands the session no longer knows about.
        let indices = Set(live.map(\.index))
        peeks = peeks.filter { indices.contains($0.key) }
        guard block.outputLen > 0 else {
            // The command genuinely printed nothing — a different statement from "cannot show it".
            peeks[block.index] = .ready(
                BlockOutputPreview(lines: [], hiddenCount: 0, fromTail: block.isFailed),
            )
            return
        }
        peeks[block.index] = .loading
        let failed = block.isFailed
        let index = block.index
        model.requestBlockOutputBytes(index: index) { bytes in
            guard let bytes else {
                peeks[index] = .unavailable
                return
            }
            peeks[index] = .ready(
                BlockOutputPreviewBuilder.make(rawOutput: bytes, failed: failed),
            )
        }
    }

    /// The rail's TRACK — a hairline down the ladder's own extent, shown only under the pointer.
    /// It says how far the index runs (it is exactly as long as the ticks are), and it says it at the
    /// one moment the rail is being read as an instrument; at rest the marks stand alone, because a
    /// permanent line down the gutter would be a second edge beside the island's own.
    private func track(height: CGFloat) -> some View {
        Capsule()
            .fill(Slate.Terminal.edge)
            .frame(width: Slate.Metric.hairline, height: height)
            .opacity(railHover ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// The ladder's FOOT rung — the way back to the LIVE PROMPT, the row the cursor is blinking on.
///
/// The same stroke as every tick above it, run out to ``Slate/Metric/ladderHome`` and drawn in the
/// terminal's own FOREGROUND rather than an outcome ink: green, red and the accent each say
/// something about how a command went, and this rung is not a command. Always live — pressing it
/// while the viewport is already at the bottom is a harmless no-op, and that costs nothing next to
/// the observable viewport state a "dim when already home" rule would need (round 14 weighed exactly
/// that cost and dropped the moving viewport marker over it).
///
/// It carries NO peek card: there is no output to excerpt at a prompt that has not run anything.
private struct LadderHomeMark: View {
    let onJump: () -> Void
    /// Reported to the rail so it can close an open peek — the pointer has left the commands.
    let onHover: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onJump) {
            Capsule()
                .fill(Slate.Terminal.ink)
                .frame(
                    width: Slate.Metric.ladderHome,
                    height: hovering ? Slate.Metric.ladderTickWeightActive : Slate.Metric.ladderTickWeight,
                )
                // Same band + centred mark as a tick, so the foot rung is aimed at exactly like the
                // rest of the rail and its growth stays inside the gutter.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover {
            hovering = $0
            onHover($0)
        }
        .animation(Slate.Anim.smallFade, value: hovering)
        .accessibilityLabel("Jump to the current prompt")
    }
}

/// One ladder tick — the block's outcome as a short dash on the rail's centre line, clickable when
/// the block carries a jumpable prompt ordinal.
private struct LadderTick: View {
    let block: CommandBlock
    let onJump: (UInt32) -> Void
    /// Reported to the rail so it can run the peek's DWELL — the tick itself knows nothing about the
    /// card, it only says when the pointer is on it.
    let onHover: (Bool) -> Void

    @State private var hovering = false

    /// A mid-stream-join block (ordinal 0) cannot be jumped to — it renders dimmed and inert.
    private var jumpable: Bool { block.promptOrdinal != 0 }

    /// Whether the pointer has this tick AND this tick can be acted on — an inert rung must not grow
    /// under the pointer, or it advertises a jump it will refuse.
    private var caught: Bool { hovering && jumpable }

    var body: some View {
        Button {
            if jumpable { onJump(block.index) }
        } label: {
            Capsule()
                .fill(ink)
                .frame(
                    width: caught ? Slate.Metric.ladderTickActive : Slate.Metric.ladderTick,
                    height: caught ? Slate.Metric.ladderTickWeightActive : Slate.Metric.ladderTickWeight,
                )
                .opacity(jumpable ? 1 : Slate.Opacity.dim)
                // The hit target is the tick's whole pitch band across the rail, and the mark is
                // CENTRED in it on both axes — so the hover growth opens either side of the rail's
                // centre line instead of reaching back over the terminal.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!jumpable)
        .onHover {
            hovering = $0
            onHover($0)
        }
        .animation(Slate.Anim.smallFade, value: hovering)
        // NO `.help` — the peek card is this tick's tooltip now, and AppKit's own would open a
        // second, poorer one over it after its own delay.
        .accessibilityLabel(axLabel)
        .accessibilityValue(axValue)
    }

    /// The outcome ink — the GLASS's status vocabulary (``Slate/Terminal``), never the system status
    /// palette: this mark is drawn on the terminal, so it answers to the profile the terminal wears.
    private var ink: Color {
        switch block.status {
        case .running: Slate.Terminal.accent
        case .succeeded: Slate.Terminal.ok
        case .failed: Slate.Terminal.err
        }
    }

    /// The duration, spoken to VoiceOver — what the dropped `.help` tooltip used to carry beyond the
    /// label, kept on the accessibility surface rather than lost with it.
    private var axValue: String {
        block.durationLabel ?? ""
    }

    private var axLabel: String {
        switch block.status {
        case .running: "Running command \(block.commandText)"
        case .succeeded: "Command \(block.commandText) succeeded"
        case let .failed(code): "Command \(block.commandText) failed, exit \(code)"
        }
    }
}
#endif
