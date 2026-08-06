// VendoredToolsTests — the vendoring layer's two claims: hostd finds the checkout it was built
// into, and the pinned prefix outranks everything else a host might have installed.
//
// Every case builds its own directory tree in a temp dir and injects it. Nothing here reads the
// developer's real machine — a locator test that consults the real `PATH` passes or fails according
// to what the person running it happens to have installed, which is the opposite of a test.

import CryptoKit
import Foundation
import XCTest
@testable import SlopDeskHost

final class VendoredToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vendored-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Writes an executable file at `path` under the temp root and returns its absolute path.
    @discardableResult
    private func makeExecutable(_ path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - Repo-root resolution

    func testRepoRootIsFoundByWalkingUpFromTheBinary() throws {
        try makeExecutable("checkout/ThirdParty/tools/tools.lock")
        let hostd = try makeExecutable("checkout/.build/release/slopdesk-hostd")

        XCTAssertEqual(
            VendoredTools.repoRoot(startingAt: hostd),
            root.appendingPathComponent("checkout").path,
        )
    }

    /// SwiftPM does not always emit into `.build/release`: a cross-compile or a plain `swift build`
    /// lands under `.build/<triple>/release`. The walk is depth-agnostic precisely so a build layout
    /// change is not a silent loss of the whole vendoring layer.
    func testRepoRootIsFoundFromADeeperBuildLayout() throws {
        try makeExecutable("checkout/ThirdParty/tools/tools.lock")
        let hostd = try makeExecutable("checkout/.build/arm64-apple-macosx/release/slopdesk-hostd")

        XCTAssertEqual(
            VendoredTools.repoRoot(startingAt: hostd),
            root.appendingPathComponent("checkout").path,
        )
    }

    /// A hostd copied out of the tree has no vendored prefix, and saying so is the correct answer:
    /// the locators then fall through to the host's own installs rather than pointing at a path that
    /// cannot hold anything.
    func testRepoRootIsNilForABinaryOutsideAnyCheckout() throws {
        let stray = try makeExecutable("elsewhere/bin/slopdesk-hostd")

        XCTAssertNil(VendoredTools.repoRoot(startingAt: stray))
    }

    /// The marker is the LOCK, not `.git` — a checkout predating the vendoring layer, or any
    /// unrelated repository up the tree, must not resolve to a prefix.
    func testRepoRootIgnoresACheckoutWithoutTheLock() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("checkout/.git"), withIntermediateDirectories: true,
        )
        let hostd = try makeExecutable("checkout/.build/release/slopdesk-hostd")

        XCTAssertNil(VendoredTools.repoRoot(startingAt: hostd))
    }

    func testRepoRootIsNilWhenTheExecutablePathIsUnknown() {
        XCTAssertNil(VendoredTools.repoRoot(startingAt: nil))
    }

    // MARK: - Search order

    /// The whole point of the layer: the pinned copy wins even when the host has one on `PATH`.
    /// Homebrew's `code-server` froze at 4.112, below the Code 1.121 floor the panel needs, and it
    /// silently winning is the failure this ordering ends.
    func testVendoredPrefixOutranksPATH() throws {
        let vendored = try makeExecutable("prefix/bin/code-server")
        try makeExecutable("homebrew/bin/code-server")

        let found = HostServiceProcess.locate(
            "code-server", overrideVariable: "SLOPDESK_CODE_SERVER_BIN",
            environment: ["PATH": root.appendingPathComponent("homebrew/bin").path],
            vendoredBinDirectory: root.appendingPathComponent("prefix/bin").path,
        )

        XCTAssertEqual(found, vendored)
    }

    /// An unprovisioned checkout must not become an unusable one — the host's own install still
    /// answers.
    func testFallsThroughToPATHWhenThePrefixIsNotProvisioned() throws {
        let onPath = try makeExecutable("homebrew/bin/code-server")

        let found = HostServiceProcess.locate(
            "code-server", overrideVariable: "SLOPDESK_CODE_SERVER_BIN",
            environment: ["PATH": root.appendingPathComponent("homebrew/bin").path],
            vendoredBinDirectory: root.appendingPathComponent("prefix/bin").path,
        )

        XCTAssertEqual(found, onPath)
    }

    /// The escape hatch stays above the pin: an operator who named a binary meant that one, and a
    /// bisect against a candidate build must not be quietly overridden by the lock.
    func testEnvironmentOverrideBeatsTheVendoredPrefix() throws {
        try makeExecutable("prefix/bin/code-server")
        let override = try makeExecutable("candidate/code-server")

        let found = HostServiceProcess.locate(
            "code-server", overrideVariable: "SLOPDESK_CODE_SERVER_BIN",
            environment: ["SLOPDESK_CODE_SERVER_BIN": override, "PATH": ""],
            vendoredBinDirectory: root.appendingPathComponent("prefix/bin").path,
        )

        XCTAssertEqual(found, override)
    }

    // MARK: - Android toolchain

    func testAdbPrefersTheVendoredPrefixOverAnSDKRoot() throws {
        let vendored = try makeExecutable("prefix/bin/adb")
        try makeExecutable("sdk/platform-tools/adb")

        let found = AndroidToolchain.locateSDKTool(
            "adb", subdirectory: "platform-tools", overrideVariable: "SLOPDESK_ADB_BIN",
            environment: ["PATH": "", "ANDROID_HOME": root.appendingPathComponent("sdk").path],
            fileManager: .default,
            vendoredBinDirectory: root.appendingPathComponent("prefix/bin").path,
        )

        XCTAssertEqual(found, vendored)
    }

    /// The emulator is deliberately NOT provisioned, so its lookup is handed no prefix and must
    /// reach the host's SDK. A prefix that accidentally shadowed it would break AVD booting on every
    /// machine while looking like it worked.
    func testEmulatorStillResolvesFromTheHostSDK() throws {
        let sdkEmulator = try makeExecutable("sdk/emulator/emulator")

        let found = AndroidToolchain.locateSDKTool(
            "emulator", subdirectory: "emulator", overrideVariable: "SLOPDESK_ANDROID_EMULATOR_BIN",
            environment: ["PATH": "", "ANDROID_HOME": root.appendingPathComponent("sdk").path],
            fileManager: .default, vendoredBinDirectory: nil,
        )

        XCTAssertEqual(found, sdkEmulator)
    }

    func testScrcpyJarPrefersTheCommittedCopy() throws {
        let vendored = root.appendingPathComponent("vendor/scrcpy-server")
        try FileManager.default.createDirectory(
            at: vendored.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("jar".utf8).write(to: vendored)

        let found = AndroidToolchain.locateScrcpyServerJar(
            environment: [:], fileManager: .default, vendoredJar: vendored.path,
        )

        XCTAssertEqual(found, vendored.path)
    }

    /// Outside a checkout the committed jar is unreachable; a `brew install scrcpy` host must keep
    /// mirroring rather than regress to "no scrcpy-server".
    func testScrcpyJarFallsBackWhenTheCommittedCopyIsAbsent() {
        let found = AndroidToolchain.locateScrcpyServerJar(
            environment: [:], fileManager: .default,
            vendoredJar: root.appendingPathComponent("nothing-here").path,
        )

        // Whatever this machine has (a Homebrew jar or nothing) — the claim is only that an absent
        // vendored jar does not short-circuit the rest of the search.
        XCTAssertNotEqual(found, root.appendingPathComponent("nothing-here").path)
    }

    // MARK: - The lock itself

    /// `#filePath` reaches the checkout this test was COMPILED from, which for a test file is the
    /// honest handle on the repo (unlike production code, where it would bake in the build machine).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskHostTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo
    }

    private static func lockRecords() throws -> [[String]] {
        let lock = repoRoot.appendingPathComponent(VendoredTools.lockRelativePath)
        let text = try String(contentsOf: lock, encoding: .utf8)
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
    }

    /// The lock is parsed by a shell script, so a malformed record fails at provision time on
    /// somebody's machine rather than here. Six fields, a known archive kind, and a real pinned URL
    /// — never a `latest` alias, which is the unpinnable shape this whole layer exists to remove.
    func testLockRecordsAreWellFormed() throws {
        let records = try Self.lockRecords()
        XCTAssertFalse(records.isEmpty, "tools.lock has no records")

        for record in records {
            XCTAssertEqual(record.count, 6, "malformed record: \(record)")
            let (name, kind, url, sha) = (record[0], record[2], record[4], record[5])
            XCTAssertTrue(
                ["tar.gz", "zip", "file"].contains(kind), "\(name): unknown archive kind '\(kind)'",
            )
            XCTAssertTrue(url.hasPrefix("https://"), "\(name): pin must be an https URL")
            XCTAssertFalse(url.contains("/latest/"), "\(name): 'latest' is not a pin")
            XCTAssertEqual(sha.count, 64, "\(name): SHA-256 must be 64 hex characters")
            XCTAssertNil(
                sha.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted),
                "\(name): SHA-256 must be lowercase hex",
            )
        }
    }

    /// The committed `scrcpy-server` jar still matches its pin. This is the one dependency whose
    /// bytes are in git, so it is the one that a bad merge, a stray text filter or a truncated
    /// checkout can corrupt — and the symptom would otherwise be a mirror that fails on the DEVICE,
    /// which reads as a phone problem.
    func testCommittedScrcpyJarMatchesItsPin() throws {
        let records = try Self.lockRecords()
        let jar = try XCTUnwrap(
            records.first { $0[0] == "scrcpy-server" }, "no scrcpy-server record in tools.lock",
        )
        XCTAssertEqual(jar[2], "file", "scrcpy-server is committed, not downloaded")

        let path = Self.repoRoot.appendingPathComponent("ThirdParty/tools/vendor/" + jar[3])
        let bytes = try Data(contentsOf: path)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(digest, jar[5], "vendor/\(jar[3]) does not match its pin in tools.lock")
    }
}
