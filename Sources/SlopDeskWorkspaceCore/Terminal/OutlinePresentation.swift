import Foundation

// MARK: - OutlinePresentation (E9 — the Outline tab's PURE presentation mapping)

/// The Outline tab's pure (no-SwiftUI) presentation mapping: a row's relative-timestamp string and its
/// exit-status gutter classification. Kept free of `Slate` / SwiftUI so the ONLY theme-coupled part is the
/// view's `Gutter → colour` map — the classification itself is headlessly unit-tested. Mirrors the
/// ``MetadataFormatting/uptime(_:)`` precedent (a single coarse unit; integer arithmetic only — no float).
public enum OutlinePresentation {
    /// Relative time from `from` to `now`: sub-second → "now", then "34s ago" / "4m ago" /
    /// "2h ago" / "3d ago" — the Outline row's exact shape (see `docs/ui-shell/screenshots/outline-panel.png` +
    /// `docs/ui-shell/spec/user-interface__outline.md` / `user-interface__details-panel.md`: "4m ago" / "7h ago" /
    /// "7s ago"). It carries the "ago" suffix
    /// that ``MetadataFormatting/uptime(_:)`` (the Process-section uptime) does NOT — that bare form is the
    /// uptime callers' contract, while THIS is read only by the Outline (`OutlineView`), so the suffix lives
    /// here. A SINGLE coarse unit; the Date delta is truncated to whole seconds ONCE and all bucketing is
    /// integer division + ordered integer comparison (no float `<`/`>`, per the codebase float-math
    /// convention). A `from` in the future (clock skew) clamps to "now" rather than emitting a negative string.
    public static func relativeTime(from: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(from)))
        if seconds == 0 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// The Outline row's exit-status gutter bucket — grey while running, green on success, red on a
    /// non-zero exit. The view maps this to `Slate.Status.ok` / `.err` / `Slate.Text.tertiary`, so this enum
    /// is the testable classification and the colour map is the only theme-coupled part.
    public enum Gutter: Equatable, Sendable {
        /// Still executing (no OSC 133 `D` yet) — a grey dot.
        case running
        /// Finished with exit 0 / no reported code — a green check.
        case succeeded
        /// Finished with a non-zero exit code — a red cross.
        case failed
    }

    /// Classifies a block's ``CommandBlock/status`` into a ``Gutter`` bucket (reusing the value type's own
    /// `running` / `succeeded` / `failed(code:)` derivation, so the host status and the Outline never
    /// disagree on what counts as success).
    public static func gutter(for block: CommandBlock) -> Gutter {
        switch block.status {
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        }
    }
}
