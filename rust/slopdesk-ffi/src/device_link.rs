//! The device panels' two sockets, as two handles and one callback each.
//!
//! Behind them is [`slopdesk_devicelink`] — the RFC 6455 framing, the reassembly, the explicit
//! pong, the line-then-stream split — which is the whole of what `SimulatorWebSocketLane.swift`,
//! `SimulatorStreamConnection.swift`, `SimulatorLogConnection.swift` and
//! `AndroidBridgeSocket.swift` decided between them. Nothing here decides anything; this file is
//! the calling convention and the lifetime rules, per the crate header.
//!
//! ## One callback, not one per event kind
//!
//! Unlike [`crate::pane_driver`], whose three callbacks carry three unlike things, every event on
//! these two sockets is the same shape: a kind and a run of bytes whose meaning the kind names. A
//! second entry point would be a second `@convention(c)` function on the near side for no
//! discrimination it does not already have to do.
//!
//! What the bytes are, per kind, is the whole of the wire contract and is stated at each door.
//!
//! ## Four obligations, the same four the pane driver states
//!
//! 1. `context` stays valid until the matching `_free` RETURNS — not until it is entered. `free`
//!    tears the socket down and JOINS the reader, so a callback may still be running when it is
//!    called, and none is once it answers.
//! 2. The callback runs on the socket's OWN thread, never on the caller's and never concurrently
//!    with itself. A near side that touches shared state still synchronises it, because that thread
//!    is not the caller's.
//! 3. No callback may re-enter `_free`. It joins the thread the callback is running on.
//! 4. Every pointer in every callback is LENT for that call. A caller that keeps a message copies
//!    it.

use core::ffi::{c_uchar, c_void};
use std::sync::Arc;

use slopdesk_devicelink::{bridge, ws};

use crate::borrow;

/// The handshake completed. No payload.
pub const SLOPDESK_DEVICE_WS_CONNECTED: u32 = 0;
/// A whole text message. The payload is its bytes, NOT validated as UTF-8 — what a bad byte means
/// belongs to the decoder the panel hands it to.
pub const SLOPDESK_DEVICE_WS_TEXT: u32 = 1;
/// A whole binary message, reassembled across however many frames carried it.
pub const SLOPDESK_DEVICE_WS_BINARY: u32 = 2;
/// The socket is over. The payload is one sentence about why, and is EMPTY for a clean close.
pub const SLOPDESK_DEVICE_WS_ENDED: u32 = 3;

/// The host's reply line, without its newline. Delivered at most once per call.
pub const SLOPDESK_DEVICE_BRIDGE_REPLY: u32 = 0;
/// Bytes after the reply line. Only `logcat` and `open` ever see these.
pub const SLOPDESK_DEVICE_BRIDGE_BYTES: u32 = 1;
/// The call is over. The payload is one sentence about why, and is EMPTY for a clean close.
pub const SLOPDESK_DEVICE_BRIDGE_ENDED: u32 = 2;

/// One simulator websocket. Opaque; freed by [`slopdesk_device_ws_free`].
#[derive(Debug)]
pub struct SlopDeskDeviceWs(ws::lane::Lane);

/// One Android bridge call. Opaque; freed by [`slopdesk_device_bridge_free`].
#[derive(Debug)]
pub struct SlopDeskDeviceBridge(bridge::Call);

/// The near side's sink: a context pointer and the one function that reaches it.
///
/// A struct rather than a closure because a `@convention(c)` pointer captures nothing, so the
/// context has to travel beside it.
#[derive(Debug, Clone, Copy)]
struct Callback {
    context: *mut c_void,
    deliver: unsafe extern "C" fn(*mut c_void, u32, *const c_uchar, usize),
}

