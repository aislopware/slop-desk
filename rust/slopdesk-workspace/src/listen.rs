//! What the host may listen on, and what to tell the operator when it cannot.
//!
//! Two pure decisions the host UI makes before and after a bind attempt: whether a typed port is
//! usable at all, and whether a failure that looks retryable is really a port collision. Neither
//! needs a socket, which is why both are here rather than in the code that opens one.

/// The inclusive range a listen port field accepts. `0` means "OS-assigned".
pub const VALID_PORT_RANGE: core::ops::RangeInclusive<i64> = 0..=65_535;

/// `EADDRINUSE` on Darwin and the BSDs. The host is macOS-only, so this is the errno the framework
/// reports; naming it here keeps the number out of the two call sites that would otherwise spell
/// it.
pub const EADDRINUSE: i32 = 48;

/// Whether `raw` is a usable listen port.
///
/// The field is free-form and persisted as a signed integer, but a TCP port is `0..=65535`. An
/// out-of-range value is REJECTED — the Start button goes dark and the operator gets told — rather
/// than silently coerced. Coercion mapped `-5` to `0`, an OS-assigned port nobody asked for and
/// then persisted, and `99999` to `65535` while the field still read `99999`: in both cases the
/// displayed and persisted value desynced from what the host actually bound.
#[must_use]
pub const fn is_valid_port(raw: i64) -> bool {
    *VALID_PORT_RANGE.start() <= raw && raw <= *VALID_PORT_RANGE.end()
}

/// `raw` as a bindable port, or `None` when it is out of range.
///
/// The UI starts ONLY on a `Some`, which is what keeps the displayed value and the bound value the
/// same number.
#[must_use]
pub fn port(raw: i64) -> Option<u16> {
    u16::try_from(raw).ok()
}

/// `raw` clamped into [`VALID_PORT_RANGE`] — for a caller that wants to normalise the displayed
/// value rather than reject it.
#[must_use]
pub fn clamped_port(raw: i64) -> i64 {
    raw.clamp(*VALID_PORT_RANGE.start(), *VALID_PORT_RANGE.end())
}

/// Whether a listener-failure detail string says the bind failed because the address is already in
/// use.
///
/// The host classifier uses this to say "Port N is already in use" — actionable: change the port,
/// or kill the holder — instead of a generic "could not open port".
///
/// Robust against the false positives a loose substring search produces: a port number like `4843`,
/// a different errno like `148`, and a buffer size like `1048576` all embed "48" and none of them
/// is `EADDRINUSE`. So the errno matches only as a STANDALONE token, digit-bounded on both sides,
/// in addition to the canonical phrase the framework's own description produces.
#[must_use]
pub fn detail_indicates_address_in_use(detail: &str) -> bool {
    let lowered = detail.to_lowercase();
    lowered.contains("in use") || contains_standalone_number(&lowered, EADDRINUSE)
}

/// Whether a listener parked in the framework's retryable "no usable network path yet" state is
/// actually stuck on a NON-recoverable bind conflict.
///
/// Waiting is normally retryable — DHCP not up, Wi-Fi joining, a VPN coming up — and the framework
/// auto-recovers once a path appears, so the host should keep waiting. Surfacing it as a failure
/// would false-positive a host that started half a second before the network did.
///
/// The one exception is `EADDRINUSE`. On the common path a collision lands directly in `failed`,
/// but the state sequence is OS-version-dependent and on some versions the conflict STICKS in
/// `waiting` and never progresses — and it never auto-recovers either, because another process owns
/// the port. Treating only that errno as fatal-while-waiting lets the host say "port in use" at
/// once instead of burning the readiness timeout and then mis-reporting a bind collision as a
/// timeout. Every other waiting errno keeps waiting.
#[must_use]
pub const fn waiting_errno_is_fatal_bind_conflict(posix_errno: i32) -> bool {
    posix_errno == EADDRINUSE
}

