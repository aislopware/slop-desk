// AndroidSidebarModelTests — the panel's MARSHALLING, plus the replay the video path turns on.
//
// Nothing here builds a socket or a display layer (hang-safety): the ensure loop's mapping and the
// frame sink are both value-shaped on purpose, and they are the two places a mistake is invisible
// until the panel is on a real host — a phase that renders the install hint for a host that merely
// has not finished starting, or a mirror that sits black because its keyframe arrived before the view
// did.
//
// The RULES are `slopdesk_devicepanel::android_sidebar`'s and are pinned there, exhaustively. What
// is pinned here is the half that cannot leave Swift: which of an `AndroidDevice`'s fields become
// the flags the rules read, which field of a positional table each word comes back in, and which
// index each of the eleven measures answers at. Those are the three ways a face can be wrong while
// every Rust test still passes.

#if os(macOS)
import CoreGraphics
import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskDevicePanels

@MainActor
final class AndroidSidebarPhaseTests: XCTestCase {
    /// Only a reached bridge has somewhere to dial, and the socket reads that address from the phase
    /// rather than from a second field that could disagree with it. The phase machine itself is
    /// `DevicePanelRulesTests` — it is the simulator panel's too.
    func testOnlyAReadyPhaseYieldsAnAddress() {
        XCTAssertNil(AndroidSidebarModel.address(of: .starting))
        XCTAssertNil(AndroidSidebarModel.address(of: .unavailable))
        let address = AndroidSidebarModel.address(of: .ready(host: "h", port: 1))
        XCTAssertEqual(address?.host, "h")
        XCTAssertEqual(address?.port, 1)
    }

    /// A row the way `adb devices -l` leaves one. `isRunning` — the flag the shared wait verdict
    /// reads, pinned by `AndroidDeviceTests` — is `serial != nil && state == "device"`, so `offline`
    /// is a boot in progress rather than a failure.
    private func device(state: String, serial: String? = "emulator-5554") -> AndroidDevice {
        AndroidDevice(
            key: "avd:Pixel_API36", name: "Pixel API36", serial: serial, avdName: "Pixel_API36",
            state: state, isEmulator: true,
        )
    }

    // MARK: The lifecycle spinner's hold

    /// What `pending` waits for after a play press. Both lifecycle verbs are fire-and-forget on the
    /// host (`emulator` is spawned; `adb emu kill` merely asks), so "the host accepted it" is not a
    /// state change — these two predicates are. A spinner that resolves any earlier re-arms the
    /// button mid-flight: a second boot press then hits the AVD lock, and a second stop press sits
    /// on a card that looks healthy and is not.
    ///
    /// The RULE is `slopdesk_devicepanel::android_sidebar`'s and is pinned there; what these two pin
    /// is the half that has to stay Swift — which of an `AndroidDevice`'s fields become the flags
    /// the rule reads. A face that matched on the wrong field would answer a plausible verdict about
    /// the wrong row.
    func testABootHoldsItsSpinnerUntilTheSerialFoldsIn() {
        let key = "avd:Pixel_API36"
        // Accepted but not yet surfaced: the AVD row still has no transport.
        XCTAssertFalse(
            AndroidSidebarRules.bootIsVisible([device(state: "offline", serial: nil)], key: key),
        )
        // A list glitch that drops the row entirely is still not visibility.
        XCTAssertFalse(AndroidSidebarRules.bootIsVisible([], key: key))
        // The fold: same row, now carrying the booted serial — state is irrelevant, `offline`
        // IS the boot in progress.
        XCTAssertTrue(
            AndroidSidebarRules.bootIsVisible([device(state: "offline")], key: key),
        )
        // A serial on somebody else's row is not this boot.
        XCTAssertFalse(AndroidSidebarRules.bootIsVisible([device(state: "device")], key: "avd:Other"))
    }

    func testAShutdownHoldsItsSpinnerUntilTheSerialIsGone() {
        let serial = "emulator-5554"
        // Still dying: the serial is listed, however the row is keyed and whatever adb calls it.
        XCTAssertFalse(
            AndroidSidebarRules.shutdownIsVisible([device(state: "offline")], serial: serial),
        )
        // Landed: the AVD row remains — merely no longer running — and that is the resolved state.
        XCTAssertTrue(
            AndroidSidebarRules.shutdownIsVisible(
                [device(state: "offline", serial: nil)], serial: serial,
            ),
        )
        XCTAssertTrue(AndroidSidebarRules.shutdownIsVisible([], serial: serial))
    }

    // MARK: The list lookup

    /// The one question four readers ask. It answers a POSITION, so a face that lost the mapping
    /// back would silently hand every reader the wrong row rather than none.
    func testTheLookupFindsTheNamedRowAndNothingElse() {
        let rows = [
            device(state: "device", serial: "emulator-5554"),
            AndroidDevice(
                key: "avd:Other", name: "Other", serial: nil, avdName: "Other",
                state: "offline", isEmulator: true,
            ),
        ]
        XCTAssertEqual(AndroidSidebarRules.rowPosition(rows, key: "avd:Other"), 1)
        XCTAssertEqual(AndroidSidebarRules.device(rows, key: "avd:Other")?.name, "Other")
        XCTAssertNil(AndroidSidebarRules.rowPosition(rows, key: "avd:Missing"))
        XCTAssertNil(AndroidSidebarRules.device([], key: "avd:Other"))
    }
}

