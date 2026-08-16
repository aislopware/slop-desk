//! The video path's CONTROL channel.
//!
//! Session bring-up, discovery, the host-window feed and the live knobs — twenty-eight message
//! types, five of which carry a list of records, and every record carries text.
//!
//! ## Why this one needs an arena where the others needed an offset
//!
//! Every earlier wire on this path answered with a span into the caller's datagram, because its
//! payload was already sitting there. Two things here make that insufficient:
//!
//! * a message carries a LIST — up to a datagram's worth of window records — so there is no single
//!   span to point at, and
//! * a title off the wire is decoded LOSSILY. One mangled byte becomes U+FFFD, which is bytes that
//!   are not in the datagram, so the answer cannot always be a substring of the question. The whole
//!   point of the lossy rule is that a hostile title costs that title and not the list.
//!
//! So both directions use one ARENA: a flat byte buffer the caller provides, into which every
//! string is written once, with each field naming its `(offset, length)` inside it. Decode fills
//! the arena; encode reads from it. The shape is symmetric, and the lossy repair happens exactly
//! once, in `rust/slopdesk-video`, where it always did.
//!
//! ## The two flat messages
//!
//! [`SlopDeskVideoControl`] holds every scalar any arm carries, each field named for the one thing
//! it means; `message_type` says which of them are live. [`SlopDeskControlRecord`] does the same
//! for the five list arms — a window summary, a feed record, a display, a system dialog and a mask
//! rect are one struct because they are one wire shape with different fields switched on.
//!
//! A C union would have to be kept in step with the Rust enum by hand on both sides, which is the
//! drift this port exists to remove. Flat costs a few unread bytes per message on a channel that
//! carries a keepalive every few seconds.

use core::ffi::c_uchar;

use slopdesk_video::error::VideoProtocolError;
use slopdesk_video::geometry::{VideoRect, VideoSize};
use slopdesk_video::video_control::{
    DisplaySummary, HostWindowFlags, HostWindowRecord, MaskRect, SystemDialogSummary, VideoControlMessage,
    WindowSummary,
};

use crate::{arena_span, arena_text, borrow, deliver, truncating_u32};

/// The datagram parsed and everything fits the buffers it was given.
pub const CONTROL_DECODE_OK: u32 = 0;
/// The datagram ended mid-field, or a declared list count outran it.
pub const CONTROL_DECODE_TRUNCATED: u32 = 1;
/// The datagram was well-sized and unacceptable: an unknown type byte, a non-finite coordinate, or
/// a chunk that does not name a real slot in a real sequence.
pub const CONTROL_DECODE_MALFORMED: u32 = 2;
/// The datagram parsed and did not fit the buffers it was given.
///
/// Nothing was written to the record array or the arena, but `record_count` and `arena_length`
/// were, so the caller can size and ask again.
pub const CONTROL_DECODE_AGAIN: u32 = 3;

/// Which verdict a decode failure earns.
const fn verdict(error: &VideoProtocolError) -> u32 {
    match *error {
        VideoProtocolError::Truncated => CONTROL_DECODE_TRUNCATED,
        VideoProtocolError::Malformed(_) => CONTROL_DECODE_MALFORMED,
    }
}

