//! The accessibility TRUST grant, and nothing else.
//!
//! This module used to be the accessibility tree's host end — park a window on a display, put it
//! back, un-minimize it, resize it, raise it, sweep an app for what its windows are doing. Every
//! one of those had exactly one caller, the Swift video host, and that host is
//! `rust/slopdesk-videohostd` now: it links `slopdesk-apple-ax` and `slopdesk_video::ax_probe`
//! directly, in `windowplace`, `windowprobe` and `injector`, so the orchestration crosses no
//! boundary at all. What is left is the one accessibility question a CLIENT still asks.
//!
//! The client asks it because the client is the process that captures system keys: without the
//! grant the event tap it installs is created and then never called, which is indistinguishable
//! from a working tap that no key matched. So the grant is read on every status refresh, and the
//! prompt is offered once from the same surface — see `SystemKeyCaptureController`.

/// Whether this process holds the Accessibility grant.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_is_trusted() -> bool {
    slopdesk_apple_ax::is_trusted()
}

/// Asks for the Accessibility grant with the system prompt, and answers whether it is already held.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_prompt_for_trust() -> bool {
    slopdesk_apple_ax::prompt_for_trust()
}

#[cfg(test)]
mod tests {
    use super::slopdesk_ax_is_trusted;

    /// The trust read is a fact about the PROCESS, not a computation, so all a test can assert is
    /// that asking twice agrees — which is the property that lets it be called on every refresh.
    #[test]
    fn the_trust_read_is_stable_within_one_process() {
        assert_eq!(slopdesk_ax_is_trusted(), slopdesk_ax_is_trusted());
    }
}
