import Foundation

/// A free, dependency-free async timeout helper for tests.
///
/// Runs `body` and returns its value, or `nil` if it does not finish within
/// `timeout`. The losing branch is cancelled, so a body that respects
/// cancellation unwinds promptly; a body that ignores cancellation still leaves
/// this function the moment the timer wins (the orphaned task is detached from
/// the caller's wait), so a hung await NEVER wedges the test — it surfaces as a
/// `nil` the caller can turn into an attributable failure.
///
/// This is the HostServer-FREE twin of `HostServerE2ECase.withTimeout(_:_:)`:
/// the same mechanism, compiled into a target that links NO HostServer/PTY, so
/// `HostServerE2EGuardTests` can prove the ceiling works headlessly without ever
/// standing up the E2E machinery it protects.
func withTestTimeout<T: Sendable>(
    _ timeout: Duration,
    _ body: @escaping @Sendable () async -> T,
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask { try? await Task.sleep(for: timeout)
            return nil
        }
        // `group.next()` is `T??`; the `?? nil` flattens the double-optional to `T?`.
        // swiftlint:disable:next redundant_nil_coalescing
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