/// One control message, flat. `message_type` picks which fields carry meaning; the rest are zero.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskVideoControl {
    /// The client surface size the host should size capture to — `hello`, `helloDisplay`, and the
    /// `desired` of a `resizeRequest`.
    pub viewport_width: f64,
    /// The viewport's height.
    pub viewport_height: f64,
    /// The captured window's CG top-left bounds in a `helloAck` — the input-mapping origin until
    /// the geometry channel updates it.
    pub bounds_x: f64,
    /// The bounds' y.
    pub bounds_y: f64,
    /// The bounds' width.
    pub bounds_width: f64,
    /// The bounds' height.
    pub bounds_height: f64,
    /// Which blob a `blobChunk` belongs to — `FNV-1a64(bundleID)` for an icon, the window id for a
    /// preview.
    pub blob_id: u64,
    /// What the sender is asking for: a `hello`'s window id, a `helloDisplay`'s display id, or a
    /// `windowPreviewRequest`'s window id.
    pub requested_id: u32,
    /// The session a `helloAck` minted.
    pub stream_id: u32,
    /// The client-minted monotonic counter on a `resizeRequest` and the `resizeAck` answering it.
    pub epoch: u32,
    /// The host-window feed's generation — held by a `windowFeedSubscribe`, carried by a snapshot,
    /// confirmed by a `windowFeedCurrent`.
    pub generation: u32,
    /// A `streamSettings` bitrate ceiling; 0 means AUTO.
    pub bitrate_ceiling_bps: u32,
    /// Where this message's one loose payload sits in the arena — an `appIconRequest`'s bundle id,
    /// or a `blobChunk`'s bytes.
    pub span_offset: u32,
    /// How long that payload is.
    pub span_length: u32,
    /// How many records the list arms carry.
    pub record_count: u32,
    /// How many arena bytes the whole answer needs.
    pub arena_length: u32,
    /// A `hello`/`helloDisplay` version, which must match the host's exactly.
    pub protocol_version: u16,
    /// The negotiated capture width in a `helloAck` or a `resizeAck`.
    pub capture_width: u16,
    /// The negotiated capture height.
    pub capture_height: u16,
    /// A `streamCadence`'s governed content rate.
    pub fps: u16,
    /// A `scrollOffset`'s measured horizontal shift, in pixels.
    pub scroll_dx: i16,
    /// The vertical shift.
    pub scroll_dy: i16,
    /// The moving band's top, in ten-thousandths of frame height.
    pub band_top: u16,
    /// The moving band's bottom; at or below `band_top` means no band.
    pub band_bottom: u16,
    /// A `displayMax`'s reachable width in points.
    pub display_max_width: u16,
    /// The reachable height.
    pub display_max_height: u16,
    /// A `blobChunk`'s first meta word — an icon's px edge, a preview's px width.
    pub meta_a: u16,
    /// The second — a preview's px height.
    pub meta_b: u16,
    /// An `appIconRequest`'s asked-for icon edge in pixels.
    pub size_px: u16,
    /// A `windowPreviewRequest`'s width cap in pixels.
    pub max_width_px: u16,
    /// A `hostStats` round-trip time, in tenths of a millisecond.
    pub rtt_tenths_millis: u16,
    /// The host's encode wall time, same unit.
    pub encode_tenths_millis: u16,
    /// Which of the 28 wire messages this is.
    pub message_type: u8,
    /// Which chunk of a sequence this is — a feed snapshot's, or a blob's.
    pub chunk_index: u8,
    /// How many chunks that sequence has.
    pub chunk_count: u8,
    /// What kind of blob a `blobChunk` carries: 0 an app icon, 1 a window preview.
    pub blob_kind: u8,
    /// A `streamSettings` fps cap; 0 means AUTO.
    pub fps_cap: u8,
    /// Whether a `helloAck` accepted the session.
    pub accepted: bool,
    /// Whether the stream's luma swing is full range.
    pub full_range: bool,
    /// The wish an `audioControl` or a `privacyMode` carries.
    pub enabled: bool,
}

/// One record from a list-carrying arm, flat. Which fields are live follows from the message that
/// holds it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskControlRecord {
    /// The host `CGWindowID`, or the `CGDirectDisplayID` in a display list.
    pub id: u32,
    /// Where the owning app's name — a dialog's owning PROCESS name — sits in the arena.
    pub name_offset: u32,
    /// How long it is.
    pub name_length: u32,
    /// Where the title sits in the arena. May be empty.
    pub title_offset: u32,
    /// How long the title is.
    pub title_length: u32,
    /// Where a feed record's bundle identifier sits in the arena. Empty when the process has none.
    pub bundle_offset: u32,
    /// How long the bundle identifier is.
    pub bundle_length: u32,
    /// The record's width in points, or a mask rect's width in capture pixels.
    pub width: u16,
    /// The height, same units.
    pub height: u16,
    /// A mask rect's left edge, capture pixels.
    pub x: u16,
    /// A mask rect's top edge.
    pub y: u16,
    /// A feed record's state bits. Unknown future bits survive the round trip.
    pub flags: u8,
    /// Which display a feed record's window is on, 0-based; 0 when unknown.
    pub display_index: u8,
    /// Whether a display is the host's MAIN one.
    pub is_main: bool,
    /// Whether a system dialog is a secure-credential prompt.
    pub is_secure: bool,
}

