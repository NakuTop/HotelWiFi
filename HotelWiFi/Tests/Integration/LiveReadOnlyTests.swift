import XCTest
@testable import HotelWiFiCore

final class LiveReadOnlyTests: XCTestCase {
    func testControlledCurlReadsPublicFixedObjectsWithExplicitOptIn() async throws {
        guard ProcessInfo.processInfo.environment["HOTELWIFI_LIVE_READONLY"] == "1" else {
            throw XCTSkip("实机只读网络测试未启用；默认测试不访问外部端点。")
        }
        let probe = ControlledProbe(), budget = BudgetManager(bytes:262144,seconds:30)
        for e in [ProbeEndpoint.defaults[0],ProbeEndpoint.defaults[2]] {
            let sample = try await probe.run(e,path:.direct,budget:budget)
            XCTAssertTrue(sample.complete,"\(e.id): \(sample.failure?.rawValue ?? "unknown") exit=\(sample.exitCode ?? -1)")
            XCTAssertEqual(sample.status,200); XCTAssertEqual(sample.path,.direct); XCTAssertEqual(sample.viaProxy,false)
            XCTAssertGreaterThan(sample.bytes,0); XCTAssertNotNil(sample.times.total)
        }
        XCTAssertEqual(budget.bytes,68 + 10474)
    }
}