// SAFETY: `context` is the near side's, and obligation 1 above is what makes moving it to the
// socket's thread sound — it stays valid until `_free` returns, and `_free` joins that thread. The
// pointer is never dereferenced here; it is handed back to the near side, which owns what it means.
#[expect(
    unsafe_code,
    reason = "the context is a raw pointer the caller keeps alive across a thread"
)]
unsafe impl Send for Callback {}
// SAFETY: as above. The socket calls `deliver` from one thread and never concurrently with itself
// (obligation 2), so a shared reference to this struct is only ever read.
#[expect(
    unsafe_code,
    reason = "the context is a raw pointer the caller keeps alive across a thread"
)]
unsafe impl Sync for Callback {}

impl Callback {
    /// Hand one event over. An empty run crosses as a null pointer and a zero length, which is the
    /// convention every other door in this crate uses.
    #[expect(
        unsafe_code,
        reason = "calling the caller's own function pointer is the whole point"
    )]
    fn say(&self, kind: u32, payload: &[u8]) {
        let (bytes, length) = if payload.is_empty() {
            (core::ptr::null(), 0)
        } else {
            (payload.as_ptr(), payload.len())
        };
        // SAFETY: `deliver` is the pointer the caller passed to the open door and `context` is its
        // own; both are valid until `_free` returns, which cannot happen while this runs because
        // `_free` joins this thread.
        unsafe { (self.deliver)(self.context, kind, bytes, length) }
    }
}

impl ws::lane::Sink for Callback {
    fn event(&self, event: ws::lane::Event<'_>) {
        match event {
            ws::lane::Event::Connected => self.say(SLOPDESK_DEVICE_WS_CONNECTED, &[]),
            ws::lane::Event::Text(bytes) => self.say(SLOPDESK_DEVICE_WS_TEXT, bytes),
            ws::lane::Event::Binary(bytes) => self.say(SLOPDESK_DEVICE_WS_BINARY, bytes),
            ws::lane::Event::Ended(reason) => {
                self.say(SLOPDESK_DEVICE_WS_ENDED, reason.unwrap_or_default().as_bytes());
            },
        }
    }
}

impl bridge::Sink for Callback {
    fn event(&self, event: bridge::Event<'_>) {
        match event {
            bridge::Event::Reply(line) => self.say(SLOPDESK_DEVICE_BRIDGE_REPLY, line),
            bridge::Event::Bytes(bytes) => self.say(SLOPDESK_DEVICE_BRIDGE_BYTES, bytes),
            bridge::Event::Ended(reason) => {
                self.say(
                    SLOPDESK_DEVICE_BRIDGE_ENDED,
                    reason.unwrap_or_default().as_bytes(),
                );
            },
        }
    }
}

/// Open one `ws://` URL and start reading it.
///
/// Returns at once; the dial happens on the socket's own thread, so the first thing the callback
/// says is either `CONNECTED` or `ENDED`. A URL this client will not open — anything that is not
/// `ws://`, or an authority it cannot dial — ends through the callback rather than answering null,
/// so the near side has ONE failure path instead of two.
///
/// Null only when the URL bytes are not UTF-8. No callback has run or ever will in that case, so
/// the context may be freed at once.
///
/// # Safety
/// `url` is null or `url_len` readable bytes for the duration of this call, and `context` stays
/// valid until [`slopdesk_device_ws_free`] RETURNS — the reader thread holds it until then.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_device_ws_open(
    url: *const c_uchar,
    url_len: usize,
    context: *mut c_void,
    on_event: unsafe extern "C" fn(*mut c_void, u32, *const c_uchar, usize),
) -> *mut SlopDeskDeviceWs {
    // SAFETY: the caller's obligation, restated at the door; the borrow dies with this call.
    let Ok(url) = core::str::from_utf8(unsafe { borrow(url, url_len) }) else {
        return core::ptr::null_mut();
    };
    let sink = Arc::new(Callback {
        context,
        deliver: on_event,
    });
    Box::into_raw(Box::new(SlopDeskDeviceWs(ws::lane::Lane::open(url, sink))))
}

