import Foundation
import XCTest
@testable import SlopDeskCLICore

/// `slopdesk sidecars` — finding the two manifests, and recording the baseline.
///
/// The DIFF and the policy behind every note are `rust/slopdesk-sidecars` and are tested there; the
/// one case below that goes through the door checks the CROSSING, not the rule. What is tested here
/// is what is Swift: three install layouts, and a write that has to work the first time it runs.
final class CLISidecarsTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-sidecars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Finding the installed manifest

    /// The release TARBALL's layout: `MANIFEST.json` travels inside `slopdesk-cli-<v>-arm64/` beside
    /// the twelve binaries, so it is the binary's own directory.
    func testTheManifestBesideTheBinaryIsFound() throws {
        let binary = scratch.appendingPathComponent("slopdesk")
        try write("{}", to: scratch.appendingPathComponent("MANIFEST.json"))
        XCTAssertEqual(
            CLISidecars.installedManifestURL(argv0: binary.path, environment: [:])?.lastPathComponent,
            "MANIFEST.json",
        )
    }

    /// Homebrew's layout: the tools are in `#{prefix}/bin` and the manifest is the formula's
    /// `prefix.install`, one directory up.
    func testTheManifestOneDirectoryUpIsFound() throws {
        let binary = scratch.appendingPathComponent("bin/slopdesk")
        try write("{}", to: binary)
        try write("{}", to: scratch.appendingPathComponent("MANIFEST.json"))
        let found = CLISidecars.installedManifestURL(argv0: binary.path, environment: [:])
        XCTAssertEqual(
            found?.resolvingSymlinksInPath().path,
            scratch.appendingPathComponent("MANIFEST.json").resolvingSymlinksInPath().path,
        )
    }

    /// Homebrew's `bin` is a farm of symlinks into the Cellar, and the LINK's parent holds no
    /// manifest. Resolving first is the whole reason a brew install can answer this at all.
    func testASymlinkedBinaryResolvesToTheCellarsManifest() throws {
        let cellar = scratch.appendingPathComponent("Cellar/slopdesk/0.5.0", isDirectory: true)
        let real = cellar.appendingPathComponent("bin/slopdesk")
        try write("#!/bin/sh\n", to: real)
        try write("{}", to: cellar.appendingPathComponent("MANIFEST.json"))

        let link = scratch.appendingPathComponent("bin/slopdesk")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let found = CLISidecars.installedManifestURL(argv0: link.path, environment: [:])
        XCTAssertEqual(
            found?.resolvingSymlinksInPath().path,
            cellar.appendingPathComponent("MANIFEST.json").resolvingSymlinksInPath().path,
        )
    }

    /// A developer tree has no packaged manifest, and that must read as absent rather than as a
    /// manifest somewhere unrelated.
    func testNoManifestAnywhereReadsAsAbsent() {
        let binary = scratch.appendingPathComponent("nested/slopdesk")
        XCTAssertNil(CLISidecars.installedManifestURL(argv0: binary.path, environment: [:]))
        XCTAssertNil(CLISidecars.installedManifestURL(argv0: "", environment: [:]))
    }

    /// The override wins before either guess, and it is NOT required to exist — a caller that
    /// pointed it at the wrong path should be told that file is unreadable, not silently handed
    /// the manifest of the install it happens to be running from.
    func testTheOverrideWinsAndIsTakenAsGiven() throws {
        let binary = scratch.appendingPathComponent("slopdesk")
        try write("{}", to: scratch.appendingPathComponent("MANIFEST.json"))
        let elsewhere = scratch.appendingPathComponent("elsewhere.json")
        XCTAssertEqual(
            CLISidecars.installedManifestURL(
                argv0: binary.path, environment: [CLISidecars.manifestEnvKey: elsewhere.path],
            )?.path,
            elsewhere.path,
        )
    }

    /// An empty value is the shell idiom `FOO="${BAR}"` with `BAR` unset, and must not point the
    /// reader at the filesystem root.
    func testAnEmptyOverrideIsTreatedAsUnset() throws {
        let binary = scratch.appendingPathComponent("slopdesk")
        try write("{}", to: scratch.appendingPathComponent("MANIFEST.json"))
        XCTAssertEqual(
            CLISidecars.installedManifestURL(
                argv0: binary.path, environment: [CLISidecars.manifestEnvKey: ""],
            )?.lastPathComponent,
            "MANIFEST.json",
        )
    }

    // MARK: - The recorded baseline

    func testTheRecordLivesInTheAppSupportContainer() {
        let url = CLISidecars.recordedManifestURL(environment: ["SLOPDESK_APP_SUPPORT_DIR": scratch.path])
        XCTAssertEqual(url?.lastPathComponent, CLISidecars.recordName)
        XCTAssertEqual(url?.deletingLastPathComponent().path, scratch.path)
    }

    /// `--record` runs from a formula's `post_install`, which on a FIRST install is the one moment
    /// the container does not exist yet.
    func testRecordingCreatesTheContainerItWritesInto() throws {
        let url = scratch.appendingPathComponent("not/there/yet/\(CLISidecars.recordName)")
        try CLISidecars.record(#"{"product":"0.5.0"}"#, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"product":"0.5.0"}"#)

        // And it overwrites, because the point is that it is the LAST install's manifest.
        try CLISidecars.record(#"{"product":"0.6.0"}"#, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"product":"0.6.0"}"#)
    }

    // MARK: - The crossing

    /// One case through the door: the plan comes back as JSON with the tools in it. What each
    /// `change` and `note` says is the crate's, asserted in the crate.
    func testThePlanCrossesTheDoorAsJSON() throws {
        let current = #"""
        {"product":"0.5.0","tools":[{"name":"slopdesk-dropd","version":"0.2.0"}]}
        """#
        let previous = #"""
        {"product":"0.4.0","tools":[{"name":"slopdesk-dropd","version":"0.1.0"}]}
        """#
        let text = CLISidecars.plan(previous: previous, current: current)
        let plan = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        )
        XCTAssertEqual(plan["product"] as? String, "0.5.0")
        let tools = try XCTUnwrap(plan["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["tool"] as? String, "slopdesk-dropd")
        XCTAssertEqual(tools.first?["change"] as? String, "changed")
    }

    /// A manifest the door cannot read answers nothing at all, which is the caller's cue to say so
    /// rather than print an empty table as though the upgrade changed nothing.
    func testAnUnreadableManifestPlansNothing() {
        XCTAssertTrue(CLISidecars.plan(previous: nil, current: "not json").isEmpty)
    }
}
