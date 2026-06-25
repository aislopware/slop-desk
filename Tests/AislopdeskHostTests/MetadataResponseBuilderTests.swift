import AislopdeskProtocol
import Foundation
import XCTest
@testable import AislopdeskHost

/// E4 / WI-3 — the PURE host responder ``MetadataResponseBuilder`` over an injected fake
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
        func processes() -> [MetadataCodec.ProcessInfo] { processList }
        func ports() -> [MetadataCodec.PortInfo] { portList }
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
            ahead: 2, behind: 1, files: [.init(statusCode: 0x11, path: "a.swift")],
        )
        let ok = response(MetadataResponseBuilder(query: fake), .gitStatus)
        XCTAssertEqual(ok.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(try MetadataCodec.decodeGitStatus(ok.payload), fake.gitStatusPayload)

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

    func testReadAgentSessionOk() {
        let fake = FakeQuery()
        let r = response(MetadataResponseBuilder(query: fake), .readAgentSession, Data("abc.jsonl".utf8))
        XCTAssertEqual(r.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(r.payload, fake.sessionBytes)
        XCTAssertEqual(fake.readAgentSessionCalls, ["abc.jsonl"])
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
        let r = response(MetadataResponseBuilder(query: fake), .readAgentSession, Data("abc.jsonl".utf8))
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
        let r = response(builder, .readAgentSession, Data("a.jsonl".utf8))
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
        // 0 is not a defined MetadataVerb (verbs are 1...8) — must be tolerated, not trap.
        let fake = FakeQuery()
        let r = decode(MetadataResponseBuilder(query: fake).response(requestID: 1, verb: 0, payload: Data()))
        XCTAssertEqual(r.status, MetadataStatus.unsupportedVerb.rawValue)
    }
}
