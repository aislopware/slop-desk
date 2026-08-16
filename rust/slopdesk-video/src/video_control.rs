//! Session control for the GUI video path — `Sources/SlopDeskVideoProtocol/VideoControlCodec.swift`
//! (doc 17 §3.6, doc 18).
//!
//! PATH 2 is plain UDP, so there is no TCP handshake like PATH 1's `hello`/`helloAck` (doc 20 §8).
//! A tiny control exchange runs over the SAME UDP path as the media:
//!
//! 1. client → host [`VideoControlMessage::Hello`] — the client, the window to remote, and the
//!    viewport size the host should size capture to;
//! 2. host → client [`VideoControlMessage::HelloAck`] — accept/reject, the negotiated capture
//!    dimensions, and the window's current CG top-left bounds (the input-mapping origin until the
//!    geometry channel updates it);
//! 3. either side sends [`VideoControlMessage::Bye`] to tear down cleanly.
//!
//! Everything after that trio is additive: in-session resize, discovery of windows and displays,
//! the host-window feed, blob transfers, and the live per-session knobs. Every message is
//! `[u8 type][body]`, big-endian, one datagram, never packetized.
//!
//! ## The unknown type byte is the whole compatibility story
//!
//! [`VideoControlMessage::decode`] answers `Malformed` for a type it does not know, and BOTH
//! consumers — the host's control handler and the client's datagram router — catch and DROP. That
//! is what makes every message after type 3 inert against an older peer rather than fatal: a new
//! host can add a message kind and an old client simply ignores it. It also means a message's
//! absence must be survivable by design, which is why, for example, a client that never receives
//! [`VideoControlMessage::DisplayMax`] just leaves its resize fields uncapped.
//!
//! ## Untrusted counts never pre-allocate
//!
//! Every list decoder reads its `u16` count and then reads records one at a time WITHOUT reserving
//! capacity. A hostile `count = 65535` with an empty body therefore fails on the first missing byte
//! with [`VideoProtocolError::Truncated`] instead of allocating for records that were never sent.
//!
//! ## Record strings are LOSSY, and that is the opposite of the other codecs
//!
//! [`crate::window_geometry`] and [`crate::input_event`] reject invalid UTF-8; this codec replaces
//! it. The asymmetry is deliberate and load-bearing. Those two carry a value the user SEES or
//! TYPES, where a substituted character is worse than a dropped update. A control datagram carries
//! a DECISION — a window list, a snapshot generation, a chunk of an icon — and dropping the whole
//! datagram over one bad byte in one window's title would lose the other nine windows with it. So a
//! mangled title becomes U+FFFD and the list still arrives.

use crate::bytes::{ByteReader, ByteWriter, truncating_u16};
use crate::error::{Result, VideoProtocolError};
use crate::geometry::{VideoRect, VideoSize};

/// One host-side shareable window in a [`VideoControlMessage::WindowList`] — the rows the client's
/// remote-window PICKER renders, the same data as `slopdesk-videohostd --list` over the wire.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WindowSummary {
    /// The host `CGWindowID` to put in a hello's `requested_window_id` to stream this window.
    pub window_id: u32,
    /// The owning application name, e.g. "Google Chrome".
    pub app_name: String,
    /// The window title; may be empty.
    pub title: String,
    /// Window width in points, clamped to `u16` on the wire.
    pub width: u16,
    /// Window height in points.
    pub height: u16,
}

/// Per-window state bits in a [`HostWindowRecord`] — the type-17 `flags` byte.
///
/// Unknown future bits decode INERTLY: they survive the round trip and an old client simply never
/// reads them.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct HostWindowFlags(u8);

impl HostWindowFlags {
    /// The window is on the active Space and not minimized (`kCGWindowIsOnscreen`).
    pub const ON_SCREEN: Self = Self(1 << 0);
    /// The window is minimized to the Dock (`AXMinimized`, best-effort).
    pub const MINIMIZED: Self = Self(1 << 1);
    /// The owning application is hidden (`NSRunningApplication.isHidden`).
    pub const APP_HIDDEN: Self = Self(1 << 2);
    /// The owning application is frontmost on the host.
    pub const FRONTMOST_APP: Self = Self(1 << 3);
    /// This window is the frontmost app's focused (first, layer-0) window — at most one per
    /// snapshot.
    pub const FOCUSED_WINDOW: Self = Self(1 << 4);

    /// Wraps a raw wire byte.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Self {
        Self(bits)
    }

    /// The raw wire byte.
    #[must_use]
    pub const fn bits(self) -> u8 {
        self.0
    }

    /// Whether every bit in `other` is set.
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The union of two masks.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// One host window in a [`VideoControlMessage::WindowFeedSnapshot`] — the host-windows RAIL's row
/// data (docs/45).
///
/// Richer than the picker's [`WindowSummary`]: it adds `bundle_id` for client-local app-icon
/// resolution, the state [`HostWindowFlags`], and a display ordinal. Record order on the wire is
/// host z-order front-to-back, which is free data for the client's FIRST seed and never a live sort
/// key — rail rows are position-stable after seeding.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostWindowRecord {
    /// The host `CGWindowID`; a hello's `requested_window_id` streams it.
    pub window_id: u32,
    /// Window width in points, clamped to `u16` on the wire.
    pub width_pt: u16,
    /// Window height in points.
    pub height_pt: u16,
    /// State bits.
    pub flags: HostWindowFlags,
    /// Ordinal of the display the window is on (0-based; 0 when unknown) — captions only.
    pub display_index: u8,
    /// The owning app's bundle identifier, empty when the process has none — the icon cache key.
    pub bundle_id: String,
    /// The owning application name — the section key and the empty-title fallback.
    pub app_name: String,
    /// The window title; may be empty, and the host caps it to
    /// [`VideoControlMessage::FEED_TITLE_MAX_BYTES`].
    pub title: String,
}

