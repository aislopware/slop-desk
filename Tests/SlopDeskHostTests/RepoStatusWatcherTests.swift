import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The event-driven git-status source behind wire type 35 — driven ENTIRELY through the seams
/// (fake event sources, stubbed probe, captured pushes): no FSEvents stream, no git subprocess, no
/// filesystem beyond nothing at all (`isRepoRoot` is injected). Pins the refcount lifecycle (one
/// stream per repo across N panes; the LAST owner leaving cancels it), the debounce (a burst costs
/// one probe), the dirty-guard (porcelain-identical output pushes nothing), the probe gate (no
/// client → no subprocess), and re-key/shutdown teardown.
final class RepoStatusWatcherTests: XCTestCase {
    /// Lock-guarded harness state shared with the watcher's @Sendable seam closures.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _created: [String] = []
        private var _cancelled: [String] = []
        private var _fires: [String: @Sendable () -> Void] = [:]
        private var _computes: [String] = []
        private var _pushes: [WireMessage.ProjectGitStatus] = []
        var status: WireMessage.ProjectGitStatus?
        var probeGateOpen = true
        /// When set, `compute` parks on this until signalled — the "slow git subprocess" stand-in
        /// (safe: compute runs on the watcher's concurrent probe queue, never its control queue).
        var computeHold: DispatchSemaphore?

        func makeSource(
            _ path: String, _: DispatchQueue, _ onEvent: @escaping @Sendable () -> Void,
        ) -> RepoStatusWatcher.SourceHandle? {
            lock.lock()
            _created.append(path)
            _fires[path] = onEvent
            lock.unlock()
            return RepoStatusWatcher.SourceHandle { [self] in
                lock.lock()
                _cancelled.append(path)
                _fires[path] = nil
                lock.unlock()
            }
        }

        func compute(_ path: String) -> WireMessage.ProjectGitStatus? {
            lock.lock()
            _computes.append(path)
            let hold = computeHold
            let result = status
            lock.unlock()
            hold?.wait()
            return result
        }

        func pushed(_ status: WireMessage.ProjectGitStatus) {
            lock.lock()
            _pushes.append(status)
            lock.unlock()
        }

        func fire(_ path: String) {
            lock.lock()
            let fire = _fires[path]
            lock.unlock()
            fire?()
        }

        var created: [String] { lock.lock()
            defer { lock.unlock() }
            return _created
        }

        var cancelled: [String] { lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }

        var computes: [String] { lock.lock()
            defer { lock.unlock() }
            return _computes
        }