/// Parses one control datagram.
///
/// Writes the flat message to `out`, this message's records to `records`, and every string it
/// carries to `arena` — each field naming where in the arena its bytes went. Passing null (or a
/// short) `records`/`arena` still answers `record_count` and `arena_length` in `out`, with the
/// verdict [`CONTROL_DECODE_AGAIN`]; the parse is pure, so asking again with room cannot disagree.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes; `out` must be null or point to one
/// writable, aligned [`SlopDeskVideoControl`]; `records` must be null or point to `records_cap`
/// writable, aligned [`SlopDeskControlRecord`]s; `arena` must be null or point to `arena_cap`
/// writable bytes. All for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_control_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskVideoControl,
    records: *mut SlopDeskControlRecord,
    records_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let message = match VideoControlMessage::decode(datagram) {
        Ok(message) => message,
        Err(error) => return verdict(&error),
    };
    let mut packed = Packed::default();
    let flat = packed.flatten(&message);
    if out.is_null() {
        return CONTROL_DECODE_OK;
    }
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned value.
    unsafe { out.write(flat) };
    if packed.records.len() > records_cap
        || packed.arena.len() > arena_cap
        || (!packed.records.is_empty() && records.is_null())
        || (!packed.arena.is_empty() && arena.is_null())
    {
        return CONTROL_DECODE_AGAIN;
    }
    for (slot, record) in packed.records.iter().enumerate() {
        // SAFETY: `slot` is below `records.len()`, which the check above put at or under the cap.
        unsafe { records.add(slot).write(*record) };
    }
    if !packed.arena.is_empty() {
        // SAFETY: `arena` is non-null with at least `packed.arena.len()` writable bytes, and the
        // source is a `Vec` this function owns, so the two cannot overlap.
        unsafe { core::ptr::copy_nonoverlapping(packed.arena.as_ptr(), arena, packed.arena.len()) };
    }
    CONTROL_DECODE_OK
}

/// Serialises one control message; its records and its strings arrive the way a decode hands them
/// back. Returns bytes NEEDED under §4, and 0 for a message no arm answers to.
///
/// # Safety
/// `records` must be null or point to `record_count` readable [`SlopDeskControlRecord`]s; `arena`
/// must be null or point to `arena_len` readable bytes; `out` must be null or point to `cap`
/// writable bytes. All for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_control_encode(
    message: SlopDeskVideoControl,
    records: *const SlopDeskControlRecord,
    record_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let rows: &[SlopDeskControlRecord] = if records.is_null() || record_count == 0 {
        &[]
    } else {
        // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBufferPointer`.
        unsafe { core::slice::from_raw_parts(records, record_count) }
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let arena_bytes = unsafe { borrow(arena, arena_len) };
    let Some(built) = rebuild(&message, rows, arena_bytes) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&built.encode(), out, cap) }
}

/// The control channel's declared numbers.
///
/// `index` selects — 0 a blob chunk's data bytes, 1 the icon blob cap, 2 the preview blob cap, 3 a
/// feed chunk's record budget, 4 the feed title cap, then the five window-state bits: 5 on-screen,
/// 6 minimized, 7 app-hidden, 8 frontmost-app, 9 focused-window.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_video_control_constant(index: u8) -> usize {
    match index {
        0 => VideoControlMessage::BLOB_BYTES_PER_CHUNK,
        1 => VideoControlMessage::ICON_BLOB_MAX_BYTES,
        2 => VideoControlMessage::PREVIEW_BLOB_MAX_BYTES,
        3 => VideoControlMessage::FEED_RECORD_BYTES_PER_CHUNK,
        4 => VideoControlMessage::FEED_TITLE_MAX_BYTES,
        5 => HostWindowFlags::ON_SCREEN.bits() as usize,
        6 => HostWindowFlags::MINIMIZED.bits() as usize,
        7 => HostWindowFlags::APP_HIDDEN.bits() as usize,
        8 => HostWindowFlags::FRONTMOST_APP.bits() as usize,
        9 => HostWindowFlags::FOCUSED_WINDOW.bits() as usize,
        _ => 0,
    }
}

/// The decode side's working state: the flat records and the arena they name.
#[derive(Default)]
struct Packed {
    records: Vec<SlopDeskControlRecord>,
    arena: Vec<u8>,
}

impl Packed {
    /// Appends `text` to the arena and answers where it went.
    fn intern(&mut self, text: &str) -> (u32, u32) {
        let offset = truncating_u32(self.arena.len());
        self.arena.extend_from_slice(text.as_bytes());
        (offset, truncating_u32(text.len()))
    }

    /// Appends raw bytes to the arena and answers where they went.
    fn intern_bytes(&mut self, bytes: &[u8]) -> (u32, u32) {
        let offset = truncating_u32(self.arena.len());
        self.arena.extend_from_slice(bytes);
        (offset, truncating_u32(bytes.len()))
    }

