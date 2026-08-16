//! The ONE host the whole app connects to.
//!
//! Every terminal opens a channel on a single multiplexed TCP connection, and every video pane
//! opens a lane on a single UDP flow. There is deliberately no per-pane host or port: the transport
//! already pools both per host, so a per-pane address would be a second source of truth that could
//! disagree with the pooled one. What stays on a pane is only WHICH remote window it mirrors.
//!
//! This is the INTENT the connect gate dials from, not a live connection — the document holds no
//! socket.

/// The host and ports the whole app dials.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionTarget {
    /// The host every pane connects to.
    pub host: String,
    /// The multiplexed TCP port carrying the terminals.
    pub port: u16,
    /// The UDP port carrying encoded video frames.
    pub media_port: u16,
    /// The UDP port carrying the cursor side-channel.
    pub cursor_port: u16,
}

impl Default for ConnectionTarget {
    /// The local host on the conventional ports — what the connect gate prefills before anything
    /// has been saved.
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_owned(),
            port: 7420,
            media_port: 9000,
            cursor_port: 9001,
        }
    }
}

impl ConnectionTarget {
    /// A target.
    #[must_use]
    pub const fn new(host: String, port: u16, media_port: u16, cursor_port: u16) -> Self {
        Self {
            host,
            port,
            media_port,
            cursor_port,
        }
    }

    /// The TCP port a drag-and-drop upload dials.
    ///
    /// DERIVED as the terminal port plus two — one past the inspector's plus one — rather than
    /// stored, because the daemon binds the same offset from the same base. A stored field could
    /// drift from what the daemon actually bound and would have to be carried through every saved
    /// document for nothing.
    ///
    /// It wraps rather than saturating so the arithmetic matches the daemon's byte for byte at the
    /// top of the port range; a base that high is not a port anything binds in practice.
    #[must_use]
    pub const fn file_port(&self) -> u16 {
        self.port.wrapping_add(2)
    }
}

#[cfg(test)]
mod tests {
    use super::ConnectionTarget;

    #[test]
    fn the_default_is_the_local_host_on_the_conventional_ports() {
        let target = ConnectionTarget::default();
        assert_eq!(target.host, "127.0.0.1");
        assert_eq!(
            (target.port, target.media_port, target.cursor_port),
            (7420, 9000, 9001)
        );
    }

    #[test]
    fn the_file_port_tracks_the_terminal_port() {
        assert_eq!(ConnectionTarget::default().file_port(), 7422);
        assert_eq!(
            ConnectionTarget::new("10.0.0.1".to_owned(), 1234, 9000, 9001).file_port(),
            1236,
        );
    }

    #[test]
    fn a_port_at_the_top_of_the_range_wraps_exactly_as_the_daemon_does() {
        assert_eq!(
            ConnectionTarget::new("10.0.0.1".to_owned(), u16::MAX, 9000, 9001).file_port(),
            1,
        );
    }
}
