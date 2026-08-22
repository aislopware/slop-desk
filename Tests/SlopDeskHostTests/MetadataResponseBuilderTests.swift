import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// Exercises the PURE host responder ``MetadataResponseBuilder`` over an injected fake
/// ``MetadataQuerying``. NO subprocess, NO PTY, NO syscall — the real ``HostMetadataProbe`` is
/// compiled + reviewed only (hang-safety; the ``PTYForegroundProbe`` precedent). These tests pin:
///
/// - verb → payload mapping (each verb encodes the fake's data via the shared ``MetadataCodec``),
/// - the host ALWAYS replies, echoing the requestID (the client never hangs),
/// - path-confinement: a hostile `..` / out-of-root absolute arg reaches ``MetadataStatus/error``
///   WITHOUT calling the query (revert-to-confirm-fail: the fake records every call),
/// - the entry / byte CAPS,
/// - an unknown verb byte → ``MetadataStatus/unsupportedVerb`` (forward-tolerant, no trap).
final class MetadataResponseBuilderTests: XCTestCase {
    private let root = "/Users/dev/repo"

    // MARK: - Fake query (records path/id calls so a confinement rejection is "no read")

    private final class FakeQuery: MetadataQuerying {
        var cwd: String? = "/Users/dev/repo"
        var processList: [MetadataCodec.ProcessInfo] = []
        var portList: [MetadataCodec.PortInfo] = []
        var gitStatusPayload: MetadataCodec.GitStatusPayload = .noRepo
        var gitDiffResult: Data? = Data("@@ diff @@".utf8)
        var dirEntries: [MetadataCodec.DirEntry]? = []
        var sessionList: [MetadataCodec.AgentSessionInfo] = []
        var sessionBytes: Data? = Data("{}".utf8)

        private(set) var gitDiffCalls: [(cwd: String, file: String)] = []
        private(set) var listDirectoryCalls: [String] = []
        private(set) var listAgentSessionsCalls: [String] = []
        private(set) var readAgentSessionCalls: [String] = []

        func paneWorkingDirectory() -> String? { cwd }
        // The seam carries ENCODED payloads now, so the fake encodes: what the builder is being
        // asked to prove is that it forwards those bytes verbatim, and the round-trip below still
        // reads them back as the values that went in.
        func processes() -> Data { MetadataCodec.encodeProcessList(processList) }
        func ports() -> Data { MetadataCodec.encodePortList(portList) }
        func gitStatus(cwd _: String) -> MetadataCodec.GitStatusPayload { gitStatusPayload }
        func gitDiff(cwd: String, file: String) -> Data? {
            gitDiffCalls.append((cwd, file))
            return gitDiffResult
        }

        func listDirectory(absolutePath: String) -> [MetadataCodec.DirEntry]? {
            listDirectoryCalls.append(absolutePath)
            return dirEntries
        }

        func listAgentSessions(project: String) -> [MetadataCodec.AgentSessionInfo] {
            listAgentSessionsCalls.append(project)
            return sessionList
        }

        func readAgentSession(id: String) -> Data? {
            readAgentSessionCalls.append(id)
            return sessionBytes
        }

        var hostNameValue: String? = "mac-studio.local"
        func hostName() -> String? { hostNameValue }

        var hostVitalsValue: MetadataCodec.HostVitals? = .init(
            cpuPercent: 34, memoryPercent: 61, pressure: .normal,
        )
        func hostVitals() -> MetadataCodec.HostVitals? { hostVitalsValue }
    }

    // MARK: - Helpers

    private func decode(_ message: WireMessage) -> (requestID: UInt32, status: UInt8, payload: Data) {
        guard case let .metadataResponse(requestID, status, payload) = message else {
            XCTFail("expected .metadataResponse, got \(message)")
            return (0, 0xFF, Data())
        }
        return (requestID, status, payload)
    }