// MARK: - The rest of the face

@MainActor
final class AndroidSidebarRulesTests: XCTestCase {
    /// The console keeps a bounded window, and the trim is a COUNT rather than a comparison spelled
    /// at the call site.
    func testTheConsoleTrimsOnlyWhatIsOverTheCap() {
        let cap = AndroidSidebarModel.logCapacity
        XCTAssertGreaterThan(cap, 0, "an index the build cannot name would answer 0")
        XCTAssertEqual(AndroidSidebarRules.logOverflow(0), 0)
        XCTAssertEqual(AndroidSidebarRules.logOverflow(cap), 0)
        XCTAssertEqual(AndroidSidebarRules.logOverflow(cap + 12), 12)
        XCTAssertEqual(AndroidSidebarRules.logOverflow(-5), 0, "a negative count cannot evict")
    }

    /// The one field every positional message on the wire is paired with. A second writer here is a
    /// mirror that silently stops responding to fingers, so a degenerate size must never be news.
    func testOnlyARealAndChangedStreamSizeIsNews() {
        XCTAssertTrue(
            AndroidSidebarRules.streamSizeIsNews(current: nil, incoming: CGSize(width: 1024, height: 2280)),
        )
        XCTAssertFalse(
            AndroidSidebarRules.streamSizeIsNews(
                current: CGSize(width: 1024, height: 2280),
                incoming: CGSize(width: 1024, height: 2280),
            ),
        )
        XCTAssertTrue(
            AndroidSidebarRules.streamSizeIsNews(
                current: CGSize(width: 1024, height: 2280),
                incoming: CGSize(width: 2280, height: 1024),
            ),
        )
        for degenerate in [CGSize(width: 0, height: 2280), CGSize(width: 1024, height: 0)] {
            XCTAssertFalse(AndroidSidebarRules.streamSizeIsNews(current: nil, incoming: degenerate))
        }
    }

    /// With no campaign running there is nothing to be out of patience with; a campaign past the
    /// grace window is over.
    func testPatienceRunsOutOnlyOnceACampaignHasStarted() {
        let grace = AndroidSidebarRules.duration(.deviceGrace)
        XCTAssertTrue(AndroidSidebarRules.withinGrace(elapsed: nil))
        XCTAssertTrue(AndroidSidebarRules.withinGrace(elapsed: .zero))
        XCTAssertTrue(AndroidSidebarRules.withinGrace(elapsed: grace - .milliseconds(1)))
        XCTAssertFalse(AndroidSidebarRules.withinGrace(elapsed: grace))
        XCTAssertTrue(
            AndroidSidebarRules.withinGrace(elapsed: .seconds(-1)),
            "a negative reading clamps to zero rather than becoming an enormous unsigned number",
        )
    }

    /// Every sentence crosses whole, and the three that name a device fall back to the crate's
    /// anonymous subject rather than leaving a hole at the front.
    func testEveryReportCrossesAndNamesSomething() {
        let named: [AndroidSidebarReport] = [
            .bootNeverSurfaced, .shutdownNeverLanded, .noLongerRunning, .neverFinishedStarting,
        ]
        for report in named {
            XCTAssertTrue(AndroidSidebarRules.report(report, name: "Pixel 8").contains("Pixel 8"))
            XCTAssertTrue(AndroidSidebarRules.report(report).hasPrefix("This device"))
        }
        XCTAssertEqual(
            AndroidSidebarRules.report(.noVideo),
            "The device is running, but no video has arrived.",
        )
        XCTAssertEqual(
            AndroidSidebarRules.report(.screenshotUnreadable),
            "The screenshot could not be read.",
        )
    }

    /// The notices table is positional, so a field-order disagreement would dress every notice after
    /// the gap in its neighbour's words. Reading all five apart is what catches that.
    func testEveryNoticeCrossesInItsOwnField() {
        let table: [AndroidSidebarNotice: String] = [
            .screenOn: "Device screen on",
            .screenOff: "Device screen off",
            .pasted: "Pasted to device",
            .copied: "Copied to device",
            .screenshotCopied: "Screenshot copied",
        ]
        for (notice, words) in table {
            XCTAssertEqual(AndroidSidebarRules.notice(notice), words)
        }
    }

