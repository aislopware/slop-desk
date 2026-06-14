//! Session bring-up control messages for the GUI video path — a port of Swift
//! `VideoControlCodec`.
//!
//! PATH 2 is plain UDP with no TCP handshake; a tiny control exchange (hello/helloAck/
//! bye, plus resize, keepalive, window/dialog discovery, and cadence) runs over the same
//! UDP path. Wire layout is `[u8 type][body]`, big-endian. Unknown types decode to
//! `Malformed` so an older peer drops them (forward-compatible).

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::{VideoRect, VideoSize};

/// One host-side shareable window in a [`VideoControlMessage::WindowList`] response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowSummary {
    /// Host `CGWindowID` to stream this window (put in a `hello`'s `requested_window_id`).
    pub window_id: u32,
    /// The owning application name.
    pub app_name: String,
    /// The window title (may be empty).
    pub title: String,
    /// Window width in points (clamped to `u16` on the wire).
    pub width: u16,
    /// Window height in points.
    pub height: u16,
}

/// One host-side SYSTEM dialog/prompt in a [`VideoControlMessage::SystemDialogList`]
/// response (e.g. a `SecurityAgent` password prompt).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemDialogSummary {
    /// Host `CGWindowID` — stream the dialog by putting this in a `hello`.
    pub window_id: u32,
    /// The owning process name (e.g. `SecurityAgent`).
    pub owner: String,
    /// The dialog title (often empty for `SecurityAgent`).
    pub title: String,
    /// Dialog width in points.
    pub width: u16,
    /// Dialog height in points.
    pub height: u16,
    /// True when the dialog raises Secure Event Input (pixels stream, keystrokes dropped).
    pub is_secure: bool,
}

/// A session bring-up / control message.
#[derive(Debug, Clone, PartialEq)]
pub enum VideoControlMessage {
    /// Client → host: open a session for `requested_window_id`, sized to `viewport`.
    Hello {
        /// Must equal the protocol version (strict check, no fallback).
        protocol_version: u16,
        /// The `CGWindowID` to remote.
        requested_window_id: u32,
        /// The client viewport size (points).
        viewport: VideoSize,
    },
    /// Host → client: accept/reject + negotiated capture size + current CG bounds +
    /// negotiated luma range.
    HelloAck {
        /// Whether the session was accepted.
        accepted: bool,
        /// The minted stream id.
        stream_id: u32,
        /// Negotiated capture width.
        capture_width: u16,
        /// Negotiated capture height.
        capture_height: u16,
        /// The window's current CG-top-left bounds (the input-mapping origin).
        window_bounds_cg: VideoRect,
        /// The encoded stream's luma swing (false ⇒ video-range, the default).
        full_range: bool,
    },
    /// Either side: clean session teardown.
    Bye,
    /// Client → host: the client surface settled to `desired`; re-size capture.
    ResizeRequest {
        /// The desired capture size (points).
        desired: VideoSize,
        /// Monotonic epoch so the host can drop a stale request.
        epoch: u32,
    },
    /// Host → client: capture was re-sized for the request carrying `epoch`.
    ResizeAck {
        /// The adopted capture width.
        capture_width: u16,
        /// The adopted capture height.
        capture_height: u16,
        /// The request epoch this acks.
        epoch: u32,
    },
    /// Client → host: zero-body liveness heartbeat.
    Keepalive,
    /// Client → host: session-less "what windows can I stream?" discovery request.
    ListWindows,
    /// Host → client: the shareable windows (picker source).
    WindowList(Vec<WindowSummary>),
    /// Client → host: the remote-window pane was focused; raise the captured window once.
    FocusWindow,
    /// Host → client: the stream's content cadence (FPS governor) changed.
    StreamCadence {
        /// The new content cadence in frames per second.
        fps: u16,
    },
    /// Client → host: session-less poll for open system dialogs.
    ListSystemDialogs,
    /// Host → client: the currently-open system dialogs.
    SystemDialogList(Vec<SystemDialogSummary>),
}