    private func response(
        _ builder: MetadataResponseBuilder,
        _ verb: MetadataVerb,
        _ payload: Data = Data(),
        requestID: UInt32 = 7,
    ) -> (requestID: UInt32, status: UInt8, payload: Data) {
        decode(builder.response(requestID: requestID, verb: verb.rawValue, payload: payload))
    }

    // MARK: - Verb → payload mapping

    func testProcessesEncodesFakeList() throws {
        let fake = FakeQuery()
        fake.processList = [
            .init(pid: 42, uptimeSec: 100, name: "-zsh"),
            .init(pid: 99, uptimeSec: 5, name: "claude"),
        ]
        let r = response(MetadataResponseBuilder(query: fake), .processes, requestID: 13)
        XCTAssertEqual(r.requestID, 13)
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(try MetadataCodec.decodeProcessList(r.payload), fake.processList)
    }

    func testPortsEmptyIsOkWithZeroCount() throws {
        let fake = FakeQuery()
        fake.portList = []
        let r = response(MetadataResponseBuilder(query: fake), .ports)
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(try MetadataCodec.decodePortList(r.payload), [])
    }

    func testPortsEncodesFakeList() throws {
        let fake = FakeQuery()
        fake.portList = [.init(port: 8080, proto: 0, procName: "node")]
        let r = response(MetadataResponseBuilder(query: fake), .ports)
        XCTAssertEqual(try MetadataCodec.decodePortList(r.payload), fake.portList)
    }

    func testHostInfoReturnsHostnameBytes() {
        let fake = FakeQuery()
        fake.hostNameValue = "mac-studio.local"
        let r = response(MetadataResponseBuilder(query: fake), .hostInfo)
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(String(data: r.payload, encoding: .utf8), "mac-studio.local")
    }

    func testHostInfoUnresolvableIsError() {
        for value in [nil, ""] as [String?] {
            let fake = FakeQuery()
            fake.hostNameValue = value
            let r = response(MetadataResponseBuilder(query: fake), .hostInfo)
            XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
            XCTAssertTrue(r.payload.isEmpty)
        }
    }

    func testHostVitalsEncodesEveryFieldAndIsPaneAgnostic() throws {
        let fake = FakeQuery()
        fake.cwd = nil // pane-agnostic like hostInfo: no cwd, no confinement, still answers
        fake.hostVitalsValue = .init(
            cpuPercent: 34, memoryPercent: 61, pressure: .warn, diskFreeMiB: 245_760,
        )
        let r = response(MetadataResponseBuilder(query: fake), .hostVitals)
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(try MetadataCodec.decodeHostVitals(r.payload), fake.hostVitalsValue)
    }

