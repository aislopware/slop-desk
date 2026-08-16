//! What the bridge says when it cannot do what was asked.
//!
//! Each variant carries ONE English sentence, and that sentence is what the panel renders — there
//! is no error code table on the client side and no second message written there. Two consequences
//! worth stating, because both were decisions:
//!
//! 1. **The strings are wire surface.** They cross the socket verbatim in `{"ok":false,"error":…}`.
//!    Rewording one changes what a user reads; it does not break a client, because no client
//!    matches on them.
//! 2. **They name the missing piece, not the layer.** "No adb on this host" beats "toolchain
//!    unavailable" by exactly the amount of searching it saves the person reading it.

use std::fmt;

/// Every way an operation can be refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeError {
    /// No `adb` anywhere the locator looks. Without it there is no Android panel at all.
    AdbMissing,
    /// No `emulator` binary — attached devices still list, AVDs cannot.
    EmulatorMissing,
    /// The jar is committed at `ThirdParty/tools/vendor/scrcpy-server`, so reaching this now means
    /// the daemon is running from outside a checkout — naming the checkout is the actionable part.
    ScrcpyServerMissing,
    /// `adb push` of the mirror server failed.
    PushFailed,
    /// `adb forward` refused to open the tunnel.
    ForwardFailed,
    /// The `adb shell` that starts the device-side server could not be spawned.
    LaunchFailed,
    /// The tunnel connected but the device-side server never wrote its first byte — which is the
    /// only proof it is up, since `adb forward` completes a handshake regardless.
    ServerDidNotStart,
    /// The serial is not one `adb` lists.
    UnknownDevice,
    /// The device exists but cannot take a mirror YET. "Yet" is the part the client needs: its
    /// reattempt loop is what turns this into a mirror twenty seconds later.
    DeviceStarting,
    /// `adb` sees it, the user has not tapped "Allow USB debugging".
    DeviceUnauthorized,
    /// The request line did not decode, or was missing a field its `op` requires.
    BadRequest,
}

impl BridgeError {
    /// The sentence the panel shows.
    #[must_use]
    pub const fn message(self) -> &'static str {
        match self {
            Self::AdbMissing => "No adb on this host. Install the Android SDK platform-tools.",
            Self::EmulatorMissing => "No emulator binary on this host — only attached devices can be listed.",
            Self::ScrcpyServerMissing => {
                "No scrcpy-server jar reachable. Run hostd from a SlopDesk checkout, or set \
                 SLOPDESK_ANDROID_SERVER_JAR."
            },
            Self::PushFailed => "Could not copy the mirror server onto the device.",
            Self::ForwardFailed => "adb refused to open a tunnel to the device.",
            Self::LaunchFailed => "Could not start the mirror server on the device.",
            Self::ServerDidNotStart => "The device accepted the connection but never answered.",
            Self::UnknownDevice => "That device is no longer attached.",
            Self::DeviceStarting => "The device is still starting up.",
            Self::DeviceUnauthorized => "Debugging has not been allowed on the device yet.",
            Self::BadRequest => "The bridge did not understand that request.",
        }
    }
}

impl fmt::Display for BridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message())
    }
}

impl std::error::Error for BridgeError {}

#[cfg(test)]
mod tests {
    use super::BridgeError;

    #[test]
    fn every_message_is_a_sentence_a_user_can_act_on() {
        // Not a style rule for its own sake: these strings ARE the panel's error text, so a variant
        // added without one would render as an empty banner.
        for error in [
            BridgeError::AdbMissing,
            BridgeError::EmulatorMissing,
            BridgeError::ScrcpyServerMissing,
            BridgeError::PushFailed,
            BridgeError::ForwardFailed,
            BridgeError::LaunchFailed,
            BridgeError::ServerDidNotStart,
            BridgeError::UnknownDevice,
            BridgeError::DeviceStarting,
            BridgeError::DeviceUnauthorized,
            BridgeError::BadRequest,
        ] {
            let message = error.message();
            assert!(!message.is_empty(), "{error:?} has no message");
            assert!(message.ends_with('.'), "{error:?} is not a sentence");
        }
    }
}
