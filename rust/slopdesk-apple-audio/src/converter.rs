//! One owned `AudioConverter`, and the four property calls anyone makes on it.
//!
//! This is the crate's leak boundary. `AudioConverterNew` hands back a `+1` reference that
//! `AudioConverterDispose` is the only way to give up, and `objc2` cannot model that for a plain
//! `*mut OpaqueAudioConverter` the way `CFRetained` models a Core Foundation object. So exactly one
//! type holds one, it is created in one place and disposed in one place, and both the encoder and
//! the decoder reach the framework only through it. The leak test in `lib.rs` builds and drops
//! several hundred of these; a missing dispose is a codec instance per frame, which on a live
//! session is a process that grows until it is killed.
//!
//! ## Not `Send`, on purpose
//! An `AudioConverter` is documented as safe to use from one thread at a time and this crate makes
//! no attempt to widen that. `AudioConverterRef` is a raw pointer, so the type is `!Send` and
//! `!Sync` by inference and nothing here lifts it. The FFI layer hands Swift an opaque handle and
//! Swift confines every call to its serial audio queue, which is the same discipline the Swift this
//! replaces ran under — it just had to spell it as an `@unchecked Sendable` promise instead.

use core::ffi::c_void;
use core::ptr::NonNull;

use objc2_audio_toolbox::{
    AudioConverterDispose, AudioConverterGetProperty, AudioConverterGetPropertyInfo, AudioConverterNew,
    AudioConverterPropertyID, AudioConverterRef, AudioConverterReset, AudioConverterSetProperty,
};
use objc2_core_audio_types::AudioStreamBasicDescription;

use crate::asbd::{NO_ERR, OsStatus};

/// A live `AudioConverter`, disposed when dropped.
#[derive(Debug)]
pub(crate) struct Converter {
    raw: AudioConverterRef,
}

