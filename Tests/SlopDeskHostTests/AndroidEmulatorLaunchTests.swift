// AndroidEmulatorLaunchTests — the flags a headless emulator is started with.
//
// One of them decides whether the panel is a mirror or a slideshow. `-no-window` makes the emulator's
// `auto` renderer resolve to a SOFTWARE one, and the difference is not marginal: measured 2026-08-04
// on the same AVD under the same drag, the software path renders 98.7% janky frames and reaches the
// client at 6.4 frames a second, against 58 and 2.6% on `-gpu host`. `docs/48-android-panel.md` has
// the table. Nothing about that is visible in code review, which is why it is asserted here.

import XCTest
@testable import SlopDeskHost

final class AndroidEmulatorLaunchTests: XCTestCase {
    func testAHeadlessEmulatorIsGivenTheHostsGPU() {
        let arguments = AndroidBridgeServer.emulatorArguments(avd: "Pixel_API36", extra: [])
        XCTAssertEqual(
            arguments, ["-avd", "Pixel_API36", "-no-window", "-no-boot-anim", "-gpu", "host"],
        )
    }

    func testAnOperatorsOwnGPUChoiceIsLeftAlone() {
        // The escape hatch for a host that cannot use its GPU. Ours is not appended alongside theirs:
        // two `-gpu` flags would leave the outcome to an argument-precedence rule nothing documents.
        let arguments = AndroidBridgeServer.emulatorArguments(
            avd: "Pixel_API36", extra: ["-gpu", "swiftshader_indirect"],
        )
        XCTAssertEqual(arguments.filter { $0 == "-gpu" }.count, 1)
        XCTAssertEqual(arguments.last, "swiftshader_indirect")
    }

    func testOtherExtraFlagsRideAlongsideTheGPUChoice() {
        let arguments = AndroidBridgeServer.emulatorArguments(
            avd: "Pixel_API36", extra: ["-no-audio", "-memory", "4096"],
        )
        XCTAssertEqual(arguments.firstIndex(of: "host").map { arguments[$0 - 1] }, "-gpu")
        XCTAssertEqual(arguments.suffix(3), ["-no-audio", "-memory", "4096"])
    }
}
