// Fixtures are REAL output, captured 2026-08-04 from `adb` 1.0.41 / emulator 36 against a booted
// `Pixel_API36` AVD on mac-studio. These formats are conventions rather than contracts, and a
// recorded fixture that stops matching is the only warning we get that one has moved.

import XCTest
@testable import SlopDeskHost

final class AndroidDeviceCatalogTests: XCTestCase {
    // MARK: - `adb devices -l`

    func testParsesDevicesAndSkipsTheHeader() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a
        39121FDJH000TR         unauthorized

        """
        let devices = AndroidDeviceCatalog.parseDevices(output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "emulator-5554")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertEqual(devices[1].state, "unauthorized")
    }

    /// `adb` prefixes daemon chatter with `*`, and it arrives interleaved with the list.
    func testSkipsDaemonChatter() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5554	device
        """
        XCTAssertEqual(AndroidDeviceCatalog.parseDevices(output).map(\.serial), ["emulator-5554"])
    }

    // MARK: - `getprop`

    func testParsesPropertyDump() {
        let output = """
        [ro.product.model]: [sdk_gphone64_arm64]
        [ro.product.manufacturer]: [Google]
        [ro.build.version.sdk]: [36]
        [ro.boot.qemu.avd_name]: [Pixel_API36]
        [persist.sys.locale]: []
        garbage line without brackets
        """
        let properties = AndroidDeviceCatalog.parseProperties(output)
        XCTAssertEqual(properties["ro.product.model"], "sdk_gphone64_arm64")
        XCTAssertEqual(properties["ro.boot.qemu.avd_name"], "Pixel_API36")
        // An empty value is a real value, not an absent key — a device with no locale set must not
        // read as a device whose property dump was truncated.
        XCTAssertEqual(properties["persist.sys.locale"], "")
        XCTAssertNil(properties["garbage line without brackets"])
    }

    // MARK: - `wm size` / `wm density`

    func testReadsPhysicalDisplayMetrics() {
        XCTAssertEqual(
            AndroidDeviceCatalog.parseDisplaySize("Physical size: 1080x2400").map { [$0.width, $0.height] },
            [1080, 2400],
        )
        XCTAssertEqual(AndroidDeviceCatalog.parseDensity("Physical density: 420"), 420)
    }

    /// An override is what is actually being rendered, so it is what the stream will carry.
    func testOverrideBeatsPhysical() {
        let size = """
        Physical size: 1080x2400
        Override size: 720x1600
        """
        XCTAssertEqual(
            AndroidDeviceCatalog.parseDisplaySize(size).map { [$0.width, $0.height] }, [720, 1600],
        )
        let density = """
        Physical density: 420
        Override density: 320
        """
        XCTAssertEqual(AndroidDeviceCatalog.parseDensity(density), 320)
    }

    // MARK: - AVDs on disk

    /// The exact `config.ini` of this host's `Pixel_API36`, trimmed to the keys that are read.
    func testBuildsAShutDownDeviceFromItsConfig() {
        let config = AndroidDeviceCatalog.parseConfig("""
        abi.type=arm64-v8a
        hw.device.manufacturer=Google
        hw.device.name=pixel_7
        hw.lcd.density=420
        hw.lcd.height=2400
        hw.lcd.width=1080
        image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/
        """)
        let device = AndroidDeviceCatalog.device(avdName: "Pixel_API36", config: config)

        // This is the fact the iOS panel could not have: an AVD that has never booted still knows
        // its exact screen. `docs/47` records the opposite for CoreSimulator, where `definition.json`
        // falls back to a near model and was measured wrong for four devices of eleven.
        XCTAssertEqual(device.width, 1080)
        XCTAssertEqual(device.height, 2400)
        XCTAssertEqual(device.density, 420)
        XCTAssertEqual(device.abi, "arm64-v8a")
        XCTAssertEqual(device.apiLevel, 36)
        XCTAssertEqual(device.model, "pixel 7")
        XCTAssertFalse(device.isRunning)
        XCTAssertTrue(device.isEmulator)
    }

    /// The system-image path is the ONLY place a non-running AVD records its API level.
    func testAPILevelComesFromTheSystemImagePath() {
        XCTAssertEqual(
            AndroidDeviceCatalog.apiLevel(fromSystemImageDirectory: "system-images/android-36/google_apis/arm64-v8a/"),
            36,
        )
        // A preview release names its directory after a letter. `nil` beats a wrong number.
        XCTAssertNil(
            AndroidDeviceCatalog
                .apiLevel(fromSystemImageDirectory: "system-images/android-Baklava/google_apis/arm64-v8a/"),
        )
        XCTAssertNil(AndroidDeviceCatalog.apiLevel(fromSystemImageDirectory: nil))
    }

    func testParsesAVDNamesAndRejectsWarnings() {
        let output = """
        INFO    | Storing crashdata in: /tmp/foo
        Pixel_API36
        Tablet_API34
        """
        XCTAssertEqual(AndroidDeviceCatalog.parseAVDNames(output), ["Pixel_API36", "Tablet_API34"])
    }

    // MARK: - Naming

    /// An emulator's `ro.product.model` is `sdk_gphone64_arm64` for EVERY AVD on the host, so it
    /// cannot title a row; the AVD name can, and it is what the user typed.
    func testEmulatorIsTitledByItsAVDNotItsModel() {
        let device = AndroidDeviceCatalog.device(
            serial: "emulator-5554", state: "device",
            properties: [
                "ro.product.model": "sdk_gphone64_arm64",
                "ro.boot.qemu.avd_name": "Pixel_API36",
            ],
            size: (1080, 2400), density: 420,
        )
        XCTAssertEqual(device.displayName, "Pixel API36")
        XCTAssertTrue(device.isEmulator)
    }

    /// A physical device has no AVD name and its model is exactly right.
    func testPhysicalDeviceIsTitledByItsModel() {
        let device = AndroidDeviceCatalog.device(
            serial: "39121FDJH000TR", state: "device",
            properties: ["ro.product.model": "Pixel 7 Pro"], size: nil, density: nil,
        )
        XCTAssertEqual(device.displayName, "Pixel 7 Pro")
        XCTAssertFalse(device.isEmulator)
        XCTAssertEqual(device.key, "serial:39121FDJH000TR")
    }

    // MARK: - Merge

    /// A booted AVD appears ONCE, as its running record — the one with measured metrics and a live
    /// state. Listing it twice is the bug this covers.
    func testABootedAVDDoesNotAlsoAppearAsAvailable() {
        let running = AndroidDeviceCatalog.device(
            serial: "emulator-5554", state: "device",
            properties: ["ro.boot.qemu.avd_name": "Pixel_API36"], size: (1080, 2400), density: 420,
        )
        let onDisk = [
            AndroidDeviceCatalog.device(avdName: "Pixel_API36", config: ["hw.lcd.width": "1080"]),
            AndroidDeviceCatalog.device(avdName: "Tablet_API34", config: ["hw.lcd.width": "1600"]),
        ]
        let merged = AndroidDeviceCatalog.merge(running: [running], avds: onDisk)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.filter { $0.avdName == "Pixel_API36" }.count, 1)
        XCTAssertTrue(merged[0].isRunning)
        XCTAssertFalse(merged[1].isRunning)
    }

    /// An AVD keeps ONE identity across a boot, so a device the user opened stays selected when it
    /// acquires a serial.
    func testAVDKeyIsStableAcrossABoot() {
        let off = AndroidDeviceCatalog.device(avdName: "Pixel_API36", config: [:])
        let on = AndroidDeviceCatalog.device(
            serial: "emulator-5554", state: "device",
            properties: ["ro.boot.qemu.avd_name": "Pixel_API36"], size: nil, density: nil,
        )
        XCTAssertEqual(off.key, on.key)
    }

    // MARK: - Request decoding

    func testBridgeRequestRejectsMalformedInput() {
        XCTAssertNil(AndroidBridgeRequest.decode(Data("not json".utf8)))
        XCTAssertNil(AndroidBridgeRequest.decode(Data(#"{"noop":1}"#.utf8)))
        XCTAssertNil(AndroidBridgeRequest.decode(Data(#"{"op":""}"#.utf8)))
        XCTAssertNil(AndroidBridgeRequest.decode(Data()))

        let request = AndroidBridgeRequest.decode(Data(#"{"op":"open","serial":"x","maxSize":1024}"#.utf8))
        XCTAssertEqual(request?.op, "open")
        XCTAssertEqual(request?.string("serial"), "x")
        XCTAssertEqual(request?.int("maxSize"), 1024)
        XCTAssertNil(request?.string("missing"))
    }

    // MARK: - Emulator console

    func testConsolePortIsCarriedByTheSerial() {
        XCTAssertEqual(AndroidEmulatorConsole.port(forSerial: "emulator-5554"), 5554)
        XCTAssertEqual(AndroidEmulatorConsole.port(forSerial: "emulator-5556"), 5556)
        // A physical device has no console — the panel offers its verbs on emulator rows alone.
        XCTAssertNil(AndroidEmulatorConsole.port(forSerial: "39121FDJH000TR"))
    }

    // MARK: - scrcpy launch

    /// `clipboard_autosync=false` is what makes the control socket strictly client→device, which is
    /// what lets the bridge put video down and control up on ONE connection. Turning it back on
    /// would let the device write a clipboard message into a stream the client parses as H.264.
    func testLaunchDisablesClipboardAutosync() {
        let arguments = AndroidScrcpySession.serverArguments(
            scid: "0badf00d", options: AndroidScrcpySession.Options(),
        )
        XCTAssertTrue(arguments.contains("clipboard_autosync=false"))
        XCTAssertTrue(arguments.contains("tunnel_forward=true"))
        XCTAssertTrue(arguments.contains("audio=false"))
        XCTAssertTrue(arguments.contains("scid=0badf00d"))
    }

    /// H.264 by default even though the server offers H.265 and AV1: measured on this host's
    /// emulator, H.265 at the same size ran at 11.3 fps against H.264's 25.3, because every encoder
    /// an emulator exposes is a SOFTWARE one.
    func testDefaultCodecIsH264() {
        XCTAssertEqual(AndroidScrcpySession.Options().codec, "h264")
        XCTAssertTrue(AndroidScrcpySession.serverArguments(
            scid: "x", options: AndroidScrcpySession.Options(),
        ).contains("video_codec=h264"))
    }

    /// logcat's filter spec reaches an argument vector, so the level is a closed set.
    func testLogcatLevelsAreClosed() {
        XCTAssertTrue(AndroidBridgeServer.logcatLevels.contains("E"))
        XCTAssertFalse(AndroidBridgeServer.logcatLevels.contains("*:E; rm -rf /"))
    }
}
