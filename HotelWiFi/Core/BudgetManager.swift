import Foundation

/// One shared budget across native, DNS, curl, and experiment paths. Recovery never consumes this budget.
public final class BudgetManager: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    public let byteLimit: Int
    public let durationLimit: Double
    private var received = 0
    private var stopped = false
    private var requests = 0
    private var experiments = 0
    private var scans = 0
    private var dnsQueries = 0
    private var linkRequests = 0
    public init(bytes: Int = 30_000_000, seconds: Double = 180) { byteLimit = bytes; durationLimit = seconds }
    public var bytes: Int { lock.withLock { received } }
    public func stop() { lock.withLock { stopped = true } }
    public func startRequest(final: Bool = false) throws -> Double {
        try lock.withLock {
            let remaining = durationLimit - (ProcessInfo.processInfo.systemUptime - started)
            if stopped && !final { throw HWError.cancelled }
            let reserve = final ? 0 : min(24, durationLimit / 4)
            guard remaining > reserve, received < byteLimit - (final ? 0 : min(131_072, byteLimit/4)), requests < 120 else { throw HWError.budget }
            requests += 1
            return min(8, remaining - reserve)
        }
    }
    @discardableResult public func consume(_ count: Int, final: Bool = false) -> Bool {
        lock.withLock {
            received += max(0, count) // Include the actual chunk that crossed the boundary, even on cancellation.
            return received <= byteLimit && (final || !stopped)
        }
    }
    public func takeExperiment() throws {
        try lock.withLock {
            guard !stopped, experiments < 2, received < byteLimit - min(131_072, byteLimit/4),
                  durationLimit - (ProcessInfo.processInfo.systemUptime - started) > min(24, durationLimit/4) + 8 else { throw HWError.budget }
            experiments += 1
        }
    }
    public func takeScan() throws { try lock.withLock { guard !stopped, scans < 1 else { throw HWError.budget }; scans += 1 } }
    public func takeLinkRequest() throws {
        try lock.withLock {
            guard !stopped, linkRequests < 3, durationLimit - (ProcessInfo.processInfo.systemUptime-started) > 40,
                  received < byteLimit-min(131_072,byteLimit/4) else { throw HWError.budget }
            linkRequests += 1
        }
    }
    public func takeDNSQuery() throws { try lock.withLock { guard !stopped, dnsQueries < 12 else { throw HWError.budget }; dnsQueries += 1 } }
}