/// Send one text message. `false` when the socket is not up — which is a DROP, not a queue: a
/// gesture delivered late replays a tap the user has already moved on from.
///
/// # Safety
/// `lane` is null or a live handle from [`slopdesk_device_ws_open`], and `text` is null or
/// `text_len` readable bytes — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_device_ws_send_text(
    lane: *mut SlopDeskDeviceWs,
    text: *const c_uchar,
    text_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated at the door; both borrows die with this call.
    unsafe { lane.as_ref() }.is_some_and(|lane| {
        // SAFETY: as above.
        lane.0.send_text(unsafe { borrow(text, text_len) })
    })
}

/// Close the socket and release the handle.
///
/// Tears the connection down and JOINS the reader, so the callback is not running when this
/// returns and never will be again. A null pointer is a no-op.
///
/// # Safety
/// `lane` is null or a handle from [`slopdesk_device_ws_open`] that is freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_device_ws_free(lane: *mut SlopDeskDeviceWs) {
    if lane.is_null() {
        return;
    }
    // SAFETY: the caller's obligation — this pointer came from `slopdesk_device_ws_open` and is
    // freed exactly once. The drop tears down and joins.
    drop(unsafe { Box::from_raw(lane) });
}

/// Dial the Android bridge and write one request line.
///
/// `request` is a whole line, newline included — `slopdesk_android_bridge_request` built it, and it
/// is the only thing that can refuse to. Returns at once; the dial happens on the call's own
/// thread.
///
/// Null only when the host bytes are not UTF-8. No callback has run or ever will in that case.
///
/// # Safety
/// `host` is null or `host_len` readable bytes and `request` is null or `request_len` readable
/// bytes, both for the duration of this call; `context` stays valid until
/// [`slopdesk_device_bridge_free`] RETURNS.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_device_bridge_open(
    host: *const c_uchar,
    host_len: usize,
    port: u16,
    request: *const c_uchar,
    request_len: usize,
    context: *mut c_void,
    on_event: unsafe extern "C" fn(*mut c_void, u32, *const c_uchar, usize),
) -> *mut SlopDeskDeviceBridge {
    // SAFETY: the caller's obligation, restated at the door; both borrows die with this call.
    let (host, request) = unsafe { (borrow(host, host_len), borrow(request, request_len)) };
    let Ok(host) = core::str::from_utf8(host) else {
        return core::ptr::null_mut();
    };
    let sink = Arc::new(Callback {
        context,
        deliver: on_event,
    });
    Box::into_raw(Box::new(SlopDeskDeviceBridge(bridge::Call::open(
        host, port, request, sink,
    ))))
}

/// Send bytes upstream — `open`'s control channel, and nothing else uses it. `false` when the
/// socket is not up, for the same reason the websocket's send says so.
///
/// # Safety
/// `call` is null or a live handle from [`slopdesk_device_bridge_open`], and `bytes` is null or
/// `bytes_len` readable bytes — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_device_bridge_send(
    call: *mut SlopDeskDeviceBridge,
    bytes: *const c_uchar,
    bytes_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated at the door; both borrows die with this call.
    unsafe { call.as_ref() }.is_some_and(|call| {
        // SAFETY: as above.
        call.0.send(unsafe { borrow(bytes, bytes_len) })
    })
}

