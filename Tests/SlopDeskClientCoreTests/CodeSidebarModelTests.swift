import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskClientCore

/// ``CodeSidebarModel`` — the right code panel's readiness machine. Pure helpers + the poll loop
/// against a FAKE ensure closure; the hang-safety rule holds (no WKWebView, no network — the pool
/// and the webview never enter this dependency closure).
@MainActor
final class CodeSidebarModelTests: XCTestCase {
    // MARK: folderURL

    func testFolderURLShape() {
        let url = CodeSidebarModel.folderURL(host: "10.0.0.7", port: 62636, projectRoot: "/Users/x/proj")
        XCTAssertEqual(url?.absoluteString, "http://10.0.0.7:62636/?folder=/Users/x/proj")
    }

    func testFolderURLEncodesSpaces() {
        let url = CodeSidebarModel.folderURL(host: "host", port: 80, projectRoot: "/tmp/a b")
        XCTAssertEqual(url?.absoluteString, "http://host:80/?folder=/tmp/a%20b")
    }

    func testFolderURLRejectsDegenerateEndpoint() {
        XCTAssertNil(CodeSidebarModel.folderURL(host: "", port: 80, projectRoot: "/p"))
        XCTAssertNil(CodeSidebarModel.folderURL(host: "h", port: 0, projectRoot: "/p"))
    }

    // MARK: phase(for:)

    func testPhaseMapping() throws {
        XCTAssertEqual(CodeSidebarModel.phase(for: nil, host: "h", projectRoot: "/p"), .offline)
        XCTAssertEqual(
            CodeSidebarModel.phase(
                for: .init(state: .starting, port: 0), host: "h", projectRoot: "/p",
            ),
            .starting,
        )
        XCTAssertEqual(
            CodeSidebarModel.phase(
                for: .init(state: .unavailable, port: 0), host: "h", projectRoot: "/p",
            ),
            .unavailable,
        )
        try XCTAssertEqual(
            CodeSidebarModel.phase(
                for: .init(state: .ready, port: 8080), host: "h", projectRoot: "/p",
            ),
            .ready(projectRoot: "/p", url: XCTUnwrap(URL(string: "http://h:8080/?folder=/p"))),
        )
    }

    func testReadyWithoutHostDegradesToOffline() {
        // A ready endpoint that cannot form a URL must keep the panel polling, never trap.
        XCTAssertEqual(
            CodeSidebarModel.phase(for: .init(state: .ready, port: 8080), host: nil, projectRoot: "/p"),
            .offline,
        )
        XCTAssertEqual(
            CodeSidebarModel.phase(for: .init(state: .ready, port: 0), host: "h", projectRoot: "/p"),
            .offline,
        )
    }

    // MARK: endpointMoved

    func testEndpointMoved() throws {
        let target = try XCTUnwrap(URL(string: "http://h:9000/?folder=/p"))
        XCTAssertTrue(CodeSidebarModel.endpointMoved(current: nil, target: target))
        XCTAssertTrue(
            CodeSidebarModel.endpointMoved(current: URL(string: "http://h:9001/?folder=/p"), target: target),
        )
        XCTAssertTrue(
            CodeSidebarModel.endpointMoved(current: URL(string: "http://other:9000/?folder=/p"), target: target),
        )
        // Same origin, different in-app path/query — the workbench navigated itself; NOT a move.
        XCTAssertFalse(
            CodeSidebarModel.endpointMoved(current: URL(string: "http://h:9000/somewhere?x=1"), target: target),
        )
    }

    // MARK: poll loop

    func testPollStopsOnReady() async throws {
        let model = CodeSidebarModel()
        // starting → starting → ready: the loop must run exactly three ensure rounds and settle.
        let states: [MetadataCodec.ServiceEndpoint?] = [
            .init(state: .starting, port: 0),
            .init(state: .starting, port: 6000),
            .init(state: .ready, port: 6000),
        ]
        let round = Counter()
        await model.poll(
            projectRoot: "/p",
            host: { "h" },
            ensure: { _ in states[min(round.next(), states.count - 1)] },
            interval: .zero,
        )
        try XCTAssertEqual(
            model.phase,
            .ready(projectRoot: "/p", url: XCTUnwrap(URL(string: "http://h:6000/?folder=/p"))),
        )
        XCTAssertEqual(round.value, 3)
    }

