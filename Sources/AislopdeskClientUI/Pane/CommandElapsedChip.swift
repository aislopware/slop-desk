// CommandElapsedChip — the transient long-command elapsed/outcome chip (design-craft pass, 2026-07-04;
// the Warp-blocks affordance, scoped to OUR chrome idiom). While the pane's NEWEST OSC-133 block has been
// running for ≥ 2s, a small glass chip in the pane's top-trailing pill stack ticks the live elapsed time
// ("4s", "1m 12s"); when that same block completes, the chip swaps to a brief OUTCOME (✓ + the
// host-measured duration, or ✗ + exit code + duration, red) and fades after a short linger. Everything is
// client-local: the running anchor is ``TerminalBlockModel/firstSeen(index:)`` (client-receive time — no
// wire change), the final number is the HOST-measured `durationMS` (jitter-free).
//
// GATING is the craft: the chip NEVER appears for keystroke-rhythm commands (< 2s), and an outcome shows
// ONLY for a block this pane actually WATCHED run (``ElapsedChipLatch``) — a reconnect resync that floods
// in already-completed history must not flash stale outcomes. The chip is a transient top-trailing pill
// (the `ReadOnlyPill` slot convention) — deliberately NOT a persistent footer (the pane footer was
// removed as low-value; this earns its space only while something is genuinely running).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// Pure presentation rules for the elapsed chip — separated from the view so the thresholds, label
/// formatting and outcome gating are unit-pinned headlessly.
enum ElapsedChipPresentation {
    /// How long a command must have been running before the chip appears — under this, the chip would
    /// flicker on every `ls` (the keystroke-frequency rule).
    static let appearThreshold: TimeInterval = 2
    /// How long the completion outcome lingers before fading.
    static let outcomeLinger: TimeInterval = 4

    /// Whether the RUNNING chip shows for a block first seen at `firstSeen`.
    static func runningVisible(firstSeen: Date, now: Date) -> Bool {
        now.timeIntervalSince(firstSeen) >= appearThreshold
    }

    /// Whether a completed block earns the outcome flash: only one long enough that the running chip was
    /// (or would have been) showing — gated on the HOST-measured duration so the rule can't drift from
    /// what the user saw.
    static func showsOutcome(durationMS: UInt32?) -> Bool {
        Double(durationMS ?? 0) >= appearThreshold * 1000
    }

    /// The live elapsed label: whole seconds under a minute ("4s"), then "1m 05s" — coarse on purpose
    /// (the final, precise number is the host's `durationLabel` on the outcome chip).
    static func elapsedLabel(from start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        guard total >= 60 else { return "\(total)s" }
        let seconds = total % 60
        let pad = seconds < 10 ? "0" : ""
        return "\(total / 60)m \(pad)\(seconds)s"
    }
}

/// The watched-it-run latch: an outcome may show ONLY for a block this latch previously folded as
/// RUNNING. A reconnect/resync that delivers already-completed blocks (never seen incomplete here) can
/// never latch an outcome — stale history must not flash. Pure + Equatable so the gate is unit-pinned.
struct ElapsedChipLatch: Equatable {
    /// The newest block index this latch has seen INCOMPLETE (the candidate for an outcome).
    private(set) var runningIndex: UInt32?
    /// The block whose completion outcome is currently lingering, if any.
    private(set) var outcomeIndex: UInt32?

    /// Folds the pane's newest-block state. Returns `true` when a FRESH outcome just latched (the caller
    /// starts the linger timer).
    mutating func fold(latestIndex: UInt32?, complete: Bool, durationMS: UInt32?) -> Bool {
        guard let latestIndex else { return false }
        if !complete {
            runningIndex = latestIndex
            return false
        }
        guard runningIndex == latestIndex else { return false }
        runningIndex = nil
        guard ElapsedChipPresentation.showsOutcome(durationMS: durationMS) else { return false }
        outcomeIndex = latestIndex
        return true
    }

    /// Ends the outcome linger (the view's timer expired, or the pane reset).
    mutating func clearOutcome() { outcomeIndex = nil }
}

/// The chip view — mounted UNCONDITIONALLY in the pane's top-trailing pill stack (so its latch state
/// survives its own hidden phases) and rendering nothing until a block earns it.
struct CommandElapsedChip: View {
    let blocks: TerminalBlockModel

    @State private var latch = ElapsedChipLatch()

    /// The Equatable snapshot of the newest block the latch folds on — index + completion + duration
    /// (a same-index running→complete update changes it; content-only updates don't re-fire the fold).
    private var latestKey: [UInt32]? {
        blocks.latest.map { [$0.index, $0.complete ? 1 : 0, $0.durationMS ?? 0] }
    }

    var body: some View {
        Group {
            if let latest = blocks.latest, !latest.complete,
               let started = blocks.firstSeen(index: latest.index)
            {
                // RUNNING: tick once a second from the client-receive anchor; hidden under the threshold.
                TimelineView(.periodic(from: started, by: 1)) { context in
                    if ElapsedChipPresentation.runningVisible(firstSeen: started, now: context.date) {
                        chip(
                            symbol: .timer, tint: .secondary,
                            text: ElapsedChipPresentation.elapsedLabel(from: started, now: context.date),
                        )
                    }
                }
            } else if let index = latch.outcomeIndex, let block = blocks.block(at: index),
                      block.complete, let duration = block.durationLabel
            {
                // OUTCOME: the host-measured duration, ✓ green / ✗ red with the exit code. Lingers
                // briefly (the `.task(id:)` below), then fades.
                chip(
                    symbol: block.isFailed ? .xmarkCircleFill : .checkmarkCircleFill,
                    tint: block.isFailed ? .red : .green,
                    text: block.isFailed
                        ? "exit \(block.exitCode.map(String.init) ?? "?") · \(duration)"
                        : duration,
                )
                .task(id: index) {
                    do { try await Task.sleep(for: .seconds(ElapsedChipPresentation.outcomeLinger)) }
                    catch { return } // torn down early (pane closed / new command) — never a late clear
                    latch.clearOutcome()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: latch.outcomeIndex)
        .onChange(of: latestKey) { _, _ in
            guard let latest = blocks.latest else { return }
            _ = latch.fold(
                latestIndex: latest.index, complete: latest.complete, durationMS: latest.durationMS,
            )
        }
    }

    private func chip(symbol: SFSymbol, tint: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemSymbol: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassPanel(radius: 6, shadowRadius: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command \(text)")
    }
}
#endif
