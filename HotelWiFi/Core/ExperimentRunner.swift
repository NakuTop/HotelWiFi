import Foundation

public struct ExperimentResult: Sendable {
    public var retained: Bool
    public var windows: [MeasurementWindow]
}
/// Dependency-injected orchestration; production and simulated fault tests execute this same A/B/A/B order.
public enum ExperimentRunner {
    public static func run(original: MeasurementWindow, policy: OptimizationPolicy, budget: BudgetManager,
                           begin: () async throws -> Void,
                           collect: (String) async throws -> MeasurementWindow,
                           rollback: () async throws -> Bool,
                           commit: () async throws -> Void) async throws -> ExperimentResult {
        var windows: [MeasurementWindow] = []
        var mayOwnWrite = false
        do {
            try budget.takeExperiment(); mayOwnWrite = true; try await begin()
            let b1 = try await collect("候选 B 第一次系统路径验证"); windows.append(b1)
            guard try await rollback() else { throw HWError.blocked("恢复存在外部冲突，停止后续实验。") }
            mayOwnWrite = false
            guard b1.fullyHealthy else { return .init(retained: false, windows: windows) }
            let a2 = try await collect("恢复 A 后复测"); windows.append(a2)
            try budget.takeExperiment(); mayOwnWrite = true; try await begin()
            let b2 = try await collect("候选 B 第二次系统路径验证"); windows.append(b2)
            if SelectionPolicy.wins(baselines: [original, a2], candidates: [b1, b2], policy: policy) {
                try await commit(); mayOwnWrite = false
                return .init(retained: true, windows: windows)
            }
            guard try await rollback() else { throw HWError.blocked("外部修改受到保护；配置恢复状态存在冲突。") }
            mayOwnWrite = false
            return .init(retained: false, windows: windows)
        } catch {
            if mayOwnWrite { _ = try? await rollback() }
            throw error
        }
    }
}
