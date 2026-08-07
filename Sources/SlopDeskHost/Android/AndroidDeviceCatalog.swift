// AndroidDeviceCatalog — the PURE parsers behind the Android panel's device list.
//
// Everything in this file is a function from captured tool output to a value. Nothing spawns a
// process, so the whole catalogue is unit-testable against recorded `adb`/`emulator` output — which
// matters more here than usual, because these formats are conventions rather than contracts and the
// only way to notice one has moved is a fixture that stops matching.
//
// ## The one fact Android has that iOS does not
//
// `docs/47` records that for a SHUT-DOWN iOS simulator the server knows exactly four things
// (name, runtime, state, udid) and that `definition.json`'s geometry is chrome data which silently
// falls back to a near model — measured wrong for four of eleven devices. Android is the opposite
// case, and the panel is designed around the difference: an AVD that has never been booted still has
// an exact `config.ini` carrying `hw.lcd.width`, `hw.lcd.height`, `hw.lcd.density`, its device
// profile, its ABI and its API level. Those are the AVD's DEFINITION, not a lookup against a table
// of lookalikes, so a row for a shut-down Android device can carry real figures where the iOS row
// could only carry a name.
//
// ## Naming
//
// An emulator's `ro.product.model` is `sdk_gphone64_arm64` for every AVD on the host, so it cannot
// name a row. The AVD name can, and it is what the user typed when they created it. A physical
// device has no AVD name and its `ro.product.model` is exactly right ("Pixel 7 Pro"). So the
// headline is per-kind, and ``AndroidDevice/displayName`` is where that choice lives.

import Foundation

/// One device the panel can list — a running `adb` target, an AVD that is not booted, or an AVD that
/// is booted (in which case the two records are FOLDED into one carrying both halves).
struct AndroidDevice: Equatable, Sendable {
    /// The `adb` transport id (`emulator-5554`, `39121FDJH000TR`). `nil` for an AVD that is not
    /// running — it has no transport until it boots.
    var serial: String?
    /// The AVD's id (`Pixel_API36`). `nil` for a physical device.
    var avdName: String?
    /// `adb`'s own word: `device`, `offline`, `unauthorized`, `booting`… Kept as the RAW string for
    /// the reason `docs/47` gives for simulator state — `adb` has more states than the ones seen
    /// here, and a closed enum turns a transient one into a decode failure for the whole list.
    var state: String
    var manufacturer: String?
    /// `ro.product.model` for a physical device; the AVD's device profile otherwise.
    var model: String?
    /// The Android version as a marketing string ("16").
    var release: String?
    /// The API level (36). Named `apiLevel` rather than `sdk` because `sdk` reads like a path.
    var apiLevel: Int?
    var abi: String?
    /// Display metrics. For a running device these are MEASURED (`wm size`/`wm density`); for a
    /// shut-down AVD they are its declared `hw.lcd.*`. Both are exact — see the file comment.
    var width: Int?
    var height: Int?
    var density: Int?
    /// The form-factor hint, kept as the platform's RAW word: `ro.build.characteristics` for a
    /// running device (`emulator,nosdcard`, `tablet`, `tv`, `watch`, `automotive`), `tag.id` for an
    /// AVD on disk (`google_apis`, `android-tv`, `android-wear`, `android-automotive`). It is passed
    /// through rather than resolved here because the panel is where a hint becomes a glyph — the
    /// same split the simulator panel makes with ``SimulatorDeviceKind``.
    var formFactor: String?

    var isRunning: Bool { serial != nil && state == "device" }
    var isEmulator: Bool { avdName != nil }

    /// What the row is titled. An AVD is titled by the name the user gave it, with the underscores
    /// that `avdmanager` forces in it spelled back out as spaces; a physical device by its model.
    var displayName: String {
        if let avdName { return avdName.replacingOccurrences(of: "_", with: " ") }
        if let model, !model.isEmpty { return model }
        return serial ?? "Android device"
    }

    /// The key the panel selects on. An AVD keeps ONE identity across a boot — its name — so that a
    /// device the user opened stays selected when it acquires a serial. A physical device has only
    /// its serial.
    var key: String { avdName.map { "avd:" + $0 } ?? "serial:" + (serial ?? "?") }
}

enum AndroidDeviceCatalog {
    // MARK: - `adb devices -l`

