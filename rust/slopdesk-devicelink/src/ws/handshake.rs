//! The RFC 6455 opening handshake, as two pure halves: the request a client writes, and the answer
//! it is allowed to accept.
//!
//! ## Why the accept header is verified rather than glanced at
//!
//! RFC 6455 §4.1 makes it a MUST, and the failure it prevents is not theoretical on a mesh where
//! any port may be forwarded to anything: a plain TCP service that echoes, or a server that answers
//! `101` without understanding the upgrade, would otherwise be read as a live websocket and the
//! first frame parse would report a malformed frame rather than the wrong port. Verifying the
//! digest is twenty bytes of work once per dial and turns that into "the handshake failed".
//!
//! ## The key is not a secret
//!
//! `Sec-WebSocket-Key` exists to keep an intermediary cache from being poisoned into replaying a
//! response to a later request, so its randomness matters exactly as much as there are
//! intermediaries — and on this link there are none. It is therefore derived from the clock rather
//! than from an entropy source this tree does not otherwise carry, which keeps the crate free of a
//! random dependency for a value whose only real job is to be different from the last one.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

/// The GUID RFC 6455 §1.3 appends to the key before hashing. Constant for the protocol version.
const ACCEPT_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// The port a `ws://` URL means when it names none.
const DEFAULT_PORT: u16 = 80;

/// A dial, ready to perform: where to connect, what to write, and what the answer must contain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dial {
    /// The authority's host, as written — a name or a literal address.
    pub host: String,
    /// The authority's port, defaulted to 80 when the URL named none.
    pub port: u16,
    /// The whole request head, terminated. Written verbatim.
    pub request: Vec<u8>,
    /// The `Sec-WebSocket-Accept` value the response must carry.
    pub accept: String,
}

/// Plan the dial for one `ws://` URL, or `None` for one this client will not open.
///
/// Refused, each for its own reason: a scheme that is not `ws://` (see the crate header on
/// `wss://`), an empty host, and a port that does not parse — a URL that would open a socket to
/// somewhere other than what it names is worse than one that opens none.
///
/// `seed` is the clock reading the key is derived from; see the module header.
#[must_use]
pub fn dial(url: &str, seed: u64) -> Option<Dial> {
    let rest = url.strip_prefix("ws://")?;
    let (authority, target) = match rest.find('/') {
        Some(at) => (rest.get(..at)?, rest.get(at..)?),
        None => (rest, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, port.parse().ok()?),
        None => (authority, DEFAULT_PORT),
    };
    if host.is_empty() || port == 0 {
        return None;
    }

    let key = key(seed);
    let accept = accept_for(&key);
    let mut request = String::new();
    request.push_str("GET ");
    request.push_str(target);
    request.push_str(" HTTP/1.1\r\nHost: ");
    request.push_str(authority);
    request.push_str("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ");
    request.push_str(&key);
    request.push_str("\r\nSec-WebSocket-Version: 13\r\n\r\n");

    Some(Dial {
        host: host.to_owned(),
        port,
        request: request.into_bytes(),
        accept,
    })
}

/// The `Sec-WebSocket-Accept` value that answers `key`.
#[must_use]
pub fn accept_for(key: &str) -> String {
    let mut digest = sha1_smol::Sha1::new();
    digest.update(key.as_bytes());
    digest.update(ACCEPT_GUID.as_bytes());
    STANDARD.encode(digest.digest().bytes())
}

/// Whether a response head is the upgrade this dial asked for.
///
/// `head` is everything up to and including the blank line. Header names are compared
/// case-insensitively because HTTP says they are, and the value is trimmed because a server is
/// allowed to pad it — a comparison that missed either would reject a conforming server.
#[must_use]
pub fn accepted(head: &[u8], accept: &str) -> bool {
    let Ok(head) = core::str::from_utf8(head) else {
        return false;
    };
    let mut lines = head.split("\r\n");
    let Some(status) = lines.next() else {
        return false;
    };
    // The reason phrase is the server's to choose, so only the version and the code are read.
    if !status.starts_with("HTTP/1.1 101") && !status.starts_with("HTTP/1.0 101") {
        return false;
    }
    lines.any(|line| {
        line.split_once(':').is_some_and(|(name, value)| {
            name.trim().eq_ignore_ascii_case("sec-websocket-accept") && value.trim() == accept
        })
    })
}

/// One dial's key: sixteen bytes, base64'd, derived from `seed`.
fn key(seed: u64) -> String {
    let low = mix(seed).to_le_bytes();
    let high = mix(seed ^ 0x9E37_79B9_7F4A_7C15).to_le_bytes();
    let mut bytes = [0_u8; 16];
    for (slot, byte) in bytes.iter_mut().zip(low.into_iter().chain(high)) {
        *slot = byte;
    }
    STANDARD.encode(bytes)
}

