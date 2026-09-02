//! Every `VideoToolbox`, `CoreMedia` and `CoreVideo` key this crate names, resolved in one place.
//!
//! The keys are `extern` statics rather than string literals, and the reason is measured rather
//! than cautious: `kVTEncodeFrameOptionKey_ForceKeyFrame` is the string `EncoderForceKeyframe`.
//! Every other key in this surface — `RealTime`, `AverageBitRate`, `MaxAllowedFrameQP`,
//! `EnableLowLatencyRateControl`, all twenty-odd of them — is spelled exactly like the tail of its
//! own constant, so a reviewer transcribing literals would have got that one wrong and had no way
//! to see it: the property would apply, the encode would succeed, and every frame the host meant to
//! force as an IDR would ship as a delta. Recovery would stop working and nothing would report an
//! error.
//!
//! Reading an `extern` static is `unsafe` because Rust cannot prove the image initialised it. The
//! frameworks guarantee they did, at load, and `slopdesk-apple-cgwindow` already carries the
//! identical obligation for the `kCGWindow*` keys. Stating it once, here, is what keeps every other
//! module in the crate free of it.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use objc2_core_foundation::CFString;

/// A COMPRESSION property or option key this crate may name.
///
/// An enum rather than a `&CFString` parameter so the vocabulary is closed: a caller cannot invent
/// a key, and the compiler lists every one that exists at the single site that resolves them.
/// [`DecodeKey`] is its decompression twin, and they are two enums rather than one because only one
/// of them exists on every slice.
#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Key {
    // ---- encoder specification (the CREATE dictionary, not `VTSessionSetProperty`) ----
    /// `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`.
    EnableLowLatencyRateControl,
    /// `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`.
    RequireHardwareAcceleratedVideoEncoder,

    // ---- session properties ----
    /// `kVTCompressionPropertyKey_RealTime`.
    RealTime,
    /// `kVTCompressionPropertyKey_ExpectedFrameRate`.
    ExpectedFrameRate,
    /// `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`.
    PrioritizeEncodingSpeedOverQuality,
    /// `kVTCompressionPropertyKey_AllowFrameReordering`.
    AllowFrameReordering,
    /// `kVTCompressionPropertyKey_MaxFrameDelayCount`.
    MaxFrameDelayCount,
    /// `kVTCompressionPropertyKey_MaximizePowerEfficiency`.
    MaximizePowerEfficiency,
    /// `kVTCompressionPropertyKey_MaxKeyFrameInterval`.
    MaxKeyFrameInterval,
    /// `kVTCompressionPropertyKey_AverageBitRate`.
    AverageBitRate,
    /// `kVTCompressionPropertyKey_DataRateLimits`.
    DataRateLimits,
    /// `kVTCompressionPropertyKey_SpatialAdaptiveQPLevel`.
    SpatialAdaptiveQPLevel,
    /// `kVTCompressionPropertyKey_MaxAllowedFrameQP`.
    MaxAllowedFrameQP,
    /// `kVTCompressionPropertyKey_MinAllowedFrameQP`.
    MinAllowedFrameQP,
    /// `kVTCompressionPropertyKey_EnableLTR`.
    EnableLtr,
    /// `kVTCompressionPropertyKey_ColorPrimaries`.
    ColorPrimaries,
    /// `kVTCompressionPropertyKey_TransferFunction`.
    TransferFunction,
    /// `kVTCompressionPropertyKey_YCbCrMatrix`.
    YCbCrMatrix,

    // ---- per-frame options ----
    /// `kVTEncodeFrameOptionKey_ForceKeyFrame` — the string `EncoderForceKeyframe`, see above.
    ForceKeyFrame,
    /// `kVTEncodeFrameOptionKey_ForceLTRRefresh`.
    ForceLtrRefresh,
    /// `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`.
    AcknowledgedLtrTokens,
}