/// One host-side display in a [`VideoControlMessage::DisplayList`] — the full-desktop pane's
/// display targeting. The [`WindowSummary`] for whole displays.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DisplaySummary {
    /// The host `CGDirectDisplayID` to put in a [`VideoControlMessage::HelloDisplay`].
    pub display_id: u32,
    /// Display width in points.
    pub width: u16,
    /// Display height in points.
    pub height: u16,
    /// Whether this is the host's MAIN display — the default target, which
    /// `requested_display_id == 0` also resolves to.
    pub is_main: bool,
}

/// One host-side SYSTEM dialog in a [`VideoControlMessage::SystemDialogList`].
///
/// **DORMANT** (`docs/DECISIONS.md`, 2026-07-23): the system-dialog-pane feature is removed. The
/// codec and its golden vectors are kept so the wire stays pinned, but no shipped peer sends this.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SystemDialogSummary {
    /// Host `CGWindowID` — a hello's `requested_window_id` would stream the dialog.
    pub window_id: u32,
    /// The owning process name, e.g. `SecurityAgent`.
    pub owner: String,
    /// The dialog title, often empty — the owner is the useful label.
    pub title: String,
    /// Dialog width in points.
    pub width: u16,
    /// Dialog height in points.
    pub height: u16,
    /// A `SecurityAgent`/`coreauthd` secure-credential prompt.
    pub is_secure: bool,
}

/// One opaque content rectangle in a [`VideoControlMessage::ContentMask`] — capture PIXEL
/// coordinates, top-left origin, the decoder's texture space.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MaskRect {
    /// Left edge, capture pixels.
    pub x: u16,
    /// Top edge, capture pixels.
    pub y: u16,
    /// Width, capture pixels.
    pub width: u16,
    /// Height, capture pixels.
    pub height: u16,
}