    /// Splits one decoded message into the flat form, filling `self` with what does not fit in it.
    #[expect(
        clippy::too_many_lines,
        reason = "one arm per wire message, the same reason the codec it mirrors is one function"
    )]
    fn flatten(&mut self, message: &VideoControlMessage) -> SlopDeskVideoControl {
        let mut flat = SlopDeskVideoControl {
            message_type: message.message_type(),
            ..SlopDeskVideoControl::default()
        };
        match *message {
            VideoControlMessage::Hello {
                protocol_version,
                requested_window_id,
                viewport,
            } => {
                flat.protocol_version = protocol_version;
                flat.requested_id = requested_window_id;
                flat.viewport_width = viewport.width;
                flat.viewport_height = viewport.height;
            },
            VideoControlMessage::HelloDisplay {
                protocol_version,
                requested_display_id,
                viewport,
            } => {
                flat.protocol_version = protocol_version;
                flat.requested_id = requested_display_id;
                flat.viewport_width = viewport.width;
                flat.viewport_height = viewport.height;
            },
            VideoControlMessage::HelloAck {
                accepted,
                stream_id,
                capture_width,
                capture_height,
                window_bounds_cg,
                full_range,
            } => {
                flat.accepted = accepted;
                flat.stream_id = stream_id;
                flat.capture_width = capture_width;
                flat.capture_height = capture_height;
                flat.bounds_x = window_bounds_cg.origin.x;
                flat.bounds_y = window_bounds_cg.origin.y;
                flat.bounds_width = window_bounds_cg.size.width;
                flat.bounds_height = window_bounds_cg.size.height;
                flat.full_range = full_range;
            },
            VideoControlMessage::ResizeRequest { desired, epoch } => {
                flat.viewport_width = desired.width;
                flat.viewport_height = desired.height;
                flat.epoch = epoch;
            },
            VideoControlMessage::ResizeAck {
                capture_width,
                capture_height,
                epoch,
            } => {
                flat.capture_width = capture_width;
                flat.capture_height = capture_height;
                flat.epoch = epoch;
            },
            VideoControlMessage::WindowList(ref windows) => {
                for window in windows {
                    let (name_offset, name_length) = self.intern(&window.app_name);
                    let (title_offset, title_length) = self.intern(&window.title);
                    self.records.push(SlopDeskControlRecord {
                        id: window.window_id,
                        name_offset,
                        name_length,
                        title_offset,
                        title_length,
                        width: window.width,
                        height: window.height,
                        ..SlopDeskControlRecord::default()
                    });
                }
            },
            VideoControlMessage::SystemDialogList(ref dialogs) => {
                for dialog in dialogs {
                    let (name_offset, name_length) = self.intern(&dialog.owner);
                    let (title_offset, title_length) = self.intern(&dialog.title);
                    self.records.push(SlopDeskControlRecord {
                        id: dialog.window_id,
                        name_offset,
                        name_length,
                        title_offset,
                        title_length,
                        width: dialog.width,
                        height: dialog.height,
                        is_secure: dialog.is_secure,
                        ..SlopDeskControlRecord::default()
                    });
                }
            },
            VideoControlMessage::DisplayList(ref displays) => {
                for display in displays {
                    self.records.push(SlopDeskControlRecord {
                        id: display.display_id,
                        width: display.width,
                        height: display.height,
                        is_main: display.is_main,
                        ..SlopDeskControlRecord::default()
                    });
                }
            },
            VideoControlMessage::ContentMask(ref rects) => {
                for rect in rects {
                    self.records.push(SlopDeskControlRecord {
                        x: rect.x,
                        y: rect.y,
                        width: rect.width,
                        height: rect.height,
                        ..SlopDeskControlRecord::default()
                    });
                }
            },
            VideoControlMessage::WindowFeedSnapshot {
                generation,
                chunk_index,
                chunk_count,
                ref records,
            } => {
                flat.generation = generation;
                flat.chunk_index = chunk_index;
                flat.chunk_count = chunk_count;
                for record in records {
                    let (bundle_offset, bundle_length) = self.intern(&record.bundle_id);
                    let (name_offset, name_length) = self.intern(&record.app_name);
                    let (title_offset, title_length) = self.intern(&record.title);
                    self.records.push(SlopDeskControlRecord {
                        id: record.window_id,
                        name_offset,
                        name_length,
                        title_offset,
                        title_length,
                        bundle_offset,
                        bundle_length,
                        width: record.width_pt,
                        height: record.height_pt,
                        flags: record.flags.bits(),
                        display_index: record.display_index,
                        ..SlopDeskControlRecord::default()
                    });
                }
            },
            VideoControlMessage::StreamCadence { fps } => flat.fps = fps,
            VideoControlMessage::ScrollOffset {
                dx,
                dy,
                band_top,
                band_bottom,
            } => {
                flat.scroll_dx = dx;
                flat.scroll_dy = dy;
                flat.band_top = band_top;
                flat.band_bottom = band_bottom;
            },
            VideoControlMessage::DisplayMax { width, height } => {
                flat.display_max_width = width;
                flat.display_max_height = height;
            },
            VideoControlMessage::WindowFeedSubscribe { known_generation } => {
                flat.generation = known_generation;
            },
            VideoControlMessage::WindowFeedCurrent { generation } => flat.generation = generation,
            VideoControlMessage::AppIconRequest {
                size_px,
                ref bundle_id,
            } => {
                flat.size_px = size_px;
                (flat.span_offset, flat.span_length) = self.intern(bundle_id);
            },
            VideoControlMessage::BlobChunk {
                blob_kind,
                blob_id,
                meta_a,
                meta_b,
                chunk_index,
                chunk_count,
                ref bytes,
            } => {
                flat.blob_kind = blob_kind;
                flat.blob_id = blob_id;
                flat.meta_a = meta_a;
                flat.meta_b = meta_b;
                flat.chunk_index = chunk_index;
                flat.chunk_count = chunk_count;
                (flat.span_offset, flat.span_length) = self.intern_bytes(bytes);
            },
            VideoControlMessage::WindowPreviewRequest {
                window_id,
                max_width_px,
            } => {
                flat.requested_id = window_id;
                flat.max_width_px = max_width_px;
            },
            VideoControlMessage::StreamSettings {
                fps_cap,
                bitrate_ceiling_bps,
            } => {
                flat.fps_cap = fps_cap;
                flat.bitrate_ceiling_bps = bitrate_ceiling_bps;
            },
            VideoControlMessage::AudioControl { enabled } | VideoControlMessage::PrivacyMode { enabled } => {
                flat.enabled = enabled;
            },
            VideoControlMessage::HostStats {
                rtt_tenths_millis,
                encode_tenths_millis,
            } => {
                flat.rtt_tenths_millis = rtt_tenths_millis;
                flat.encode_tenths_millis = encode_tenths_millis;
            },
            // The bodyless arms: bye, keepalive, listWindows, focusWindow, listSystemDialogs,
            // listDisplays. The type byte IS the message.
            VideoControlMessage::Bye
            | VideoControlMessage::Keepalive
            | VideoControlMessage::ListWindows
            | VideoControlMessage::FocusWindow
            | VideoControlMessage::ListSystemDialogs
            | VideoControlMessage::ListDisplays => {},
        }
        flat.record_count = truncating_u32(self.records.len());
        flat.arena_length = truncating_u32(self.arena.len());
        flat
    }
}

