// AndroidSidebarRules — the Swift FACE of `slopdesk_devicepanel::android_sidebar`.
//
// ``AndroidPresentation`` is the face of what the panel SAYS about one device. This is the face of
// what the MODEL decides: which row of a list the question is about, whether a lifecycle verb has
// landed, when a wait has gone on too long, how much of a console to keep, and the eleven numbers
// that set this surface's shape and its timing.
//
// ## What crosses, and what deliberately does not
//
// No key and no serial. The model holds the device list and does its own string comparison; what
// crosses is one three-flag record per row saying which rows the question is ABOUT, and the answer
// is a POSITION into the array the model still holds. Building that array per call is one small
// allocation over a list that is a handful of rows on any real host — measured against the
// alternative, which is a rule spelled half in each language.
//
// The lifecycle GUARDS stay in the model: "this row has an AVD name and no serial yet", "this key
// is already in flight". They read `@Observable` state and a `Set` mutated across an `await`, which
// is actor plumbing rather than a rule.
//
// ## The numbers are read once
//
// Every `static let` below is one door call at first use. ``AndroidSidebarMeasure`` is an INDEX into
// one constant family rather than eleven doors, which is `docs/55`'s constant-door shape: an index
// this build cannot name answers `0`, and `0` is not a value any of these can hold.

import CoreGraphics
import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// MARK: - The vocabularies, and the bytes each crosses as

/// A failure this surface reports in its own words.
///
/// Three of the six name the device; the other three cannot, and say so — the two about the MIRROR
/// are about a device already named on screen, and the screenshot one is about the bytes rather than
/// the machine.
package enum AndroidSidebarReport {
    /// A launch the host accepted, whose serial never folded into the row.
    case bootNeverSurfaced
    /// A `kill` the host accepted, whose serial never left the list.
    case shutdownNeverLanded
    /// The device is gone from a freshly-read list.
    case noLongerRunning
    /// The device is up, the mirror is open, and no video has arrived.
    case noVideo
    /// The device never reached a state that could take a mirror before patience ran out.
    case neverFinishedStarting
    /// The bytes the host sent back are not an image anything can paste.
    case screenshotUnreadable

    /// The byte the crate names this report by.
    var ffiByte: UInt8 {
        switch self {
        case .bootNeverSurfaced: UInt8(SLOPDESK_ANDROID_SIDEBAR_REPORT_BOOT_NEVER_SURFACED)
        case .shutdownNeverLanded: UInt8(SLOPDESK_ANDROID_SIDEBAR_REPORT_SHUTDOWN_NEVER_LANDED)
        case .noLongerRunning: UInt8(SLOPDESK_ANDROID_SIDEBAR_REPORT_NO_LONGER_RUNNING)
        case .noVideo: UInt8(SLOPDESK_ANDROID_SIDEBAR_REPORT_NO_VIDEO)
        case .neverFinishedStarting: UInt8(SLOPDESK_ANDROID_SIDEBAR_REPORT_NEVER_FINISHED_STARTING)
        case .screenshotUnreadable: UInt8(SLOPDESK_ANDROID_SIDEBAR_REPORT_SCREENSHOT_UNREADABLE)
        }
    }
}

/// A confirmation for an action whose result is not on screen — something that happened to the
/// DEVICE rather than to the panel.
package enum AndroidSidebarNotice {
    /// The device's own display was switched back on.
    case screenOn
    /// The device's own display was switched off, with the mirror still running.
    case screenOff
    /// Text was pushed to the device's clipboard and pasted.
    case pasted
    /// Text was pushed to the device's clipboard without pasting.
    case copied
    /// A screenshot reached this machine's pasteboard.
    case screenshotCopied

    /// Which field of the notices delivery holds this one's words.
    var ffiField: Int {
        switch self {
        case .screenOn: Int(SLOPDESK_ANDROID_SIDEBAR_NOTICE_SCREEN_ON)
        case .screenOff: Int(SLOPDESK_ANDROID_SIDEBAR_NOTICE_SCREEN_OFF)
        case .pasted: Int(SLOPDESK_ANDROID_SIDEBAR_NOTICE_PASTED)
        case .copied: Int(SLOPDESK_ANDROID_SIDEBAR_NOTICE_COPIED)
        case .screenshotCopied: Int(SLOPDESK_ANDROID_SIDEBAR_NOTICE_SCREENSHOT_COPIED)
        }
    }
}