/// Whether `haystack` contains the decimal `number` as a WHOLE token, not as part of a longer run
/// of digits.
///
/// So `48` matches in `"errno 48"` and `"posix(48)"` but not in `"4843"`, `"148"` or `"1048576"`.
fn contains_standalone_number(haystack: &str, number: i32) -> bool {
    let needle = number.to_string();
    let bytes = haystack.as_bytes();
    let mut from = 0;
    while let Some(offset) = haystack.get(from..).and_then(|rest| rest.find(&needle)) {
        let start = from + offset;
        let end = start + needle.len();
        let before_ok = start == 0 || !bytes.get(start - 1).is_some_and(u8::is_ascii_digit);
        let after_ok = !bytes.get(end).is_some_and(u8::is_ascii_digit);
        if before_ok && after_ok {
            return true;
        }
        from = end;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::{
        EADDRINUSE, clamped_port, contains_standalone_number, detail_indicates_address_in_use, is_valid_port,
        port, waiting_errno_is_fatal_bind_conflict,
    };

    #[test]
    fn the_range_is_zero_through_sixty_five_thousand_five_hundred_and_thirty_five() {
        assert!(is_valid_port(0));
        assert!(is_valid_port(7420));
        assert!(is_valid_port(65_535));
        assert!(!is_valid_port(-1));
        assert!(!is_valid_port(65_536));
        assert!(!is_valid_port(i64::MIN));
        assert!(!is_valid_port(i64::MAX));
    }

    #[test]
    fn an_out_of_range_port_is_refused_rather_than_coerced() {
        // The two coercions the Swift comment names, neither of which happens here.
        assert_eq!(port(-5), None);
        assert_eq!(port(99_999), None);
        assert_eq!(port(0), Some(0));
        assert_eq!(port(65_535), Some(65_535));
    }

    #[test]
    fn clamping_is_the_other_answer_for_a_caller_that_wants_to_normalise() {
        assert_eq!(clamped_port(-5), 0);
        assert_eq!(clamped_port(99_999), 65_535);
        assert_eq!(clamped_port(7420), 7420);
    }

    #[test]
    fn the_canonical_phrase_is_recognised_whatever_its_case() {
        assert!(detail_indicates_address_in_use("Address already in use"));
        assert!(detail_indicates_address_in_use("ADDRESS ALREADY IN USE"));
        assert!(detail_indicates_address_in_use("posix(48)"));
        assert!(detail_indicates_address_in_use("errno 48"));
    }

    #[test]
    fn the_errno_digits_inside_a_longer_number_are_not_a_bind_conflict() {
        // A port, a different errno, a buffer size — every one embeds "48".
        assert!(!detail_indicates_address_in_use("could not bind port 4843"));
        assert!(!detail_indicates_address_in_use("posix(148)"));
        assert!(!detail_indicates_address_in_use("send buffer 1048576 bytes"));
        assert!(!detail_indicates_address_in_use("no usable network path"));
        assert!(!detail_indicates_address_in_use(""));
    }

    #[test]
    fn a_standalone_number_is_bounded_on_both_sides_by_non_digits() {
        assert!(contains_standalone_number("48", 48));
        assert!(contains_standalone_number("x48", 48));
        assert!(contains_standalone_number("48x", 48));
        assert!(contains_standalone_number("a 48 b", 48));
        assert!(!contains_standalone_number("480", 48));
        assert!(!contains_standalone_number("148", 48));
        assert!(!contains_standalone_number("1481", 48));
        // The scan continues past a rejected match rather than stopping at the first one.
        assert!(contains_standalone_number("148 and 48", 48));
    }

    #[test]
    fn only_the_bind_conflict_errno_is_fatal_while_waiting() {
        assert!(waiting_errno_is_fatal_bind_conflict(EADDRINUSE));
        // ENETDOWN, ENETUNREACH, ETIMEDOUT, EAGAIN — every one of these keeps waiting.
        for errno in [50, 51, 60, 35, 0, -1] {
            assert!(!waiting_errno_is_fatal_bind_conflict(errno), "{errno}");
        }
    }
}
