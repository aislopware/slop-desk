// FileUploadProgress — one drag-drop upload's progress as the desktop pane renders it, with the two
// DERIVATIONS behind `slopdesk_workspace::gui_readout`, beside the glyph and the tint that already
// crossed for the same three-case phase.
//
// The stored properties stay here: the app-layer coordinator (which owns the PATH-4 reliable-channel
// client) maps its wire events onto this value and hands it to `RemoteWindowModel.upsertUpload(_:)`,
// and the pane overlay diffs it. What crossed is `fraction` and `isSettled`.
//
// ### Why four lines of arithmetic were worth a boundary crossing
//
// `CLAUDE.md`'s bit-exactness rule is the whole argument. `fraction` is two `UInt64`→`Double`
// conversions, one division and one `min`, IN THAT ORDER and with nothing fused. A second copy of
// those four lines — which is what a "keep it in Swift, it's trivial" answer means — is a copy that
// can be reassociated, or reach for `addingProduct`, and drift by one bit with every test still
// green. Keeping it on one side of the boundary means there is nothing to drift from.
//
// The crate's own module header spells the ordering out step by step; the shape of it is:
// COMPLETED short-circuits to 1 before any arithmetic happens, so a transfer whose size was never
// reported does not finish at an empty bar; a zero total short-circuits to 0 rather than dividing,
// because there is no fraction of an unknown size and an indeterminate bar is the renderer's
// business; and the ratio is ceilinged with `Double.minimum`-equivalent semantics rather than a `<`
// ternary, so a host that over-reports cannot push the bar past its track.

import CSlopDeskFFI
import Foundation

/// One drag-drop upload's progress, as the desktop pane renders it. A headless value type: the
/// app-layer coordinator maps its wire events onto this and hands it to
/// ``RemoteWindowModel/upsertUpload(_:)``; the pane overlay reads the list.
public struct FileUploadProgress: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case sending
        case completed
        case failed
    }

    /// Stable per-file id (a fresh UUID per dropped file), so re-drops never collide and an update
    /// finds its row regardless of ordering.
    public let id: UUID
    public var name: String
    public var sentBytes: UInt64
    public var totalBytes: UInt64
    public var phase: Phase
    /// A short failure reason for the row (nil unless `phase == .failed`).
    public var reason: String?

    public init(
        id: UUID,
        name: String,
        sentBytes: UInt64 = 0,
        totalBytes: UInt64 = 0,
        phase: Phase = .sending,
        reason: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
        self.phase = phase
        self.reason = reason
    }

    /// Completion fraction in `0...1` for a progress bar. A finished upload reads full even when the
    /// size was unknown (0 bytes / never reported); an in-flight one with no known size reads empty.
    public var fraction: Double {
        slopdesk_ws_gui_upload_fraction(phase.ffiByte, sentBytes, totalBytes)
    }

    /// Whether the upload has settled (completed or failed) — the coordinator schedules its dismissal.
    /// Failure settles as surely as success does; a row that lingered because the transfer ended badly
    /// would be the one row on the overlay that never goes away.
    public var isSettled: Bool {
        slopdesk_ws_gui_upload_is_settled(phase.ffiByte)
    }
}

/// The byte an upload phase crosses as — this enum's own declaration order, mirrored by the far
/// side's `UploadPhase`.
///
/// `package` rather than private, and here rather than beside a caller: the readout's stats door and
/// the two doors above read the SAME byte, so a row's bar and its mark can never be reading two
/// different phases.
package extension FileUploadProgress.Phase {
    var ffiByte: UInt8 {
        switch self {
        case .sending: 0
        case .completed: 1
        case .failed: 2
        }
    }
}