    /// One line of `adb devices -l`, minus the header and the blank lines.
    ///
    /// ```
    /// List of devices attached
    /// emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 …
    /// 39121FDJH000TR         unauthorized
    /// ```
    ///
    /// The qualifiers after the state are deliberately ignored: `model:` there is the same
    /// `sdk_gphone64_arm64` that cannot name an emulator row, and the properties read separately are
    /// both richer and the same round trip.
    static func parseDevices(_ output: String) -> [(serial: String, state: String)] {
        var devices: [(serial: String, state: String)] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else {
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            devices.append((String(fields[0]), String(fields[1])))
        }
        return devices
    }

    // MARK: - `adb shell getprop`

    /// The whole `getprop` dump as a bag. Lines are `[key]: [value]`; anything else is skipped
    /// rather than treated as an error, because `getprop` interleaves warnings on some builds.
    ///
    /// One dump instead of one `getprop <key>` per field: eight round trips over `adb` cost eight
    /// process spawns and eight USB/loopback exchanges, and this panel polls.
    static func parseProperties(_ output: String) -> [String: String] {
        var properties: [String: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let separator = line.range(of: "]: ["), line.hasSuffix("]")
            else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            let value = String(line[separator.upperBound..<line.index(before: line.endIndex)])
            guard !key.isEmpty else { continue }
            properties[key] = value
        }
        return properties
    }

