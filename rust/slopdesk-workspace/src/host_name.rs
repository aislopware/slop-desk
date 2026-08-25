//! What the chrome CALLS the host it is connected to.
//!
//! The user usually connects by ADDRESS, and the titlebar should still speak the host's NAME. So a
//! typed hostname is shortened to its first DNS label — `mac-studio.local` reads as `mac-studio` —
//! and a typed IP literal is left exactly as typed, because its dots separate octets rather than
//! labels. Resolving an address BACK to a name is a lookup and belongs to whoever owns the socket;
//! what is here is the two decisions that must not disagree with it.
//!
//! ## Why the literal test is written out rather than borrowed
//!
//! [`is_ip_literal`] answers what Darwin's `inet_pton` answers, and that is NOT what
//! `std::net::IpAddr::from_str` answers. The two disagree on inputs a person actually types, and
//! the disagreement is silent — it comes back as a WRONG LABEL, never as an error:
//!
//! * `010.0.0.1`. `inet_pton` reads a padded decimal octet and says yes; `std` rejects any leading
//!   zero outright. Borrowing `std` would make the chrome shorten that address to `010`.
//! * `fe80::1%en0`. `inet_pton` accepts the zone suffix a link-local address is useless without;
//!   `std` does not parse one at all.
//! * `::ffff:010.0.0.1`. The same padding rule, one level down, inside a v6 address's embedded v4
//!   tail.
//!
//! Each of those was MEASURED against the platform before it was written down here — the Swift this
//! replaces called `inet_pton` directly, so its answers are the contract, and the table in the
//! tests below is that measurement rather than a reading of anyone's documentation. Note that this
//! makes the rule DARWIN's: glibc rejects the leading zeros that BSD accepts, and this app has no
//! Linux client to disagree with.

use std::net::Ipv6Addr;

/// Whether `text` is a bare IP literal — octets or hextets, never DNS labels.
#[must_use]
pub fn is_ip_literal(text: &str) -> bool {
    is_v4(text) || is_v6(text)
}

/// The short display label for a HOSTNAME: its first DNS label.
///
/// An IP literal passes through unchanged, as does a label-less string. Borrows rather than
/// allocates: every answer is a slice of the input.
#[must_use]
pub fn short_label(name: &str) -> &str {
    if is_ip_literal(name) {
        return name;
    }
    name.split('.').next().unwrap_or(name)
}

/// Four DECIMAL octets, each at most 255, each allowed any number of leading zeros.
///
/// The padding is the whole reason this is spelled out: `0177.0.0.1` is 177.0.0.1 on this platform
/// and NOT 127.0.0.1 — `inet_pton` reads decimal even where the leading zero looks like C's octal.
fn is_v4(text: &str) -> bool {
    let mut octets = 0_usize;
    for part in text.split('.') {
        octets += 1;
        if octets > 4 || part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()) {
            return false;
        }
        // An all-zero part trims to nothing, which is the value zero.
        let digits = part.trim_start_matches('0');
        let value = if digits.is_empty() {
            0
        } else {
            match digits.parse::<u32>() {
                Ok(value) => value,
                Err(_) => return false,
            }
        };
        if value > 255 {
            return false;
        }
    }
    octets == 4
}

/// A v6 address, with the ZONE suffix `std` will not parse and the padded v4 tail it will not
/// accept.
fn is_v6(text: &str) -> bool {
    let (head, zone) = text
        .split_once('%')
        .map_or((text, None), |(head, zone)| (head, Some(zone)));
    // One `%` and one only: `fe80::1%` names an empty zone and is accepted, `fe80::1%%` is not an
    // address at all.
    if zone.is_some_and(|zone| zone.contains('%')) {
        return false;
    }
    unpadded_v4_tail(head).parse::<Ipv6Addr>().is_ok()
}