/// One of the eleven numbers that set this surface's shape and its timing.
///
/// Two counts and nine durations in ONE family, and the mixture is the point: they are all "how
/// much" or "how long" for the same surface, so a reader that takes them through one door cannot
/// pick up ten and re-spell the eleventh.
package enum AndroidSidebarMeasure {
    /// How many rows the console keeps.
    case logCapacity
    /// The longest edge the mirror is scaled to, in pixels.
    case streamMaxSize
    /// How long a freshly-opened mirror may stay silent.
    case firstFrameDeadline
    /// How long a selection keeps chasing a device that is not ready.
    case deviceGrace
    /// The pause between attempts while the device is coming up.
    case reattemptPause
    /// How long a launch may stay invisible before the panel calls it failed.
    case bootVisibleDeadline
    /// How long a `kill` may stay invisible.
    case shutdownVisibleDeadline
    /// How long a confirmation stays up.
    case noticeLifetime
    /// The ensure loop's base cadence.
    case ensurePoll
    /// The device catalogue's own, slower cadence.
    case deviceWatch
    /// How often a lifecycle verb re-reads the list while it holds its spinner.
    case pendingHold

    /// The index the crate answers this measure at.
    var ffiIndex: UInt32 {
        switch self {
        case .logCapacity: UInt32(SLOPDESK_ANDROID_SIDEBAR_LOG_CAPACITY)
        case .streamMaxSize: UInt32(SLOPDESK_ANDROID_SIDEBAR_STREAM_MAX_SIZE)
        case .firstFrameDeadline: UInt32(SLOPDESK_ANDROID_SIDEBAR_FIRST_FRAME_DEADLINE_MS)
        case .deviceGrace: UInt32(SLOPDESK_ANDROID_SIDEBAR_DEVICE_GRACE_MS)
        case .reattemptPause: UInt32(SLOPDESK_ANDROID_SIDEBAR_REATTEMPT_PAUSE_MS)
        case .bootVisibleDeadline: UInt32(SLOPDESK_ANDROID_SIDEBAR_BOOT_VISIBLE_DEADLINE_MS)
        case .shutdownVisibleDeadline: UInt32(SLOPDESK_ANDROID_SIDEBAR_SHUTDOWN_VISIBLE_DEADLINE_MS)
        case .noticeLifetime: UInt32(SLOPDESK_ANDROID_SIDEBAR_NOTICE_LIFETIME_MS)
        case .ensurePoll: UInt32(SLOPDESK_ANDROID_SIDEBAR_ENSURE_POLL_MS)
        case .deviceWatch: UInt32(SLOPDESK_ANDROID_SIDEBAR_DEVICE_WATCH_MS)
        case .pendingHold: UInt32(SLOPDESK_ANDROID_SIDEBAR_PENDING_HOLD_MS)
        }
    }
}

// MARK: - The face