        var pushes: [WireMessage.ProjectGitStatus] { lock.lock()
            defer { lock.unlock() }
            return _pushes
        }
    }

    private func makeStatus(branch: String = "main", modified: UInt32 = 1) -> WireMessage.ProjectGitStatus {
        WireMessage.ProjectGitStatus(
            repoRoot: "/repo", branch: branch, ahead: 0, behind: 0, stashCount: 0,
            staged: 0, modified: modified, untracked: 0, conflicted: 0, changedCount: modified,
        )
    }

    /// A watcher over the harness seams; `debounce` kept tiny so the async settle stays fast.
    private func makeWatcher(_ harness: Harness, repos: Set<String> = ["/repo"]) -> RepoStatusWatcher {
        let watcher = RepoStatusWatcher(
            debounce: 0.02,
            isRepoRoot: { repos.contains($0) },
            computeStatus: { harness.compute($0) },
            makeEventSource: { harness.makeSource($0, $1, $2) },
        )
        watcher.push = { harness.pushed($0) }
        watcher.shouldProbe = { [weak harness] in harness?.probeGateOpen ?? false }
        return watcher
    }

    /// Polls (bounded) until `condition` holds — the watcher settles its serial queue + debounce.
    private func settle(_ condition: () -> Bool) {
        for _ in 0..<200 where !condition() {
            usleep(5000)
        }
        XCTAssertTrue(condition(), "the watcher did not settle in time")
    }

    func testNonRepoKeyNeverCreatesASource() {
        let harness = Harness()
        let watcher = makeWatcher(harness)
        watcher.noteProjectKey("/scratch", owner: ObjectIdentifier(self)) // a plain-dir section
        watcher.noteProjectKey("/repo", owner: ObjectIdentifier(harness))
        settle { harness.created == ["/repo"] }
        XCTAssertEqual(harness.created, ["/repo"], "only a repo toplevel is ever FSEvents-watched")
    }

    func testOwnersShareOneSourceAndLastDropCancels() {
        let harness = Harness()
        harness.status = makeStatus()
        let watcher = makeWatcher(harness)
        let ownerA = ObjectIdentifier(self)
        let ownerB = ObjectIdentifier(harness)
        watcher.noteProjectKey("/repo", owner: ownerA)
        watcher.noteProjectKey("/repo", owner: ownerB)
        settle { harness.created.count == 1 }

        watcher.dropOwner(ownerA)
        harness.fire("/repo") // the surviving owner keeps the stream hot
        settle { harness.pushes.count == 1 }
        XCTAssertTrue(harness.cancelled.isEmpty, "a non-last drop keeps the shared stream")

        watcher.dropOwner(ownerB)
        settle { harness.cancelled == ["/repo"] }
        harness.fire("/repo") // a late event on the (already-cancelled) source probes nothing
        usleep(60000)
        XCTAssertEqual(harness.pushes.count, 1, "no probe after the last owner left")
    }

    func testEventBurstDebouncesToOneProbeAndPush() {
        let harness = Harness()
        harness.status = makeStatus()
        let watcher = makeWatcher(harness)
        watcher.noteProjectKey("/repo", owner: ObjectIdentifier(self))
        settle { harness.created.count == 1 }
        harness.fire("/repo")
        harness.fire("/repo")
        harness.fire("/repo")
        settle { harness.pushes.count == 1 }
        usleep(60000) // past another debounce window — nothing else may land
        XCTAssertEqual(harness.computes, ["/repo"], "a burst costs exactly one probe")
        XCTAssertEqual(harness.pushes, [makeStatus()], "and exactly one push")
    }

    func testUnchangedStatusIsNotRePushed() {
        let harness = Harness()
        harness.status = makeStatus()
        let watcher = makeWatcher(harness)
        watcher.noteProjectKey("/repo", owner: ObjectIdentifier(self))
        settle { harness.created.count == 1 }
        harness.fire("/repo")
        settle { harness.pushes.count == 1 }

        harness.fire("/repo") // object-db churn: porcelain-identical output
        settle { harness.computes.count == 2 }
        usleep(30000)
        XCTAssertEqual(harness.pushes.count, 1, "identical status is dirty-guarded — no client wake")

        harness.status = makeStatus(modified: 2) // a REAL change
        harness.fire("/repo")
        settle { harness.pushes.count == 2 }
        XCTAssertEqual(harness.pushes.last, makeStatus(modified: 2))
    }

    /// A SLOW probe (the wedged-mount / hanging-hook shape) must not freeze the CONTROL plane:
    /// while one repo's compute is parked, another repo's stream still gets created and the parked
    /// repo's later events coalesce into exactly ONE follow-up probe after it returns (its output
    /// may predate them — never zero, never a stack of subprocesses).
    func testSlowProbeNeverBlocksControlAndRearmsOnce() {
        let harness = Harness()
        harness.status = makeStatus()
        let hold = DispatchSemaphore(value: 0)
        harness.computeHold = hold
        let watcher = makeWatcher(harness, repos: ["/repo", "/other"])
        watcher.noteProjectKey("/repo", owner: ObjectIdentifier(self))
        settle { harness.created == ["/repo"] }
        harness.fire("/repo")
        settle { harness.computes.count == 1 } // the probe is now PARKED on `hold`

        // Control plane stays live while the probe hangs: a new repo's stream is created.
        watcher.noteProjectKey("/other", owner: ObjectIdentifier(harness))
        settle { harness.created == ["/repo", "/other"] }

        // Events during the in-flight probe: no stacked subprocess, one re-arm after it returns.
        harness.fire("/repo")
        harness.fire("/repo")
        usleep(60000)
        XCTAssertEqual(harness.computes.count, 1, "no second subprocess while one is in flight")
        harness.computeHold = nil
        hold.signal() // the wedged probe returns
        settle { harness.computes.count == 2 } // exactly one follow-up
        settle { harness.pushes.count == 1 } // identical status → the follow-up is dirty-guarded
        usleep(60000)
        XCTAssertEqual(harness.computes.count, 2, "the re-arm fires once, not per buffered event")
    }

    func testRekeyReleasesThePriorRepo() {
        let harness = Harness()
        let watcher = makeWatcher(harness, repos: ["/repo", "/other"])
        let owner = ObjectIdentifier(self)
        watcher.noteProjectKey("/repo", owner: owner)
        settle { harness.created == ["/repo"] }
        watcher.noteProjectKey("/other", owner: owner) // the pane cd'd into a different repo
        settle { harness.created == ["/repo", "/other"] && harness.cancelled == ["/repo"] }
    }

    func testClosedProbeGateSkipsTheSubprocess() {
        let harness = Harness()
        harness.status = makeStatus()
        harness.probeGateOpen = false // no client attached
        let watcher = makeWatcher(harness)
        watcher.noteProjectKey("/repo", owner: ObjectIdentifier(self))
        settle { harness.created.count == 1 }
        harness.fire("/repo")
        usleep(60000)
        XCTAssertTrue(harness.computes.isEmpty, "no audience ⇒ no git subprocess")
        XCTAssertTrue(harness.pushes.isEmpty)
    }

    func testShutdownCancelsEverything() {
        let harness = Harness()
        let watcher = makeWatcher(harness, repos: ["/repo", "/other"])
        watcher.noteProjectKey("/repo", owner: ObjectIdentifier(self))
        watcher.noteProjectKey("/other", owner: ObjectIdentifier(harness))
        settle { harness.created.count == 2 }
        watcher.shutdown()
        settle { Set(harness.cancelled) == ["/repo", "/other"] }
        watcher.noteProjectKey("/repo", owner: ObjectIdentifier(self)) // post-shutdown: refused
        usleep(30000)
        XCTAssertEqual(harness.created.count, 2, "a stopped watcher creates nothing")
    }
}
