// CommandLadderOverlay — the pane's command LADDER (round 14, user-directed 2026-08-08): a thin
// instrument rail down the terminal's trailing edge, one tick per OSC-133 ``CommandBlock``,
// oldest at the top, newest at the bottom (the scrollback's own direction). Each tick speaks the
// block's OUTCOME in the status inks the rail already owns (running = accent, clean = ok, failed
// = err — never a new hue); a click jumps the pane's scrollback to that block through the SAME
// absolute re-anchor engine the Command Navigator uses (``WorkspaceStore/jumpToBlock(index:pane:)``),
// and the existing prompt-jump flash anchors the eye where it lands.
//
// A DECORATION overlay at the ``TerminalLeafView`` seam the file reserved for block chrome (never
// a content branch — the libghostty-freeze guardrail). It occupies ONLY its own narrow trailing
// strip, so every click outside the rail still lands in the terminal.
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
    /// The preferred centre-to-centre tick pitch — roomy enough to pick one tick with a pointer.
    static let preferredPitch: CGFloat = 10
    /// The floor pitch — below this the ticks fuse and the rail stops being an instrument, so the
    /// ladder DROPS oldest ticks instead of compressing further.
    static let minPitch: CGFloat = 4

    /// How many NEWEST ticks fit in `available` points, and at what pitch. The pitch compresses
    /// from `preferredPitch` down to `minPitch` before any tick is dropped; a degenerate height
    /// (zero/negative) shows nothing.
    static func fit(count: Int, available: CGFloat) -> (shown: Int, pitch: CGFloat) {
        guard count > 0, available >= minPitch else { return (0, preferredPitch) }
        let capacity = Int(available / minPitch)
        let shown = min(count, capacity)
        guard shown > 0 else { return (0, preferredPitch) }
        let pitch = Double.minimum(preferredPitch, available / CGFloat(shown))
        return (shown, pitch)
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

    var body: some View {
        let blocks = model.blocks.blocks
        if !blocks.isEmpty {
            GeometryReader { proxy in
                let inset = Slate.Metric.space4
                let fit = CommandLadderLayout.fit(
                    count: blocks.count, available: proxy.size.height - inset * 2,
                )
                if fit.shown > 0 {
                    VStack(spacing: 0) {
                        // The NEWEST `shown` blocks, oldest-first — the same slice the eye reads
                        // top→down in the scrollback itself.
                        ForEach(blocks.suffix(fit.shown), id: \.index) { block in
                            LadderTick(block: block, onJump: onJump)
                                .frame(height: fit.pitch)
                        }
                    }
                    .padding(.vertical, inset)
                    // The rail's OWN strip — a plate-wide hover/hit column hugging the trailing
                    // edge; everything left of it stays the terminal's.
                    .frame(width: Slate.Metric.plate)
                    .opacity(railHover ? 1 : Slate.Opacity.muted)
                    .onHover { railHover = $0 }
                    .animation(Slate.Anim.smallFade, value: railHover)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
    }
}

/// One ladder tick — the block's outcome as a short trailing dash, clickable when the block
/// carries a jumpable prompt ordinal.
private struct LadderTick: View {
    let block: CommandBlock
    let onJump: (UInt32) -> Void

    @State private var hovering = false

    /// A mid-stream-join block (ordinal 0) cannot be jumped to — it renders dimmed and inert.
    private var jumpable: Bool { block.promptOrdinal != 0 }

    var body: some View {
        Button {
            if jumpable { onJump(block.index) }
        } label: {
            RoundedRectangle(cornerRadius: Slate.Metric.hairline)
                .fill(ink)
                .frame(width: hovering && jumpable ? 12 : 6, height: 2)
                .opacity(jumpable ? 1 : Slate.Opacity.dim)
                // The hit target is the tick's whole pitch band, not the 2pt dash.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, Slate.Metric.space1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!jumpable)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .help(helpText)
        .accessibilityLabel(axLabel)
    }

    /// The outcome ink — the status vocabulary the rail already speaks; never a new hue.
    private var ink: Color {
        switch block.status {
        case .running: Slate.State.accent
        case .succeeded: Slate.Status.ok
        case .failed: Slate.Status.err
        }
    }

    private var helpText: String {
        let command = block.commandText.isEmpty ? "(command)" : block.commandText
        let duration = block.durationLabel.map { " · \($0)" } ?? ""
        switch block.status {
        case .running: return "\(command) — running"
        case .succeeded: return command + duration
        case let .failed(code): return "\(command) — exit \(code)\(duration)"
        }
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