/// A video-path control message.
#[derive(Debug, Clone, PartialEq)]
pub enum VideoControlMessage {
    /// Client → host: open a session for `requested_window_id`, sized to `viewport`.
    Hello {
        /// Must equal the host's protocol version exactly — no fallback, mirroring PATH 1.
        protocol_version: u16,
        /// The host `CGWindowID` to stream.
        requested_window_id: u32,
        /// The client surface size the host should size capture to.
        viewport: VideoSize,
    },
    /// Host → client: accept or reject, plus the negotiated capture size and the window's current
    /// CG top-left bounds. `full_range` tells the client the encoded stream's luma swing so it
    /// picks the matching decoder pixel format and shader coefficients FROM THE STREAM — see
    /// [`crate::ycbcr`].
    HelloAck {
        /// Whether the host accepted.
        accepted: bool,
        /// The minted session id.
        stream_id: u32,
        /// Negotiated capture width, points.
        capture_width: u16,
        /// Negotiated capture height, points.
        capture_height: u16,
        /// The window's CG top-left bounds — the input-mapping origin until geometry updates.
        window_bounds_cg: VideoRect,
        /// `true` ⇒ full-range luma; `false` ⇒ video range, the default.
        full_range: bool,
    },
    /// Either side: clean session teardown.
    Bye,
    /// Client → host: the surface settled to `desired`; please re-size capture. `epoch` is a
    /// client-minted monotonic counter, so the host drops a stale request and a burst coalesces to
    /// the settled size.
    ResizeRequest {
        /// The settled client size, points.
        desired: VideoSize,
        /// The client's monotonic request counter.
        epoch: u32,
    },
    /// Host → client: capture was re-sized for the request carrying `epoch`; the client re-bases
    /// its aspect-fit denominator on it.
    ResizeAck {
        /// The applied capture width.
        capture_width: u16,
        /// The applied capture height.
        capture_height: u16,
        /// The epoch this answers.
        epoch: u32,
    },
    /// Client → host: a zero-body liveness heartbeat, so the host's idle reaper can tell a
    /// quiet-but-alive client from a crashed one that never sent [`VideoControlMessage::Bye`].
    Keepalive,
    /// Client → host: "what windows can I stream?" — session-LESS discovery, answered without
    /// minting a capture session.
    ListWindows,
    /// Host → client: the shareable windows.
    WindowList(Vec<WindowSummary>),
    /// Client → host: the pane was focused; raise the captured window ONCE, proactively, so the
    /// first click lands instantly instead of paying the activate-then-control stall. Idempotent.
    FocusWindow,
    /// Host → client: the stream's content cadence changed (the FPS governor). Duplicated ×2 about
    /// 25 ms apart for loss tolerance; the client's application is idempotent.
    StreamCadence {
        /// The governed content frames per second.
        fps: u16,
    },
    /// **DORMANT** — client → host poll for system dialogs. Kept for codec and golden stability.
    ListSystemDialogs,
    /// **DORMANT** — the answer to [`VideoControlMessage::ListSystemDialogs`].
    SystemDialogList(Vec<SystemDialogSummary>),
    /// Host → client: the per-frame content scroll offset in pixels, driving client-side scroll
    /// reprojection. `(0, 0)` means no confident scroll this frame.
    ScrollOffset {
        /// Signed horizontal shift, pixels.
        dx: i16,
        /// Signed vertical shift, pixels.
        dy: i16,
        /// Top of the moving-content band, ten-thousandths of frame height.
        band_top: u16,
        /// Bottom of the band. `band_bottom <= band_top` ⇒ no band, so the whole frame warps.
        band_bottom: u16,
    },
    /// Host → client: the opaque content sub-rectangles within the captured frame. An EMPTY list
    /// means the whole frame is opaque, which is the contracted default state.
    ContentMask(Vec<MaskRect>),
    /// Host → client: the maximum POINT size the captured window can be resized to, so the client's
    /// resize popover caps its fields at a reachable size.
    DisplayMax {
        /// Maximum width, points.
        width: u16,
        /// Maximum height, points.
        height: u16,
    },
    /// Client → host: "keep the host-window feed flowing; I hold `known_generation`" — the ONE
    /// session-less feed message (docs/45). It is the poll, the subscription renewal AND the
    /// loss-healing resync anchor at once. `0` means the client has nothing.
    WindowFeedSubscribe {
        /// The generation the client already holds.
        known_generation: u32,
    },
    /// Host → client: one chunk of the FULL host-window snapshot for `generation` — full snapshots,
    /// never deltas, so application is idempotent and latest-wins on a lossy lane.
    WindowFeedSnapshot {
        /// The snapshot generation.
        generation: u32,
        /// This chunk's index.
        chunk_index: u8,
        /// How many chunks the generation has; all chunks must agree.
        chunk_count: u8,
        /// The records in this chunk, host z-order front-to-back.
        records: Vec<HostWindowRecord>,
    },
    /// Host → client: "your generation is current — no snapshot coming". The five-byte ack that
    /// lets the client tell a quiet host from a lost snapshot.
    WindowFeedCurrent {
        /// The generation confirmed current.
        generation: u32,
    },
    /// Client → host: "send me `bundle_id`'s app icon at `size_px`" — session-less, answered with a
    /// [`VideoControlMessage::BlobChunk`] of kind 0.
    AppIconRequest {
        /// The requested icon edge in pixels.
        size_px: u16,
        /// The bundle identifier to resolve.
        bundle_id: String,
    },
    /// Host → client: one chunk of a binary blob — the ONE shared blob reply, for app icons
    /// (kind 0, PNG) and window previews (kind 1, JPEG).
    BlobChunk {
        /// 0 = app icon, 1 = window preview.
        blob_kind: u8,
        /// FNV-1a64 of the bundle id for icons; the window id for previews.
        blob_id: u64,
        /// Icons: the pixel edge. Previews: pixel width.
        meta_a: u16,
        /// Previews: pixel height. Unused for icons.
        meta_b: u16,
        /// This chunk's index.
        chunk_index: u8,
        /// How many chunks the blob has.
        chunk_count: u8,
        /// This chunk's bytes.
        bytes: Vec<u8>,
    },
    /// Client → host: "capture `window_id` as a one-shot preview at most `max_width_px` wide" — the
    /// rail's PEEK, session-less, and throttled hard on the host because `SCScreenshotManager`
    /// shares `WindowServer` with the live encoders.
    WindowPreviewRequest {
        /// The window to capture.
        window_id: u32,
        /// The preview's maximum pixel width.
        max_width_px: u16,
    },
    /// Client → host: "what displays can I stream?" — the [`VideoControlMessage::ListWindows`]
    /// mirror for whole displays.
    ListDisplays,
    /// Host → client: the online displays.
    DisplayList(Vec<DisplaySummary>),
    /// Client → host: open a FULL-DESKTOP session streaming `requested_display_id` (`0` = the main
    /// display). The host answers with the SAME [`VideoControlMessage::HelloAck`] shape, where the
    /// bounds carry the DISPLAY's — the client's decode, aspect-fit and input math are
    /// target-agnostic.
    HelloDisplay {
        /// Must equal the host's protocol version exactly.
        protocol_version: u16,
        /// The display to stream; `0` resolves to the main display.
        requested_display_id: u32,
        /// The client surface size.
        viewport: VideoSize,
    },
    /// Client → host: live per-session encode caps. `0` in either field means AUTO — clear that
    /// override. Out-of-range values CLAMP on the host at apply time rather than dropping the
    /// datagram; validate-then-drop stays at the length level.
    StreamSettings {
        /// Requested fps cap, or 0 for auto.
        fps_cap: u8,
        /// Requested bitrate ceiling in bits per second, or 0 for auto.
        bitrate_ceiling_bps: u32,
    },
    /// Client → host: the live per-session audio wish — turn the host's app-audio lane on or off.
    /// Per-session host state that dies with a session re-mint, so the client re-sends after every
    /// accepted (re-)hello.
    AudioControl {
        /// Whether audio should flow.
        enabled: bool,
    },
    /// Host → client: the HOST-side halves of the stats HUD at about 2 Hz — the smoothed RTT the
    /// host derives from the client's reports (the client cannot measure RTT itself; its telemetry
    /// is all relative) and the host's encode-wall-time EWMA. Both in TENTHS of a millisecond, `0`
    /// meaning no reading yet.
    HostStats {
        /// Smoothed round-trip time, tenths of a millisecond.
        rtt_tenths_millis: u16,
        /// Encode wall-time EWMA, tenths of a millisecond.
        encode_tenths_millis: u16,
    },
    /// Client → host: PRIVACY BLANK for a full-desktop session — black the streamed display with a
    /// zero gamma table AND swallow local input at the host, so a bystander at the physical Mac
    /// cannot see or interfere. Per-session host state that resets OFF on session mint.
    PrivacyMode {
        /// Whether the blank is on.
        enabled: bool,
    },
}

impl VideoControlMessage {
    /// One blob chunk's maximum data bytes: the 1200-byte datagram less 5 bytes of mux framing and
    /// the 18-byte message header. The host's chunker packs against this.
    pub const BLOB_BYTES_PER_CHUNK: usize = 1177;
    /// Validate-then-drop cap for an assembled app-icon blob.
    pub const ICON_BLOB_MAX_BYTES: usize = 32 * 1024;
    /// Validate-then-drop cap for an assembled window-preview blob.
    pub const PREVIEW_BLOB_MAX_BYTES: usize = 48 * 1024;
    /// The host-side byte cap for one snapshot chunk's RECORDS, excluding the 9-byte header:
    /// control datagrams are not packetized, so a chunk must fit one mux datagram. The host's
    /// packer greedy-packs against this; the codec does not enforce it, because decode is
    /// bounds-checked per field regardless.
    pub const FEED_RECORD_BYTES_PER_CHUNK: usize = 1186;
    /// The host-side UTF-8 byte cap for a [`HostWindowRecord::title`], truncated at a character
    /// boundary host-side — it bounds the worst-case record so the greedy packer always progresses.
    pub const FEED_TITLE_MAX_BYTES: usize = 120;

