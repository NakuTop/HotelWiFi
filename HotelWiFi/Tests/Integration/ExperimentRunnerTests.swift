import XCTest
@testable import HotelWiFiCore

private final class SimulatedExperiment {
    let backend = MemoryConfiguration(), journal = MemoryJournal()
    lazy var recovery = RecoveryCoordinator(backend: backend, journal: journal)
    var record: RecoveryRecord?
    var actions: [String] = []
    var windows: [MeasurementWindow]
    var failCollectionAt: Int?
    var collections = 0
    init(_ windows: [MeasurementWindow]) { self.windows = windows }
    func begin() throws {
        actions.append("begin")
        let r = try recovery.prepare(target: .init(serviceID:"test-service",field:.dnsServers), value:.strings(["1.1.1.1","1.0.0.1"]),context:knownContext(),uid:501,nonce:UUID().uuidString)
        record = r; _ = try recovery.arm(r.id); _ = try recovery.apply(r.id,gate:allowedGate()); _ = try recovery.verify(r.id)
    }
    func collect(_ label: String) throws -> MeasurementWindow {
        collections += 1; actions.append(label.contains("恢复 A") ? "A" : "B")
        if collections == failCollectionAt { throw HWError.budget }
        return windows.removeFirst()
    }
    func rollback() throws -> Bool {
        actions.append("rollback"); guard let record else { return true }
        return try recovery.rollback(record.id,reason:"experiment").configurationRestored
    }
    func commit() throws { actions.append("commit"); _ = try recovery.commit(record!.id) }
}
final class ExperimentRunnerTests: XCTestCase {
    func testSameProductionRunnerExecutesABABThenCommit() async throws {
        let a = window([1,1,1,1]), b = window([0.5,0.5,0.5,0.5]), io = SimulatedExperiment([b,a,b])
        let result = try await ExperimentRunner.run(original:a,policy:allowedPolicy(),budget:.init(),begin:io.begin,collect:io.collect,rollback:io.rollback,commit:io.commit)
        XCTAssertTrue(result.retained); XCTAssertEqual(io.actions,["begin","B","rollback","A","begin","B","commit"])
        XCTAssertEqual(io.journal.record?.phase,.committed)
    }
    func testFasterButLessReliableIsRestoredImmediately() async throws {
        let a = window([1,1,1,1]), b = window([0.1,0.1,0.1,0.1],failedAt:[3]), io = SimulatedExperiment([b])
        let result = try await ExperimentRunner.run(original:a,policy:allowedPolicy(),budget:.init(),begin:io.begin,collect:io.collect,rollback:io.rollback,commit:io.commit)
        XCTAssertFalse(result.retained); XCTAssertEqual(io.backend.value,.init(nil)); XCTAssertFalse(io.actions.contains("commit"))
        XCTAssertEqual(io.actions,["begin","B","rollback"])
    }
    func testLostRepeatBenefitRestoresAfterSecondExperiment() async throws {
        let a = window([1,1,1,1]), b = window([0.5,0.5,0.5,0.5]), io = SimulatedExperiment([b,a,a])
        let result = try await ExperimentRunner.run(original:a,policy:allowedPolicy(),budget:.init(),begin:io.begin,collect:io.collect,rollback:io.rollback,commit:io.commit)
        XCTAssertFalse(result.retained); XCTAssertEqual(io.backend.value,.init(nil)); XCTAssertEqual(io.actions.last,"rollback")
    }
    func testBudgetExhaustedDuringCandidateStillRollsBack() async {
        let a = window([1,1,1,1]), io = SimulatedExperiment([]); io.failCollectionAt = 1
        do {
            _ = try await ExperimentRunner.run(original:a,policy:allowedPolicy(),budget:.init(),begin:io.begin,collect:io.collect,rollback:io.rollback,commit:io.commit)
            XCTFail("must stop")
        } catch { XCTAssertEqual(io.backend.value,.init(nil)); XCTAssertEqual(io.actions,["begin","B","rollback"]) }
    }
    func testExhaustedBudgetCannotStartNewExperiment() async {
        let a = window([1,1,1,1]), io = SimulatedExperiment([]), budget = BudgetManager(bytes:1000); _ = budget.consume(1001)
        do {
            _ = try await ExperimentRunner.run(original:a,policy:allowedPolicy(),budget:budget,begin:io.begin,collect:io.collect,rollback:io.rollback,commit:io.commit)
            XCTFail("must stop")
        } catch { XCTAssertTrue(io.actions.isEmpty); XCTAssertEqual(io.backend.writes,0) }
    }
}