/// Puts one flat message back together, reading its text out of `arena`.
///
/// Answers `None` for a `message_type` no arm claims — the caller built something this wire cannot
/// carry, which is a bug on that side rather than a datagram to drop.
#[expect(
    clippy::too_many_lines,
    reason = "one arm per wire message, mirroring `flatten`"
)]
fn rebuild(
    flat: &SlopDeskVideoControl,
    records: &[SlopDeskControlRecord],
    arena: &[u8],
) -> Option<VideoControlMessage> {
    let viewport = VideoSize::new(flat.viewport_width, flat.viewport_height);
    Some(match flat.message_type {
        1 => {
            VideoControlMessage::Hello {
                protocol_version: flat.protocol_version,
                requested_window_id: flat.requested_id,
                viewport,
            }
        },
        2 => {
            VideoControlMessage::HelloAck {
                accepted: flat.accepted,
                stream_id: flat.stream_id,
                capture_width: flat.capture_width,
                capture_height: flat.capture_height,
                window_bounds_cg: VideoRect::xywh(
                    flat.bounds_x,
                    flat.bounds_y,
                    flat.bounds_width,
                    flat.bounds_height,
                ),
                full_range: flat.full_range,
            }
        },
        3 => VideoControlMessage::Bye,
        4 => {
            VideoControlMessage::ResizeRequest {
                desired: viewport,
                epoch: flat.epoch,
            }
        },
        5 => {
            VideoControlMessage::ResizeAck {
                capture_width: flat.capture_width,
                capture_height: flat.capture_height,
                epoch: flat.epoch,
            }
        },
        6 => VideoControlMessage::Keepalive,
        7 => VideoControlMessage::ListWindows,
        8 => {
            VideoControlMessage::WindowList(
                records
                    .iter()
                    .map(|row| {
                        WindowSummary {
                            window_id: row.id,
                            app_name: arena_text(arena, row.name_offset, row.name_length),
                            title: arena_text(arena, row.title_offset, row.title_length),
                            width: row.width,
                            height: row.height,
                        }
                    })
                    .collect(),
            )
        },
        9 => VideoControlMessage::FocusWindow,
        10 => VideoControlMessage::StreamCadence { fps: flat.fps },
        11 => VideoControlMessage::ListSystemDialogs,
        12 => {
            VideoControlMessage::SystemDialogList(
                records
                    .iter()
                    .map(|row| {
                        SystemDialogSummary {
                            window_id: row.id,
                            owner: arena_text(arena, row.name_offset, row.name_length),
                            title: arena_text(arena, row.title_offset, row.title_length),
                            width: row.width,
                            height: row.height,
                            is_secure: row.is_secure,
                        }
                    })
                    .collect(),
            )
        },
        13 => {
            VideoControlMessage::ScrollOffset {
                dx: flat.scroll_dx,
                dy: flat.scroll_dy,
                band_top: flat.band_top,
                band_bottom: flat.band_bottom,
            }
        },
        14 => {
            VideoControlMessage::ContentMask(
                records
                    .iter()
                    .map(|row| {
                        MaskRect {
                            x: row.x,
                            y: row.y,
                            width: row.width,
                            height: row.height,
                        }
                    })
                    .collect(),
            )
        },
        15 => {
            VideoControlMessage::DisplayMax {
                width: flat.display_max_width,
                height: flat.display_max_height,
            }
        },
        16 => {
            VideoControlMessage::WindowFeedSubscribe {
                known_generation: flat.generation,
            }
        },
        17 => {
            VideoControlMessage::WindowFeedSnapshot {
                generation: flat.generation,
                chunk_index: flat.chunk_index,
                chunk_count: flat.chunk_count,
                records: records
                    .iter()
                    .map(|row| {
                        HostWindowRecord {
                            window_id: row.id,
                            width_pt: row.width,
                            height_pt: row.height,
                            flags: HostWindowFlags::from_bits(row.flags),
                            display_index: row.display_index,
                            bundle_id: arena_text(arena, row.bundle_offset, row.bundle_length),
                            app_name: arena_text(arena, row.name_offset, row.name_length),
                            title: arena_text(arena, row.title_offset, row.title_length),
                        }
                    })
                    .collect(),
            }
        },
        18 => {
            VideoControlMessage::WindowFeedCurrent {
                generation: flat.generation,
            }
        },
        19 => {
            VideoControlMessage::AppIconRequest {
                size_px: flat.size_px,
                bundle_id: arena_text(arena, flat.span_offset, flat.span_length),
            }
        },
        20 => {
            VideoControlMessage::BlobChunk {
                blob_kind: flat.blob_kind,
                blob_id: flat.blob_id,
                meta_a: flat.meta_a,
                meta_b: flat.meta_b,
                chunk_index: flat.chunk_index,
                chunk_count: flat.chunk_count,
                bytes: arena_span(arena, flat.span_offset, flat.span_length).to_vec(),
            }
        },
        21 => {
            VideoControlMessage::WindowPreviewRequest {
                window_id: flat.requested_id,
                max_width_px: flat.max_width_px,
            }
        },
        22 => VideoControlMessage::ListDisplays,
        23 => {
            VideoControlMessage::DisplayList(
                records
                    .iter()
                    .map(|row| {
                        DisplaySummary {
                            display_id: row.id,
                            width: row.width,
                            height: row.height,
                            is_main: row.is_main,
                        }
                    })
                    .collect(),
            )
        },
        24 => {
            VideoControlMessage::HelloDisplay {
                protocol_version: flat.protocol_version,
                requested_display_id: flat.requested_id,
                viewport,
            }
        },
        25 => {
            VideoControlMessage::StreamSettings {
                fps_cap: flat.fps_cap,
                bitrate_ceiling_bps: flat.bitrate_ceiling_bps,
            }
        },
        26 => {
            VideoControlMessage::AudioControl {
                enabled: flat.enabled,
            }
        },
        27 => {
            VideoControlMessage::HostStats {
                rtt_tenths_millis: flat.rtt_tenths_millis,
                encode_tenths_millis: flat.encode_tenths_millis,
            }
        },
        28 => {
            VideoControlMessage::PrivacyMode {
                enabled: flat.enabled,
            }
        },
        _ => return None,
    })
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::cast_possible_truncation,
    reason = "the tests call the C entry points, and a panic in a test is the failure report"
)]
mod tests {
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{
        CONTROL_DECODE_AGAIN, CONTROL_DECODE_MALFORMED, CONTROL_DECODE_OK, SlopDeskControlRecord,
        SlopDeskVideoControl, slopdesk_video_control_constant, slopdesk_video_control_decode,
        slopdesk_video_control_encode,
    };