/// A v6 address's embedded v4 tail with its octets' padding removed, so `std`'s parser sees the
/// same address `inet_pton` does.
///
/// Everything else is handed over untouched — including a malformed tail, which `std` is then left
/// to reject. This only ever REMOVES leading zeros from four digit-only octets, so it cannot turn
/// text `inet_pton` rejects into text `std` accepts.
fn unpadded_v4_tail(head: &str) -> String {
    let Some((prefix, tail)) = head.rsplit_once(':') else {
        return head.to_owned();
    };
    if !tail.contains('.') || !is_v4(tail) {
        return head.to_owned();
    }
    let octets: Vec<&str> = tail
        .split('.')
        .map(|part| {
            let digits = part.trim_start_matches('0');
            if digits.is_empty() { "0" } else { digits }
        })
        .collect();
    format!("{prefix}:{}", octets.join("."))
}

#[cfg(test)]
mod tests {
    use super::{is_ip_literal, short_label};

    /// The platform's own answers, MEASURED by calling `inet_pton` through the Swift this replaces
    /// on 2026-08-26. Every line is a recorded answer and not a reading of a manual page — which is
    /// the point, because four of them are answers a manual page would not have predicted.
    const MEASURED: &[(&str, bool)] = &[
        // The ordinary ones.
        ("192.168.1.1", true),
        ("100.94.23.11", true),
        ("0.0.0.0", true),
        ("255.255.255.255", true),
        ("::1", true),
        ("::", true),
        ("fe80::1", true),
        ("2001:db8::1", true),
        ("1:2:3:4:5:6:7:8", true),
        ("::ffff:1.2.3.4", true),
        // Names, which is the whole point of asking.
        ("mac-studio", false),
        ("mac-studio.local", false),
        ("herdr.example.com", false),
        ("192.168.host", false),
        ("", false),
        // ⚠️ PADDED DECIMAL OCTETS ARE ACCEPTED, and read as decimal — `0177` is 177, not 127.
        // `std::net` rejects every one of these.
        ("010.0.0.1", true),
        ("0177.0.0.1", true),
        ("01.02.03.04", true),
        ("1.2.3.04", true),
        ("00.0.0.0", true),
        ("0000.0.0.0", true),
        ("::ffff:010.0.0.1", true),
        ("::ffff:0177.0.0.1", true),
        // ⚠️ A ZONE SUFFIX IS ACCEPTED, including an empty one — but only one `%`.
        ("fe80::1%en0", true),
        ("fe80::1%1", true),
        ("fe80::1%", true),
        ("fe80::1%%", false),
        ("1.2.3.4%en0", false),
        // Wrong shapes.
        ("1.2.3", false),
        ("1.2.3.4.5", false),
        ("1.2.3.4.", false),
        ("256.1.1.1", false),
        ("999.1.1.1", false),
        ("1.2.3.256", false),
        ("0x7f.0.0.1", false),
        ("-1.2.3.4", false),
        ("+1.2.3.4", false),
        ("1::2::3", false),
        ("12345::1", false),
        ("::1:", false),
        ("1:2:3:4:5:6:7:8:9", false),
        ("1.2.3.4:80", false),
        ("[::1]", false),
        // Surrounding space is NOT trimmed: `inet_pton` reads the whole string or nothing.
        (" 1.2.3.4", false),
        ("1.2.3.4 ", false),
        ("1.2.3.4\n", false),
    ];

    #[test]
    fn every_measured_answer_is_the_answer() {
        for (text, expected) in MEASURED {
            assert_eq!(
                is_ip_literal(text),
                *expected,
                "{text:?} — this is what the platform answered, so it is what this must answer",
            );
        }
    }

    #[test]
    fn a_hostname_is_cut_at_its_first_label() {
        assert_eq!(short_label("mac-studio.local"), "mac-studio");
        assert_eq!(short_label("herdr.example.com"), "herdr");
        assert_eq!(short_label("macstudio"), "macstudio");
        assert_eq!(short_label(""), "");
    }

    /// An address's dots separate OCTETS, not labels — cutting one at the first dot would name the
    /// host `192`.
    #[test]
    fn an_address_passes_through_whole() {
        assert_eq!(short_label("192.168.1.7"), "192.168.1.7");
        assert_eq!(short_label("fe80::1"), "fe80::1");
        assert_eq!(
            short_label("010.0.0.1"),
            "010.0.0.1",
            "the padded form is the one `std::net` would have shortened to `010`",
        );
    }
}