/// Close the call and release the handle. Joins the reader, as the websocket's free does. A null
/// pointer is a no-op.
///
/// # Safety
/// `call` is null or a handle from [`slopdesk_device_bridge_open`] that is freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_device_bridge_free(call: *mut SlopDeskDeviceBridge) {
    if call.is_null() {
        return;
    }
    // SAFETY: the caller's obligation — this pointer came from `slopdesk_device_bridge_open` and is
    // freed exactly once. The drop tears down and joins.
    drop(unsafe { Box::from_raw(call) });
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "a door's test calls the door")]
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]

    use core::ffi::{c_uchar, c_void};
    use std::io::{Read as _, Write as _};
    use std::net::{Ipv4Addr, TcpListener};
    use std::sync::{Condvar, Mutex};
    use std::time::Duration;

    use super::{
        SLOPDESK_DEVICE_BRIDGE_ENDED, SLOPDESK_DEVICE_BRIDGE_REPLY, SLOPDESK_DEVICE_WS_ENDED,
        slopdesk_device_bridge_free, slopdesk_device_bridge_open, slopdesk_device_ws_free,
        slopdesk_device_ws_open,
    };

    /// Everything the door said, in order, as the near side would collect it.
    #[derive(Debug, Default)]
    struct Heard {
        said: Mutex<Vec<(u32, Vec<u8>)>>,
        rang: Condvar,
    }

    impl Heard {
        fn settled(&self, count: usize) -> Vec<(u32, Vec<u8>)> {
            let mut said = self.said.lock().unwrap();
            while said.len() < count {
                let (next, timed_out) = self.rang.wait_timeout(said, Duration::from_secs(5)).unwrap();
                said = next;
                if timed_out.timed_out() {
                    break;
                }
            }
            said.clone()
        }
    }

    /// The `@convention(c)` sink a near side would write, in Rust.
    unsafe extern "C" fn collect(context: *mut c_void, kind: u32, bytes: *const c_uchar, length: usize) {
        let Some(heard) = (unsafe { context.cast::<Heard>().as_ref() }) else {
            return;
        };
        let payload = if length == 0 || bytes.is_null() {
            Vec::new()
        } else {
            unsafe { core::slice::from_raw_parts(bytes, length) }.to_vec()
        };
        if let Ok(mut said) = heard.said.lock() {
            said.push((kind, payload));
        }
        heard.rang.notify_all();
    }

    /// A URL the client will not open reports through the callback, which is the property that
    /// keeps the near side to one failure path.
    #[test]
    fn a_websocket_url_this_build_refuses_ends_through_the_callback() {
        let heard = Heard::default();
        let url = b"wss://simulator.local/stream";
        let lane = unsafe {
            slopdesk_device_ws_open(
                url.as_ptr(),
                url.len(),
                core::ptr::from_ref(&heard).cast::<c_void>().cast_mut(),
                collect,
            )
        };
        assert!(!lane.is_null());
        assert_eq!(heard.settled(1), vec![(SLOPDESK_DEVICE_WS_ENDED, Vec::new())]);
        unsafe { slopdesk_device_ws_free(lane) };
    }

    /// The whole bridge door end to end: a request written, an ack read, an ending said.
    #[test]
    fn a_bridge_call_writes_its_request_and_answers_the_ack() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let served = std::thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            let mut asked = Vec::new();
            let mut scratch = [0_u8; 256];
            while !asked.contains(&b'\n') {
                let read = peer.read(&mut scratch).unwrap();
                if read == 0 {
                    break;
                }
                asked.extend_from_slice(scratch.get(..read).unwrap_or_default());
            }
            peer.write_all(b"{\"ok\":true}\n").unwrap();
            drop(peer);
            asked
        });

        let heard = Heard::default();
        let host = b"127.0.0.1";
        let request = b"{\"op\":\"list\"}\n";
        let call = unsafe {
            slopdesk_device_bridge_open(
                host.as_ptr(),
                host.len(),
                port,
                request.as_ptr(),
                request.len(),
                core::ptr::from_ref(&heard).cast::<c_void>().cast_mut(),
                collect,
            )
        };
        assert!(!call.is_null());
        let said = heard.settled(2);
        unsafe { slopdesk_device_bridge_free(call) };
        assert_eq!(served.join().unwrap(), request);
        assert_eq!(said, vec![
            (SLOPDESK_DEVICE_BRIDGE_REPLY, b"{\"ok\":true}".to_vec()),
            (SLOPDESK_DEVICE_BRIDGE_ENDED, Vec::new()),
        ]);
    }

    /// Freeing a null handle is the near side's `deinit` on a socket that never opened.
    #[test]
    fn freeing_nothing_is_allowed() {
        unsafe { slopdesk_device_ws_free(core::ptr::null_mut()) };
        unsafe { slopdesk_device_bridge_free(core::ptr::null_mut()) };
    }
}