    /// Encodes through the boundary the way Swift does: size, then write.
    fn wire(message: SlopDeskVideoControl, records: &[SlopDeskControlRecord], arena: &[u8]) -> Vec<u8> {
        let needed = unsafe {
            slopdesk_video_control_encode(
                message,
                records.as_ptr(),
                records.len(),
                arena.as_ptr(),
                arena.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![0_u8; needed];
        let written = unsafe {
            slopdesk_video_control_encode(
                message,
                records.as_ptr(),
                records.len(),
                arena.as_ptr(),
                arena.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed);
        out
    }

    /// Decodes through the boundary with room for anything a control datagram could hold.
    fn parse(bytes: &[u8]) -> (u32, SlopDeskVideoControl, Vec<SlopDeskControlRecord>, Vec<u8>) {
        let mut flat = SlopDeskVideoControl::default();
        let mut records = vec![SlopDeskControlRecord::default(); 64];
        let mut arena = vec![0_u8; 4096];
        let verdict = unsafe {
            slopdesk_video_control_decode(
                bytes.as_ptr(),
                bytes.len(),
                &raw mut flat,
                records.as_mut_ptr(),
                records.len(),
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        records.truncate(flat.record_count as usize);
        arena.truncate(flat.arena_length as usize);
        (verdict, flat, records, arena)
    }

    #[test]
    fn a_hello_round_trips_through_the_flat_form() {
        let hello = SlopDeskVideoControl {
            viewport_width: 1280.0,
            viewport_height: 720.5,
            requested_id: 4242,
            protocol_version: 7,
            message_type: 1,
            ..SlopDeskVideoControl::default()
        };
        let bytes = wire(hello, &[], &[]);
        // The same bytes the owning Rust codec writes — the boundary adds no layout of its own.
        assert_eq!(
            bytes,
            VideoControlMessage::Hello {
                protocol_version: 7,
                requested_window_id: 4242,
                viewport: slopdesk_video::geometry::VideoSize::new(1280.0, 720.5),
            }
            .encode()
        );
        let (verdict, back, records, arena) = parse(&bytes);
        assert_eq!(verdict, CONTROL_DECODE_OK);
        assert_eq!(back, hello);
        assert!(records.is_empty() && arena.is_empty());
    }

    #[test]
    fn a_window_list_carries_its_text_through_the_arena() {
        let mut arena = Vec::new();
        let mut rows = Vec::new();
        for (id, app, title) in [(1_u32, "Ghostty", "~/src"), (2, "Safari", "")] {
            let name_offset = arena.len() as u32;
            arena.extend_from_slice(app.as_bytes());
            let title_offset = arena.len() as u32;
            arena.extend_from_slice(title.as_bytes());
            rows.push(SlopDeskControlRecord {
                id,
                name_offset,
                name_length: app.len() as u32,
                title_offset,
                title_length: title.len() as u32,
                width: 800,
                height: 600,
                ..SlopDeskControlRecord::default()
            });
        }
        let list = SlopDeskVideoControl {
            message_type: 8,
            ..SlopDeskVideoControl::default()
        };
        let bytes = wire(list, &rows, &arena);
        let (verdict, back, records, back_arena) = parse(&bytes);
        assert_eq!(verdict, CONTROL_DECODE_OK);
        assert_eq!(back.record_count, 2);
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].id, 1);
        let name = &back_arena[records[0].name_offset as usize..][..records[0].name_length as usize];
        assert_eq!(name, b"Ghostty");
        assert_eq!(records[1].title_length, 0);
    }

    #[test]
    fn a_feed_snapshot_keeps_its_flags_and_all_three_strings() {
        let mut arena = Vec::new();
        let mut push = |text: &str| {
            let offset = arena.len() as u32;
            arena.extend_from_slice(text.as_bytes());
            (offset, text.len() as u32)
        };
        let (bundle_offset, bundle_length) = push("com.mitchellh.ghostty");
        let (name_offset, name_length) = push("Ghostty");
        let (title_offset, title_length) = push("slop-desk");
        let row = SlopDeskControlRecord {
            id: 99,
            name_offset,
            name_length,
            title_offset,
            title_length,
            bundle_offset,
            bundle_length,
            width: 1200,
            height: 800,
            flags: 0b1_0001,
            display_index: 1,
            ..SlopDeskControlRecord::default()
        };
        let snapshot = SlopDeskVideoControl {
            generation: 5,
            chunk_index: 0,
            chunk_count: 1,
            message_type: 17,
            ..SlopDeskVideoControl::default()
        };
        let bytes = wire(snapshot, &[row], &arena);
        let (verdict, back, records, back_arena) = parse(&bytes);
        assert_eq!(verdict, CONTROL_DECODE_OK);
        assert_eq!(back.generation, 5);
        assert_eq!(records[0].flags, 0b1_0001);
        assert_eq!(records[0].display_index, 1);
        let bundle = &back_arena[records[0].bundle_offset as usize..][..records[0].bundle_length as usize];
        assert_eq!(bundle, b"com.mitchellh.ghostty");
    }

    #[test]
    fn a_blob_chunk_carries_its_bytes_and_not_a_string() {
        let payload: Vec<u8> = (0..64_u8).collect();
        let chunk = SlopDeskVideoControl {
            blob_id: 0xDEAD_BEEF_1234_5678,
            span_offset: 0,
            span_length: payload.len() as u32,
            meta_a: 32,
            meta_b: 0,
            message_type: 20,
            chunk_index: 1,
            chunk_count: 3,
            blob_kind: 0,
            ..SlopDeskVideoControl::default()
        };
        let bytes = wire(chunk, &[], &payload);
        let (verdict, back, _, arena) = parse(&bytes);
        assert_eq!(verdict, CONTROL_DECODE_OK);
        assert_eq!(back.blob_id, 0xDEAD_BEEF_1234_5678);
        assert_eq!(back.chunk_index, 1);
        assert_eq!(arena, payload);
    }

    #[test]
    fn a_short_arena_answers_the_sizes_rather_than_a_partial_list() {
        let mut arena = Vec::new();
        arena.extend_from_slice(b"Ghostty");
        let row = SlopDeskControlRecord {
            id: 1,
            name_length: 7,
            width: 10,
            height: 10,
            ..SlopDeskControlRecord::default()
        };
        let bytes = wire(
            SlopDeskVideoControl {
                message_type: 8,
                ..SlopDeskVideoControl::default()
            },
            &[row],
            &arena,
        );
        let mut flat = SlopDeskVideoControl::default();
        let verdict = unsafe {
            slopdesk_video_control_decode(
                bytes.as_ptr(),
                bytes.len(),
                &raw mut flat,
                core::ptr::null_mut(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(verdict, CONTROL_DECODE_AGAIN);
        assert_eq!(flat.record_count, 1);
        assert_eq!(flat.arena_length, 7);
    }

    #[test]
    fn an_unknown_type_is_refused_in_both_directions() {
        let stranger = [99_u8, 0, 0];
        let (verdict, ..) = parse(&stranger);
        assert_eq!(verdict, CONTROL_DECODE_MALFORMED);
        let unbuildable = SlopDeskVideoControl {
            message_type: 99,
            ..SlopDeskVideoControl::default()
        };
        let refused = unsafe {
            slopdesk_video_control_encode(
                unbuildable,
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(refused, 0);
    }

    #[test]
    fn the_constants_are_vended_rather_than_respelled() {
        assert_eq!(
            slopdesk_video_control_constant(0),
            VideoControlMessage::BLOB_BYTES_PER_CHUNK
        );
        assert_eq!(
            slopdesk_video_control_constant(3),
            VideoControlMessage::FEED_RECORD_BYTES_PER_CHUNK
        );
        assert_eq!(slopdesk_video_control_constant(5), 1);
        assert_eq!(slopdesk_video_control_constant(9), 16);
        assert_eq!(slopdesk_video_control_constant(200), 0);
    }
}
