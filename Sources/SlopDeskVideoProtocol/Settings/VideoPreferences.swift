import CSlopDeskFFI

/// User-facing subset of the ~80 video/host `SLOPDESK_*` flags (decision #6 / #10), grouped into a
/// `Codable` model. These flags are read at `static let` init from the environment and CANNOT
/// live-reload — so the model is serialised to a `video-prefs.json` SIDECAR that the host daemon reads
/// at launch and folds into ``EnvConfig/overlay`` BEFORE any consumer's `static let` is forced (W12).
/// The Settings UI (W13) marks every field **"applies on reconnect / restart."**
///
/// Pure value type, no SwiftUI / `@AppStorage` — it persists via the sidecar (host) and round-trips
/// through `EnvBridge.toEnv()`. The model is the source of truth; `EnvBridge` maps each field 1:1 to
/// the `SLOPDESK_*` key it overrides.
///
/// SYMMETRY: a few keys must be set IDENTICALLY on host AND client or the two ends disagree
/// (`SLOPDESK_FEC_M` / `_FEC_K`, the mux window). Those fields are flagged in ``EnvBridge`` and the
/// UI surfaces a "set on both ends" warning.
///
/// DEFAULT = "unset": every field is `nil` by default, so a freshly-constructed `VideoPreferences`
/// produces an EMPTY env overlay (``EnvBridge/toEnv()`` emits nothing) — byte-identical to today's
/// compile-time-default behaviour. A field becomes an overlay entry only once the user sets it.
public struct VideoPreferences: Codable, Sendable, Equatable {
    // MARK: Quality (QP)

    /// Sharpest (lowest) constant QP on a clean link → `SLOPDESK_QP_SHARP` (1…51, default 26).
    public var qpSharp: Int?
    /// Coarsest (highest) QP under congestion → `SLOPDESK_QP_COARSE` (1…51, default 40).
    public var qpCoarse: Int?
    /// Min/Max QP decouple (skip-coding keeps a static sidebar crisp) → `SLOPDESK_QP_DECOUPLE`.
    public var qpDecouple: Bool?

    // MARK: FEC (SYMMETRIC — set on both ends)

    /// Reed–Solomon parity count `m` → `SLOPDESK_FEC_M` (`m >= 2` activates multi-loss RS). SYMMETRIC.
    public var fecM: Int?
    /// RS group size `k` → `SLOPDESK_FEC_K`. Only consulted when `fecM >= 2`. SYMMETRIC.
    public var fecK: Int?

    // MARK: Pacer / playout

    /// Presentation pacer mode → `SLOPDESK_PACER`. `deadline` = the smoothness-tuned buffer; any
    /// other value = present-on-arrival.
    public enum Pacer: String, Codable, Sendable, CaseIterable {
        case deadline
        case arrival
    }

    /// Presentation pacer → `SLOPDESK_PACER`.
    public var pacer: Pacer?
    /// Fixed playout buffer (ms) → `SLOPDESK_PLAYOUT_MS` (also flips the client OUT of adaptive playout).
    public var playoutMs: Double?

    // MARK: Capture

    /// Capture-scale override (downscale the 2× VD render to N× capture) → `SLOPDESK_CAPTURE_SCALE`.
    public var captureScale: Double?
    /// SCStream filter mode → `SLOPDESK_DISPLAY_CAPTURE` (`window` / `display` / `include`).
    public enum DisplayCapture: String, Codable, Sendable, CaseIterable {
        case window
        case display
        case include
    }

    /// Display-capture filter mode → `SLOPDESK_DISPLAY_CAPTURE`.
    public var displayCapture: DisplayCapture?
    /// HiDPI 2× virtual display → `SLOPDESK_VD` (default ON; OFF writes `"0"`).
    public var virtualDisplay: Bool?

    // MARK: Client-side render

    /// Unsharp-mask strength on the luma channel → `SLOPDESK_SHARPEN` (0 = off). Client-side.
    public var sharpen: Double?

    // MARK: What UNSET means, named

