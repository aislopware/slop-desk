#if os(macOS)
import CSlopDeskFFI
import Darwin
import Foundation
import SlopDeskProtocol

/// The host's answer to the metadata RPC for ONE pane (its PTY master fd + shell pid) — a FACE over
/// doors, and nothing else.
///
/// ## What used to be here
/// Every OS query in this file was Swift: `proc_listpids` over every live pid, `proc_pidinfo` per
/// pid to read `e_tdev` and `pbi_start_tvsec`, `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the cwd,
/// `ptsname` + `stat` for the pane's device number, `proc_pidpath`/`proc_name` for each row's name,
/// a `Foundation.Process` running `lsof` with its own drain-before-wait loop and byte budget, and a
/// hand-rolled parser for `lsof -F cn`. It carried a standing note that it was compiled and
/// code-reviewed ONLY, never unit-tested, because every one of those needs a live PTY and a real
/// subprocess — which is exactly what the hang-safety rule keeps out of the suite.
///
/// The census is `rust/slopdesk-panecensus` now, reached through `rust/slopdesk-ffi::pane_probe`,
/// and behind that boundary the parse is a function over a string. The three verbs that were
/// subprocess and filesystem work with no handle behind them — git diff, directory listing, session
/// listing and reading — were already `slopdesk-probe`'s and are still forwarded through
/// ``HostProbe``; `gitStatus` is `rust/slopdesk-git`, linked.
///
/// ## Two verbs cross ENCODED
/// ``processes()`` and ``ports()`` answer reply payloads, not values, because
/// ``MetadataResponseBuilder`` forwards both verbatim. Decoding them here to hand the builder
/// records it would immediately re-encode is work no one asked for, and it is the shape
/// ``gitStatus(cwd:)`` already rejected.
///
/// `#if os(macOS)` — the census is Darwin `proc_*` and an `lsof` spawn, and it is NEVER compiled
/// into the iOS slice (the shared codec/models are — see `check-ios.sh`).
struct HostMetadataProbe: MetadataQuerying {
    /// The pane's PTY master fd — the controlling-terminal anchor for the process and port scope.
    let masterFD: Int32
    /// The pane's shell pid — the cwd fallback when no foreground group resolves.
    let shellPID: pid_t

    // MARK: - the pane

    func paneWorkingDirectory() -> String? {
        FFIStringDoor.read { out, cap in
            slopdesk_pane_working_directory(masterFD, shellPID, out, cap)
        }
    }

    func processes() -> Data {
        // The clock is read ONCE, here, and passed down: a census that read `now` per row would age
        // two processes started in the same second differently.
        let now = Int64(Date().timeIntervalSince1970)
        return FFIStringDoor.readData { out, cap in
            slopdesk_pane_process_list(masterFD, now, out, cap)
        }
    }

    func ports() -> Data {
        FFIStringDoor.readData { out, cap in
            slopdesk_pane_port_list(masterFD, out, cap)
        }
    }

    // MARK: - forwarded to `slopdesk-git` and `slopdesk-probe`

    func gitStatus(cwd: String) -> MetadataCodec.GitStatusPayload { HostGitStatus.of(cwd: cwd) }

    func gitDiff(cwd: String, file: String) -> Data? { HostProbe.gitDiff(cwd: cwd, file: file) }

    func listDirectory(absolutePath: String) -> [MetadataCodec.DirEntry]? {
        HostProbe.listDirectory(absolutePath: absolutePath)
    }

    /// Claude Code and OpenCode only. Codex auto-enumeration is intentionally DEFERRED (the
    /// Claude-first scope reduction), not removed: the probe still lists `~/.codex/sessions` as a
    /// read root, so an EXPLICIT absolute codex session id stays readable while auto-discovery is the
    /// deferred half — see `docs/DECISIONS.md`.
    func listAgentSessions(project: String) -> [MetadataCodec.AgentSessionInfo] {
        HostProbe.listAgentSessions(project: project)
    }

    func readAgentSession(id: String) -> Data? { HostProbe.readAgentSession(id: id) }

    // MARK: - host identity + vitals

    func hostName() -> String? {
        // The machine's own name ("mac-studio.local") — the `hostInfo` verb's answer. Pane-agnostic,
        // no file access; `ProcessInfo` resolves it without a DNS round-trip.
        ProcessInfo.processInfo.hostName
    }

    func hostVitals() -> MetadataCodec.HostVitals? {
        // The machine's pulse — the `hostVitals` verb's answer. Pane-agnostic, so it reads the
        // PROCESS-WIDE sampler rather than any state of this per-request probe: the CPU percent is a
        // delta between polls and would never exist if the baseline died with the probe.
        HostVitalsSampler.shared.sample()
    }
}

/// The `docs/55` §4 two-call shape, once.
///
/// Every door in this file answers "how many bytes the answer needs", so every caller would
/// otherwise spell the same grow-and-retry: lend a buffer, and when the door asks for more, lend
/// exactly that much and ask again. The second call cannot disagree with the first — the doors are
/// pure functions of the same pane — so one retry is the whole protocol, not a loop.
private enum FFIStringDoor {
    /// The starting buffer. A cwd is under `MAXPATHLEN`, and a pane's process list is a few hundred
    /// bytes; this is sized so the common case is one call and the retry is genuinely rare.
    private static let initialCapacity = 4096

    /// The answer as bytes, or EMPTY when the door has none.
    ///
    /// Empty rather than `nil` because both list doors document that they never answer nothing: a
    /// pane whose PTY is gone encodes a zero-count list, and that is a valid reply the client
    /// already renders.
    static func readData(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data {
        var out = [UInt8](repeating: 0, count: initialCapacity)
        var needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        }
        guard needed > 0, needed <= out.count else { return Data() }
        return Data(out[0..<needed])
    }

    /// The answer as UTF-8, or `nil` when the door has none — the shape for the doors where nothing
    /// is a real answer the caller must act on rather than render.
    static func read(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String? {
        let bytes = readData(call)
        guard !bytes.isEmpty else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
#endif
