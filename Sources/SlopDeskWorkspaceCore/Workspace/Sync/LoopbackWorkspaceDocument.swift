import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel

/// A workspace document that lives in this process and answers on the caller's turn.
///
/// The same shape as `HostWorkspaceDocument` — install a state, serve intents, publish what changed —
/// with the actor and the socket taken out. It exists for the callers that cannot suspend: a
/// synchronous mutator, a headless harness, a test that has to read the result on its next line.
///
/// **It is not a second implementation of the workspace.** The decision is
/// ``WorkspaceIntentApplier``, the same pure function the host runs; the frames go out through
/// `WorkspaceStateCodec` and come back in through ``HostWorkspaceMirror/apply(kind:epoch:baseStateNum:newStateNum:payload:)``,
/// the same entry point a socket frame takes. What is reproduced here is only the ~30 lines of
/// versioning around the decision, and ``LoopbackWorkspaceDocumentTests`` pins those against the real
/// host byte for byte, because that is precisely the part a suite running only one of the two cannot
/// see drift in.
///
/// **Nothing installs one by default.** Production builds its channel through
/// ``WorkspaceStore/liveWorkspaceChannel(box:muxRegistry:target:clientKind:label:)``, which has no
/// document — a client that can rewrite its own workspace with no host is the locally-owned tree the
/// workspace document exists to replace, and it must stay something a caller asks for out loud.
@preconcurrency
@MainActor
public final class LoopbackWorkspaceDocument {
    /// The mirror this document publishes into. Public because the loopback channel client is built
    /// around the same box, and one box is the whole invariant.
    public let box: WorkspaceMirrorBox

    /// Identity of THIS document. Minted here unless ``adopt(pristine:)`` takes over a seeded mirror,
    /// which keeps the seed's epoch so its diffs are based on something the mirror holds.
    public private(set) var epoch: UUID

    /// Monotone, and bumped ONLY when the state actually changed — the host's rule, for the host's
    /// reason: a no-op costs every subscriber a frame.
    public private(set) var stateNum: Int64 = 0

    /// Whether this document is still exactly what was minted for a first run. Read by
    /// ``WorkspaceIntentOp/adoptWorkspace`` and nothing else.
    public private(set) var isPristine = true

    private var state = HostWorkspaceState()

    public init(box: WorkspaceMirrorBox, epoch: UUID = UUID()) {
        self.box = box
        self.epoch = epoch
    }

    /// The document as a value. Read-only; the only way to change it is through this object.
    public var snapshot: HostWorkspaceState { state }

    /// The topology half, or `nil` before one is installed.
    public var topology: WorkspaceTopology? { state.topology }

    /// Whether an intent can be served at all. `false` with no topology, which is the one state where
    /// every mutation is a silent no-op.
    public var canMutate: Bool { state.topology != nil }

    // MARK: - Installing

