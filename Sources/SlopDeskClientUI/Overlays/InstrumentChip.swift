// InstrumentChip — the shared shell + the generic notice behind every transient instrument-voice chip.
//
// The copy receipt proved the shape: a high-frequency or invisible action gets a small fade-only chip
// speaking the instrument caps register — never a toast card (icon + X + body reads as spam and can
// occlude the prompt line). This file makes that shape reusable: `instrumentChipShell` is the ONE
// visual treatment (typography, raised surface, hairline, lift shadow) so `CopyReceiptChip` and
// `NoticeChip` can never drift apart, and `ChipNotice` is the pure value behind every non-copy cue
// (tab closed → ⇧⌘T reopens, Peek & Reply delivered) so wording stays unit-pinnable.
//
// `Slate.*` tokens only (the ds-leaks ratchet).

#if canImport(SwiftUI)
import SwiftUI

// MARK: - ChipNotice (the pure value behind a window-level transient cue)

/// One transient `LABEL · DETAIL` notice: `label` speaks the secondary caps register ("TAB CLOSED",
/// "REPLY SENT"), `detail` the primary data register (the actionable fact — "⇧⌘T REOPENS", the target
/// pane's title). `epoch` is the dwell-timer identity (a rapid successor RETARGETS the mounted chip —
/// the text hard-cuts and the dwell restarts, never a re-entrance animation).
public struct ChipNotice: Equatable, Sendable {
    /// Longest `detail` kept verbatim — a longer one is middle-agnostic tail-clipped at construction
    /// (deterministic, testable data-layer truncation) so the fixed-size chip can never outgrow the window.
    static let detailCap = 48

    public let label: String
    public let detail: String
    public let epoch: Int
    /// How long the chip dwells before expiring — per notice, because an undo affordance ("⇧⌘T REOPENS")
    /// needs more reading time than a pure confirmation.
    public let dwell: Duration

    public init(label: String, detail: String, epoch: Int, dwell: Duration) {
        self.label = label
        self.detail = detail.count > Self.detailCap
            ? String(detail.prefix(Self.detailCap - 1)) + "…"
            : detail
        self.epoch = epoch
        self.dwell = dwell
    }

    /// The full one-string form for accessibility + tests (mirrors `CopyReceipt.label`).
    public var accessibilityText: String { detail.isEmpty ? label : label + " · " + detail }
}

// MARK: - NoticeChip (the generic window-level chip view)

/// The generic twin of `CopyReceiptChip`: label secondary · detail primary, shared shell, fade-only,
/// dwell keyed on the notice epoch. Hit-transparent at the mount site (`OverlayHostView`).
struct NoticeChip: View {
    let notice: ChipNotice
    /// Called when the dwell elapses — the owner clears its notice, unmounting through the mount fade.
    let onExpire: () -> Void

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(notice.label)
                .foregroundStyle(Slate.Text.secondary)
            if !notice.detail.isEmpty {
                Text("·")
                    .foregroundStyle(Slate.Text.tertiary)
                Text(notice.detail)
                    .foregroundStyle(Slate.Text.primary)
            }
        }
        .modifier(InstrumentChipShell(accessibility: notice.accessibilityText))
        // Dwell timer, keyed on the notice epoch: a successor notice retargets the chip and restarts it.
        // A CANCELLED sleep must NOT expire — cancellation means a newer notice owns the chip or the chip
        // unmounted; calling `onExpire` then would kill the successor's dwell (the CopyReceiptChip rule).
        .task(id: notice.epoch) {
            guard await (try? Task.sleep(for: notice.dwell)) != nil else { return }
            onExpire()
        }
    }
}

// MARK: - InstrumentChipShell (the ONE shared chip treatment)

/// The shared chip shell: instrument small/medium + tracking over a raised surface with a hairline and
/// the small lift shadow that keeps a chip legible over busy terminal output (the ReadOnlyPill
/// treatment). One modifier so the copy receipt and every notice read as the same instrument.
struct InstrumentChipShell: ViewModifier {
    let accessibility: String

    func body(content: Content) -> some View {
        content
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .medium))
            .tracking(Slate.Typeface.instrumentTracking)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(Slate.Surface.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
            .shadow(color: Slate.State.shadow, radius: 4, x: 0, y: 1)
            .accessibilityLabel(accessibility)
    }
}
#endif
