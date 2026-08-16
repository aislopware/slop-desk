import Foundation
import XCTest
@testable import SlopDeskSupervisor

/// The search order that decides whether a host has a screen engine, a file drop, an inspector, an
/// Android panel and a profile seed — or reports all five unavailable.
///
/// This had no test at all, and that is how the release shipped without them. `locate` searched the
/// override, a hand-installed copy, and a cargo target tree; a packaged install has none of the
/// three, so it answered `nil` on every machine that got SlopDesk from Homebrew and on none that
/// got it from a checkout. Nothing failed — a `nil` here is a service the host politely reports as
/// unavailable — so the only place the defect was visible was a machine nobody developing on it
/// had. The beside-the-executable step is what a flat `bin` directory needs, and these pin both it
/// and the precedence around it (`docs/49`).
///
/// Every case drives the injected `environment` / `fileManager` / `executable`, so nothing here
/// touches a real path or depends on what this checkout happens to have built.
final class RustServicePathsTests: XCTestCase {
    /// A `FileManager` that calls exactly the named paths executable and nothing else.
    private final class OnlyTheseExist: FileManager, @unchecked Sendable {
        private let executables: Set<String>
        init(_ executables: Set<String>) {
            self.executables = executables
            super.init()
        }

        override func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    }

    private static let home = "/Users/pin"
    private static let installed = "\(home)/Library/Application Support/SlopDesk/bin/slopdesk-screend"
    private static let beside = "/opt/homebrew/bin/slopdesk-screend"
    private static let hostd = URL(fileURLWithPath: "/opt/homebrew/bin/slopdesk-hostd")

    private func locate(
        existing: Set<String>,
        environment: [String: String] = ["HOME": RustServicePathsTests.home],
        executable: URL? = RustServicePathsTests.hostd,
    ) -> String? {
        RustServicePaths.locate(
            "slopdesk-screend",
            crate: "slopdesk-screend",
            overrideVariable: "SLOPDESK_SCREEND_BIN",
            environment: environment,
            fileManager: OnlyTheseExist(existing),
            executable: executable,
        )
    }

    /// The packaged case, and the whole reason this step exists: one flat directory of binaries,
    /// no `~/Library/Application Support` copy, no cargo tree anywhere above it.
    func testABinaryBesideTheHostIsFound() {
        XCTAssertEqual(locate(existing: [Self.beside]), Self.beside)
    }

    /// A tree with neither an installed copy nor a sibling still answers `nil` rather than a path
    /// that is not there — the pre-existing contract, kept.
    func testNothingAnywhereIsStillNil() {
        XCTAssertNil(locate(existing: []))
    }

    /// The override outranks everything, including a sibling that exists. It is the escape hatch
    /// every gate script uses to point one host at another build.
    func testTheOverrideBeatsASibling() {
        XCTAssertEqual(
            locate(
                existing: [Self.beside],
                environment: ["HOME": Self.home, "SLOPDESK_SCREEND_BIN": "/tmp/mine"],
            ),
            "/tmp/mine",
        )
    }

    /// A deliberate hand-install outranks a sibling: someone who put a binary in
    /// `~/Library/Application Support/SlopDesk/bin` meant that one, even on a packaged host.
    func testAnInstalledCopyBeatsASibling() {
        XCTAssertEqual(locate(existing: [Self.installed, Self.beside]), Self.installed)
    }

    /// The sibling is checked BEFORE the walk, so a checkout that staged one beside hostd does not
    /// silently resolve to a stale per-crate `target/` instead.
    func testASiblingBeatsTheBuildTreeWalk() {
        let checkout = URL(fileURLWithPath: "/src/slopdesk/.build/release/slopdesk-hostd")
        let staged = "/src/slopdesk/.build/release/slopdesk-screend"
        let walked = "/src/slopdesk/rust/slopdesk-screend/target/release/slopdesk-screend"
        XCTAssertEqual(
            locate(existing: [staged, walked], executable: checkout), staged,
        )
    }

    /// The walk still finds a per-crate target directory several levels up — the dev path, which
    /// the new step must not have displaced.
    func testTheWalkStillFindsACrateTarget() {
        let checkout = URL(fileURLWithPath: "/src/slopdesk/.build/arm64-apple-macosx/release/slopdesk-hostd")
        let walked = "/src/slopdesk/rust/slopdesk-screend/target/release/slopdesk-screend"
        XCTAssertEqual(locate(existing: [walked], executable: checkout), walked)
    }

    /// `locateBeside` is the root-workspace half: no walk, and no existence probe at all — the path
    /// goes to a spawn that reports its own failure, and probing first would answer `nil` for a
    /// binary being replaced by a build in flight.
    func testLocateBesideAnswersWithoutProbing() {
        XCTAssertEqual(
            RustServicePaths.locateBeside(
                "slopdesk-probe",
                overrideVariable: "SLOPDESK_PROBE_BIN",
                environment: [:],
                executableURL: Self.hostd,
            ),
            "/opt/homebrew/bin/slopdesk-probe",
        )
    }
}
