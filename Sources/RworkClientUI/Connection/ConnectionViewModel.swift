import Foundation
import RworkClient

/// Orchestrates a ``RworkClient`` + ``ReconnectManager`` for the UI: host/port entry,
/// connect/disconnect, and a live status the chrome renders.
///
/// It owns the connect lifecycle so the views stay declarative:
/// - ``connect()`` stands up the client, starts the reconnect supervisor, kicks off the
///   ``TerminalViewModel`` stream observation, and flips status to `.connecting` → (on first
///   byte) `.connected`.
/// - ``disconnect()`` is a *deliberate* close (distinct from a network drop): it closes the
///   client and stops the supervisor so no reconnect is attempted.
///
/// `@MainActor @Observable`: bound directly to ``ConnectionView``. The terminal byte handling
/// is delegated to the injected ``TerminalViewModel`` (one source of truth for live state).
@MainActor
@Observable
public final class ConnectionViewModel {
    /// What the UI shows for the connection (mirrors + extends the terminal status with the
    /// "deliberately disconnected" distinction the terminal model can't make on its own).
    public enum Status: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(String)

        public var label: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .reconnecting: return "reconnecting"
            case .failed(let m): return "failed: \(m)"
            }
        }
    }

    // MARK: Entry fields (bound to the form)

    public var host: String
    public var port: String

    // MARK: Observable status

    public private(set) var status: Status = .disconnected
    public private(set) var sessionID: UUID?
    /// Last log line from the reconnect supervisor (surfaced in the UI for diagnostics).
    public private(set) var lastLog: String?

    // MARK: Collaborators

    private let terminal: TerminalViewModel
    private let makeClient: @Sendable () -> RworkClient
    private let backoff: ReconnectManager.Backoff

    private var client: RworkClient?
    private var reconnect: ReconnectManager?
    private var supervisorTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    /// True between a deliberate ``disconnect()`` and the next ``connect()`` so a trailing
    /// `.disconnected` event is not mis-read as a drop to reconnect.
    private var deliberatelyClosed = false

    public init(
        terminal: TerminalViewModel,
        host: String = "127.0.0.1",
        port: UInt16 = 7420,
        backoff: ReconnectManager.Backoff = .init(),
        makeClient: @escaping @Sendable () -> RworkClient = { RworkClient() }
    ) {
        self.terminal = terminal
        self.host = host
        self.port = String(port)
        self.backoff = backoff
        self.makeClient = makeClient
    }

    /// The terminal view-model (so the view can pass it to ``TerminalScreenView``).
    public var terminalModel: TerminalViewModel { terminal }

    /// The live client (so the input bar can `sendInput`). `nil` while disconnected.
    public var activeClient: RworkClient? { client }

    /// Whether the host/port form parses to a valid endpoint.
    public var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && parsedPort != nil
    }

    private var parsedPort: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }

    // MARK: Lifecycle

    /// Connects to the entered host/port, starts reconnect supervision + stream observation.
    public func connect() async {
        guard let port = parsedPort else {
            status = .failed("invalid port")
            return
        }
        let host = self.host.trimmingCharacters(in: .whitespaces)

        // Tear down any prior session first (re-connect to a new target).
        await teardown()
        deliberatelyClosed = false
        terminal.reset()
        status = .connecting

        let client = makeClient()
        self.client = client

        // Watch the client's events at the connection level so a non-deliberate drop flips
        // the chrome to "reconnecting" and a clean exit is reflected.
        observeEvents(client)
        observeTask = Task { @MainActor [weak self] in
            await self?.terminal.observe(client: client)
        }

        // Reconnect supervisor: drives byte-exact resumes on a drop.
        let manager = ReconnectManager(client: client, backoff: backoff) { [weak self] line in
            Task { @MainActor in self?.lastLog = line }
        }
        self.reconnect = manager

        do {
            try await client.connect(host: host, port: port)
            sessionID = await client.sessionID
            status = .connected
            supervisorTask = manager.start(host: host, port: port)
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// A deliberate disconnect: close the client + stop the supervisor (no reconnect).
    public func disconnect() async {
        deliberatelyClosed = true
        await teardown()
        status = .disconnected
        terminal.reset()
    }

    /// iOS lifecycle: app backgrounded → proactively pause the client (host retains the tail).
    public func pause() async {
        await client?.pause()
    }

    /// iOS lifecycle: app foregrounded → byte-exact resume.
    public func resume() async {
        do {
            try await client?.resume()
            status = .connected
        } catch {
            status = .failed(String(describing: error))
        }
    }

    // MARK: Internals

    /// Mirrors connection-relevant client events into the chrome status. The terminal model
    /// folds the same stream for its own state; here we only need the connect/drop signal.
    private func observeEvents(_ client: RworkClient) {
        Task { @MainActor [weak self] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case .disconnected:
                    if self.deliberatelyClosed {
                        self.status = .disconnected
                    } else {
                        self.status = .reconnecting
                        self.terminal.markReconnecting()
                    }
                case let .reconnected(sessionID, _):
                    self.sessionID = sessionID
                    self.status = .connected
                case .exit:
                    self.status = .disconnected
                case .title, .bell:
                    break
                }
            }
        }
    }

    private func teardown() async {
        supervisorTask?.cancel()
        observeTask?.cancel()
        supervisorTask = nil
        observeTask = nil
        await client?.close()
        client = nil
        reconnect = nil
    }
}
