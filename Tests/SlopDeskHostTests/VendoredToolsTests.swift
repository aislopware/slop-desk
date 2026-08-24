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

    //
    // The five cases that lived here (the walk finds the checkout, it is depth-agnostic across
    // SwiftPM's build layouts, a binary outside a checkout answers nothing, the marker is the LOCK
    // and not `.git`, an unknown executable path answers nothing) moved WITH the capability:
    // the walk is `rust/slopdesk-androidd/src/toolchain.rs`, next to the binary search order whose
    // second rung it fills, and there is no Swift copy of it. `VendoredTools` is a face over those
    // three doors and holds only the `Bundle.main.executableURL` the walk starts from.

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

    /// The divergence the port removed, asserted from the side that had it wrong.
    ///
    /// `FileManager.isExecutableFile` is `access(X_OK)`, which a DIRECTORY passes, so a directory
    /// wearing the tool's name on `PATH` used to end the walk and be handed to `posix_spawn`. The
    /// order is `slopdesk_androidd::toolchain::locate_tool` now, which tests `is_file()` as well, so
    /// the decoy is walked past and the real binary two entries along is what answers.
    func testADirectoryWearingTheToolsNameIsNotACandidate() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("decoy/bin/code-server"), withIntermediateDirectories: true,
        )
        let real = try makeExecutable("later/bin/code-server")

        let found = HostServiceProcess.locate(
            "code-server", overrideVariable: "SLOPDESK_CODE_SERVER_BIN",
            environment: ["PATH": root.appendingPathComponent("decoy/bin").path + ":"
                + root.appendingPathComponent("later/bin").path],
            vendoredBinDirectory: nil,
            homeDirectory: root.appendingPathComponent("nobody").path,
        )

        XCTAssertEqual(found, real)
    }

    /// The tail after `PATH`, and the reason it exists: hostd is launched by `nohup`/launchd, so an
    /// inherited `PATH` routinely misses `~/.local/bin`. The home directory is INJECTED here for the
    /// same reason the environment is — a test that read the developer's real one would pass or fail
    /// on what they happen to have installed.
    func testTheHomeLocalBinTailAnswersWhenPATHDoesNot() throws {
        let inTail = try makeExecutable("home/.local/bin/baguette")

        let found = HostServiceProcess.locate(
            "baguette", overrideVariable: "SLOPDESK_SIMULATOR_SERVER_BIN",
            environment: ["PATH": ""],
            vendoredBinDirectory: nil,
            homeDirectory: root.appendingPathComponent("home").path,
        )

        XCTAssertEqual(found, inTail)
    }

    // MARK: - Android toolchain

    //
    // The four cases that lived here (adb prefers the vendored prefix, the emulator deliberately
    // does not, the committed scrcpy jar wins, an absent one does not short-circuit) moved WITH the
    // capability: the Android toolchain locator is `rust/slopdesk-androidd/src/toolchain.rs` and
    // there is no Swift copy of it. What stays this side is the repo-root walk above, which androidd
    // does not repeat — it takes hostd's answer on argv.

    // MARK: - The lock itself

    /// `#filePath` reaches the checkout this test was COMPILED from, which for a test file is the
    /// honest handle on the repo (unlike production code, where it would bake in the build machine).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskHostTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo
    }

    /// Spelled out rather than read from a door: this is the FIXTURE these two cases open, the way
    /// they also spell `ThirdParty/tools/vendor/` below. The path as an implementation constant is
    /// `slopdesk_androidd::toolchain::LOCK_RELATIVE_PATH`, and `lint-invariants` pins the pair.
    private static let lockRelativePath = "ThirdParty/tools/tools.lock"

    private static func lockRecords() throws -> [[String]] {
        let lock = repoRoot.appendingPathComponent(lockRelativePath)
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
