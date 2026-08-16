import CSlopDeskFFI
import Foundation

/// One process inside a pane's foreground process group (herdr `ForegroundProcess`). The host's
/// OS probe fills these; the identification logic below is pure and testable.
public struct ForegroundJobProcess: Sendable, Equatable {
    public var pid: Int32
    /// The BSD comm name (bounded, may be truncated by the kernel).
    public var name: String
    /// argv[0] when recoverable (handles `process.title =` rewrites and login-shell `-` prefix).
    public var argv0: String?
    /// Full argv when recoverable.
    public var argv: [String]?
    /// Flat command line fallback when structured argv is not recoverable.
    public var cmdline: String?

    public init(pid: Int32, name: String, argv0: String? = nil, argv: [String]? = nil, cmdline: String? = nil) {
        self.pid = pid
        self.name = name
        self.argv0 = argv0
        self.argv = argv
        self.cmdline = cmdline
    }
}

/// A pane's foreground job: the group id plus every process in it (herdr `ForegroundJob`).
public struct ForegroundJob: Sendable, Equatable {
    public var processGroupID: Int32
    public var processes: [ForegroundJobProcess]

    public init(processGroupID: Int32, processes: [ForegroundJobProcess]) {
        self.processGroupID = processGroupID
        self.processes = processes
    }
}

/// Pure agent identification over a foreground job (herdr `identify_agent_in_job` +
/// `normalized_process_name` + the runtime-argv unwrap family, ported 1:1).
///
/// The one filesystem touch — resolving a multi-component path token through symlinks — is
/// injected so tests stay hermetic and the default only runs on the host probe path.
public enum AgentJobIdentifier {
    /// Resolves a path to its symlink target's basename, or nil. Injected for tests.
    public typealias SymlinkResolver = @Sendable (String) -> String?

    /// The default resolver: `realpath`, through the crate's own `canonicalize`. A token that does
    /// not exist, a permission error, a symlink loop and a non-UTF-8 target all answer `nil`, which
    /// is exactly the "this token names nothing I know" every caller already handles.
    ///
    /// `nil` here means "use the crate's resolver", which is why it is not a Swift closure: routing
    /// a filesystem touch back out through the callback would pay two boundary crossings per token
    /// to reach the same `realpath`.
    public static let defaultSymlinkResolver: SymlinkResolver? = nil

    /// Prefer the group leader; else scan every process, keep recognised agents, pick the highest
    /// `process_priority` (`rust/slopdesk-agent/src/job.rs`, strict `>` — first wins ties). Returns the agent plus
    /// the normalized name that identified it.
    ///
    /// The whole ladder — the runtime argv unwrap, the `cmd`/PowerShell forms, the known package
    /// paths, the command-text tokenizer — is `rust/slopdesk-agent::job` (docs/55).
    public static func identify(
        job: ForegroundJob,
        resolveSymlink: SymlinkResolver? = nil,
    ) -> (agent: AgentKind, name: String)? {
        withStagedJob(job) { handle in
            let index = withResolver(resolveSymlink) { resolve, context in
                Int(slopdesk_agent_job_identify(handle, resolve, context))
            }
            guard index >= 0 else { return nil }
            let all = AgentKind.allCases
            guard index < all.count else { return nil }
            return (all[all.index(all.startIndex, offsetBy: index)], answer(of: handle))
        }
    }

    // MARK: Staging

    /// Builds the job on a handle, runs `body`, and frees it — the staging half of docs/55 §4b.
    private static func withStagedJob<T>(_ job: ForegroundJob, _ body: (OpaquePointer) -> T) -> T {
        guard let handle = slopdesk_agent_job_new(job.processGroupID) else {
            preconditionFailure("slopdesk_agent_job_new returned null")
        }
        defer { slopdesk_agent_job_free(handle) }
        for process in job.processes {
            push(process, onto: handle)
        }
        return body(handle)
    }

    private static func push(_ process: ForegroundJobProcess, onto handle: OpaquePointer) {
        var blob: [UInt8] = []
        func span(_ text: String?) -> SlopDeskAgentSpan {
            guard let text else { return SlopDeskAgentSpan(offset: 0, len: 0, present: false) }
            let offset = blob.count
            blob.append(contentsOf: text.utf8)
            return SlopDeskAgentSpan(offset: offset, len: blob.count - offset, present: true)
        }
        let name = span(process.name)
        let argv0 = span(process.argv0)
        let cmdline = span(process.cmdline)
        blob.withUnsafeMutableBufferPointer { buffer in
            slopdesk_agent_job_push_process(
                handle, process.pid, name, argv0, cmdline, buffer.baseAddress, buffer.count,
            )
        }
        // argv rides separately: it starts ABSENT and becomes a list on the first push, which is
        // what keeps "no argv" distinguishable from "an empty argv" across the boundary.
        for argument in process.argv ?? [] {
            var bytes = Array(argument.utf8)
            bytes.withUnsafeMutableBufferPointer { buffer in
                slopdesk_agent_job_push_argv(handle, buffer.baseAddress, buffer.count)
            }
        }
    }

    private static func answer(of handle: OpaquePointer) -> String {
        var out = [UInt8](repeating: 0, count: 512)
        var needed = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_agent_job_answer(handle, buffer.baseAddress, buffer.count)
        }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_agent_job_answer(handle, buffer.baseAddress, buffer.count)
            }
        }
        guard needed > 0, needed <= out.count else { return "" }
        return String(bytes: out[0..<needed], encoding: .utf8) ?? ""
    }

    // MARK: The resolver, crossing back the other way

    /// Boxes an injected resolver so the crate can call it, or passes null so the crate uses its own
    /// `realpath`. The box lives for exactly `body`, which is exactly how long the crate may call it.
    private static func withResolver<T>(
        _ resolver: SymlinkResolver?,
        _ body: (slopdesk_agent_resolve_fn?, UnsafeMutableRawPointer?) -> T,
    ) -> T {
        guard let resolver else { return body(nil, nil) }
        let box = ResolverBox(resolver)
        return withExtendedLifetime(box) {
            body(resolveTrampoline, Unmanaged.passUnretained(box).toOpaque())
        }
    }
}

/// The injected resolver, as something a `void *` can name.
private final class ResolverBox {
    let resolve: AgentJobIdentifier.SymlinkResolver
    init(_ resolve: @escaping AgentJobIdentifier.SymlinkResolver) { self.resolve = resolve }
}

/// The C entry point the crate calls per token. Answers 0 for "nothing", the needed length
/// otherwise — §4's convention, inverted.
private func resolveTrampoline(
    _ context: UnsafeMutableRawPointer?,
    _ token: UnsafePointer<UInt8>?,
    _ tokenLength: Int,
    _ out: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int,
) -> Int {
    guard let context else { return 0 }
    let box = Unmanaged<ResolverBox>.fromOpaque(context).takeUnretainedValue()
    let text =
        if let token, tokenLength > 0 {
            String(bytes: UnsafeBufferPointer(start: token, count: tokenLength), encoding: .utf8) ?? ""
        } else {
            ""
        }
    guard let answer = box.resolve(text) else { return 0 }
    let bytes = Array(answer.utf8)
    guard !bytes.isEmpty else { return 0 }
    // Over capacity writes NOTHING and asks to be called again — a partial basename would be a
    // different program's name.
    guard bytes.count <= capacity, let out else { return bytes.count }
    out.update(from: bytes, count: bytes.count)
    return bytes.count
}
