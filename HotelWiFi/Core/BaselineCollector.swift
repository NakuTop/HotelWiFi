import Foundation

public struct BaselineResult: Sendable {
    public var window: MeasurementWindow
    public var comparisonEndpoints: [ProbeEndpoint]
    public var skippedObjects: Bool
}
public enum BaselineCollector {
    /// Connectivity precedes object downloads so an offline run retains time for local recovery.
    public static func collect(endpoints: [ProbeEndpoint], count: Int,
        measure: ([ProbeEndpoint], Int, Double, String) async throws -> MeasurementWindow) async throws -> BaselineResult {
        let connectivity = endpoints.filter { $0.kind == .connectivity }
        var first = try await measure(connectivity.isEmpty ? endpoints : connectivity, count, 3, "正在测量当前连接")
        if first.fullyHealthy && !connectivity.isEmpty {
            let objects = endpoints.filter { $0.kind != .connectivity }
            if !objects.isEmpty {
                let loaded = try await measure(objects, count, 8, "正在测量固定对象加载")
                first.samples += loaded.samples
            }
        } else if !connectivity.isEmpty {
            return .init(window: first, comparisonEndpoints: connectivity, skippedObjects: true)
        }
        return .init(window: first, comparisonEndpoints: endpoints, skippedObjects: false)
    }
}