/// `splitmix64`'s finaliser — enough to keep two readings taken microseconds apart from sharing
/// their high bits, which is the whole of what is asked of it here.
const fn mix(value: u64) -> u64 {
    let mut state = value.wrapping_add(0x9E37_79B9_7F4A_7C15);
    state = (state ^ (state >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    state = (state ^ (state >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    state ^ (state >> 31)
}

#[cfg(test)]
mod tests {
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]

    use super::{Dial, accept_for, accepted, dial};

    /// RFC 6455 §1.3's own worked example. The one vector that pins the digest, the GUID and the
    /// base64 together.
    #[test]
    fn the_rfc_s_own_key_answers_the_rfc_s_own_accept() {
        assert_eq!(
            accept_for("dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        );
    }

    #[test]
    fn a_url_without_a_port_dials_eighty_and_asks_for_the_root() {
        let planned = dial("ws://simulator.local/stream", 7).unwrap();
        assert_eq!(planned.host, "simulator.local");
        assert_eq!(planned.port, 80);
        let request = String::from_utf8(planned.request).unwrap();
        assert!(request.starts_with("GET /stream HTTP/1.1\r\n"), "{request}");
        assert!(request.contains("\r\nHost: simulator.local\r\n"), "{request}");
        assert!(request.ends_with("\r\n\r\n"), "{request}");
    }

    /// The query string is the dialect and the format; a target that dropped it would ask the
    /// server for its default rather than for what this build decodes.
    #[test]
    fn the_query_string_rides_the_request_line() {
        let planned = dial("ws://10.0.0.2:8080/stream/abc?format=h264&version=v2", 1).unwrap();
        assert_eq!(planned.port, 8080);
        let request = String::from_utf8(planned.request).unwrap();
        assert!(
            request.starts_with("GET /stream/abc?format=h264&version=v2 HTTP/1.1\r\n"),
            "{request}"
        );
        assert!(request.contains("\r\nHost: 10.0.0.2:8080\r\n"), "{request}");
    }

    #[test]
    fn a_scheme_this_client_does_not_speak_is_refused_rather_than_downgraded() {
        assert_eq!(dial("wss://simulator.local/stream", 1), None);
        assert_eq!(dial("http://simulator.local/stream", 1), None);
        assert_eq!(dial("simulator.local/stream", 1), None);
    }

    #[test]
    fn a_degenerate_authority_dials_nothing() {
        assert_eq!(dial("ws:///stream", 1), None);
        assert_eq!(dial("ws://host:0/stream", 1), None);
        assert_eq!(dial("ws://host:nine/stream", 1), None);
    }

    /// Two dials taken from two clock readings must not share a key, which is the only property
    /// asked of the derivation.
    #[test]
    fn two_seeds_answer_two_keys() {
        let first = dial("ws://h/s", 1).unwrap();
        let second = dial("ws://h/s", 2).unwrap();
        assert_ne!(first.request, second.request);
        assert_ne!(first.accept, second.accept);
    }

    #[test]
    fn the_upgrade_is_accepted_only_when_the_digest_matches() {
        let Dial { accept, .. } = dial("ws://h/s", 3).unwrap();
        let head = format!(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: \
             {accept}\r\n\r\n"
        );
        assert!(accepted(head.as_bytes(), &accept));
        // The same head with the digest of somebody else's key.
        let wrong = head.replace(&accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
        assert!(!accepted(wrong.as_bytes(), &accept));
    }

    /// A server that answers a normal status is a server that did not upgrade. The frame parser
    /// must never see its body.
    #[test]
    fn a_status_that_is_not_one_hundred_and_one_is_not_an_upgrade() {
        let accept = accept_for("dGhlIHNhbXBsZSBub25jZQ==");
        let head = format!("HTTP/1.1 200 OK\r\nSec-WebSocket-Accept: {accept}\r\n\r\n");
        assert!(!accepted(head.as_bytes(), &accept));
    }

    #[test]
    fn the_header_name_is_read_the_way_http_spells_it() {
        let accept = accept_for("dGhlIHNhbXBsZSBub25jZQ==");
        let head = format!("HTTP/1.1 101 Switching Protocols\r\nSEC-WEBSOCKET-ACCEPT:   {accept}  \r\n\r\n");
        assert!(accepted(head.as_bytes(), &accept));
    }

    #[test]
    fn a_head_that_is_not_text_is_not_an_upgrade() {
        assert!(!accepted(&[0xFF, 0xFE, 0xFD], "anything"));
    }
}
