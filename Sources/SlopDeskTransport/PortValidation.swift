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
    ///
    /// This asked ``isValid(_:)`` and then made its own `UInt16` conversion, which read as pure
    /// marshalling and was not: `listen::port` — the half that does BOTH — had no caller, so the
    /// refusal was decided in Rust and the conversion here, and the two agreed only because `u16`'s
    /// range happens to be the accepted range. That is a fact about today's rule, not a rule, and a
    /// range that stopped being `u16`'s (a reserved floor, a refusal of `0`) would have moved the
    /// predicate and left this cast agreeing with nothing. One door answers both halves now.
    ///
    /// `-1` is the refusal and it cannot collide with an answer, a port being unsigned; `0` is a
    /// real answer here and means "OS-assigned", which is why the door is not `(out, cap)`-shaped.
    public static func port(_ raw: Int) -> UInt16? {
        let answer = slopdesk_ws_listen_port(Int64(raw))
        guard answer >= 0 else { return nil }
        return UInt16(exactly: answer)
    }
}
