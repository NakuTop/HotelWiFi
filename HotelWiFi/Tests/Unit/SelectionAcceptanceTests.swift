import XCTest
@testable import HotelWiFiCore

final class SelectionAcceptanceTests: XCTestCase {
    func testVPNOrProxyPathChangeInvalidatesCausalComparison() {
        let a = window([1,1,1,1]); var b = window([0.2,0.2,0.2,0.2]); b.context.vpnPresent = true
        XCTAssertFalse(SelectionPolicy.wins(baselines:[a,a],candidates:[b,b],policy:allowedPolicy()))
        b.context.vpnPresent = false; b.context.proxy.manual = true
        XCTAssertFalse(SelectionPolicy.wins(baselines:[a,a],candidates:[b,b],policy:allowedPolicy()))
    }
    func test85PercentICMPLossCannotOverride20SuccessfulHTTPSRequests() {
        // ICMP intentionally has no input to either health or selection.
        let s = samples(Array(repeating: 0.3, count: 20))
        XCTAssertEqual(SelectionPolicy.health(s), .healthy)
        var g = allowedGate(operation: .reconnect); g.health = .healthy; g.policy.allowReconnect = true
        XCTAssertNotNil(OperationGate.rejection(g))
    }
    func testStrongSignalDoesNotMakeFailedApplicationsHealthy() {
        var c = knownContext(); c.radio.rssi = -20
        let w = window([1,1,1,1], failedAt: [0,1,2,3], context: c)
        XCTAssertEqual(SelectionPolicy.health(w.samples), .failed)
    }
    func testCCADropWithoutApplicationImprovementIsNotAWinner() {
        var a = knownContext(), b = knownContext(); a.radio.cca = 72; b.radio.cca = 8
        XCTAssertFalse(SelectionPolicy.wins(baselines: [window([0.5,0.5,0.5,0.5], context: a), window([0.5,0.5,0.5,0.5], context: a)],
                                            candidates: [window([0.5,0.5,0.5,0.5], context: b), window([0.5,0.5,0.5,0.5], context: b)], policy: allowedPolicy()))
    }
    func testSingleZeroTransmitRateDoesNotTriggerReconnect() {
        var g = allowedGate(operation: .reconnect); g.context.radio.transmitMbps = 0; g.health = .healthy; g.policy.allowReconnect = true
        XCTAssertNotNil(OperationGate.rejection(g))
    }
    func testDirectCurlSuccessDoesNotCountAsSystemConnectivity() {
        let direct = samples([0.2,0.2,0.2,0.2], path: .direct)
        let system = samples([4,4,4,4], failedAt: [0,1,2,3])
        XCTAssertEqual(SelectionPolicy.health(direct), .insufficient)
        XCTAssertEqual(SelectionPolicy.health(direct + system), .failed)
    }
    func testMillisecondDNSDifferencesKeepOriginal() {
        let a = window([0.2,0.2,0.2,0.2]), b = window([0.197,0.197,0.197,0.197])
        XCTAssertFalse(SelectionPolicy.wins(baselines: [a,a], candidates: [b,b], policy: allowedPolicy()))
    }
    func testIPv6OnlyHealthyConnectionRejectsDHCPRepair() {
        var g = allowedGate(operation: .dhcpRenew); g.context.hasIPv4 = false; g.context.hasIPv6 = true; g.health = .healthy; g.policy.allowReconnect = true
        XCTAssertNotNil(OperationGate.rejection(g))
        XCTAssertEqual(SelectionPolicy.health(samples([0.2,0.2,0.2,0.2])), .healthy)
    }
    func testFasterCandidateWithMoreFailuresLoses() {
        let a = window([1,1,1,1]), b = window([0.1,0.1,0.1,0.1], failedAt: [3])
        XCTAssertFalse(SelectionPolicy.wins(baselines: [a,a], candidates: [b,b], policy: allowedPolicy()))
    }
    func testOneFastWindowWithoutRepeatLoses() {
        let a = window([1,1,1,1]), b = window([0.4,0.4,0.4,0.4])
        XCTAssertFalse(SelectionPolicy.wins(baselines: [a,a], candidates: [b,a], policy: allowedPolicy()))
        XCTAssertFalse(SelectionPolicy.wins(baselines: [a], candidates: [b], policy: allowedPolicy()))
    }
    func testRepeatedImprovementAboveBothThresholdsWins() {
        let a = window([1.0,1.1,1.02,1.08]), b = window([0.60,0.65,0.61,0.64])
        XCTAssertTrue(SelectionPolicy.wins(baselines: [a,a], candidates: [b,b], policy: allowedPolicy()))
    }
    func testNaturalVariationAndOneEndpointRegressionVetoWinner() {
        let a = window([0.4,0.4,1.6,1.6]), b = window([0.6,0.6,0.6,0.6])
        XCTAssertFalse(SelectionPolicy.wins(baselines: [a,a], candidates: [b,b], policy: allowedPolicy()))
        let c = window([1,1,1,1]), d = window([0.1,1.2,0.1,1.2])
        XCTAssertFalse(SelectionPolicy.wins(baselines: [c,c], candidates: [d,d], policy: allowedPolicy()))
    }
    func testDifferentObjectsAndWarmConnectionsAreNotComparable() {
        let a = window([1,1,1,1]); var b = window([0.2,0.2,0.2,0.2])
        b.samples[0].endpoint = "different-object"
        XCTAssertFalse(SelectionPolicy.wins(baselines: [a,a], candidates: [b,b], policy: allowedPolicy()))
        b = window([0.2,0.2,0.2,0.2]); b.samples[0].reused = true
        XCTAssertFalse(SelectionPolicy.wins(baselines: [a,a], candidates: [b,b], policy: allowedPolicy()))
    }
    func testSingleEndpointFailureIsNotWholeNetworkFailure() {
        XCTAssertEqual(SelectionPolicy.health(samples([0.2,4,0.2,4], failedAt: [1,3])), .endpointLimited)
    }
    func testSameSSIDIsNotEnoughToReuseAnotherHotelIdentity() {
        var c = knownContext(); c.identity = "different-hotel-evidence"
        XCTAssertFalse(knownContext().sameNetwork(as: c))
        c = knownContext(); c.apIdentity = "roamed-ap-2"
        XCTAssertTrue(knownContext().sameNetwork(as: c))
        c.identity = nil; XCTAssertFalse(knownContext().sameNetwork(as: c))
    }
    func testStatisticsUseMedianRangeMADAndActualFailures() {
        let stats = SampleStatistics(samples([0.1,0.2,0.3,9], failedAt: [3]))
        XCTAssertEqual(stats.successes, 3); XCTAssertEqual(stats.count, 4); XCTAssertEqual(stats.median, 0.2)
        XCTAssertEqual(stats.maximum, 0.3); XCTAssertEqual(stats.failures["timeout"], 1)
    }
}