    /// `Physical size: 1080x2400` — and `Override size: …` when the user has resized the display,
    /// which WINS, because the override is what is actually being rendered and therefore what the
    /// stream will carry.
    static func parseDisplaySize(_ output: String) -> (width: Int, height: Int)? {
        var result: (width: Int, height: Int)?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0 else { continue }
            if line.hasPrefix("Physical size"), result == nil {
                result = (width, height)
            } else if line.hasPrefix("Override size") {
                return (width, height)
            }
        }
        return result
    }

    /// `Physical density: 420`, with `Override density:` winning for the same reason.
    static func parseDensity(_ output: String) -> Int? {
        var result: Int?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let density = Int(value), density > 0 else { continue }
            if line.hasPrefix("Physical density"), result == nil {
                result = density
            } else if line.hasPrefix("Override density") {
                return density
            }
        }
        return result
    }

    /// Fold a running target's properties into a device record.
    static func device(
        serial: String, state: String, properties: [String: String],
        size: (width: Int, height: Int)?, density: Int?,
    ) -> AndroidDevice {
        // `ro.boot.qemu.avd_name` is what maps a bare `emulator-5554` back to the AVD the user
        // knows; `ro.kernel.qemu` alone would say "an emulator" without saying WHICH.
        let avdName = properties["ro.boot.qemu.avd_name"]
            ?? properties["ro.kernel.qemu.avd_name"]
        return AndroidDevice(
            serial: serial,
            avdName: avdName.flatMap { $0.isEmpty ? nil : $0 },
            state: state,
            manufacturer: properties["ro.product.manufacturer"],
            model: properties["ro.product.model"],
            release: properties["ro.build.version.release"],
            apiLevel: properties["ro.build.version.sdk"].flatMap(Int.init),
            abi: properties["ro.product.cpu.abi"],
            width: size?.width,
            height: size?.height,
            density: density,
            formFactor: properties["ro.build.characteristics"],
        )
    }

    // MARK: - AVDs on disk

    /// `emulator -list-avds` — one bare name per line. The binary prints unrelated warnings to the
    /// same stream on some hosts, so a line is taken only when a matching `.ini` exists beside it.
    static func parseAVDNames(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") && !$0.hasPrefix("[") }
    }

    /// An AVD's `config.ini`: plain `key=value`, no sections, no quoting.
    static func parseConfig(_ output: String) -> [String: String] {
        var config: [String: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            config[key] = value
        }
        return config
    }

    /// The record for an AVD that is not running, built from its `config.ini` alone.
    static func device(avdName: String, config: [String: String]) -> AndroidDevice {
        AndroidDevice(
            serial: nil,
            avdName: avdName,
            state: "offline",
            manufacturer: config["hw.device.manufacturer"],
            // `hw.device.name` is a profile id (`pixel_7`), so it is spelled out the same way the
            // AVD name is — the row shows "pixel 7" as a fact under a title of "Pixel API36".
            model: config["hw.device.name"]?.replacingOccurrences(of: "_", with: " "),
            release: nil,
            apiLevel: apiLevel(fromSystemImageDirectory: config["image.sysdir.1"]),
            abi: config["abi.type"],
            width: config["hw.lcd.width"].flatMap(Int.init),
            height: config["hw.lcd.height"].flatMap(Int.init),
            density: config["hw.lcd.density"].flatMap(Int.init),
            formFactor: config["tag.id"],
        )
    }

    /// The `avd name` console reply → the AVD's name, or `nil`.
    ///
    /// This is how a BOOTING emulator gets its name: `adbd` inside the guest answers no shell until
    /// well into the boot (measured 2026-08-07: ~21 s of `offline` on a cold start), but the QEMU
    /// console on the host side is up from process launch. The reply is the name on its own line
    /// followed by a bare `OK`; anything refused says `KO: …`.
    static func parseConsoleAVDName(_ reply: String?) -> String? {
        guard let reply else { return nil }
        // The console speaks CRLF, and Swift reads "\r\n" as ONE grapheme — a split on the Character
        // "\n" finds nothing to cut. `isNewline` matches the CRLF cluster as well as a bare newline.
        for rawLine in reply.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line == "OK" { continue }
            if line.hasPrefix("KO") { return nil }
            // An AVD name never contains whitespace (`avdmanager` refuses it); a line with any is
            // console chatter, not a name.
            guard !line.contains(where: \.isWhitespace) else { continue }
            return line
        }
        return nil
    }

    /// `system-images/android-36/google_apis/arm64-v8a/` → `36`.
    ///
    /// The system-image path is the only place a non-running AVD records its API level —
    /// `config.ini` has no `ro.build.version.sdk` because nothing has booted to produce one. A
    /// preview release names its directory after a letter (`android-Baklava`), which yields `nil`
    /// rather than a wrong number.
    static func apiLevel(fromSystemImageDirectory directory: String?) -> Int? {
        guard let directory else { return nil }
        for component in directory.split(separator: "/") where component.hasPrefix("android-") {
            return Int(component.dropFirst("android-".count))
        }
        return nil
    }

    // MARK: - Merge

    /// The list the panel draws: every running target, plus every AVD on disk that is not among
    /// them.
    ///
    /// A booted AVD appears ONCE, as its running record — that record has measured display metrics
    /// and a live state, which strictly dominate the declared ones. The `config.ini` fallback fills
    /// only the fields a running device does not report, which in practice is nothing; it is written
    /// as a merge anyway so that a device whose `getprop` timed out still shows its declared size
    /// instead of an empty row.
    static func merge(running: [AndroidDevice], avds: [AndroidDevice]) -> [AndroidDevice] {
        let declared = Dictionary(
            avds.compactMap { avd in avd.avdName.map { ($0, avd) } },
            uniquingKeysWith: { first, _ in first },
        )
        var devices = running.compactMap { device -> AndroidDevice? in
            if let name = device.avdName {
                return declared[name].map { filling(device, from: $0) } ?? device
            }
            // An emulator serial that cannot yet say WHICH AVD it is: for the first beat of a boot
            // the serial registers with `adb` before the QEMU console accepts, so the name lookup
            // comes back empty. Without a name the row has no `isEmulator`, no identity and no AVD
            // to fold into — it would render as a physical phone that is "Not responding" for a
            // second or two. Hold it back; the next poll names it. (The cost: an emulator whose
            // console never answers stays hidden while offline — a row that would have been an
            // unusable stranger anyway.)
            if device.state != "device", device.serial?.hasPrefix("emulator-") == true {
                return nil
            }
            return device
        }
        let bootedNames = Set(running.compactMap(\.avdName))
        for avd in avds where !bootedNames.contains(avd.avdName ?? "") {
            devices.append(avd)
        }
        return devices
    }

    /// A running record with its gaps filled from the AVD's declared definition. Live facts win —
    /// only the fields the probe could not produce fall back, which is the whole list for a device
    /// still booting: it answers no shell, but its `config.ini` was exact before it ever booted.
    static func filling(_ device: AndroidDevice, from avd: AndroidDevice) -> AndroidDevice {
        var filled = device
        filled.manufacturer = device.manufacturer ?? avd.manufacturer
        filled.model = device.model ?? avd.model
        filled.release = device.release ?? avd.release
        filled.apiLevel = device.apiLevel ?? avd.apiLevel
        filled.abi = device.abi ?? avd.abi
        filled.width = device.width ?? avd.width
        filled.height = device.height ?? avd.height
        filled.density = device.density ?? avd.density
        filled.formFactor = device.formFactor ?? avd.formFactor
        return filled
    }
}
