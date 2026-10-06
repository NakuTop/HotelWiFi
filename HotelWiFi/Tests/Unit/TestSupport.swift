import Foundation
@testable import HotelWiFiCore

func knownContext() -> NetworkContext {
    var proxy = ProxySummary(); proxy.managed = false
    return .init(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, interface: "test-wifi", serviceID: "test-service",
                 identity: "hotel-network-session", apIdentity: "ap-1", confidence: .sessionOnly, wifiOn: true,
                 hasIPv4: true, hasIPv6: true, hasRoute: true, proxy: proxy, expensive: false,
                 radio: .init(rssi: -52, transmitMbps: 144, channel: 36, band: "5 GHz"), configurationDigest: "original-config")
}
func allowedPolicy() -> OptimizationPolicy {
    var p = OptimizationPolicy(); p.completedOnboarding = true; p.allowTemporaryDNS = true; p.allowControlledDirect = true; return p
}
func samples(_ times: [Double], failedAt: Set<Int> = [], failure: ProbeFailure = .timeout, path: ProbePath = .system) -> [ProbeSample] {
    times.enumerated().map { i, time in
        var s = ProbeSample(endpoint: i % 2 == 0 ? "endpoint-a" : "endpoint-b", provider: i % 2 == 0 ? "provider-a" : "provider-b", path: path)
        s.complete = !failedAt.contains(i); s.failure = s.complete ? nil : failure; s.status = 200
        s.times.total = time; s.bytes = 1024; s.reused = false; return s
    }
}
func window(_ times: [Double], failedAt: Set<Int> = [], context: NetworkContext = knownContext()) -> MeasurementWindow {
    .init(label: "fixture", context: context, samples: samples(times, failedAt: failedAt))
}
func allowedGate(operation: OperationKind = .dns) -> GateInput {
    .init(operation: operation, context: knownContext(), policy: allowedPolicy(), helperReady: true,
          snapshotSaved: true, guardianArmed: true, originalKnown: true, reproducibleEvidence: true, health: .failed, importantTraffic: false)
}
final class MemoryConfiguration: ConfigurationBackend {
    var value = FieldSnapshot(nil)
    var writes = 0
    var unavailable = false
    var beforeCAS: (() -> Void)?
    func read(_ target: FieldTarget) throws -> FieldSnapshot { if unavailable { throw HWError.blocked("service unavailable") }; return value }
    func compareAndSet(_ target: FieldTarget, expected: FieldSnapshot, desired: FieldSnapshot) throws {
        beforeCAS?(); beforeCAS = nil
        guard !unavailable, value == expected else { throw HWError.blocked("conflict") }; value = desired; writes += 1
    }
}
final class MemoryJournal: JournalPersistence {
    var record: RecoveryRecord?
    var writes = 0
    var failAt: Int?
    var corrupted = false
    func load() throws -> RecoveryRecord? { if corrupted { throw HWError.storage("corrupt") }; return record }
    func save(_ record: RecoveryRecord) throws { writes += 1; if failAt == writes { throw HWError.storage("disk full") }; self.record = record }
}
func prepared(_ backend: MemoryConfiguration, _ journal: MemoryJournal) throws -> (RecoveryCoordinator, RecoveryRecord) {
    let c = RecoveryCoordinator(backend: backend, journal: journal)
    let r = try c.prepare(target: .init(serviceID: "test-service", field: .dnsServers), value: .strings(["1.1.1.1", "1.0.0.1"]),
                          context: knownContext(), uid: 501, nonce: UUID().uuidString)
    return (c, r)
}