/// Every decision the Android sidebar's model makes about its own list, clocks and words, as
/// `slopdesk_devicepanel::android_sidebar` answers them.
package enum AndroidSidebarRules {
    // MARK: The list

    /// Where the row named by `key` sits, or `nil` when the list no longer carries it.
    ///
    /// The one question four readers ask: the serial for a key, the selected device, whether a
    /// refreshed list still holds the selection, and whether a retry has something to open.
    package static func rowPosition(_ devices: [AndroidDevice], key: String) -> Int? {
        let rows = flags(devices, key: key, serial: nil)
        let position = rows.withUnsafeBufferPointer { list in
            slopdesk_android_sidebar_row_position(list.baseAddress, list.count)
        }
        guard position >= 0, devices.indices.contains(position) else { return nil }
        return position
    }

    /// The device named by `key`, or `nil`.
    package static func device(_ devices: [AndroidDevice], key: String) -> AndroidDevice? {
        rowPosition(devices, key: key).map { devices[$0] }
    }

    /// The launch has SURFACED: the booted serial folded into the row that was pressed.
    package static func bootIsVisible(_ devices: [AndroidDevice], key: String) -> Bool {
        let rows = flags(devices, key: key, serial: nil)
        return rows.withUnsafeBufferPointer { list in
            slopdesk_android_sidebar_boot_is_visible(list.baseAddress, list.count)
        }
    }

    /// The shutdown has LANDED: no row carries `serial` any more, under whatever key the dying
    /// emulator was listed.
    package static func shutdownIsVisible(_ devices: [AndroidDevice], serial: String) -> Bool {
        let rows = flags(devices, key: nil, serial: serial)
        return rows.withUnsafeBufferPointer { list in
            slopdesk_android_sidebar_shutdown_is_visible(list.baseAddress, list.count)
        }
    }

    /// One record per row, carrying only what the rules read: which rows the question is about, and
    /// which of them have surfaced a serial. The two comparisons are HERE because the strings are.
    private static func flags(
        _ devices: [AndroidDevice], key: String?, serial: String?,
    ) -> [SlopDeskAndroidSidebarRow] {
        devices.map { device in
            SlopDeskAndroidSidebarRow(
                matches_key: key != nil && device.key == key,
                matches_serial: serial != nil && device.serial == serial,
                has_serial: device.serial != nil,
            )
        }
    }

    // MARK: The console ring

    /// How many console rows to drop from the FRONT at `count`. `0` while it is under its cap.
    package static func logOverflow(_ count: Int) -> Int {
        slopdesk_android_sidebar_log_overflow(Swift.max(0, count))
    }

    // MARK: The stream

    /// Whether a session packet's geometry is worth writing to the panel's one size field.
    ///
    /// A degenerate size is never news, which is what keeps a second, plausible-looking writer from
    /// pairing every finger with a number the device discards.
    package static func streamSizeIsNews(current: CGSize?, incoming: CGSize) -> Bool {
        slopdesk_android_sidebar_stream_size_is_news(
            current != nil,
            Double(current?.width ?? 0), Double(current?.height ?? 0),
            Double(incoming.width), Double(incoming.height),
        )
    }

    /// Whether a wait for video still has patience left. `nil` is no campaign running, which is
    /// always within grace.
    package static func withinGrace(elapsed: Duration?) -> Bool {
        guard let elapsed else { return slopdesk_android_sidebar_within_grace(false, 0) }
        return slopdesk_android_sidebar_within_grace(true, milliseconds(elapsed))
    }

    /// One duration off a monotonic clock, in whole milliseconds, saturating rather than wrapping.
    ///
    /// A negative reading cannot come off `ContinuousClock` and clamps to zero rather than becoming
    /// an enormous unsigned number, which is the one way this could turn a fresh wait into an
    /// expired one.
    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        let seconds = UInt64(clamping: parts.seconds)
        let ceiling = UInt64.max / 1000
        guard seconds < ceiling else { return UInt64.max }
        let extra = UInt64(clamping: parts.attoseconds / 1_000_000_000_000_000)
        return seconds * 1000 + extra
    }

    // MARK: The words

    /// The failure sentence for `report`, with `name` folded in where it names a device.
    ///
    /// An empty name reads as the crate's anonymous subject rather than leaving a hole at the front
    /// of the sentence — which is the ordinary case here, since a report is often about a device the
    /// list has already dropped.
    package static func report(_ report: AndroidSidebarReport, name: String = "") -> String {
        devicePanelLend(name) { bytes, len in
            wsDelivered(capacity: 96) { out, cap in
                slopdesk_android_sidebar_report(report.ffiByte, bytes, len, out, cap)
            } ?? ""
        }
    }

    /// What `notice` says.
    package static func notice(_ notice: AndroidSidebarNotice) -> String {
        let field = notice.ffiField
        return notices.indices.contains(field) ? notices[field] : ""
    }

    /// Every confirmation, in the order `slopdesk_android_sidebar_notices` documents. Read ONCE —
    /// these five strings never change within a process.
    ///
    /// PADDED, never trusted: ``DevicePanelBlob/texts(_:)`` fills a short delivery with empties
    /// rather than shifting, so a crate and a face that disagree about the layout lose ONE word
    /// instead of wearing each other's from the gap onward.
    private static let notices: [String] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_android_sidebar_notices(out, cap) }
        return blob.texts(5)
    }()

    // MARK: The numbers

    /// A measure that counts things — the console's cap, the mirror's requested edge in pixels.
    package static func count(_ measure: AndroidSidebarMeasure) -> Int {
        Int(clamping: slopdesk_android_sidebar_measure(measure.ffiIndex))
    }

    /// A measure that is a length of TIME.
    package static func duration(_ measure: AndroidSidebarMeasure) -> Duration {
        .milliseconds(Int(clamping: slopdesk_android_sidebar_measure(measure.ffiIndex)))
    }
}
