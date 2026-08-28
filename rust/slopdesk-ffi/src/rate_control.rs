//! One TABLE: the tuned defaults for the quantiser knobs.
//!
//! The two admission laws this module used to carry — what quantiser the encoder runs at, and
//! whether a client's recovery request may force a keyframe — were the HOST's, and the host is
//! `rust/slopdesk-videohostd` now. It folds `slopdesk_video::qp_control` and
//! `slopdesk_video::recovery_idr` in-process, so neither law crosses a boundary any more and the
//! handle the recovery policy used to need is a plain field on a session.
//!
//! What survives is the one thing a CLIENT still asks for. `VideoPreferences` shows the
//! `SLOPDESK_QP_*` knobs in the settings sidecar, and every one of them needs the number its parse
//! falls back TO. Those four were hardware-validated together; a client that re-declared them would
//! keep offering the old operating point after a retune with nothing to show it had diverged — no
//! build error, no failing test, just a settings screen that lies about the default.

use slopdesk_video::qp_control::QpConfig;

/// The quantiser bounds and step sizes, as they cross.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SlopDeskQpConfig {
    /// The sharpest — lowest — quantiser on a clean link.
    pub sharp: i32,
    /// The coarsest — highest — quantiser under sustained congestion.
    pub coarse: i32,
    /// The rise per congested report.
    pub up_step: i32,
    /// Clean reports per one-step sharpen.
    pub down_interval: i32,
}

impl SlopDeskQpConfig {
    /// These numbers for the crate's config.
    const fn of(config: QpConfig) -> Self {
        Self {
            sharp: config.sharp,
            coarse: config.coarse,
            up_step: config.up_step,
            down_interval: config.down_interval,
        }
    }
}

/// The tuned defaults for the quantiser knobs, so the fallback each `SLOPDESK_QP_*` parse falls
/// back TO is spelled once.
///
/// The numbers are unsanitised on purpose: they are already legal, and the controller that runs on
/// them sanitises whatever it is handed regardless. This door does not sanitise, and there is no
/// door that only sanitises — a rule the caller can skip is a rule that is sometimes not applied,
/// where a TABLE the caller can skip is a table nobody spelled twice.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_qp_config_default() -> SlopDeskQpConfig {
    SlopDeskQpConfig::of(QpConfig::default())
}

#[cfg(test)]
mod tests {
    use slopdesk_video::qp_control::QpConfig;

    use super::slopdesk_qp_config_default;

    /// The whole point of the door: the four numbers it answers are the crate's, not a second copy.
    #[test]
    fn the_defaults_door_answers_the_crate_s_own_table() {
        let crossed = slopdesk_qp_config_default();
        let native = QpConfig::default();
        assert_eq!(crossed.sharp, native.sharp);
        assert_eq!(crossed.coarse, native.coarse);
        assert_eq!(crossed.up_step, native.up_step);
        assert_eq!(crossed.down_interval, native.down_interval);
    }
}