    /// The on-wire type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match *self {
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
            Self::ScrollOffset { .. } => 13,
            Self::ContentMask(_) => 14,
            Self::DisplayMax { .. } => 15,
            Self::WindowFeedSubscribe { .. } => 16,
            Self::WindowFeedSnapshot { .. } => 17,
            Self::WindowFeedCurrent { .. } => 18,
            Self::AppIconRequest { .. } => 19,
            Self::BlobChunk { .. } => 20,
            Self::WindowPreviewRequest { .. } => 21,
            Self::ListDisplays => 22,
            Self::DisplayList(_) => 23,
            Self::HelloDisplay { .. } => 24,
            Self::StreamSettings { .. } => 25,
            Self::AudioControl { .. } => 26,
            Self::HostStats { .. } => 27,
            Self::PrivacyMode { .. } => 28,
        }
    }

    /// Encodes the message to its `[u8 type][body]` wire form.
    ///
    /// For list messages the CALLER — always the host — must cap the list to one UDP datagram,
    /// because control is not packetized; the count truncates to `u16` like every wire count.
    #[must_use]
    #[expect(
        clippy::too_many_lines,
        reason = "one arm per wire message: splitting 28 flat field-writes across helpers would scatter the \
                  layout this function exists to state in one place"
    )]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::new();
        out.put_u8(self.message_type());
        match *self {
            Self::Hello {
                protocol_version,
                requested_window_id,
                viewport,
            } => {
                out.put_u16(protocol_version);
                out.put_u32(requested_window_id);
                out.put_f64(viewport.width);
                out.put_f64(viewport.height);
            },
            Self::HelloAck {
                accepted,
                stream_id,
                capture_width,
                capture_height,
                window_bounds_cg,
                full_range,
            } => {
                out.put_u8(u8::from(accepted));
                out.put_u32(stream_id);
                out.put_u16(capture_width);
                out.put_u16(capture_height);
                // The negotiated luma range sits after captureHeight, not at the end.
                out.put_u8(u8::from(full_range));
                out.put_f64(window_bounds_cg.origin.x);
                out.put_f64(window_bounds_cg.origin.y);
                out.put_f64(window_bounds_cg.size.width);
                out.put_f64(window_bounds_cg.size.height);
            },
            Self::Bye
            | Self::Keepalive
            | Self::ListWindows
            | Self::FocusWindow
            | Self::ListSystemDialogs
            | Self::ListDisplays => {},
            Self::ResizeRequest { desired, epoch } => {
                out.put_f64(desired.width);
                out.put_f64(desired.height);
                out.put_u32(epoch);
            },
            Self::ResizeAck {
                capture_width,
                capture_height,
                epoch,
            } => {
                out.put_u16(capture_width);
                out.put_u16(capture_height);
                out.put_u32(epoch);
            },
            Self::WindowList(ref windows) => {
                out.put_u16(truncating_u16(windows.len()));
                for window in windows {
                    out.put_u32(window.window_id);
                    out.put_u16(window.width);
                    out.put_u16(window.height);
                    put_length_prefixed_str(&mut out, &window.app_name);
                    put_length_prefixed_str(&mut out, &window.title);
                }
            },
            Self::StreamCadence { fps } => out.put_u16(fps),
            Self::SystemDialogList(ref dialogs) => {
                out.put_u16(truncating_u16(dialogs.len()));
                for dialog in dialogs {
                    out.put_u32(dialog.window_id);
                    out.put_u16(dialog.width);
                    out.put_u16(dialog.height);
                    out.put_u8(u8::from(dialog.is_secure));
                    put_length_prefixed_str(&mut out, &dialog.owner);
                    put_length_prefixed_str(&mut out, &dialog.title);
                }
            },
            Self::ScrollOffset {
                dx,
                dy,
                band_top,
                band_bottom,
            } => {
                // `i16` → `u16` is a bit-preserving reinterpret; the decoder casts straight back.
                out.put_u16(dx.cast_unsigned());
                out.put_u16(dy.cast_unsigned());
                out.put_u16(band_top);
                out.put_u16(band_bottom);
            },
            Self::ContentMask(ref rects) => {
                out.put_u16(truncating_u16(rects.len()));
                for rect in rects {
                    out.put_u16(rect.x);
                    out.put_u16(rect.y);
                    out.put_u16(rect.width);
                    out.put_u16(rect.height);
                }
            },
            Self::DisplayMax { width, height } => {
                out.put_u16(width);
                out.put_u16(height);
            },
            Self::WindowFeedSubscribe { known_generation } => out.put_u32(known_generation),
            Self::WindowFeedSnapshot {
                generation,
                chunk_index,
                chunk_count,
                ref records,
            } => {
                out.put_u32(generation);
                out.put_u8(chunk_index);
                out.put_u8(chunk_count);
                out.put_u16(truncating_u16(records.len()));
                for record in records {
                    out.put_u32(record.window_id);
                    out.put_u16(record.width_pt);
                    out.put_u16(record.height_pt);
                    out.put_u8(record.flags.bits());
                    out.put_u8(record.display_index);
                    put_length_prefixed_str(&mut out, &record.bundle_id);
                    put_length_prefixed_str(&mut out, &record.app_name);
                    put_length_prefixed_str(&mut out, &record.title);
                }
            },
            Self::WindowFeedCurrent { generation } => out.put_u32(generation),
            Self::AppIconRequest {
                size_px,
                ref bundle_id,
            } => {
                out.put_u16(size_px);
                put_length_prefixed_str(&mut out, bundle_id);
            },
            Self::BlobChunk {
                blob_kind,
                blob_id,
                meta_a,
                meta_b,
                chunk_index,
                chunk_count,
                ref bytes,
            } => {
                out.put_u8(blob_kind);
                out.put_u64(blob_id);
                out.put_u16(meta_a);
                out.put_u16(meta_b);
                out.put_u8(chunk_index);
                out.put_u8(chunk_count);
                out.put_u16(truncating_u16(bytes.len()));
                out.put_bytes(bytes);
            },
            Self::WindowPreviewRequest {
                window_id,
                max_width_px,
            } => {
                out.put_u32(window_id);
                out.put_u16(max_width_px);
            },
            Self::DisplayList(ref displays) => {
                out.put_u16(truncating_u16(displays.len()));
                for display in displays {
                    out.put_u32(display.display_id);
                    out.put_u16(display.width);
                    out.put_u16(display.height);
                    out.put_u8(u8::from(display.is_main));
                }
            },
            Self::HelloDisplay {
                protocol_version,
                requested_display_id,
                viewport,
            } => {
                out.put_u16(protocol_version);
                out.put_u32(requested_display_id);
                out.put_f64(viewport.width);
                out.put_f64(viewport.height);
            },
            Self::StreamSettings {
                fps_cap,
                bitrate_ceiling_bps,
            } => {
                out.put_u8(fps_cap);
                out.put_u32(bitrate_ceiling_bps);
            },
            Self::AudioControl { enabled } | Self::PrivacyMode { enabled } => {
                out.put_u8(u8::from(enabled));
            },
            Self::HostStats {
                rtt_tenths_millis,
                encode_tenths_millis,
            } => {
                out.put_u16(rtt_tenths_millis);
                out.put_u16(encode_tenths_millis);
            },
        }
        out.into_vec()
    }

    /// Decodes a message from its `[u8 type][body]` payload.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for a short body — including a list whose declared count
    /// outruns the datagram; [`VideoProtocolError::Malformed`] for an unknown type byte, a
    /// non-finite coordinate, or a chunk that does not name a real slot in a real sequence.
    #[expect(
        clippy::too_many_lines,
        reason = "the decode mirror of `encode`: one arm per wire message, kept flat for the same reason"
    )]
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(data);
        let kind = reader.read_u8()?;
        match kind {
            1 => {
                let protocol_version = reader.read_u16()?;
                let requested_window_id = reader.read_u32()?;
                let width = reader.read_finite_f64("hello.viewport.w")?;
                let height = reader.read_finite_f64("hello.viewport.h")?;
                Ok(Self::Hello {
                    protocol_version,
                    requested_window_id,
                    viewport: VideoSize::new(width, height),
                })
            },
            2 => {
                let accepted = reader.read_u8()? != 0;
                let stream_id = reader.read_u32()?;
                let capture_width = reader.read_u16()?;
                let capture_height = reader.read_u16()?;
                let full_range = reader.read_u8()? != 0;
                let x = reader.read_finite_f64("helloAck.bounds.x")?;
                let y = reader.read_finite_f64("helloAck.bounds.y")?;
                let width = reader.read_finite_f64("helloAck.bounds.w")?;
                let height = reader.read_finite_f64("helloAck.bounds.h")?;
                Ok(Self::HelloAck {
                    accepted,
                    stream_id,
                    capture_width,
                    capture_height,
                    window_bounds_cg: VideoRect::xywh(x, y, width, height),
                    full_range,
                })
            },
            3 => Ok(Self::Bye),
            4 => {
                let width = reader.read_finite_f64("resizeRequest.w")?;
                let height = reader.read_finite_f64("resizeRequest.h")?;
                let epoch = reader.read_u32()?;
                Ok(Self::ResizeRequest {
                    desired: VideoSize::new(width, height),
                    epoch,
                })
            },
            5 => {
                let capture_width = reader.read_u16()?;
                let capture_height = reader.read_u16()?;
                let epoch = reader.read_u32()?;
                Ok(Self::ResizeAck {
                    capture_width,
                    capture_height,
                    epoch,
                })
            },
            6 => Ok(Self::Keepalive),
            7 => Ok(Self::ListWindows),
            8 => {
                let count = usize::from(reader.read_u16()?);
                let mut windows = Vec::new();
                // Do NOT reserve for `count` — it is untrusted. Each record read fails the instant
                // the datagram runs short, so a bogus count cannot over-allocate or over-read.
                for _ in 0..count {
                    let window_id = reader.read_u32()?;
                    let width = reader.read_u16()?;
                    let height = reader.read_u16()?;
                    let app_name = read_length_prefixed_str(&mut reader)?;
                    let title = read_length_prefixed_str(&mut reader)?;
                    windows.push(WindowSummary {
                        window_id,
                        app_name,
                        title,
                        width,
                        height,
                    });
                }
                Ok(Self::WindowList(windows))
            },
            9 => Ok(Self::FocusWindow),
            10 => {
                Ok(Self::StreamCadence {
                    fps: reader.read_u16()?,
                })
            },
            11 => Ok(Self::ListSystemDialogs),
            12 => {
                let count = usize::from(reader.read_u16()?);
                let mut dialogs = Vec::new();
                for _ in 0..count {
                    let window_id = reader.read_u32()?;
                    let width = reader.read_u16()?;
                    let height = reader.read_u16()?;
                    let is_secure = reader.read_u8()? != 0;
                    let owner = read_length_prefixed_str(&mut reader)?;
                    let title = read_length_prefixed_str(&mut reader)?;
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
            },
            13 => {
                // The bit-preserving counterpart to the encoder's `cast_unsigned`.
                let dx = reader.read_u16()?.cast_signed();
                let dy = reader.read_u16()?.cast_signed();
                let band_top = reader.read_u16()?;
                let band_bottom = reader.read_u16()?;
                Ok(Self::ScrollOffset {
                    dx,
                    dy,
                    band_top,
                    band_bottom,
                })
            },
            14 => {
                let count = usize::from(reader.read_u16()?);
                let mut rects = Vec::new();
                for _ in 0..count {
                    let x = reader.read_u16()?;
                    let y = reader.read_u16()?;
                    let width = reader.read_u16()?;
                    let height = reader.read_u16()?;
                    rects.push(MaskRect { x, y, width, height });
                }
                Ok(Self::ContentMask(rects))
            },
            15 => {
                let width = reader.read_u16()?;
                let height = reader.read_u16()?;
                Ok(Self::DisplayMax { width, height })
            },
            16 => {
                Ok(Self::WindowFeedSubscribe {
                    known_generation: reader.read_u32()?,
                })
            },
            17 => {
                let generation = reader.read_u32()?;
                let chunk_index = reader.read_u8()?;
                let chunk_count = reader.read_u8()?;
                validate_chunk_slot("windowFeedSnapshot", chunk_index, chunk_count)?;
                let count = usize::from(reader.read_u16()?);
                let mut records = Vec::new();
                for _ in 0..count {
                    let window_id = reader.read_u32()?;
                    let width_pt = reader.read_u16()?;
                    let height_pt = reader.read_u16()?;
                    let flags = HostWindowFlags::from_bits(reader.read_u8()?);
                    let display_index = reader.read_u8()?;
                    let bundle_id = read_length_prefixed_str(&mut reader)?;
                    let app_name = read_length_prefixed_str(&mut reader)?;
                    let title = read_length_prefixed_str(&mut reader)?;
                    records.push(HostWindowRecord {
                        window_id,
                        width_pt,
                        height_pt,
                        flags,
                        display_index,
                        bundle_id,
                        app_name,
                        title,
                    });
                }
                Ok(Self::WindowFeedSnapshot {
                    generation,
                    chunk_index,
                    chunk_count,
                    records,
                })
            },
            18 => {
                Ok(Self::WindowFeedCurrent {
                    generation: reader.read_u32()?,
                })
            },
            19 => {
                let size_px = reader.read_u16()?;
                let bundle_id = read_length_prefixed_str(&mut reader)?;
                Ok(Self::AppIconRequest { size_px, bundle_id })
            },
            20 => {
                let blob_kind = reader.read_u8()?;
                let blob_id = reader.read_u64()?;
                let meta_a = reader.read_u16()?;
                let meta_b = reader.read_u16()?;
                let chunk_index = reader.read_u8()?;
                let chunk_count = reader.read_u8()?;
                validate_chunk_slot("blobChunk", chunk_index, chunk_count)?;
                let byte_count = usize::from(reader.read_u16()?);
                // `read_bytes` bounds-checks BEFORE reading, so a corrupt count drops the datagram.
                let bytes = reader.read_bytes(byte_count)?.to_vec();
                Ok(Self::BlobChunk {
                    blob_kind,
                    blob_id,
                    meta_a,
                    meta_b,
                    chunk_index,
                    chunk_count,
                    bytes,
                })
            },
            21 => {
                let window_id = reader.read_u32()?;
                let max_width_px = reader.read_u16()?;
                Ok(Self::WindowPreviewRequest {
                    window_id,
                    max_width_px,
                })
            },
            22 => Ok(Self::ListDisplays),
            23 => {
                let count = usize::from(reader.read_u16()?);
                let mut displays = Vec::new();
                for _ in 0..count {
                    let display_id = reader.read_u32()?;
                    let width = reader.read_u16()?;
                    let height = reader.read_u16()?;
                    let is_main = reader.read_u8()? != 0;
                    displays.push(DisplaySummary {
                        display_id,
                        width,
                        height,
                        is_main,
                    });
                }
                Ok(Self::DisplayList(displays))
            },
            24 => {
                let protocol_version = reader.read_u16()?;
                let requested_display_id = reader.read_u32()?;
                let width = reader.read_finite_f64("helloDisplay.viewport.w")?;
                let height = reader.read_finite_f64("helloDisplay.viewport.h")?;
                Ok(Self::HelloDisplay {
                    protocol_version,
                    requested_display_id,
                    viewport: VideoSize::new(width, height),
                })
            },
            25 => {
                // Length is the only decode-time check; out-of-range VALUES clamp on the host at
                // apply time rather than dropping the datagram.
                let fps_cap = reader.read_u8()?;
                let bitrate_ceiling_bps = reader.read_u32()?;
                Ok(Self::StreamSettings {
                    fps_cap,
                    bitrate_ceiling_bps,
                })
            },
            26 => {
                Ok(Self::AudioControl {
                    enabled: reader.read_u8()? != 0,
                })
            },
            27 => {
                let rtt_tenths_millis = reader.read_u16()?;
                let encode_tenths_millis = reader.read_u16()?;
                Ok(Self::HostStats {
                    rtt_tenths_millis,
                    encode_tenths_millis,
                })
            },
            28 => {
                Ok(Self::PrivacyMode {
                    enabled: reader.read_u8()? != 0,
                })
            },
            other => {
                Err(VideoProtocolError::malformed(format!(
                    "unknown video control message type {other}"
                )))
            },
        }
    }
}

