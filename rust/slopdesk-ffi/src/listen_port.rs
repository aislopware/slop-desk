//! The default port both ends dial, in C.
//!
//! ## The door that stood beside this one
//! `slopdesk_ws_listen_port` — `raw` as a bindable port, or `-1` for one out of range — was the
//! other half of this module and had exactly one caller, `PortValidation.swift`, which composed it
//! with the neighbouring range predicate to decide what a host may bind. `docs/63` G.3 deleted that
//! file with the rest of the Swift transport: the bind is `slopdesk_hostd`'s own now and asks
//! `slopdesk_workspace::listen::port` directly, in-process. `docs/55` §4b retires a door when its
//! far side goes away, so the door went and the rule it fronted stayed exactly where it was.

/// The port a host binds, and a client dials, when nobody says otherwise.
///
/// Here rather than behind the macOS gate with the rest of hostd's command line, because this is
/// the one fact in that domain BOTH ends need: the client's connect gate prefills it and the
/// menu-bar app seeds the host it starts with it. Three halves once spelled it separately and two
/// of them disagreed — the menu-bar app stored `7779` while the client dialled `7420`, so starting
/// a host from the menu bar and pressing Connect dialled a port nothing was listening on. A default
/// only one half knows is not a default.
///
/// `docs/55` §8's answer to that shape is a door, not a ratchet: the constant is in-process across
/// `CSlopDeskFFI`, so Swift ASKS rather than transcribing, and there is no second spelling for a
/// rule to have to compare.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_hostd_default_port() -> u16 {
    slopdesk_hostlaunch::args::DEFAULT_PORT
}

#[cfg(test)]
mod tests {
    use slopdesk_workspace::listen;

    use super::slopdesk_hostd_default_port;

    /// The default is a port the range rule accepts. A default the bind then refuses would be a
    /// host that cannot start on the one number nobody had to type.
    #[test]
    fn the_default_port_is_a_port_the_range_accepts() {
        let default = slopdesk_hostd_default_port();
        assert!(listen::is_valid_port(i64::from(default)));
        assert_eq!(listen::port(i64::from(default)), Some(default));
        assert_ne!(
            default, 0,
            "the default must not ask the OS for an ephemeral port"
        );
    }
}