impl VideoControlMessage {
    /// The on-wire type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match self {
            Self::Hello { .. } => 1,
            Self::HelloAck { .. } => 2,
            Self::Bye => 3,
            Self::ResizeRequest { .. } => 4,
            Self::ResizeAck { .. } => 5,
            Self::Keepalive => 6,
            Self::ListWindows => 7,
            Self::WindowList(_) => 8,
            Self::FocusWindow => 9,
            Self::StreamCadence { .. } => 10,
            Self::ListSystemDialogs => 11,
            Self::SystemDialogList(_) => 12,
        }
    }

    /// Serialises the message. For list messages the CALLER must cap the list to fit one
    /// UDP datagram (control is not packetized); the count is truncated to `u16`.
    #[must_use]
    #[allow(clippy::too_many_lines)] // one flat match over 12 wire variants reads clearest inline.
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.put_u8(self.message_type());
        match self {
            Self::Hello {
                protocol_version,
                requested_window_id,
                viewport,
            } => {
                w.put_u16(*protocol_version);
                w.put_u32(*requested_window_id);
                w.put_f64(viewport.width);
                w.put_f64(viewport.height);
            }
            Self::HelloAck {
                accepted,
                stream_id,
                capture_width,
                capture_height,
                window_bounds_cg,
                full_range,
            } => {
                w.put_u8(u8::from(*accepted));
                w.put_u32(*stream_id);
                w.put_u16(*capture_width);
                w.put_u16(*capture_height);
                w.put_u8(u8::from(*full_range));
                w.put_f64(window_bounds_cg.origin.x);
                w.put_f64(window_bounds_cg.origin.y);
                w.put_f64(window_bounds_cg.size.width);
                w.put_f64(window_bounds_cg.size.height);
            }
            Self::Bye
            | Self::Keepalive
            | Self::ListWindows
            | Self::FocusWindow
            | Self::ListSystemDialogs => {}
            Self::ResizeRequest { desired, epoch } => {
                w.put_f64(desired.width);
                w.put_f64(desired.height);
                w.put_u32(*epoch);
            }
            Self::ResizeAck {
                capture_width,
                capture_height,
                epoch,
            } => {
                w.put_u16(*capture_width);
                w.put_u16(*capture_height);
                w.put_u32(*epoch);
            }
            Self::WindowList(windows) => {
                w.put_u16(windows.len() as u16);
                for window in windows {
                    w.put_u32(window.window_id);
                    w.put_u16(window.width);
                    w.put_u16(window.height);
                    w.put_length_prefixed_str(&window.app_name);
                    w.put_length_prefixed_str(&window.title);
                }
            }
            Self::StreamCadence { fps } => w.put_u16(*fps),
            Self::SystemDialogList(dialogs) => {
                w.put_u16(dialogs.len() as u16);
                for dialog in dialogs {
                    w.put_u32(dialog.window_id);
                    w.put_u16(dialog.width);
                    w.put_u16(dialog.height);
                    w.put_u8(u8::from(dialog.is_secure));
                    w.put_length_prefixed_str(&dialog.owner);
                    w.put_length_prefixed_str(&dialog.title);
                }
            }
        }
        w.into_vec()
    }

    /// Parses a control message. An unknown type byte is malformed; list records are read
    /// without pre-allocating against the untrusted count, so each short read fails fast.
    #[allow(clippy::too_many_lines)] // one flat match over 12 wire variants reads clearest inline.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = ByteReader::new(data);
        let kind = r.read_u8()?;
        match kind {
            1 => {
                let protocol_version = r.read_u16()?;
                let requested_window_id = r.read_u32()?;
                let width = r.read_finite_f64("hello.viewport.w")?;
                let height = r.read_finite_f64("hello.viewport.h")?;
                Ok(Self::Hello {
                    protocol_version,
                    requested_window_id,
                    viewport: VideoSize::new(width, height),
                })
            }
            2 => {
                let accepted = r.read_u8()? != 0;
                let stream_id = r.read_u32()?;
                let capture_width = r.read_u16()?;
                let capture_height = r.read_u16()?;
                let full_range = r.read_u8()? != 0;
                let bx = r.read_finite_f64("helloAck.bounds.x")?;
                let by = r.read_finite_f64("helloAck.bounds.y")?;
                let bw = r.read_finite_f64("helloAck.bounds.w")?;
                let bh = r.read_finite_f64("helloAck.bounds.h")?;
                Ok(Self::HelloAck {
                    accepted,
                    stream_id,
                    capture_width,
                    capture_height,
                    window_bounds_cg: VideoRect::xywh(bx, by, bw, bh),
                    full_range,
                })
            }
            3 => Ok(Self::Bye),
            4 => {
                let width = r.read_finite_f64("resizeRequest.w")?;
                let height = r.read_finite_f64("resizeRequest.h")?;
                let epoch = r.read_u32()?;
                Ok(Self::ResizeRequest {
                    desired: VideoSize::new(width, height),
                    epoch,
                })
            }
            5 => {
                let capture_width = r.read_u16()?;
                let capture_height = r.read_u16()?;
                let epoch = r.read_u32()?;
                Ok(Self::ResizeAck {
                    capture_width,
                    capture_height,
                    epoch,
                })
            }
            6 => Ok(Self::Keepalive),
            7 => Ok(Self::ListWindows),
            8 => {
                let count = r.read_u16()?;
                let mut windows = Vec::new();
                for _ in 0..count {
                    let window_id = r.read_u32()?;
                    let width = r.read_u16()?;
                    let height = r.read_u16()?;
                    let app_name = r.read_length_prefixed_str()?;
                    let title = r.read_length_prefixed_str()?;
                    windows.push(WindowSummary {
                        window_id,
                        app_name,
                        title,
                        width,
                        height,
                    });
                }
                Ok(Self::WindowList(windows))
            }
            9 => Ok(Self::FocusWindow),
            10 => Ok(Self::StreamCadence { fps: r.read_u16()? }),
            11 => Ok(Self::ListSystemDialogs),
            12 => {
                let count = r.read_u16()?;
                let mut dialogs = Vec::new();
                for _ in 0..count {
                    let window_id = r.read_u32()?;
                    let width = r.read_u16()?;
                    let height = r.read_u16()?;
                    let is_secure = r.read_u8()? != 0;
                    let owner = r.read_length_prefixed_str()?;
                    let title = r.read_length_prefixed_str()?;
                    dialogs.push(SystemDialogSummary {
                        window_id,
                        owner,
                        title,
                        width,
                        height,
                        is_secure,
                    });
                }
                Ok(Self::SystemDialogList(dialogs))
            }
            other => Err(VideoProtocolError::malformed(format!(
                "unknown video control message type {other}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(m: &VideoControlMessage) {
        assert_eq!(&VideoControlMessage::decode(&m.encode()).unwrap(), m);
    }

    #[test]
    fn round_trips_simple_variants() {
        round_trip(&VideoControlMessage::Hello {
            protocol_version: 7,
            requested_window_id: 0xDEAD_BEEF,
            viewport: VideoSize::new(1280.0, 800.0),
        });
        round_trip(&VideoControlMessage::HelloAck {
            accepted: true,
            stream_id: 42,
            capture_width: 1920,
            capture_height: 1080,
            window_bounds_cg: VideoRect::xywh(0.0, 25.0, 800.0, 600.0),
            full_range: true,
        });
        round_trip(&VideoControlMessage::Bye);
        round_trip(&VideoControlMessage::ResizeRequest {
            desired: VideoSize::new(640.5, 480.25),
            epoch: 3,
        });
        round_trip(&VideoControlMessage::ResizeAck {
            capture_width: 640,
            capture_height: 480,
            epoch: 3,
        });
        round_trip(&VideoControlMessage::Keepalive);
        round_trip(&VideoControlMessage::ListWindows);
        round_trip(&VideoControlMessage::FocusWindow);
        round_trip(&VideoControlMessage::StreamCadence { fps: 60 });
        round_trip(&VideoControlMessage::ListSystemDialogs);
    }

    #[test]
    fn round_trips_window_list() {
        let m = VideoControlMessage::WindowList(vec![
            WindowSummary {
                window_id: 1,
                app_name: "Google Chrome".to_owned(),
                title: "Tab — Title".to_owned(),
                width: 1200,
                height: 800,
            },
            WindowSummary {
                window_id: 2,
                app_name: "Terminal".to_owned(),
                title: String::new(),
                width: 80,
                height: 24,
            },
        ]);
        round_trip(&m);
    }

    #[test]
    fn round_trips_system_dialog_list() {
        let m = VideoControlMessage::SystemDialogList(vec![SystemDialogSummary {
            window_id: 9,
            owner: "SecurityAgent".to_owned(),
            title: String::new(),
            width: 400,
            height: 200,
            is_secure: true,
        }]);
        round_trip(&m);
    }

    #[test]
    fn unknown_type_is_malformed() {
        assert!(matches!(
            VideoControlMessage::decode(&[250]),
            Err(VideoProtocolError::Malformed(_))
        ));
    }

    #[test]
    fn bogus_window_count_fails_fast_not_oom() {
        // type 8, count = 65535, but no records → truncated on the first record read.
        let mut bytes = vec![8u8];
        bytes.extend_from_slice(&u16::MAX.to_be_bytes());
        assert!(matches!(
            VideoControlMessage::decode(&bytes),
            Err(VideoProtocolError::Truncated)
        ));
    }
}