    /// What each surfaced field resolves to while it is `nil`, and therefore what a control over it
    /// must SHOW while nothing is set.
    ///
    /// Named here rather than spelled at the control, for the reason
    /// ``AgentPreferences/preventSleepDefault`` is: these are the daemon's and the renderer's own
    /// defaults, and a settings page that repeated them as literals would be a second copy that
    /// nothing tells when the first one moves. A control reads through `?? …`, so an untouched field
    /// stays `nil` — the sidecar carries a value only once someone sets one, which is what keeps a
    /// fresh install's env overlay empty.
    ///
    /// The four below spent a while proving that paragraph right by disobeying it: they were
    /// literals — `26`, `40`, `1`, `5` — directly under the sentence that forbids literals here,
    /// against doors that already vended every one of them. The failure mode is quiet and asymmetric:
    /// a retune moves the encoder's operating point while Settings keeps SHOWING the old number, and
    /// "reset to default" writes that old number into the overlay as an explicit override, so the
    /// gesture that is supposed to get out of the daemon's way is the one that pins it to a value
    /// nobody chose.
    private static let qpDefaults = slopdesk_qp_config_default()
    public static let qpSharpDefault = Int(qpDefaults.sharp)
    /// See ``qpSharpDefault``.
    public static let qpCoarseDefault = Int(qpDefaults.coarse)
    /// See ``qpSharpDefault`` — index 11 of the FEC ladder's constant door is the multi-loss default
    /// `m`, which is its own constant rather than the floor it happens to equal today.
    public static let fecMDefault = Int(slopdesk_adaptive_fec_constant(11))
    /// See ``qpSharpDefault`` — index 6 is the group size used when multi-loss is on and
    /// `SLOPDESK_FEC_K` is unset.
    public static let fecKDefault = Int(slopdesk_adaptive_fec_constant(6))
    /// See ``qpSharpDefault`` — `MetalVideoRenderer` reads anything at or below zero as off.
    public static let sharpenDefault: Double = 0
    /// See ``qpSharpDefault`` — the pacer presents on arrival unless told to hold to a deadline.
    public static let pacerDefault: Pacer = .arrival

    public init(
        qpSharp: Int? = nil,
        qpCoarse: Int? = nil,
        qpDecouple: Bool? = nil,
        fecM: Int? = nil,
        fecK: Int? = nil,
        pacer: Pacer? = nil,
        playoutMs: Double? = nil,
        captureScale: Double? = nil,
        displayCapture: DisplayCapture? = nil,
        virtualDisplay: Bool? = nil,
        sharpen: Double? = nil,
    ) {
        self.qpSharp = qpSharp
        self.qpCoarse = qpCoarse
        self.qpDecouple = qpDecouple
        self.fecM = fecM
        self.fecK = fecK
        self.pacer = pacer
        self.playoutMs = playoutMs
        self.captureScale = captureScale
        self.displayCapture = displayCapture
        self.virtualDisplay = virtualDisplay
        self.sharpen = sharpen
    }

    /// Read the `[video]` table out of a resolved ``AppConfig``.
    ///
    /// Every row here is declared WITHOUT a default, which is the whole point: unset must stay unset
    /// so the sidecar keeps emitting nothing and the daemon's own compiled defaults hold. So this
    /// reads through the `optional*` accessors — the ones that answer `nil` for an absent key instead
    /// of a zero — and a file that mentions no `[video]` key at all yields a value equal to
    /// `VideoPreferences()`.
    ///
    /// The two enum rows are `Choice`s with no default, so ``AppConfig/choice(_:_:)`` (which insists
    /// on a fallback) is the wrong door: they come across as optional text and fail to `nil` on a
    /// token the row would already have refused.
    public init(_ config: AppConfig) {
        self.init(
            qpSharp: config.optionalInt("video.qp-sharp"),
            qpCoarse: config.optionalInt("video.qp-coarse"),
            qpDecouple: config.optionalFlag("video.qp-decouple"),
            fecM: config.optionalInt("video.fec-m"),
            fecK: config.optionalInt("video.fec-k"),
            pacer: config.optionalText("video.pacer").flatMap(Pacer.init(rawValue:)),
            playoutMs: config.optionalDouble("video.playout-ms"),
            captureScale: config.optionalDouble("video.capture-scale"),
            displayCapture: config.optionalText("video.display-capture")
                .flatMap(DisplayCapture.init(rawValue:)),
            virtualDisplay: config.optionalFlag("video.virtual-display"),
            sharpen: config.optionalDouble("video.sharpen"),
        )
    }
}