/// Validate-then-drop: a chunk must identify a real slot in a real sequence. A zero count or an
/// out-of-range index can only be corruption, and handing the assembler an unsatisfiable generation
/// is worse than losing the datagram.
fn validate_chunk_slot(label: &str, chunk_index: u8, chunk_count: u8) -> Result<()> {
    if chunk_count >= 1 && chunk_index < chunk_count {
        return Ok(());
    }
    Err(VideoProtocolError::malformed(format!(
        "{label} chunk {chunk_index}/{chunk_count} is not a valid slot"
    )))
}

/// Appends a `u16`-length-prefixed UTF-8 string. UTF-8 past `u16::MAX` bytes is truncated at a BYTE
/// boundary — titles are never that long, and this only guards a pathological input.
fn put_length_prefixed_str(out: &mut ByteWriter, value: &str) {
    let bytes = value.as_bytes();
    let capped = bytes.get(..usize::from(u16::MAX)).unwrap_or(bytes);
    out.put_u16(truncating_u16(capped.len()));
    out.put_bytes(capped);
}

/// Reads a `u16`-length-prefixed UTF-8 string. Invalid UTF-8 decodes LOSSILY — see the module docs
/// for why this codec differs from the others.
fn read_length_prefixed_str(reader: &mut ByteReader<'_>) -> Result<String> {
    let length = usize::from(reader.read_u16()?);
    let bytes = reader.read_bytes(length)?;
    Ok(String::from_utf8_lossy(bytes).into_owned())
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::panic,
        clippy::too_many_lines,
        reason = "a panic in a test is the failure report, not a runtime fault, and the variant catalogue \
                  is deliberately one entry per wire message"
    )]

    use super::{
        DisplaySummary, HostWindowFlags, HostWindowRecord, MaskRect, SystemDialogSummary,
        VideoControlMessage, WindowSummary,
    };
    use crate::error::VideoProtocolError;
    use crate::geometry::{VideoRect, VideoSize};

    fn every_variant() -> Vec<VideoControlMessage> {
        vec![
            VideoControlMessage::Hello {
                protocol_version: 7,
                requested_window_id: 0xDEAD_BEEF,
                viewport: VideoSize::new(1280.0, 800.0),
            },
            VideoControlMessage::HelloAck {
                accepted: true,
                stream_id: 42,
                capture_width: 1920,
                capture_height: 1080,
                window_bounds_cg: VideoRect::xywh(0.0, 25.0, 800.0, 600.0),
                full_range: true,
            },
            VideoControlMessage::Bye,
            VideoControlMessage::ResizeRequest {
                desired: VideoSize::new(640.5, 480.25),
                epoch: 3,
            },
            VideoControlMessage::ResizeAck {
                capture_width: 640,
                capture_height: 480,
                epoch: 3,
            },
            VideoControlMessage::Keepalive,
            VideoControlMessage::ListWindows,
            VideoControlMessage::WindowList(vec![
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
            ]),
            VideoControlMessage::FocusWindow,
            VideoControlMessage::StreamCadence { fps: 60 },
            VideoControlMessage::ListSystemDialogs,
            VideoControlMessage::SystemDialogList(vec![SystemDialogSummary {
                window_id: 9,
                owner: "SecurityAgent".to_owned(),
                title: String::new(),
                width: 400,
                height: 200,
                is_secure: true,
            }]),
            VideoControlMessage::ScrollOffset {
                dx: -5,
                dy: 42,
                band_top: 1000,
                band_bottom: 9000,
            },
            VideoControlMessage::ContentMask(vec![
                MaskRect {
                    x: 0,
                    y: 0,
                    width: 2880,
                    height: 1800,
                },
                MaskRect {
                    x: 96,
                    y: 1406,
                    width: 538,
                    height: 172,
                },
            ]),
            VideoControlMessage::DisplayMax {
                width: 1920,
                height: 1080,
            },
            VideoControlMessage::WindowFeedSubscribe {
                known_generation: 0xDEAD_BEEF,
            },
            VideoControlMessage::WindowFeedSnapshot {
                generation: 7,
                chunk_index: 1,
                chunk_count: 3,
                records: vec![
                    HostWindowRecord {
                        window_id: 42,
                        width_pt: 1512,
                        height_pt: 982,
                        flags: HostWindowFlags::from_bits(25),
                        display_index: 0,
                        bundle_id: "com.mitchellh.ghostty".to_owned(),
                        app_name: "Ghostty".to_owned(),
                        title: "~/work — zsh".to_owned(),
                    },
                    HostWindowRecord {
                        window_id: 43,
                        width_pt: 800,
                        height_pt: 600,
                        flags: HostWindowFlags::from_bits(6),
                        display_index: 1,
                        bundle_id: String::new(),
                        app_name: "Tool".to_owned(),
                        title: String::new(),
                    },
                ],
            },
            VideoControlMessage::WindowFeedCurrent { generation: 7 },
            VideoControlMessage::AppIconRequest {
                size_px: 64,
                bundle_id: "com.mitchellh.ghostty".to_owned(),
            },
            VideoControlMessage::BlobChunk {
                blob_kind: 0,
                blob_id: 16_045_690_984_503_111_693,
                meta_a: 64,
                meta_b: 0,
                chunk_index: 1,
                chunk_count: 3,
                bytes: vec![0x89, 0x50, 0x4E, 0x47],
            },
            VideoControlMessage::WindowPreviewRequest {
                window_id: 42,
                max_width_px: 640,
            },
            VideoControlMessage::ListDisplays,
            VideoControlMessage::DisplayList(vec![
                DisplaySummary {
                    display_id: 1,
                    width: 2560,
                    height: 1440,
                    is_main: true,
                },
                DisplaySummary {
                    display_id: 83_689_474,
                    width: 1920,
                    height: 1080,
                    is_main: false,
                },
            ]),
            VideoControlMessage::HelloDisplay {
                protocol_version: 7,
                requested_display_id: 1,
                viewport: VideoSize::new(1280.0, 800.0),
            },
            VideoControlMessage::StreamSettings {
                fps_cap: 24,
                bitrate_ceiling_bps: 8_000_000,
            },
            VideoControlMessage::AudioControl { enabled: true },
            VideoControlMessage::AudioControl { enabled: false },
            VideoControlMessage::HostStats {
                rtt_tenths_millis: 123,
                encode_tenths_millis: 45,
            },
            VideoControlMessage::PrivacyMode { enabled: true },
            VideoControlMessage::PrivacyMode { enabled: false },
        ]
    }

    #[test]
    fn every_variant_round_trips() {
        for case in every_variant() {
            assert_eq!(VideoControlMessage::decode(&case.encode()), Ok(case));
        }
    }

    #[test]
    fn the_type_bytes_are_dense_and_unique_from_one_to_twenty_eight() {
        let mut seen: Vec<u8> = every_variant()
            .iter()
            .map(VideoControlMessage::message_type)
            .collect();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen, (1..=28).collect::<Vec<u8>>());
    }

    #[test]
    fn the_zero_body_messages_are_exactly_one_byte() {
        for case in every_variant() {
            let body_less = matches!(
                case,
                VideoControlMessage::Bye
                    | VideoControlMessage::Keepalive
                    | VideoControlMessage::ListWindows
                    | VideoControlMessage::FocusWindow
                    | VideoControlMessage::ListSystemDialogs
                    | VideoControlMessage::ListDisplays
            );
            if body_less {
                assert_eq!(case.encode().len(), 1, "{case:?} must be its type byte alone");
            }
        }
    }

    #[test]
    fn an_unknown_type_is_a_drop_not_a_crash() {
        assert!(matches!(
            VideoControlMessage::decode(&[200]),
            Err(VideoProtocolError::Malformed(_))
        ));
        assert_eq!(
            VideoControlMessage::decode(&[]),
            Err(VideoProtocolError::Truncated)
        );
    }

    #[test]
    fn a_hostile_list_count_bails_on_the_first_missing_byte() {
        // Type 8 with count 65535 and no records at all: the danger is a decoder that reserves for
        // 65535 records before discovering there are none.
        for kind in [8_u8, 12, 14, 23] {
            let bytes = [kind, 0xFF, 0xFF];
            assert_eq!(
                VideoControlMessage::decode(&bytes),
                Err(VideoProtocolError::Truncated),
                "type {kind} must refuse an unsatisfiable count"
            );
        }
    }

    #[test]
    fn an_empty_list_is_legal_everywhere() {
        for case in [
            VideoControlMessage::WindowList(Vec::new()),
            VideoControlMessage::SystemDialogList(Vec::new()),
            VideoControlMessage::ContentMask(Vec::new()),
            VideoControlMessage::DisplayList(Vec::new()),
        ] {
            assert_eq!(VideoControlMessage::decode(&case.encode()), Ok(case));
        }
    }

    #[test]
    fn a_chunk_that_names_no_real_slot_is_dropped() {
        // Zero count, and an index at or past the count — both only reachable by corruption.
        let snapshot = |index: u8, count: u8| {
            let mut bytes = vec![17_u8];
            bytes.extend_from_slice(&7_u32.to_be_bytes());
            bytes.push(index);
            bytes.push(count);
            bytes.extend_from_slice(&0_u16.to_be_bytes());
            bytes
        };
        assert!(matches!(
            VideoControlMessage::decode(&snapshot(0, 0)),
            Err(VideoProtocolError::Malformed(_))
        ));
        assert!(matches!(
            VideoControlMessage::decode(&snapshot(3, 3)),
            Err(VideoProtocolError::Malformed(_))
        ));
        assert!(VideoControlMessage::decode(&snapshot(2, 3)).is_ok());
    }

    #[test]
    fn a_blob_byte_count_past_the_datagram_is_truncation() {
        let mut bytes = VideoControlMessage::BlobChunk {
            blob_kind: 0,
            blob_id: 1,
            meta_a: 0,
            meta_b: 0,
            chunk_index: 0,
            chunk_count: 1,
            bytes: vec![1, 2, 3],
        }
        .encode();
        let count_at = bytes.len() - 5;
        bytes[count_at] = 0xFF;
        bytes[count_at + 1] = 0xFF;
        assert_eq!(
            VideoControlMessage::decode(&bytes),
            Err(VideoProtocolError::Truncated)
        );
    }

    #[test]
    fn a_mangled_title_becomes_replacement_characters_rather_than_losing_the_whole_list() {
        // The lossy contract, stated as a test: one bad byte in one window's title must not cost
        // the other window in the same datagram.
        let mut bytes = vec![8_u8];
        bytes.extend_from_slice(&1_u16.to_be_bytes());
        bytes.extend_from_slice(&5_u32.to_be_bytes());
        bytes.extend_from_slice(&100_u16.to_be_bytes());
        bytes.extend_from_slice(&50_u16.to_be_bytes());
        bytes.extend_from_slice(&2_u16.to_be_bytes());
        bytes.extend_from_slice(&[0xFF, 0xFE]);
        bytes.extend_from_slice(&0_u16.to_be_bytes());
        let decoded = VideoControlMessage::decode(&bytes).expect("a mangled title is not fatal");
        let VideoControlMessage::WindowList(windows) = decoded else {
            panic!("expected a window list");
        };
        assert_eq!(windows.len(), 1);
        assert!(
            windows[0].app_name.contains('\u{FFFD}'),
            "invalid bytes decode lossily here, unlike window_geometry and input_event"
        );
    }

    #[test]
    fn a_negative_scroll_offset_survives_the_unsigned_wire_field() {
        let case = VideoControlMessage::ScrollOffset {
            dx: i16::MIN,
            dy: i16::MAX,
            band_top: 0,
            band_bottom: 10_000,
        };
        assert_eq!(VideoControlMessage::decode(&case.encode()), Ok(case));
    }

    #[test]
    fn unknown_window_flag_bits_survive_the_round_trip() {
        let case = VideoControlMessage::WindowFeedSnapshot {
            generation: 1,
            chunk_index: 0,
            chunk_count: 1,
            records: vec![HostWindowRecord {
                flags: HostWindowFlags::from_bits(0xFF),
                ..HostWindowRecord::default()
            }],
        };
        assert_eq!(VideoControlMessage::decode(&case.encode()), Ok(case));
    }

    #[test]
    fn the_named_flags_are_the_documented_bits() {
        let combined = HostWindowFlags::ON_SCREEN
            .union(HostWindowFlags::APP_HIDDEN)
            .union(HostWindowFlags::FRONTMOST_APP);
        assert_eq!(combined.bits(), 0b0000_1101);
        assert!(combined.contains(HostWindowFlags::ON_SCREEN));
        assert!(!combined.contains(HostWindowFlags::MINIMIZED));
    }
}
