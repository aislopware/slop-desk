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

    /// The default resolver: `FileManager`-free `realpath` (never traps, nil on failure).
    public static let defaultSymlinkResolver: SymlinkResolver = { token in
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            let typed = raw.bindMemory(to: CChar.self)
            return realpath(token, typed.baseAddress) != nil
        }
        guard ok else { return nil }
        guard let resolved = String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8) else {
            return nil
        }
        let base = AgentKind.pathBasename(resolved)
        return base.isEmpty ? nil : base
    }

    /// herdr `identify_agent_in_job`: prefer the group leader; else scan every process, keep
    /// recognized agents, pick the highest `processPriority` (strict `>` — first wins ties).
    /// Returns the agent plus the normalized name that identified it.
    public static func identify(
        job: ForegroundJob,
        resolveSymlink: SymlinkResolver? = nil,
    ) -> (agent: AgentKind, name: String)? {
        let resolver = resolveSymlink ?? defaultSymlinkResolver
        if let leader = job.processes.first(where: { $0.pid == job.processGroupID }) {
            let name = normalizedProcessName(leader, resolveSymlink: resolver)
            if let agent = AgentKind.identify(processName: name) {
                return (agent, name)
            }
        }

        var best: (agent: AgentKind, name: String, priority: UInt8)?
        for process in job.processes {
            let name = normalizedProcessName(process, resolveSymlink: resolver)
            guard let agent = AgentKind.identify(processName: name) else { continue }
            let priority = processPriority(process, normalizedName: name)
            if let current = best, current.priority >= priority { continue }
            best = (agent, name, priority)
        }
        return best.map { ($0.agent, $0.name) }
    }

    /// herdr `normalized_process_name`: argv0-over-comm, runtime unwrap, direct match,
    /// argv0/cmdline path fallbacks — in that exact order.
    public static func normalizedProcessName(
        _ process: ForegroundJobProcess,
        resolveSymlink: SymlinkResolver? = nil,
    ) -> String {
        let resolver = resolveSymlink ?? defaultSymlinkResolver
        let effective = process.argv0 ?? process.name
        let lowerEffective = effective.lowercased()

        if AgentKind.isGenericRuntimeOrShell(lowerEffective),
           let wrapped = wrappedAgentName(runtime: lowerEffective, argv: process.argv, resolveSymlink: resolver)
        {
            return wrapped
        }

        if AgentKind.identify(processName: effective) != nil {
            return effective
        }

        if let wrapped = process.argv?.first.flatMap({ agentName(fromPathToken: $0, resolveSymlink: resolver) }) {
            return wrapped
        }
        if let first = (process.cmdline ?? "").split(whereSeparator: \.isWhitespace).first,
           let wrapped = agentName(fromPathToken: String(first), resolveSymlink: resolver)
        {
            return wrapped
        }

        return effective
    }

    /// herdr `process_priority`: 3 = unwrapped from a runtime/script, 2 = the literal agent
    /// binary, 1 = anything else.
    public static func processPriority(_ process: ForegroundJobProcess, normalizedName: String) -> UInt8 {
        let lowerName = normalizedName.lowercased()
        if lowerName != process.name.lowercased() { return 3 }
        if !AgentKind.isGenericRuntimeOrShell(lowerName) { return 2 }
        return 1
    }

    // MARK: - Runtime argv unwrapping (herdr wrapped_agent_name_from_runtime_argv family)

    static func wrappedAgentName(
        runtime: String,
        argv: [String]?,
        resolveSymlink: SymlinkResolver,
    ) -> String? {
        guard let argv else { return nil }
        switch AgentKind.normalizedLookupName(AgentKind.pathBasename(runtime)) {
        case "node",
             "bun":
            return scriptArgAgentName(
                argv,
                evalFlags: ["-e", "--eval", "-p", "--print"],
                moduleFlags: [],
                resolveSymlink: resolveSymlink,
            )
        case "python",
             "python3":
            return scriptArgAgentName(argv, evalFlags: ["-c"], moduleFlags: ["-m"], resolveSymlink: resolveSymlink)
        case "sh",
             "bash",
             "zsh",
             "fish":
            return scriptArgAgentName(argv, evalFlags: ["-c"], moduleFlags: [], resolveSymlink: resolveSymlink)
        case "cmd":
            return windowsCmdArgAgentName(argv, resolveSymlink: resolveSymlink)
        case "powershell",
             "pwsh":
            return powershellArgAgentName(argv, resolveSymlink: resolveSymlink)
        default:
            return nil
        }
    }

    /// herdr `script_arg_agent_name`: walk argv past option flags to the first positional
    /// (script path) token; an eval/module flag bails IMMEDIATELY — a `-c`/`-e` command's
    /// trailing args are never trusted as an agent path.
    static func scriptArgAgentName(
        _ argv: [String],
        evalFlags: [String],
        moduleFlags: [String],
        resolveSymlink: SymlinkResolver,
    ) -> String? {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            index += 1
            if arg == "--" {
                guard index < argv.count else { return nil }
                return agentName(fromPathToken: argv[index], resolveSymlink: resolveSymlink)
            }
            if flagMatches(arg, evalFlags) || flagMatches(arg, moduleFlags) { return nil }
            if arg.hasPrefix("-") {
                if optionTakesValue(arg) { index += 1 }
                continue
            }
            return agentName(fromPathToken: arg, resolveSymlink: resolveSymlink)
        }
        return nil
    }

    static func flagMatches(_ arg: String, _ flags: [String]) -> Bool {
        flags.contains { flag in
            if arg == flag { return true }
            // Short-flag glued payload (`-eSCRIPT`).
            if flag.hasPrefix("-"), !flag.hasPrefix("--"), arg.hasPrefix(flag), arg.count > flag.count {
                return true
            }
            // Long-flag `=` value (`--eval=…`).
            if flag.hasPrefix("--"), arg.hasPrefix(flag + "=") { return true }
            return false
        }
    }

    static func optionTakesValue(_ arg: String) -> Bool {
        switch arg {
        case "-r",
             "--require",
             "--loader",
             "--import",
             "--experimental-loader",
             "--inspect-port",
             "-W",
             "-X",
             "-S",
             "-L",
             "-o":
            true
        default:
            false
        }
    }

    static func windowsCmdArgAgentName(_ argv: [String], resolveSymlink: SymlinkResolver) -> String? {
        var index = 1
        while index < argv.count {
            let flag = argv[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
            index += 1
            switch flag {
            case "/c",
                 "/k":
                guard index < argv.count else { return nil }
                return commandTextAgentName(argv[index], resolveSymlink: resolveSymlink)
            case "/d",
                 "/s",
                 "/q",
                 "/a",
                 "/u",
                 "/e:on",
                 "/e:off",
                 "/f:on",
                 "/f:off",
                 "/v:on",
                 "/v:off":
                continue
            default:
                continue
            }
        }
        return nil
    }

    static func powershellArgAgentName(_ argv: [String], resolveSymlink: SymlinkResolver) -> String? {
        var index = 1
        while index < argv.count {
            let raw = argv[index]
            let flag = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
            index += 1
            switch flag {
            case "-file",
                 "-f",
                 "/file":
                guard index < argv.count else { return nil }
                return agentName(fromPathToken: argv[index], resolveSymlink: resolveSymlink)
            case "-command",
                 "-c",
                 "/command",
                 "/c":
                guard index < argv.count else { return nil }
                return commandTextAgentName(argv[index], resolveSymlink: resolveSymlink)
            case "-encodedcommand",
                 "-enc",
                 "/encodedcommand",
                 "/enc":
                return nil
            case "-configurationname",
                 "-executionpolicy",
                 "-outputformat",
                 "-psconsolefile",
                 "-version",
                 "-windowstyle",
                 "-workingdirectory":
                index += 1
            default:
                if flag.hasPrefix("-") || flag.hasPrefix("/") { continue }
                return agentName(fromPathToken: raw, resolveSymlink: resolveSymlink)
            }
        }
        return nil
    }

    /// herdr `command_text_agent_name`: first shell-ish token of a command string, skipping
    /// `&` / `.` / `call` invokers.
    static func commandTextAgentName(_ command: String, resolveSymlink: SymlinkResolver) -> String? {
        var rest = Substring(command)
        while let (token, next) = commandTextToken(rest) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.caseInsensitiveCompare("&") == .orderedSame
                || trimmed.caseInsensitiveCompare(".") == .orderedSame
                || trimmed.caseInsensitiveCompare("call") == .orderedSame
            {
                rest = next
                continue
            }
            return agentName(fromPathToken: trimmed, resolveSymlink: resolveSymlink)
        }
        return nil
    }

    static func commandTextToken(_ input: Substring) -> (String, Substring)? {
        let trimmed = input.drop(while: \.isWhitespace)
        guard let first = trimmed.first else { return nil }
        if first == "\"" || first == "'" {
            let body = trimmed.dropFirst()
            if let end = body.firstIndex(of: first) {
                return (String(body[body.startIndex..<end]), body[body.index(after: end)...])
            }
            return (String(body), Substring(""))
        }
        let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        return (String(trimmed[trimmed.startIndex..<end]), trimmed[end...])
    }

    // MARK: - Path token resolution (herdr agent_name_from_path_token)

    /// Basename match → known-package sniff → symlink resolution, in that order.
    static func agentName(fromPathToken token: String, resolveSymlink: SymlinkResolver) -> String? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if trimmed.isEmpty || trimmed.hasPrefix("-") { return nil }

        if let direct = agentName(fromBasename: AgentKind.pathBasename(trimmed)) { return direct }
        if let packaged = agentName(fromKnownPackagePath: trimmed) { return packaged }

        // Symlink resolution only for multi-component paths (a bare word never touches the fs).
        let componentCount = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).count
        let isAbsolute = trimmed.hasPrefix("/") || trimmed.hasPrefix("\\")
        guard componentCount >= 2 || (isAbsolute && componentCount >= 1) else { return nil }
        guard let resolvedBase = resolveSymlink(trimmed) else { return nil }
        return agentName(fromBasename: resolvedBase)
    }

    static func agentName(fromBasename basename: String) -> String? {
        AgentKind.identify(processName: basename)?.label
    }

    /// herdr `agent_name_from_known_package_path`: the pi coding agent's npm dist layout.
    static func agentName(fromKnownPackagePath path: String) -> String? {
        let components = path
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { AgentKind.normalizedLookupName(String($0)) }
        let needle = ["node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli"]
        guard components.count >= needle.count else { return nil }
        for start in 0...(components.count - needle.count)
            where Array(components[start..<start + needle.count]) == needle
        {
            return AgentKind.pi.label
        }
        return nil
    }
}
