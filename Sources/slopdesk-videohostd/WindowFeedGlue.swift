// The host-window FEED glue (docs/45 rail): answers `windowFeedSubscribe` from a 1 s-TTL snapshot
// cache. Enumeration is `CGWindowListCopyWindowInfo` (~2.5 ms) — NEVER `SCShareableContent` (that
// stays hello/mint-only; it costs a replayd round-trip). All pure logic (inclusion, flags, caps,
// generation, packing) lives in `SlopDeskVideoHost/WindowFeed` and is headless-tested; this file is
// only the AppKit/CoreGraphics reads + the send/retire choreography.

import Foundation

#if os(macOS)
import AppKit
import CoreGraphics
import SlopDeskVideoHost
import SlopDeskVideoProtocol

/// Enumerates the host's app windows into the pure feed input shape. `@MainActor`: the AppKit reads
/// (`NSWorkspace.frontmostApplication`, `NSRunningApplication`) belong there, and one ≤ 2.5 ms
/// CGWindowList call per cache-TTL on the daemon's otherwise-idle main queue is far below any
/// budget that matters (the transport receive queue and input path are NEVER touched).
@MainActor
func enumerateHostWindows() -> [WindowFeedSourceWindow] {
    guard let info = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements], kCGNullWindowID,
    ) as? [[String: Any]] else { return [] }

    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    // Display ordinals: CGDisplayBounds is in the SAME CG global top-left space as kCGWindowBounds,
    // so max-intersection is a plain rect test (NSScreen.frame would need a y-flip — see the
    // "NSScreen reports 1×" family of traps; stay in CG space).
    var displayCount: UInt32 = 0
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)
    let displayBounds = displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)

    // Per-PID AppKit reads cached within ONE enumeration (an app owns many windows).
    var appStates: [pid_t: (bundleID: String, isHidden: Bool)] = [:]
    func appState(for pid: pid_t) -> (bundleID: String, isHidden: Bool) {
        if let cached = appStates[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let state = (bundleID: app?.bundleIdentifier ?? "", isHidden: app?.isHidden ?? false)
        appStates[pid] = state
        return state
    }

    var onScreen: [WindowFeedSourceWindow] = []
    var offScreen: [WindowFeedSourceWindow] = []
    for dict in info {
        guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
              let number = dict[kCGWindowNumber as String] as? UInt32,
              let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { continue }
        let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
        let state = appState(for: pid)
        let display = displayBounds.enumerated().max(by: {
            $0.element.intersection(bounds).area < $1.element.intersection(bounds).area
        })?.offset ?? 0
        let window = WindowFeedSourceWindow(
            windowID: number,
            ownerName: dict[kCGWindowOwnerName as String] as? String ?? "",
            bundleID: state.bundleID,
            layer: layer,
            isOnScreen: isOnScreen,
            title: dict[kCGWindowName as String] as? String ?? "",
            widthPt: Int(bounds.width.rounded()),
            heightPt: Int(bounds.height.rounded()),
            displayIndex: UInt8(clamping: display),
            isAppHidden: state.isHidden,
            isFrontmostApp: pid == frontmostPID,
            // Phase-1 honesty: off-screen just means "minimized OR other Space OR hidden app" —
            // the AXMinimized disambiguation is the Phase-5 budgeted probe.
            isMinimized: false,
        )
        if isOnScreen { onScreen.append(window) } else { offScreen.append(window) }
    }
    // CGWindowList orders on-screen windows front-to-back; off-screen order is unspecified — keep
    // the z-ordered block first so the client's first seed (and the focused-window pick) is honest.
    return onScreen + offScreen
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Serializes feed answers over the ONE shared ``WindowFeedCache``: renewal retransmits, generation
/// re-requests, and multiple clients are all answered from the same encoded chunks — at most one
/// enumeration per TTL regardless of subscriber count (the enumeration-amplification guard).
actor WindowFeedResponder {
    private var cache = WindowFeedCache()

    /// Monotonic seconds (never wall clock — TTL must survive clock changes).
    private static func nowSeconds() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Answers one `windowFeedSubscribe` on `channelID`: rebuild-if-stale, then either the 5-byte
    /// `windowFeedCurrent` ack or the full chunk sequence dup-sent ×2 ~25 ms apart (the
    /// `bye`/`streamCadence` loss pattern). Retires the lane after the answer — the feed lane is
    /// pure request/reply in Phase 1 (the renewal re-bootstraps it, exactly like `listWindows`).
    func answer(
        channelID: UInt32,
        knownGeneration: UInt32,
        mux: NWVideoMuxDatagramTransport,
        answerGuard: ListAnswerGuard,
    ) async {
        defer { answerGuard.end(channelID) }
        let now = Self.nowSeconds()
        if cache.needsRebuild(now: now) {
            let source = await enumerateHostWindows()
            cache.fold(WindowFeedSnapshotBuilder.records(from: source), now: now)
        }
        let (isSnapshot, payloads) = cache.replyDatagrams(forKnownGeneration: knownGeneration)
        for payload in payloads {
            mux.send(payload, on: .control, channelID: channelID)
        }
        if isSnapshot {
            log(
                "answered windowFeedSubscribe on chan=\(channelID): gen=\(cache.generation) "
                    + "\(cache.records.count) windows in \(payloads.count) chunk(s)",
            )
            // Dup-send ×2: converts P(loss) → P(loss)² per chunk; the client's assembler is
            // idempotent per (generation, chunkIndex).
            try? await Task.sleep(for: .milliseconds(25))
            for payload in payloads {
                mux.send(payload, on: .control, channelID: channelID)
            }
        }
        mux.retire(channelID)
    }
}
#endif