#[cfg(target_os = "macos")]
impl Key {
    /// The framework's own `CFString` for this key.
    ///
    /// # Safety
    /// Each arm reads an `extern` static that the framework's image initialises before any code in
    /// this process runs. Rust cannot see that guarantee, which is the whole of the obligation; the
    /// bindings already carry the `&'static` lifetime and the `CFString` type, so nothing is cast
    /// and nothing is owned.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "framework key constants are extern statics; docs/57 §2 admits reading one"
    )]
    pub(crate) fn cf(self) -> &'static CFString {
        use objc2_video_toolbox as vt;
        // SAFETY: framework rule, above — every arm is a framework-initialised `extern` static.
        unsafe {
            match self {
                Self::EnableLowLatencyRateControl => {
                    vt::kVTVideoEncoderSpecification_EnableLowLatencyRateControl
                },
                Self::RequireHardwareAcceleratedVideoEncoder => {
                    vt::kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder
                },
                Self::RealTime => vt::kVTCompressionPropertyKey_RealTime,
                Self::ExpectedFrameRate => vt::kVTCompressionPropertyKey_ExpectedFrameRate,
                Self::PrioritizeEncodingSpeedOverQuality => {
                    vt::kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality
                },
                Self::AllowFrameReordering => vt::kVTCompressionPropertyKey_AllowFrameReordering,
                Self::MaxFrameDelayCount => vt::kVTCompressionPropertyKey_MaxFrameDelayCount,
                Self::MaximizePowerEfficiency => vt::kVTCompressionPropertyKey_MaximizePowerEfficiency,
                Self::MaxKeyFrameInterval => vt::kVTCompressionPropertyKey_MaxKeyFrameInterval,
                Self::AverageBitRate => vt::kVTCompressionPropertyKey_AverageBitRate,
                Self::DataRateLimits => vt::kVTCompressionPropertyKey_DataRateLimits,
                Self::SpatialAdaptiveQPLevel => vt::kVTCompressionPropertyKey_SpatialAdaptiveQPLevel,
                Self::MaxAllowedFrameQP => vt::kVTCompressionPropertyKey_MaxAllowedFrameQP,
                Self::MinAllowedFrameQP => vt::kVTCompressionPropertyKey_MinAllowedFrameQP,
                Self::EnableLtr => vt::kVTCompressionPropertyKey_EnableLTR,
                Self::ColorPrimaries => vt::kVTCompressionPropertyKey_ColorPrimaries,
                Self::TransferFunction => vt::kVTCompressionPropertyKey_TransferFunction,
                Self::YCbCrMatrix => vt::kVTCompressionPropertyKey_YCbCrMatrix,
                Self::ForceKeyFrame => vt::kVTEncodeFrameOptionKey_ForceKeyFrame,
                Self::ForceLtrRefresh => vt::kVTEncodeFrameOptionKey_ForceLTRRefresh,
                Self::AcknowledgedLtrTokens => vt::kVTEncodeFrameOptionKey_AcknowledgedLTRTokens,
            }
        }
    }
}

/// A `CFString` VALUE this crate may write, as opposed to a key.
///
/// Only the BT.709 colour tags need one; every other property takes a number or a boolean. The
/// encoder writes them, so this is macOS-only with the rest of the compression vocabulary.
#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StringValue {
    /// `kCVImageBufferColorPrimaries_ITU_R_709_2`.
    Primaries709,
    /// `kCVImageBufferTransferFunction_ITU_R_709_2`.
    Transfer709,
    /// `kCVImageBufferYCbCrMatrix_ITU_R_709_2`.
    Matrix709,
}

#[cfg(target_os = "macos")]
impl StringValue {
    /// The framework's own `CFString` for this value.
    ///
    /// # Safety
    /// [`Key::cf`]'s, for `CoreVideo`'s image-buffer attachment constants.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "framework value constants are extern statics; same obligation as Key::cf"
    )]
    pub(crate) fn cf(self) -> &'static CFString {
        use objc2_core_video as cv;
        // SAFETY: framework rule, above.
        unsafe {
            match self {
                Self::Primaries709 => cv::kCVImageBufferColorPrimaries_ITU_R_709_2,
                Self::Transfer709 => cv::kCVImageBufferTransferFunction_ITU_R_709_2,
                Self::Matrix709 => cv::kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            }
        }
    }
}

/// A per-sample ATTACHMENT this crate reads off a finished encode, or writes onto one to decode.
///
/// The only key vocabulary shared by both halves of the crate, which is why it is not `cfg`'d as a
/// whole: the two the encoder READS are macOS-only, the one the decoder WRITES is on every slice.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Attachment {
    /// `kCMSampleAttachmentKey_NotSync` — present and true on a frame that is NOT a keyframe.
    ///
    /// On EVERY slice, unlike the `VideoToolbox` key below it: the encoder reads this one on the
    /// host, and the device panels write it on whatever client is showing a phone.
    NotSync,
    /// `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken` — the token a client must ack.
    #[cfg(target_os = "macos")]
    RequireLtrAcknowledgementToken,
    /// `kCMSampleAttachmentKey_DisplayImmediately` — emit on decode rather than holding for
    /// reorder.
    DisplayImmediately,
}

