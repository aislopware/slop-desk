// AndroidDeviceTests — the bridge's `list` reply as the panel sees it, and how a device set is cut
// into sections.
//
// Two things here are Android-specific and are asserted as such. First, the figures on a SHUT-DOWN
// row are real: an AVD's `config.ini` is its definition, so width, height and density on a row that
// has never booted are exact — the inverse of the iOS case `docs/47` records, where a shut-down
// simulator's geometry comes from chrome data that is wrong for four devices in eleven. Second, the
// family hint is a comma-separated list whose commonest emulator value contains a word that a naive
// substring search misreads; that trap has its own test below.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskDevicePanels

final class AndroidDeviceTests: XCTestCase {
    private func listReply(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func device(
        key: String = "k", name: String = "Pixel 8", serial: String? = nil,
        state: String = "device", isEmulator: Bool = true, release: String? = "16",
        apiLevel: Int? = 36, width: Int? = 1080, height: Int? = 2400, density: Int? = 420,
        formFactor: String? = nil,
    ) -> AndroidDevice {
        AndroidDevice(
            key: key, name: name, serial: serial, avdName: nil, state: state,
            isEmulator: isEmulator, manufacturer: nil, model: nil, release: release,
            apiLevel: apiLevel, abi: nil, width: width, height: height, density: density,
            formFactor: formFactor,
        )
    }

    // MARK: Decoding

    func testAWellFormedReplyDecodesEveryField() {
        let data = listReply([
            "ok": true,
            "devices": [[
                "key": "emulator-5554", "name": "Pixel_8_API_36", "serial": "emulator-5554",
                "avd": "Pixel_8_API_36", "state": "device", "isEmulator": true,
                "manufacturer": "Google", "model": "sdk_gphone64_arm64", "release": "16",
                "api": 36, "abi": "arm64-v8a", "width": 1080, "height": 2400, "density": 420,
                "formFactor": "emulator,nosdcard",
            ]],
        ])
        let devices = try? XCTUnwrap(AndroidDevice.decodeList(data))
        XCTAssertEqual(devices?.count, 1)
        XCTAssertEqual(devices?.first?.serial, "emulator-5554")
        XCTAssertEqual(devices?.first?.apiLevel, 36)
        XCTAssertEqual(devices?.first?.width, 1080)
        XCTAssertTrue(devices?.first?.isRunning == true)
    }

    func testAFailedOrMalformedEnvelopeIsRefused() {
        XCTAssertNil(AndroidDevice.decodeList(listReply(["ok": false, "error": "no adb"])))
        XCTAssertNil(AndroidDevice.decodeList(listReply(["ok": true])))
        XCTAssertNil(AndroidDevice.decodeList(Data("not json".utf8)))
    }

    func testOneBadEntryCannotBlankThePanel() {
        // Validate then drop, per device: a host that renames a field still lists the rest.
        let data = listReply([
            "ok": true,
            "devices": [["name": "no key here"], ["key": "good"]],
        ])
        XCTAssertEqual(AndroidDevice.decodeList(data)?.map(\.key), ["good"])
    }

    func testEveryFieldButTheKeyDegrades() {
        let data = listReply(["ok": true, "devices": [["key": "bare"]]])
        let bare = try? XCTUnwrap(AndroidDevice.decodeList(data)?.first)
        XCTAssertEqual(bare?.name, "bare") // falls back to the key rather than to a blank row
        XCTAssertNil(bare?.serial)
        XCTAssertFalse(bare?.isRunning == true)
        XCTAssertNil(bare?.aspectRatio)
    }

    // MARK: State

    func testAnUnauthorizedDeviceIsAttachedButNotRunnable() {
        // It will refuse every shell, so it must not offer a mirror button that can only fail — but
        // it is attached, and it is the device most in need of being noticed.
        let waiting = device(serial: "R5CT", state: "unauthorized", isEmulator: false)
        XCTAssertFalse(waiting.isRunning)
        XCTAssertTrue(waiting.isAttachedButUnusable)
    }

    func testAShutDownAvdIsNeitherRunningNorUnusable() {
        let idle = device(serial: nil, state: "offline")
        XCTAssertFalse(idle.isRunning)
        XCTAssertFalse(idle.isAttachedButUnusable)
    }

    // MARK: What a row says

    func testTheSummaryIsAssembledFromWhatIsKnown() {
        XCTAssertEqual(device().summary, "Android 16 · 1080×2400")
        XCTAssertEqual(device(release: nil).summary, "API 36 · 1080×2400")
        XCTAssertEqual(device(release: nil, apiLevel: nil).summary, "1080×2400")
        XCTAssertEqual(
            device(release: nil, apiLevel: nil, width: nil, height: nil).summary, "",
        )
    }

    func testTheAspectRatioIsKnownEvenOnARowThatHasNeverBooted() {
        // The figure the running card draws its box from — Android reports it exactly, booted or not.
        XCTAssertEqual(device().aspectRatio ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertNil(device(width: 0, height: 0).aspectRatio)
    }
}

// MARK: - Family

final class AndroidDeviceKindTests: XCTestCase {
    func testTheCommonestEmulatorHintIsNotAnAutomotiveHeadUnit() {
        // THE trap: `ro.build.characteristics` is `emulator,nosdcard` on most emulators, and
        // `nosdcard` CONTAINS `car`. A substring search reads every phone AVD as a car.
        XCTAssertEqual(
            AndroidDeviceKind.infer(
                hint: "emulator,nosdcard", name: "Pixel_8", width: 1080, height: 2400, density: 420,
            ),
            .phone,
        )
    }

    func testTheHintIsBelievedWhenItIsDistinctive() {
        let cases: [(String, AndroidDeviceKind)] = [
            ("watch", .watch),
            ("nosdcard,watch", .watch),
            ("automotive", .automotive),
            ("tv", .tv),
            ("emulator,tablet", .tablet),
        ]
        for (hint, expected) in cases {
            XCTAssertEqual(
                AndroidDeviceKind.infer(
                    hint: hint, name: "Device", width: 1080, height: 2400, density: 420,
                ),
                expected,
                "hint \(hint)",
            )
        }
    }

    func testTheNameIsCheckedBeforeTheSize() {
        // A profile that says what it is beats a threshold: a `Pixel_Tablet` created at an unusual
        // density would otherwise be classified by arithmetic when it had already said.
        XCTAssertEqual(
            AndroidDeviceKind.infer(
                hint: "emulator", name: "Pixel_Tablet", width: 400, height: 800, density: 320,
            ),
            .tablet,
        )
    }

    func testAnEmulatorWithNoUsefulHintIsSortedByItsShortestWidth() {
        // `sw600dp` is Android's own line for a tablet layout, so this is the platform's threshold
        // rather than one invented here.
        XCTAssertEqual(
            AndroidDeviceKind.infer(
                hint: "emulator,nosdcard", name: "AVD", width: 1600, height: 2560, density: 320,
            ),
            .tablet, // 1600 × 160 / 320 = 800dp
        )
        XCTAssertEqual(
            AndroidDeviceKind.infer(
                hint: "emulator,nosdcard", name: "AVD", width: 1080, height: 2400, density: 440,
            ),
            .phone, // 392dp
        )
    }

    func testADeviceThatSaysNothingAtAllIsAPhone() {
        XCTAssertEqual(
            AndroidDeviceKind.infer(hint: nil, name: "", width: nil, height: nil, density: nil),
            .phone,
        )
        // A zero density crosses as a zero and comes back a phone, not a division by it. The dp
        // arithmetic itself is `slopdesk_devicepanel::android::shortest_width_dp` and is pinned
        // there; what this asserts is that an ABSENT measurement survives the boundary as absence.
        XCTAssertEqual(
            AndroidDeviceKind.infer(hint: nil, name: "", width: 100, height: 100, density: 0),
            .phone,
        )
    }

    func testTheGroupOrderDoesNotDependOnDeclarationOrder() {
        XCTAssertEqual(
            AndroidDeviceKind.allCases.sorted { $0.rank < $1.rank }.map(\.groupTitle),
            ["Phone", "Tablet", "Wear", "TV", "Automotive"],
        )
    }
}

// MARK: - Sections

final class AndroidDeviceListSectionTests: XCTestCase {
    private func device(
        _ key: String, serial: String? = nil, release: String? = "16", name: String = "Pixel",
        width: Int? = 1080, height: Int? = 2400, density: Int? = 420,
    ) -> AndroidDevice {
        AndroidDevice(
            key: key, name: name, serial: serial, avdName: nil,
            state: serial == nil ? "offline" : "device", isEmulator: true, manufacturer: nil,
            model: nil, release: release, apiLevel: nil, abi: nil, width: width, height: height,
            density: density, formFactor: "emulator,nosdcard",
        )
    }

    func testEverythingWithATransportGoesInTheTopGroup() {
        // Including a device that is `unauthorized`: burying it among the AVDs that are merely
        // switched off is where it would go to hide.
        var unauthorized = device("phone", serial: "R5CT")
        unauthorized.state = "unauthorized"
        let sections = AndroidDeviceSections.sections(for: [unauthorized, device("cold")])
        XCTAssertEqual(sections.first?.title, AndroidDeviceSections.runningTitle)
        XCTAssertEqual(sections.first?.devices.map(\.key), ["phone"])
        XCTAssertTrue(sections.first?.isRunning == true)
    }

    func testTheIdleDevicesAreCutByFamilyInRankOrder() {
        let sections = AndroidDeviceSections.sections(for: [
            device("tab", name: "AVD", width: 1600, height: 2560, density: 320),
            device("phone"),
        ])
        XCTAssertEqual(sections.map(\.title), ["Phone", "Tablet"])
    }

    func testAVersionEveryMemberSharesIsLiftedIntoTheHeading() {
        // A device set is usually a handful of AVDs on one system image, so the per-row version was
        // the same eight characters printed down the whole column.
        let sections = AndroidDeviceSections.sections(for: [device("a"), device("b")])
        XCTAssertEqual(sections.first?.version, "Android 16")
        XCTAssertFalse(sections.first?.showsVersion(device("a")) == true)
    }

    func testDisagreementLeavesTheVersionOnTheRows() {
        let sections = AndroidDeviceSections.sections(for: [device("a"), device("b", release: "15")])
        XCTAssertNil(sections.first?.version)
        XCTAssertTrue(sections.first?.showsVersion(device("a")) == true)
    }

    func testAnAbsentVersionIsNotLiftedAsIfItWereAFact() {
        // A heading reading `PHONE ·` would be the panel lifting the absence of a fact into the
        // place it prints facts.
        XCTAssertNil(AndroidDeviceSections.sharedVersion(of: [device("a", release: nil)]))
    }

    func testARowIdentityIsQualifiedByItsSection() {
        // The move a boot makes IS between sections, and a plain list of keys would not see it.
        let cold = AndroidDeviceSections.sections(for: [device("k")])
        let hot = AndroidDeviceSections.sections(for: [device("k", serial: "emulator-5554")])
        XCTAssertNotEqual(cold.first?.rowIdentities, hot.first?.rowIdentities)
    }

    func testAnEmptyDeviceSetHasNoSections() {
        XCTAssertTrue(AndroidDeviceSections.sections(for: []).isEmpty)
    }
}
#endif