    /// Installs the workspace this document starts with and publishes it as a kind-0 snapshot.
    ///
    /// A snapshot rather than a diff because the mirror has nothing to base one on, and it travels
    /// through the real `encodeSnapshot`/`decodeSnapshot` pair so a state the codec cannot carry fails
    /// here rather than on hardware.
    public func install(_ restored: HostWorkspaceState, pristine: Bool = false) {
        state = restored
        isPristine = pristine
        stateNum &+= 1
        box.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeSnapshot(state),
        )
    }

    /// Takes over whatever the mirror already holds, publishing nothing.
    ///
    /// The entry point for a store, whose `seedWorkspaceMirror(from:cache:)` has already put the
    /// restored tree and the cached per-pane facts in `entries`. Re-publishing them would churn every
    /// observer for a document that did not change, and minting a fresh epoch over the seed's would
    /// throw away everything scoped by it.
    ///
    /// - Returns: `false` when the mirror holds no document to adopt — there is nothing to be
    ///   authoritative about, and inventing an epoch would make the next diff unbasable.
    @discardableResult
    public func adopt(pristine: Bool = false) -> Bool {
        guard let seeded = box.mirror.epoch else { return false }
        epoch = seeded
        stateNum = box.mirror.stateNum
        state = box.mirror.entries
        isPristine = pristine
        return true
    }

    // MARK: - Intents

    /// Applies one intent and publishes the answer, in the order the wire produces it.
    ///
    /// **Result first, document frame second.** That is what `WorkspaceChannelSession.drain` does —
    /// it writes every queued `intentResult` before the state frame — and the client's retirement rule
    /// depends on it: an `applied` result arms its optimistic patch at `framesApplied + 1`, so the diff
    /// immediately behind retires the patch in the same turn. Publishing the diff first would leave one
    /// inert patch shadowing host truth until some later intent happened to sweep it.
    @discardableResult
    public func serve(_ intent: WorkspaceIntent) -> WorkspaceIntentStatus {
        let status = decide(op: intent.op, args: intent.args)
        deliver(WorkspaceIntentResult(intentID: intent.intentID, status: status.verdict))
        if let next = status.next { publish(next) }
        return status.verdict
    }

    private func decide(op: UInt8, args: Data) -> (verdict: WorkspaceIntentStatus, next: HostWorkspaceState?) {
        // No workspace to change. Distinguished from a refusal on the merits so a caller can tell
        // "you asked about a document that is not there" from "the document says no".
        guard let current = state.topology else { return (.rejectedNotFound, nil) }
        let outcome = WorkspaceIntentApplier.apply(
            op: op, args: args, to: current, documentIsPristine: isPristine,
            projectKey: { [state] in state.projectKey(forPane: $0) },
        )
        guard let accepted = outcome.topology else { return (Self.status(for: outcome), nil) }
        // The bootstrap is the one op that may not run twice, so ANY accepted intent ends pristine —
        // including one that changed nothing.
        isPristine = false
        var next = state
        next.write(topology: accepted)
        return (.applied, next)
    }

    private static func status(for outcome: WorkspaceIntentOutcome) -> WorkspaceIntentStatus {
        switch outcome {
        case .applied: .applied
        case .rejectedStale: .rejectedStale
        case .rejectedInvalid: .rejectedInvalid
        case .rejectedNotFound: .rejectedNotFound
        case .unknownOp: .unknownOp
        }
    }

    // MARK: - Direct edits

    /// Applies an arbitrary edit and publishes iff it changed anything — the reconciler's edge, and
    /// the shape every liveness write takes.
    ///
    /// The change test is on the VALUE, not on whether the closure ran: `HostWorkspaceState` is
    /// `Equatable` precisely so a caller cannot accidentally version a no-op.
    @discardableResult
    public func mutate(_ body: (inout HostWorkspaceState) -> Void) -> Bool {
        var next = state
        body(&next)
        return publish(next)
    }

    /// Replaces one pane's liveness fields, leaving its topology fields untouched.
    @discardableResult
    public func merge(paneLiveness record: PaneLiveness) -> Bool {
        mutate { $0.merge(paneLiveness: record) }
    }

    /// Deletes a pane OBJECT — every field, topology included.
    @discardableResult
    public func removePane(_ paneID: UUID) -> Bool {
        mutate { $0.removeObject(kind: WorkspaceObjectKind.pane.rawValue, objectID: paneID) }
    }

    // MARK: - Publishing

    /// Versions `next` and publishes the diff that carries the mirror to it.
    ///
    /// Deliberately encodes and decodes rather than assigning the value across: every mutation this
    /// document serves therefore proves the codec can carry its own effect, which is the failure a
    /// value-passing loopback would hide until a real host tried to send it.
    @discardableResult
    private func publish(_ next: HostWorkspaceState) -> Bool {
        guard next != state else { return false }
        let diff = next.diff(from: state)
        let base = stateNum
        state = next
        stateNum &+= 1
        box.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: epoch,
            baseStateNum: base,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeDiff(diff),
        )
        return true
    }

    /// Folds one verdict in and repaints — the client's own `.intentResult` handling, verbatim.
    ///
    /// No `expirePending` sweep alongside it, unlike the frame path. This document answers on the
    /// turn it is asked, so nothing of its own can time out; sweeping here could only ever drop a
    /// patch some OTHER producer staged, on a clock this object does not have.
    private func deliver(_ result: WorkspaceIntentResult) {
        box.apply(
            kind: WorkspaceEventKind.intentResult.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: 0,
            payload: result.encode(),
        )
        box.notePendingChanged()
    }
}