// `set_u32`, `get_u32` and `get_bytes` are the ENCODER's — the bitrate, the worst-case packet size
// and the compression cookie — and the encoder is macOS-only, so an iOS slice compiles a
// `Converter` only the decoder calls. Splitting the methods by their callers would cut one
// framework wrapper along the wrong seam; saying so once here is the honest version.
#[cfg_attr(
    not(target_os = "macos"),
    expect(
        dead_code,
        reason = "the three encoder-only properties; the encoder is macOS-only"
    )
)]
impl Converter {
    /// Builds a converter from `input` to `output`, or answers the framework's refusal.
    ///
    /// The refusal is a real answer and not an error to log and retry: "this machine has no AAC-ELD
    /// encoder" does not become true a frame later, so the caller latches it and the lane goes
    /// permanently silent rather than asking again sixty times a second.
    ///
    /// # Safety
    /// `AudioConverterNew` reads both descriptions for the duration of the call and writes the new
    /// converter through the third slot. All three are live locals of the declared type — the two
    /// descriptions are copied into this frame precisely so the framework cannot outlive them, and
    /// the out-slot is initialised to null so a refusal that writes nothing still reads as null.
    /// Nothing is dereferenced by this crate and nothing is transmuted.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    pub(crate) fn new(
        input: &AudioStreamBasicDescription,
        output: &AudioStreamBasicDescription,
    ) -> Result<Self, OsStatus> {
        // Copied rather than borrowed: `AudioConverterNew` takes `NonNull`, and taking one from a
        // caller's reference would state a mutability this crate was not given.
        let mut input = *input;
        let mut output = *output;
        let mut raw: AudioConverterRef = core::ptr::null_mut();
        // SAFETY: framework rule, above — three live slots of the declared types.
        let status = unsafe {
            AudioConverterNew(
                NonNull::from(&mut input),
                NonNull::from(&mut output),
                NonNull::from(&mut raw),
            )
        };
        if status != NO_ERR || raw.is_null() {
            // A converter that half-built is not a converter: the framework's contract is that a
            // non-`noErr` return has written nothing worth disposing.
            return Err(if status == NO_ERR { -1 } else { status });
        }
        Ok(Self { raw })
    }

    /// The handle, for the two fill calls that take it directly.
    pub(crate) const fn raw(&self) -> AudioConverterRef {
        self.raw
    }

    /// Drops the codec's carried state — the bit reservoir and window history.
    ///
    /// Called on a stream discontinuity: an enable transition on the host, a decode failure on the
    /// client. The status is deliberately ignored, because `AudioConverterReset` on a live
    /// converter has no failure this caller could act on, and the alternative to ignoring it is a
    /// log line on a path that is already recovering.
    ///
    /// # Safety
    /// `AudioConverterReset` takes the converter and nothing else. `self.raw` is non-null for the
    /// whole life of this value — `new` refuses to build one otherwise — and `Drop` is the only
    /// thing that invalidates it.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    pub(crate) fn reset(&self) {
        // SAFETY: framework rule, above — a live converter, no pointers.
        let _ = unsafe { AudioConverterReset(self.raw) };
    }

    /// Sets a `u32`-valued property, answering the framework's status.
    ///
    /// # Safety
    /// `AudioConverterSetProperty` reads `size` bytes from the pointer for the duration of the
    /// call. The pointer is a live local `u32` in this frame and the size is that type's own, so
    /// the framework cannot read past it. Nothing is dereferenced by this crate.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    pub(crate) fn set_u32(&self, property: AudioConverterPropertyID, value: u32) -> OsStatus {
        let mut value = value;
        // SAFETY: framework rule, above — one live `u32` described by its own size.
        unsafe {
            AudioConverterSetProperty(
                self.raw,
                property,
                u32::try_from(size_of::<u32>()).unwrap_or(4),
                NonNull::from(&mut value).cast::<c_void>(),
            )
        }
    }

    /// Sets a byte-valued property — in practice the decompression magic cookie.
    ///
    /// An empty slice is not passed to the framework at all: `AudioConverterSetProperty` has no
    /// meaningful reading of a zero-length property, and a `NonNull` over an empty slice would be a
    /// dangling pointer this crate invented. Answering `NO_ERR` is the truthful result — there was
    /// nothing to set and nothing failed.
    ///
    /// # Safety
    /// `AudioConverterSetProperty` reads `size` bytes from the pointer for the duration of the
    /// call. The pointer is the first byte of `bytes`, whose length is the size passed, and the
    /// slice is borrowed across the whole call. Nothing is dereferenced by this crate.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    pub(crate) fn set_bytes(&self, property: AudioConverterPropertyID, bytes: &[u8]) -> OsStatus {
        let Ok(size) = u32::try_from(bytes.len()) else {
            // A cookie wider than a `u32` is not a cookie; refuse rather than truncate the size and
            // let the framework read what it likes.
            return -1;
        };
        if size == 0 {
            return NO_ERR;
        }
        let Some(base) = NonNull::new(bytes.as_ptr().cast_mut()) else {
            return -1;
        };
        // SAFETY: framework rule, above — `size` is `bytes.len()`, and `bytes` outlives the call.
        unsafe { AudioConverterSetProperty(self.raw, property, size, base.cast::<c_void>()) }
    }

    /// Reads a `u32`-valued property, or `None` when the converter does not publish it.
    ///
    /// # Safety
    /// `AudioConverterGetProperty` writes at most `*size` bytes through the data slot and updates
    /// the size slot. Both are live locals of the declared types and the size is initialised to the
    /// destination's own, so the framework cannot write past it. Nothing is dereferenced by this
    /// crate.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    pub(crate) fn get_u32(&self, property: AudioConverterPropertyID) -> Option<u32> {
        let mut value = 0_u32;
        let mut size = u32::try_from(size_of::<u32>()).unwrap_or(4);
        // SAFETY: framework rule, above — a live `u32` destination bounded by its own size.
        let status = unsafe {
            AudioConverterGetProperty(
                self.raw,
                property,
                NonNull::from(&mut size),
                NonNull::from(&mut value).cast::<c_void>(),
            )
        };
        (status == NO_ERR).then_some(value)
    }

    /// Reads a byte-valued property — in practice the compression magic cookie.
    ///
    /// Two calls, which is the framework's own shape: ask how big, then ask for it. `None` covers
    /// both "this converter publishes no such property" and "it publishes an empty one", which are
    /// the same thing to every caller here.
    ///
    /// # Safety
    /// `AudioConverterGetPropertyInfo` writes a size through one live local and is passed null for
    /// the writability slot it documents as optional. `AudioConverterGetProperty` then writes at
    /// most `*size` bytes into a `Vec` this crate allocated to exactly that size and already
    /// initialised, so there is no uninitialised window even if the call fails. The size is
    /// re-read afterwards and the buffer truncated to what was actually written, so a framework
    /// that publishes less than it advertised cannot leave a tail of zeroes in the cookie.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    pub(crate) fn get_bytes(&self, property: AudioConverterPropertyID) -> Option<Vec<u8>> {
        let mut size = 0_u32;
        // SAFETY: framework rule, above — one live `u32`, and the optional slot passed null.
        let info = unsafe {
            AudioConverterGetPropertyInfo(self.raw, property, &raw mut size, core::ptr::null_mut())
        };
        if info != NO_ERR || size == 0 {
            return None;
        }
        let mut bytes = vec![0_u8; size as usize];
        let base = NonNull::new(bytes.as_mut_ptr())?;
        // SAFETY: framework rule, above — `size` initialised bytes of this crate's own allocation.
        let status = unsafe {
            AudioConverterGetProperty(
                self.raw,
                property,
                NonNull::from(&mut size),
                base.cast::<c_void>(),
            )
        };
        if status != NO_ERR {
            return None;
        }
        // The framework may report back a SMALLER size than it advertised. Trusting the first
        // number would ship trailing zeroes as part of the cookie, and a decoder initialised from
        // a cookie with a tail is a decoder that produces noise.
        bytes.truncate(size as usize);
        (!bytes.is_empty()).then_some(bytes)
    }
}

impl Drop for Converter {
    /// # Safety
    /// `AudioConverterDispose` consumes the `+1` reference `AudioConverterNew` handed out. `new` is
    /// the only constructor, it refuses to build a `Converter` around a null, and this type is not
    /// `Clone` — so there is exactly one dispose per create and the handle is live at this point.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare `AudioToolbox` entry points unsafe"
    )]
    fn drop(&mut self) {
        // SAFETY: framework rule, above — the one dispose for the one create.
        let _ = unsafe { AudioConverterDispose(self.raw) };
    }
}
