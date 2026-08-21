//! What the host may bind, in C.
//!
//! One door over [`slopdesk_workspace::listen::port`]. The neighbouring predicate,
//! `slopdesk_ws_listen_port_is_valid`, has had one since the module was ported; this is the other
//! half of the same question, and it is here rather than beside it because what it settles is a
//! composition the near side had been doing for itself.
//!
//! ## The half that did not cross was the half that could disagree
//! `PortValidation.port` asked the range door and then made its own `UInt16` conversion, while
//! `listen::port` — which does both — had no caller and said so in its own doc comment. The two
//! agree today for a reason worth writing down exactly once: `u16`'s range IS the accepted range,
//! so a try-from and a range check cannot come apart. But that is a claim about the RULE, and the
//! near side was not asking for the rule; it was re-deriving it from a predicate, which is the
//! shape `docs/55` §8 catalogues under "a constant transcribed where a door already exists". A
//! range that stopped being `u16`'s — a reserved floor, a refusal of `0` — would have moved the
//! predicate and left the cast agreeing with nothing.
//!
//! The module the near side reaches keeps both entry points. `is_valid_port` is what a text field
//! asks on every keystroke to decide whether the Start button is dark, where there is no port to
//! carry back; this is what the bind asks once, where there is.

use slopdesk_workspace::listen;

/// `raw` as a bindable port, or `-1` for one out of range.
///
/// A signed answer rather than §4's `(out, cap) -> needed`, for [`crate::pane_kind`]'s reason: `0`
/// is a REAL answer here and a load-bearing one — it is the OS-assigned port — so the convention's
/// "`0` means there is no answer" is unavailable. `-1` is outside the answer's range by
/// construction, a port being an unsigned 16-bit number, and the return type says so rather than
/// being a `size_t` a caller could read as a length.
///
/// The refusal is a refusal and never a coercion. Clamping is what this module exists to prevent:
/// it mapped `-5` to `0`, an OS-assigned port nobody asked for and then persisted, and `99999` to
/// `65535` while the field on screen still read `99999`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_listen_port(raw: i64) -> i32 {
    listen::port(raw).map_or(-1, i32::from)
}

#[cfg(test)]
mod tests {
    use slopdesk_workspace::listen;

    use super::slopdesk_ws_listen_port;

    #[test]
    fn the_whole_accepted_range_crosses_as_itself() {
        assert_eq!(
            slopdesk_ws_listen_port(0),
            0,
            "the OS-assigned port is an answer, not a refusal"
        );
        assert_eq!(slopdesk_ws_listen_port(7420), 7420);
        assert_eq!(slopdesk_ws_listen_port(65_535), 65_535);
    }

    #[test]
    fn an_out_of_range_port_refuses_rather_than_being_coerced_to_an_edge() {
        // The two coercions the module was written against, neither of which happens here.
        assert_eq!(
            slopdesk_ws_listen_port(-5),
            -1,
            "not 0 — that is a port the operator did not ask for"
        );
        assert_eq!(
            slopdesk_ws_listen_port(99_999),
            -1,
            "not 65535 — the field would still read 99999"
        );
        assert_eq!(slopdesk_ws_listen_port(65_536), -1);
        assert_eq!(slopdesk_ws_listen_port(i64::MIN), -1);
        assert_eq!(slopdesk_ws_listen_port(i64::MAX), -1);
    }

    /// The door and the predicate beside it must not be able to answer different things about one
    /// number: a field that lights the Start button for a port the bind then refuses is exactly the
    /// desync both of them exist to close.
    #[test]
    fn the_door_refuses_precisely_what_the_range_predicate_refuses() {
        for raw in [-2_i64, -1, 0, 1, 80, 7420, 65_534, 65_535, 65_536, 70_000] {
            assert_eq!(
                slopdesk_ws_listen_port(raw) >= 0,
                listen::is_valid_port(raw),
                "{raw} crossed one way and validated the other",
            );
        }
    }
}
