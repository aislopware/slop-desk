import Foundation

/// Pure TCP-port validation/normalization for the host UI (R16 HOSTVIEW-1).
///
/// The host port field is a free-form, persisted `Int`, but a TCP port is `0...65535` (where `0`
/// means "OS-assigned"). A negative or out-of-range value must be REJECTED — so the Start button is
/// disabled and the user gets feedback — rather than silently coerced by `UInt16(clamping: max(0, …))`,
/// which mapped `-5 → 0` (an OS-assigned port the user never asked for, then persisted) and
/// `99999 → 65535` (a port the field still displayed as `99999`), leaving the displayed/persisted
/// value desynced from what the host actually bound. Pure (`Int` only) so it is unit-testable with no
/// view or `HostController`.
public enum PortValidation {
    /// The inclusive range the field accepts: `0` (OS-assigned) … `65535`.
    public static let validRange: ClosedRange<Int> = 0...65535

    /// Whether `raw` is a usable listen port (`0` allowed = OS-assigned).
    public static func isValid(_ raw: Int) -> Bool { validRange.contains(raw) }

    /// `raw` as a bound `UInt16` port iff it is in range, else `nil`. The UI starts ONLY on a non-nil
    /// result, so the host never binds a coerced value (no display/actual desync).
    public static func port(_ raw: Int) -> UInt16? {
        guard isValid(raw) else { return nil }
        return UInt16(raw)
    }

    /// `raw` clamped into ``validRange`` — for a caller that wants to normalize the persisted/displayed
    /// value (a negative → `0`, an over-range → `65535`) rather than reject it.
    public static func clamped(_ raw: Int) -> Int {
        min(max(raw, validRange.lowerBound), validRange.upperBound)
    }
}
