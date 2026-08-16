import CSlopDeskFFI

/// What the host may listen on.
///
/// A face over `slopdesk-workspace`'s `listen`. The rule was written twice — here and in Rust, both
/// with the same comment naming the same two coercion bugs (`-5 → 0`, an OS-assigned port nobody
/// asked for and then persisted; `99999 → 65535`, while the field still read `99999`). The Rust
/// half had the tests and no caller, this half had the caller. One implementation now, and it is
/// the one with the tests.
///
/// The bind-conflict half of the same module is
/// ``SlopDeskTransportError/listenerDetailIndicatesAddressInUse(_:)``.
public enum PortValidation {
    /// Whether `raw` is a usable listen port. `0` is allowed and means "OS-assigned".
    public static func isValid(_ raw: Int) -> Bool {
        slopdesk_ws_listen_port_is_valid(Int64(raw))
    }

    /// `raw` as a bindable port, or `nil` when it is out of range. The UI starts ONLY on a non-nil
    /// result, which is what keeps the value the field displays and the value the host bound the
    /// same number.
    public static func port(_ raw: Int) -> UInt16? {
        guard isValid(raw) else { return nil }
        return UInt16(raw)
    }
}
