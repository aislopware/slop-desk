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
// surface a ``Slate/Metric/space2`` off the pane's edges; the ladder is mounted OUTSIDE that padding
// and is exactly that wide, so the whole instrument — marks and hit area alike — lives in ground the
// pane had already cleared. Two things follow, and both were bugs before: no tick can be drawn over
// a cell, and no click near the trailing edge is taken from the terminal (the rail used to hit-test a
// ``Slate/Metric/plate``-wide column straight through the last two text columns). Everything the
// ladder draws is measured from the rail's CENTRE LINE, so even the hover growth stays inside it.
//
// A DECORATION overlay at the ``TerminalLeafView`` seam the file reserved for block chrome (never
// a content branch — the libghostty-freeze guardrail).
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
    /// The PITCH LADDER — the only centre-to-centre spacings the rail is allowed to run at, widest
    /// first. A CLOSED scale, and that is the stability fix (user-reported 2026-08-09: the rail read
    /// as unsettled): the pitch used to be `available / count`, so in any pane too short for the
    /// preferred spacing EVERY tick shifted by a fraction of a point each time a command ran — a
    /// ladder that re-drew itself continuously while nothing about the old commands had changed.
    /// Quantized, the whole rail holds still until a rung is genuinely outgrown, and then moves once.
    static let pitchLadder: [CGFloat] = [10, 8, 6, 5, 4]

    /// The preferred centre-to-centre tick pitch — roomy enough to pick one tick with a pointer.
    static var preferredPitch: CGFloat { pitchLadder[0] }
    /// The floor pitch — below this the ticks fuse and the rail stops being an instrument, so the
    /// ladder DROPS oldest ticks instead of compressing further.
    static var minPitch: CGFloat { pitchLadder[pitchLadder.count - 1] }

    /// How many NEWEST ticks fit in `available` points, and at what pitch. The pitch steps down the
    /// ladder from ``preferredPitch`` to ``minPitch`` before any tick is dropped; a degenerate height
    /// (zero / negative / not a number) shows nothing.
    static func fit(count: Int, available: CGFloat) -> (shown: Int, pitch: CGFloat) {
        guard count > 0, available.isFinite, available >= minPitch else { return (0, preferredPitch) }
        // The widest rung the WHOLE set fits at — nothing is dropped while any rung still holds it.
        for pitch in pitchLadder where CGFloat(count) * pitch <= available {
            return (count, pitch)
        }
        // Past the floor: keep the floor pitch and show the newest ticks that fit in it.
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
                if fit.shown > 0 {
                    // The NEWEST `shown` blocks, oldest-first — the same slice the eye reads
                    // top→down in the scrollback itself.
                    let shown = Array(blocks.suffix(fit.shown))
                    ZStack(alignment: .bottom) {
                        track(height: CGFloat(fit.shown) * fit.pitch)
                        VStack(spacing: 0) {
                            ForEach(shown, id: \.index) { block in
                                LadderTick(
                                    block: block,
                                    onJump: onJump,
                                    onHover: { over in hoveredIndex = over ? block.index : nil },
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
        shown: [CommandBlock], fit: (shown: Int, pitch: CGFloat), available: CGFloat,
    ) -> some View {
        if let peekedIndex, let row = shown.firstIndex(where: { $0.index == peekedIndex }) {
            let entry = peeks[peekedIndex] ?? .unavailable
            let inset = Slate.Metric.ladderInset
            // The ticks are bottom-aligned inside the inset, so the ladder's top is measured back
            // from the pane's bottom — never from its top, which moves with the pane's height.
            let ladderTop = available - inset - CGFloat(fit.shown) * fit.pitch
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
    /// ``TerminalViewModel/copyBlockOutput(index:onResult:)``, which already coalesces a duplicate
    /// request and times out a lost reply). A RUNNING block is never fetched and never cached — the
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
        model.copyBlockOutput(index: index) { text in
            guard let text else {
                peeks[index] = .unavailable
                return
            }
            peeks[index] = .ready(
                BlockOutputPreviewBuilder.make(plainText: text, failed: failed),
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

    var body: some View {
        Button {
            if jumpable { onJump(block.index) }
        } label: {
            Capsule()
                .fill(ink)
                .frame(
                    width: hovering && jumpable ? Slate.Metric.ladderTickActive : Slate.Metric.ladderTick,
                    height: Slate.Metric.ladderTickWeight,
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
