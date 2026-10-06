import Foundation

/// Coalesce overlapping UI refreshes without dropping an authorization change.
/// Every caller waits for the final queued read, not an earlier stale snapshot.
@MainActor public final class StatusRefreshCoordinator {
    public private(set) var running = false
    private var queued = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func refresh(_ read: @MainActor () async -> Void) async {
        if running {
            queued = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        running = true
        repeat {
            queued = false
            await read()
        } while queued
        running = false
        let completed = waiters; waiters.removeAll()
        completed.forEach { $0.resume() }
    }
}