    func testPollSurfacesUnavailableAndKeepsGoing() async throws {
        let model = CodeSidebarModel()
        let round = Counter()
        // unavailable first (install hint shows), then the operator installs → ready.
        await model.poll(
            projectRoot: "/p",
            host: { "h" },
            ensure: { _ in
                round.next() == 0
                    ? MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0)
                    : MetadataCodec.ServiceEndpoint(state: .ready, port: 7000)
            },
            interval: .zero,
        )
        try XCTAssertEqual(
            model.phase,
            .ready(projectRoot: "/p", url: XCTUnwrap(URL(string: "http://h:7000/?folder=/p"))),
        )
    }

    func testPollLocalizesOnlyTheReadyRound() async throws {
        let model = CodeSidebarModel()
        let round = Counter()
        let localized = Counter()
        // starting → ready: localize must rewrite ONLY the ready endpoint (a starting endpoint has
        // no meaningful port to front), and the URL must carry the LOCAL host + port.
        await model.poll(
            projectRoot: "/p",
            host: { "mesh-host" },
            ensure: { _ in
                round.next() == 0
                    ? MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
                    : MetadataCodec.ServiceEndpoint(state: .ready, port: 6000)
            },
            localize: { host, port in
                XCTAssertEqual(host, "mesh-host")
                XCTAssertEqual(port, 6000)
                _ = localized.next()
                return ("127.0.0.1", 50001)
            },
            interval: .zero,
        )
        try XCTAssertEqual(
            model.phase, .ready(projectRoot: "/p", url: XCTUnwrap(URL(string: "http://127.0.0.1:50001/?folder=/p"))),
        )
        XCTAssertEqual(localized.value, 1)
    }

    func testPollWithoutLocalizeKeepsTheRemoteEndpoint() async throws {
        // The fallback identity: no localize hook (or a failed bind returning its input) means the
        // remote address rides straight into the URL — the pre-proxy behavior, byte for byte.
        let model = CodeSidebarModel()
        await model.poll(
            projectRoot: "/p",
            host: { "mesh-host" },
            ensure: { _ in .init(state: .ready, port: 6000) },
            interval: .zero,
        )
        try XCTAssertEqual(
            model.phase,
            .ready(projectRoot: "/p", url: XCTUnwrap(URL(string: "http://mesh-host:6000/?folder=/p"))),
        )
    }

    func testRequestReloadBumpsGeneration() {
        let model = CodeSidebarModel()
        XCTAssertEqual(model.generation, 0)
        model.requestReload()
        XCTAssertEqual(model.generation, 1)
    }

    // MARK: Re-entry (the phone's cover is dismissed and re-opened)

    /// The phone mounts the panel in a `.fullScreenCover`, so a dismissal cancels the column's
    /// `.task` and every re-open re-enters `poll`. A settled model must answer that re-entry with
    /// SILENCE: no ensure round, and — the visible half — no drop back to `.starting`, which is the
    /// spinner flashing over a workbench that is already loaded.
    func testPollOnASettledRootIsANoOp() async {
        let model = CodeSidebarModel()
        await model.poll(
            projectRoot: "/p", host: { "h" },
            ensure: { _ in .init(state: .ready, port: 6000) }, interval: .zero,
        )
        let settled = model.phase
        let reEntry = Counter()
        await model.poll(
            projectRoot: "/p", host: { "h" },
            ensure: { _ in
                _ = reEntry.next()
                return .init(state: .starting, port: 0)
            },
            interval: .zero,
        )
        XCTAssertEqual(model.phase, settled)
        XCTAssertEqual(reEntry.value, 0, "a settled root must not ensure again")
    }

    /// The guard is ROOT-scoped. A `.ready` left over from the previous project is the stale phase
    /// ``CodeSidebarPhase/ready(projectRoot:url:)`` warns about, so switching projects must re-ensure
    /// and land on the NEW root's URL rather than re-showing the old workbench.
    func testPollOnADifferentRootReEnsures() async throws {
        let model = CodeSidebarModel()
        await model.poll(
            projectRoot: "/old", host: { "h" },
            ensure: { _ in .init(state: .ready, port: 6000) }, interval: .zero,
        )
        await model.poll(
            projectRoot: "/new", host: { "h" },
            ensure: { _ in .init(state: .ready, port: 6100) }, interval: .zero,
        )
        try XCTAssertEqual(
            model.phase,
            .ready(projectRoot: "/new", url: XCTUnwrap(URL(string: "http://h:6100/?folder=/new"))),
        )
    }

    /// The reload button's two halves are one act: the bump restarts the task, and the unsettle is
    /// what lets the restarted loop do any work. Without it the button would cancel a finished loop
    /// and start one that returns on its first line.
    func testRequestReloadUnsettlesSoTheNextPollRuns() async throws {
        let model = CodeSidebarModel()
        await model.poll(
            projectRoot: "/p", host: { "h" },
            ensure: { _ in .init(state: .ready, port: 6000) }, interval: .zero,
        )
        model.requestReload()
        XCTAssertEqual(model.phase, .starting)
        await model.poll(
            projectRoot: "/p", host: { "h" },
            ensure: { _ in .init(state: .ready, port: 6200) }, interval: .zero,
        )
        try XCTAssertEqual(
            model.phase,
            .ready(projectRoot: "/p", url: XCTUnwrap(URL(string: "http://h:6200/?folder=/p"))),
        )
    }

    /// A tiny call counter usable from the `@Sendable`-ish ensure closure (the poll loop is
    /// main-actor bound, so plain state behind a class is safe here).
    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func next() -> Int {
            defer { value += 1 }
            return value
        }
    }
}