    func testHostVitalsWithoutAReadingIsErrorNotAFabricatedZero() {
        let fake = FakeQuery()
        fake.hostVitalsValue = nil // the sampler's baseline is still priming
        let r = response(MetadataResponseBuilder(query: fake), .hostVitals)
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue, "ask again next poll — never a fake 0%")
        XCTAssertTrue(r.payload.isEmpty)
    }

    func testCwdOkAndErrorWhenUnresolved() {
        let fake = FakeQuery()
        let ok = response(MetadataResponseBuilder(query: fake), .cwd)
        XCTAssertEqual(ok.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(String(data: ok.payload, encoding: .utf8), root)

        fake.cwd = nil
        let err = response(MetadataResponseBuilder(query: fake), .cwd)
        XCTAssertEqual(err.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(err.payload.isEmpty)
    }

    func testGitStatusEncodesPayloadAndErrorsWithoutCwd() throws {
        let fake = FakeQuery()
        fake.gitStatusPayload = .init(
            hasRepo: true, branch: "main", remoteURL: "https://github.com/x/y",
            repoRoot: "/Users/me/x", // the pure builder passes repoRoot through verbatim
            ahead: 2, behind: 1, files: [.init(statusCode: 0x11, path: "a.swift")],
        )
        let ok = response(MetadataResponseBuilder(query: fake), .gitStatus)
        XCTAssertEqual(ok.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(try MetadataCodec.decodeGitStatus(ok.payload), fake.gitStatusPayload)
        XCTAssertEqual(try MetadataCodec.decodeGitStatus(ok.payload).repoRoot, "/Users/me/x")

        fake.cwd = nil
        let err = response(MetadataResponseBuilder(query: fake), .gitStatus)
        XCTAssertEqual(err.status, MetadataStatus.error.rawValue)
    }

    // MARK: - gitDiff confinement + result

    func testGitDiffOkForConfinedRelativeFile() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .gitDiff, Data("src/main.swift".utf8))
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(r.payload, fake.gitDiffResult)
        XCTAssertEqual(fake.gitDiffCalls.count, 1)
        XCTAssertEqual(fake.gitDiffCalls.first?.cwd, root)
        XCTAssertEqual(fake.gitDiffCalls.first?.file, "src/main.swift")
    }

    func testGitDiffRejectsParentTraversalWithoutCallingQuery() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .gitDiff, Data("../escape.txt".utf8))
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(r.payload.isEmpty)
        XCTAssertTrue(fake.gitDiffCalls.isEmpty, "confinement must reject BEFORE the query (no read)")
    }

    func testGitDiffRejectsAbsolutePathWithoutCallingQuery() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .gitDiff, Data("/etc/passwd".utf8))
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.gitDiffCalls.isEmpty)
    }

    func testGitDiffRejectsEmptyFileArg() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .gitDiff, Data())
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.gitDiffCalls.isEmpty)
    }

    func testGitDiffNotFoundWhenQueryReturnsNil() {
        let fake = FakeQuery()
        fake.gitDiffResult = nil
        let r = response(MetadataResponseBuilder(query: fake), .gitDiff, Data("src/main.swift".utf8))
        XCTAssertEqual(r.status, MetadataStatus.notFound.rawValue)
        XCTAssertEqual(fake.gitDiffCalls.count, 1)
    }

    /// A pathspec that climbs and comes back is refused, not resolved. Lexical resolution is only
    /// correct when no component on the way is a symlink, and nothing in a string can say whether
    /// one is — so the component is refused wherever it sits.
    func testGitDiffRejectsATraversalThatWouldLandBackInside() {
        for file in ["src/../src/main.swift", "src/..", "./../src/main.swift", "a/../../repo/a"] {
            let fake = FakeQuery()
            let r = response(MetadataResponseBuilder(query: fake), .gitDiff, Data(file.utf8))
            XCTAssertEqual(r.status, MetadataStatus.error.rawValue, "rejected: \(file)")
            XCTAssertTrue(fake.gitDiffCalls.isEmpty, "no diff for: \(file)")
        }
    }

    /// The pathspec reaching git is NORMALIZED where the deleted implementation echoed the argument
    /// back verbatim. Same file either way; one spelling rather than several.
    func testGitDiffNormalizesThePathspecItPassesOn() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .gitDiff, Data("./src//main.swift".utf8))
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(fake.gitDiffCalls.first?.file, "src/main.swift")
    }

    // MARK: - listDirectory confinement + caps

    func testListDirectoryEmptyArgUsesPaneCwd() {
        let fake = FakeQuery()
        _ = response(MetadataResponseBuilder(query: fake), .listDirectory, Data())
        XCTAssertEqual(fake.listDirectoryCalls, [root])
    }

    func testListDirectoryAllowsAbsolutePathWithinRoot() {
        let fake = FakeQuery()
        let r = response(
            MetadataResponseBuilder(query: fake), .listDirectory, Data("/Users/dev/repo/src".utf8),
        )
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(fake.listDirectoryCalls, ["/Users/dev/repo/src"])
    }

    func testListDirectoryAllowsRelativePathJoinedToRoot() {
        let fake = FakeQuery()
        _ = response(MetadataResponseBuilder(query: fake), .listDirectory, Data("src/net".utf8))
        XCTAssertEqual(fake.listDirectoryCalls, ["/Users/dev/repo/src/net"])
    }

    func testListDirectoryRejectsTraversalWithoutCallingQuery() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data("../../etc".utf8))
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.listDirectoryCalls.isEmpty)
    }

    func testListDirectoryRejectsAbsolutePathOutsideRoot() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data("/etc".utf8))
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.listDirectoryCalls.isEmpty)
    }

    func testListDirectoryRejectsSiblingPrefixDir() {
        // The component-wise confinement must NOT treat `/Users/dev/repo-evil` as under `/Users/dev/repo`.
        let fake = FakeQuery()
        let r = response(
            MetadataResponseBuilder(query: fake), .listDirectory, Data("/Users/dev/repo-evil".utf8),
        )
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.listDirectoryCalls.isEmpty)
    }

    /// The adversarial sweep, in one place, over the argument that actually names a directory to
    /// read. Every one of these must reach `.error` with the query untouched — a `..` in any
    /// position including one that would resolve back inside, the filesystem root, `/` dressed up
    /// as `//`, and an interior NUL (which `execve` would truncate at, so a path whose meaning
    /// changes on the way to the syscall is refused rather than reasoned about).
    func testListDirectoryRejectsEveryTraversalShapeWithoutCallingQuery() {
        for path in [
            "..",
            "../",
            "../../etc",
            "src/../../etc",
            "src/..",
            "/Users/dev/repo/../../etc",
            "/Users/dev/repo/src/../lib",
            "src/../src",
            "/",
            "//",
            "/etc/passwd",
            "/Users/dev",
            "src/\u{0}/etc",
        ] {
            let fake = FakeQuery()
            let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data(path.utf8))
            XCTAssertEqual(r.status, MetadataStatus.error.rawValue, "rejected: \(path)")
            XCTAssertTrue(fake.listDirectoryCalls.isEmpty, "no read for: \(path)")
        }
    }

    /// The spellings that are the SAME path and must all reach the query normalized — `//`, a
    /// trailing slash and a `.` component cannot climb, so refusing them would only mean one rule
    /// with several behaviours.
    func testListDirectoryNormalizesTheHarmlessSpellings() {
        for path in ["src//net", "src/net/", "./src/./net", "/Users/dev/repo//src/net"] {
            let fake = FakeQuery()
            let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data(path.utf8))
            XCTAssertEqual(r.status, MetadataStatus.ok.rawValue, "accepted: \(path)")
            XCTAssertEqual(fake.listDirectoryCalls, ["/Users/dev/repo/src/net"], "normalized: \(path)")
        }
    }

    /// The pane's own cwd, named explicitly rather than by the empty-argument default: the root IS
    /// inside itself, and a listing of it is the most ordinary request this verb serves.
    func testListDirectoryAcceptsTheRootItselfNamedInFull() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data(root.utf8))
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(fake.listDirectoryCalls, [root])
    }

    /// A pane whose cwd could not be resolved to a real project must be refused, not handed the
    /// machine. An empty cwd already answers `.error` before confinement; a cwd of `/` reaches
    /// confinement and is refused there, because a root that contains everything is not a root.
    func testAnUnusableCwdConfinesNothing() {
        for cwd in ["/", "//", "relative/dir", "/Users/dev/.."] {
            let fake = FakeQuery()
            fake.cwd = cwd
            let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data("etc".utf8))
            XCTAssertEqual(r.status, MetadataStatus.error.rawValue, "rejected root: \(cwd)")
            XCTAssertTrue(fake.listDirectoryCalls.isEmpty, "no read under root: \(cwd)")
        }
    }

    /// A trailing slash on the ROOT is a spelling the pane's cwd probe could legitimately produce,
    /// and it must not change a single answer.
    func testATrailingSlashOnTheRootChangesNothing() {
        let fake = FakeQuery()
        fake.cwd = root + "/"
        let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data("src".utf8))
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(fake.listDirectoryCalls, ["/Users/dev/repo/src"])
    }

    func testListDirectoryNotFoundWhenQueryReturnsNil() {
        let fake = FakeQuery()
        fake.dirEntries = nil
        let r = response(MetadataResponseBuilder(query: fake), .listDirectory, Data())
        XCTAssertEqual(r.status, MetadataStatus.notFound.rawValue)
    }

    func testListDirectoryCapsEntries() throws {
        let fake = FakeQuery()
        fake.dirEntries = (0..<10).map { .init(isDir: false, name: "f\($0)") }
        let builder = MetadataResponseBuilder(query: fake, maxDirEntries: 3)
        let r = response(builder, .listDirectory, Data())
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        let decoded = try MetadataCodec.decodeDirListing(r.payload)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.map(\.name), ["f0", "f1", "f2"])
    }

    // MARK: - listAgentSessions / readAgentSession

    func testListAgentSessionsEmptyProjectUsesCwdAndEncodes() throws {
        let fake = FakeQuery()
        fake.sessionList = [.init(agentKindByte: 0, id: "/p/a.jsonl", title: "t", cwd: root, mtimeMS: 5)]
        let r = response(MetadataResponseBuilder(query: fake), .listAgentSessions, Data())
        XCTAssertEqual(fake.listAgentSessionsCalls, [root])
        XCTAssertEqual(try MetadataCodec.decodeAgentSessionList(r.payload), fake.sessionList)
    }

    /// A session id is an ABSOLUTE host path — every one a client can hold came back from
    /// `listAgentSessions`, whose rows are built from directory entries.
    func testReadAgentSessionOk() {
        let fake = FakeQuery()
        let id = "/Users/dev/.claude/projects/-Users-dev-repo/abc.jsonl"
        let r = response(MetadataResponseBuilder(query: fake), .readAgentSession, Data(id.utf8))
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(r.payload, fake.sessionBytes)
        XCTAssertEqual(fake.readAgentSessionCalls, [id])
    }

    /// A RELATIVE id is refused here now, where it used to be passed through and refused one fork
    /// later by the probe (which answers `.notFound` for anything not starting with `/`). Same
    /// outcome for the user, one spawn cheaper, and it keeps this builder's contract literally true:
    /// an argument it will not act on never reaches a query method.
    func testReadAgentSessionRejectsARelativeIdWithoutCallingQuery() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .readAgentSession, Data("abc.jsonl".utf8))
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.readAgentSessionCalls.isEmpty)
    }

    /// `/` is a well-formed absolute path and is not a session file; a `..` in any position is
    /// refused wherever it sits, including one that would have resolved back inside.
    func testReadAgentSessionRejectsTheAdversarialIdShapes() {
        for id in [
            "/",
            "//",
            "/Users/dev/.claude/../../../etc/passwd",
            "/Users/dev/.claude/projects/-p/../-p/abc.jsonl",
            "/Users/dev/..",
            "..",
        ] {
            let fake = FakeQuery()
            let r = response(MetadataResponseBuilder(query: fake), .readAgentSession, Data(id.utf8))
            XCTAssertEqual(r.status, MetadataStatus.error.rawValue, "rejected: \(id)")
            XCTAssertTrue(fake.readAgentSessionCalls.isEmpty, "no read for: \(id)")
        }
    }

    func testReadAgentSessionRejectsTraversalWithoutCallingQuery() {
        let fake = FakeQuery()
        let r = response(
            MetadataResponseBuilder(query: fake), .readAgentSession, Data("../../secrets".utf8),
        )
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.readAgentSessionCalls.isEmpty)
    }

    func testReadAgentSessionRejectsEmptyId() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .readAgentSession, Data())
        XCTAssertEqual(r.status, MetadataStatus.error.rawValue)
        XCTAssertTrue(fake.readAgentSessionCalls.isEmpty)
    }

    func testReadAgentSessionNotFoundWhenQueryReturnsNil() {
        let fake = FakeQuery()
        fake.sessionBytes = nil
        let r = response(
            MetadataResponseBuilder(query: fake), .readAgentSession,
            Data("/Users/dev/.claude/projects/-p/abc.jsonl".utf8),
        )
        XCTAssertEqual(r.status, MetadataStatus.notFound.rawValue)
    }

    // MARK: - Opaque byte cap

    func testOpaquePayloadCappedToMaxBytes() {
        let fake = FakeQuery()
        fake.gitDiffResult = Data(repeating: 0x41, count: 10)
        let builder = MetadataResponseBuilder(query: fake, maxOpaquePayloadBytes: 4)
        let r = response(builder, .gitDiff, Data("src/x".utf8))
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(r.payload.count, 4)
    }

    func testReadAgentSessionPayloadCappedToMaxBytes() {
        let fake = FakeQuery()
        fake.sessionBytes = Data(repeating: 0x7B, count: 32)
        let builder = MetadataResponseBuilder(query: fake, maxOpaquePayloadBytes: 8)
        let r = response(builder, .readAgentSession, Data("/Users/dev/.claude/projects/-p/a.jsonl".utf8))
        XCTAssertEqual(r.payload.count, 8)
    }

    // MARK: - Unknown verb (forward-tolerant)

    func testUnknownVerbByteReturnsUnsupported() {
        let fake = FakeQuery()
        let message = MetadataResponseBuilder(query: fake).response(requestID: 21, verb: 99, payload: Data())
        let r = decode(message)
        XCTAssertEqual(r.requestID, 21)
        XCTAssertEqual(r.status, MetadataStatus.unsupportedVerb.rawValue)
        XCTAssertTrue(r.payload.isEmpty)
    }

    func testZeroVerbByteReturnsUnsupported() {
        // 0 is not a defined MetadataVerb (verbs are 1...13) — must be tolerated, not trap.
        let fake = FakeQuery()
        let r = decode(MetadataResponseBuilder(query: fake).response(requestID: 1, verb: 0, payload: Data()))
        XCTAssertEqual(r.status, MetadataStatus.unsupportedVerb.rawValue)
    }

    // MARK: - Side-effecting path verbs are NOT this read-only builder's job

    func testSideEffectingPathVerbsReachingTheReadOnlyBuilderReturnError() {
        // openPath (9) / revealPath (10) are routed to `HostPathActionPerformer` by `serveMetadata`
        // BEFORE the builder; if one ever reaches this PURE reducer it must reply .error and perform NO
        // side effect — never trap on the now-exhaustive switch, never silently report success.
        for verb in [MetadataVerb.openPath, .revealPath] {
            let fake = FakeQuery()
            let r = response(
                MetadataResponseBuilder(query: fake), verb, Data("/Users/dev/repo/x.swift".utf8), requestID: 33,
            )
            XCTAssertEqual(r.requestID, 33)
            XCTAssertEqual(r.status, MetadataStatus.error.rawValue, "\(verb): the read-only builder never actuates")
            XCTAssertTrue(r.payload.isEmpty)
            // The read query seam was never touched (the builder did no work for a side-effecting verb).
            XCTAssertTrue(fake.gitDiffCalls.isEmpty && fake.listDirectoryCalls.isEmpty)
        }
    }

    // MARK: - Agent-hooks verbs are NOT this read-only builder's job

    func testAgentHooksVerbsReachingTheReadOnlyBuilderReturnError() {
        // installAgentHooks (11) / uninstallAgentHooks (12) / agentHookStatus (13) are routed to
        // `HostAgentActionPerformer` by `serveMetadata` BEFORE the builder; if one ever reaches this PURE
        // reducer it must reply .error and perform NO side effect (no settings.json write / marker read),
        // never trap on the now-exhaustive switch, never silently report success.
        for verb in [MetadataVerb.installAgentHooks, .uninstallAgentHooks, .agentHookStatus] {
            let fake = FakeQuery()
            let r = response(MetadataResponseBuilder(query: fake), verb, Data(), requestID: 44)
            XCTAssertEqual(r.requestID, 44)
            XCTAssertEqual(r.status, MetadataStatus.error.rawValue, "\(verb): the read-only builder never actuates")
            XCTAssertTrue(r.payload.isEmpty)
            XCTAssertTrue(fake.gitDiffCalls.isEmpty && fake.listDirectoryCalls.isEmpty)
        }
    }
}