    /// Eleven numbers, one family. Zero is the family's refusal, so a member reading zero means the
    /// face and the crate disagree about the index — which is exactly the failure a shared index
    /// table can have and nothing else can catch.
    func testEveryMeasureIsReachableAtItsOwnIndex() {
        let counts: [AndroidSidebarMeasure] = [.logCapacity, .streamMaxSize]
        for measure in counts {
            XCTAssertGreaterThan(AndroidSidebarRules.count(measure), 0, "\(measure)")
        }
        let clocks: [AndroidSidebarMeasure] = [
            .firstFrameDeadline, .deviceGrace, .reattemptPause, .bootVisibleDeadline,
            .shutdownVisibleDeadline, .noticeLifetime, .ensurePoll, .deviceWatch, .pendingHold,
        ]
        for measure in clocks {
            XCTAssertGreaterThan(AndroidSidebarRules.duration(measure), .zero, "\(measure)")
        }
        // The two the model publishes under its own names read the same numbers.
        XCTAssertEqual(AndroidSidebarModel.logCapacity, AndroidSidebarRules.count(.logCapacity))
        XCTAssertEqual(AndroidSidebarModel.streamMaxSize, AndroidSidebarRules.count(.streamMaxSize))
        XCTAssertEqual(
            AndroidSidebarModel.firstFrameDeadline,
            AndroidSidebarRules.duration(.firstFrameDeadline),
        )
    }

    /// The sweep's own predicate, which is the device-flags bitfield's fourth flag rather than two
    /// of them read apart.
    func testOnlyRunningEmulatorsMayBeSwept() {
        let runningEmulator = AndroidDevice(
            key: "avd:A", name: "A", serial: "emulator-5554", avdName: "A",
            state: "device", isEmulator: true,
        )
        let phone = AndroidDevice(
            key: "SER123", name: "Phone", serial: "SER123", avdName: nil,
            state: "device", isEmulator: false,
        )
        let stoppedAVD = AndroidDevice(
            key: "avd:B", name: "B", serial: nil, avdName: "B", state: "offline", isEmulator: true,
        )
        let swept = AndroidPresentation.stoppable(in: [runningEmulator, phone, stoppedAVD])
        XCTAssertEqual(
            swept.map(\.key), ["avd:A"],
            "a physical phone and a stopped AVD are both outside the sweep",
        )
    }
}

// MARK: - The video path

@MainActor
final class AndroidFrameSinkTests: XCTestCase {
    /// A renderer that records rather than decodes. No `VTDecompressionSession`, no display layer.
    private final class Recorder: AndroidFrameRenderer {
        var applied: [[Data]] = []
        var enqueued: [(Data, Bool)] = []
        var resets = 0

        func apply(parameterSets: [Data], codec _: AndroidVideoCodec) { applied.append(parameterSets) }
        func enqueue(accessUnit: Data, isKeyframe: Bool) { enqueued.append((accessUnit, isKeyframe)) }
        func reset() { resets += 1 }
    }

    func testAViewThatMountsLateStillGetsAPicture() {
        // The reason the sink exists. `scrcpy` sends its parameter sets and ONE keyframe at the head
        // of the stream and then, on a quiet screen, nothing at all — measured idle floor 547 B/s
        // with a single keyframe for a whole session. Without the replay the panel sits black until
        // the user happens to touch something.
        let sink = AndroidFrameSink()
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.deliver(accessUnit: Data([0x41]), isKeyframe: false)

        let recorder = Recorder()
        sink.attach(recorder)
        XCTAssertEqual(recorder.applied, [[Data([0x67])]])
        // The keyframe and only the keyframe: a delta frame replayed against a decoder that never
        // saw its reference is noise.
        XCTAssertEqual(recorder.enqueued.count, 1)
        XCTAssertEqual(recorder.enqueued.first?.0, Data([0x65]))
    }

    func testNewParameterSetsInvalidateTheHeldKeyframe() {
        // It was encoded against the old ones — replaying it after a rotation would hand the decoder
        // a frame its format description cannot describe.
        let sink = AndroidFrameSink()
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.deliver(parameterSets: [Data([0x67, 0x01])], codec: .h264)

        let recorder = Recorder()
        sink.attach(recorder)
        XCTAssertEqual(recorder.applied, [[Data([0x67, 0x01])]])
        XCTAssertTrue(recorder.enqueued.isEmpty)
    }

    func testAMountedViewIsFedDirectly() {
        let sink = AndroidFrameSink()
        let recorder = Recorder()
        sink.attach(recorder)
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x41]), isKeyframe: false)
        XCTAssertEqual(recorder.applied.count, 1)
        XCTAssertEqual(recorder.enqueued.count, 1)
        XCTAssertEqual(recorder.enqueued.first?.1, false)
    }

    func testAResetFlushesTheSurfaceThatStaysMounted() {
        // A disconnect or a retry: the same view is still on screen and has to be blanked.
        let sink = AndroidFrameSink()
        let recorder = Recorder()
        sink.attach(recorder)
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.reset()
        XCTAssertEqual(recorder.resets, 1)

        let next = Recorder()
        sink.attach(next)
        XCTAssertTrue(next.applied.isEmpty)
        XCTAssertTrue(next.enqueued.isEmpty)
    }

    func testADeviceSwitchForgetsWithoutBlankingTheOutgoingView() {
        // The outgoing view lives on for the length of the navigation transition, and flushing its
        // layer would spend that transition fading out a device with its screen switched off. That
        // trap cost the simulator panel a debugging round.
        let sink = AndroidFrameSink()
        let recorder = Recorder()
        sink.attach(recorder)
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.discard()
        XCTAssertEqual(recorder.resets, 0)

        let next = Recorder()
        sink.attach(next)
        XCTAssertTrue(next.applied.isEmpty)
    }
}
#endif