impl Attachment {
    /// The framework's own `CFString` for this attachment key.
    ///
    /// # Safety
    /// [`Key::cf`]'s, for the two sample-attachment constants — one `CoreMedia`'s, one
    /// `VideoToolbox`'s.
    #[expect(
        unsafe_code,
        reason = "framework attachment constants are extern statics; same obligation as Key::cf"
    )]
    pub(crate) fn cf(self) -> &'static CFString {
        // SAFETY: framework rule, above.
        unsafe {
            match self {
                Self::NotSync => objc2_core_media::kCMSampleAttachmentKey_NotSync,
                #[cfg(target_os = "macos")]
                Self::RequireLtrAcknowledgementToken => {
                    objc2_video_toolbox::kVTSampleAttachmentKey_RequireLTRAcknowledgementToken
                },
                Self::DisplayImmediately => objc2_core_media::kCMSampleAttachmentKey_DisplayImmediately,
            }
        }
    }
}

/// `kVTQPModulationLevel_Disable`, the value `SpatialAdaptiveQPLevel` is set to.
///
/// A plain `i32` in the bindings rather than a `CFNumber` static, so there is nothing to read
/// unsafely; it is here so the one call site does not carry a bare literal whose meaning is
/// invisible. MEASURED to be `0` — the sign is not guessable from the name.
#[cfg(target_os = "macos")]
pub(crate) const QP_MODULATION_DISABLE: i64 = objc2_video_toolbox::kVTQPModulationLevel_Disable as i64;

/// A DECOMPRESSION key this crate may name, and the two pixel formats it may ask for.
///
/// Separate from [`Key`] because only this half of the crate exists on every Apple slice. Same
/// obligation, same shape, same reason for reading the framework's own statics rather than spelling
/// them: `kCVPixelBufferIOSurfacePropertiesKey` is `IOSurfaceProperties`, which looks guessable
/// right up until one of them is not.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DecodeKey {
    /// `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`.
    RequireHardwareAcceleratedVideoDecoder,
    /// `kCVPixelBufferPixelFormatTypeKey`.
    PixelFormatType,
    /// `kCVPixelBufferMetalCompatibilityKey`.
    MetalCompatibility,
    /// `kCVPixelBufferIOSurfacePropertiesKey`.
    IoSurfaceProperties,
    /// `kCVPixelBufferWidthKey`.
    Width,
    /// `kCVPixelBufferHeightKey`.
    Height,
}

impl DecodeKey {
    /// The framework's own `CFString` for this key.
    ///
    /// # Safety
    /// [`Attachment::cf`]'s — every arm is a framework-initialised `extern` static, carrying the
    /// `&'static` lifetime and the `CFString` type from the binding.
    #[expect(
        unsafe_code,
        reason = "framework key constants are extern statics; same obligation as Attachment::cf"
    )]
    pub(crate) fn cf(self) -> &'static CFString {
        use objc2_core_video as cv;
        // SAFETY: framework rule, above.
        unsafe {
            match self {
                Self::RequireHardwareAcceleratedVideoDecoder => {
                    objc2_video_toolbox::kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
                },
                Self::PixelFormatType => cv::kCVPixelBufferPixelFormatTypeKey,
                Self::MetalCompatibility => cv::kCVPixelBufferMetalCompatibilityKey,
                Self::IoSurfaceProperties => cv::kCVPixelBufferIOSurfacePropertiesKey,
                Self::Width => cv::kCVPixelBufferWidthKey,
                Self::Height => cv::kCVPixelBufferHeightKey,
            }
        }
    }

    /// The NV12 four-character code for the negotiated luma range.
    ///
    /// The two variants have an IDENTICAL plane layout, so the renderer's texture creation does not
    /// branch on this; what differs is the range the shader's coefficients assume. Plain constants
    /// in the bindings, so there is nothing to read unsafely — they are resolved here so the one
    /// call site carries a name rather than a hex literal.
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a four-character code is a bit pattern; CFNumber wants those bits signed"
    )]
    pub(crate) const fn nv12_format(full_range: bool) -> i32 {
        if full_range {
            objc2_core_video::kCVPixelFormatType_420YpCbCr8BiPlanarFullRange as i32
        } else {
            objc2_core_video::kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange as i32
        }
    }
}
