import XCTest
import ServiceManagement
@testable import HotelWiFiCore

final class ConnectionDiagnosisTests: XCTestCase {
    let facts = LocalConnectionFacts(location: .denied, associated: true, nameReadable: false, dhcp: true, dnsCount: 1)
    func reconnectPolicy() -> OptimizationPolicy { var p = allowedPolicy(); p.allowReconnect = true; return p }
    func report(_ testSamples: [ProbeSample], validated: Bool = false) -> SessionReport {
        var r = SessionReport(mode: "fixture"); r.current = knownContext(); r.localAfter = facts
        r.windows = [.init(label: "最终当前连接复测", context: knownContext(), samples: testSamples)]
        if validated { r.currentValidatedAt = Date() }; return r
    }
    func testServiceReregistrationRequiresConfirmedSpawnFailureAndNoPID() {
        let failed = "last exit code = 78: EX_CONFIG\njob state = spawn failed"
        XCTAssertTrue(HelperDiagnostics.canRepairRegistration(failed))
        XCTAssertFalse(HelperDiagnostics.canRepairRegistration(failed + "\npid = 123"))
        XCTAssertFalse(HelperDiagnostics.canRepairRegistration(failed + "\nstate = running"))
        XCTAssertFalse(HelperDiagnostics.canRepairRegistration("state = unknown"))
        XCTAssertFalse(HelperDiagnostics.canRepairRegistration(nil))
    }
    func testLocationAuthorizationStateMapping() {
        XCTAssertEqual(LocationAccess.from(.notDetermined), .notRequested)
        XCTAssertEqual(LocationAccess.from(.denied), .denied)
        XCTAssertEqual(LocationAccess.from(.restricted), .restricted)
        XCTAssertEqual(LocationAccess.from(.authorizedAlways), .authorized)
    }
    func testDeniedNameIsExplainedAndDoesNotStopApplicationTests() {
        let c = knownContext()
        XCTAssertTrue(DiagnosisBuilder.shouldProbe(c, facts))
        let d = DiagnosisBuilder.diagnose(context: c, facts: facts)
        XCTAssertTrue(d.findings.contains { $0.id == "name" && $0.detail.contains("被拒绝") && $0.action == .locationSettings })
        XCTAssertFalse(d.findings.contains { $0.id == "association" })
    }
    func testAuthorizedButHiddenNameDoesNotFalselyAskForPermission() {
        var f = facts; f.location = .authorized
        XCTAssertTrue(f.location.explanation.contains("仍未返回"))
        XCTAssertFalse(f.location.explanation.contains("被拒绝"))
        let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: f)
        XCTAssertEqual(d.findings.first(where: { $0.id == "name" })?.action, .refreshStatus)
    }
    func testNamePermissionActionMatchesActualAuthorizationState() {
        for (access, expected) in [(LocationAccess.notRequested, SupportAction.locationPermission), (.denied, .locationSettings),
                                   (.restricted, .locationSettings), (.servicesOff, .locationSettings), (.unknown, .locationSettings)] {
            var f = facts; f.location = access
            let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: f)
            XCTAssertEqual(d.findings.first(where: { $0.id == "name" })?.action, expected)
        }
    }
    func testForegroundAuthorizationDoesNotPromiseDaemonIdentity() {
        var f = facts; f.location = .authorized; f.nameReadable = true
        let reconnect = NetworkInspector.reconnectCapability(nameReadable: true, helperReady: true, helperIdentityReadable: false)
        XCTAssertEqual(reconnect.state, .unavailable)
        let c = CapabilityRegistry(osVersion: "fixture", capabilities: [.init("helper", .available, "ready"), reconnect])
        let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: f, capabilities: c, policy: reconnectPolicy())
        XCTAssertFalse(d.findings.contains { $0.id == "name" })
        let issue = d.findings.first { $0.id == "associationPermission" }
        XCTAssertEqual(issue?.title, "名称已读取，自动重连暂不可用")
        XCTAssertEqual(issue?.action, .refreshStatus)
        XCTAssertEqual(issue?.secondaryAction, .networkSettings)
        XCTAssertFalse(d.findings.contains { $0.action == .locationPermission || $0.action == .locationSettings })
    }
    func testFreshAvailableBackendClearsEarlierAssociationFinding() {
        var f = facts; f.location = .authorized; f.nameReadable = true
        func diagnostic(_ readable: Bool) -> ConnectionDiagnosis {
            let reconnect = NetworkInspector.reconnectCapability(nameReadable: true, helperReady: true, helperIdentityReadable: readable)
            return DiagnosisBuilder.diagnose(context: knownContext(), facts: f,
                capabilities: .init(osVersion: "fixture", capabilities: [.init("helper", .available, "ready"), reconnect]), policy: reconnectPolicy())
        }
        XCTAssertTrue(diagnostic(false).findings.contains { $0.id == "associationPermission" })
        XCTAssertFalse(diagnostic(true).findings.contains { $0.id == "associationPermission" })
    }
    func testMissingBackendIdentityIsUnknownNotDeniedPermission() {
        XCTAssertEqual(NetworkInspector.reconnectCapability(nameReadable: true, helperReady: true, helperIdentityReadable: nil).state, .unknown)
        XCTAssertEqual(NetworkInspector.reconnectCapability(nameReadable: true, helperReady: false, helperIdentityReadable: true).state, .unavailable)
        XCTAssertEqual(NetworkInspector.reconnectCapability(nameReadable: false, helperReady: true, helperIdentityReadable: true).state, .unknown)
    }
    func testUnavailableForegroundNameDoesNotCreateDuplicateBackendPermissionAction() {
        let c = CapabilityRegistry(osVersion: "fixture", capabilities: [.init("helper", .available, "ready"),
            NetworkInspector.reconnectCapability(nameReadable: false, helperReady: true, helperIdentityReadable: false)])
        let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: facts, capabilities: c, policy: reconnectPolicy())
        XCTAssertEqual(d.findings.filter { $0.action == .locationSettings }.count, 1)
        XCTAssertFalse(d.findings.contains { $0.id == "associationPermission" })
    }
    func testPowerOffAndDisconnectedAreDifferentFromPrivacyRestriction() {
        var c = knownContext(); c.wifiOn = false
        XCTAssertEqual(DiagnosisBuilder.name(ssid: nil, context: c, facts: facts), "WiFi 已关闭")
        XCTAssertFalse(DiagnosisBuilder.shouldProbe(c, facts))
        c.wifiOn = true; var f = facts; f.associated = false
        XCTAssertEqual(DiagnosisBuilder.name(ssid: nil, context: c, facts: f), "尚未连接 WiFi")
        XCTAssertFalse(DiagnosisBuilder.shouldProbe(c, f))
    }
    func testIPv6OnlyHealthyDoesNotDiagnoseDHCPFailure() {
        var c = knownContext(); c.hasIPv4 = false
        let r = report(samples([1,1,1,1]), validated: true)
        let d = DiagnosisBuilder.diagnose(context: c, facts: facts, report: r)
        XCTAssertTrue(d.title.contains("可用")); XCTAssertFalse(d.findings.contains { $0.id == "address" })
        XCTAssertTrue(DiagnosisBuilder.shouldProbe(c, facts))
    }
    func testBothAddressesMissingDiagnosesOfflineLocalFault() {
        var c = knownContext(); c.hasIPv4 = false; c.hasIPv6 = false
        let d = DiagnosisBuilder.diagnose(context: c, facts: facts)
        XCTAssertEqual(d.findings.first?.id, "address")
        XCTAssertTrue(d.explanation.contains("DHCP"))
    }
    func testOneProviderFailureDoesNotDeclareWholeNetworkDown() {
        let r = report(samples([1,1,1,1], failedAt: [1,3]))
        let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: facts, report: r)
        XCTAssertTrue(d.findings.contains { $0.id == "endpoints" })
        XCTAssertFalse(d.findings.contains { $0.id == "internet" })
    }
    func testHTTP200TimeoutIsFailureRatherThanPortalOrHealthy() {
        let r = report(samples([1,1,1,1], failedAt: [0,1,2,3], failure: .timeout))
        let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: facts, report: r)
        XCTAssertTrue(d.findings.contains { $0.id == "internet" && $0.detail.contains("超时") })
        XCTAssertFalse(d.findings.contains { $0.id == "portal" || $0.id == "application" })
    }
    func testPortalResponseIsASuggestionNotConfirmedCause() {
        let r = report(samples([1,1,1,1], failedAt: [0,1,2,3], failure: .redirect))
        let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: facts, report: r)
        XCTAssertTrue(d.findings.contains { $0.id == "portal" && $0.detail.contains("可能") })
    }
    func testNativeProxyFailureRemainsDistinctFromDirectSuccess() {
        var c = knownContext(); c.proxy.manual = true
        var r = report(samples([1,1,1,1], failedAt: [0,1,2,3])); r.windows[0].samples += samples([0.1,0.1], path: .direct)
        let d = DiagnosisBuilder.diagnose(context: c, facts: facts, report: r)
        XCTAssertTrue(d.findings.contains { $0.id == "proxy" }); XCTAssertFalse(d.title.contains("无需"))
    }
    func testRegisteredSpawnFailedIsNotReportedAsReadyOrUnapproved() {
        let detail = HelperDiagnostics.detail(ready: false, message: "timeout", registration: .enabled, launchText: "state = spawn scheduled\nlast exit code = 78: EX_CONFIG")
        XCTAssertTrue(detail.contains("启动失败")); XCTAssertFalse(detail.contains("尚未批准"))
        let d = DiagnosisBuilder.diagnose(context: knownContext(), facts: facts,
            capabilities: .init(osVersion: "fixture", capabilities: [.init("helper", .unavailable, detail)]))
        XCTAssertTrue(d.findings.contains { $0.id == "helper" && $0.action == .repairHelper })
    }
    func testApprovedRegistryWithoutHandshakeDoesNotDeclareHelperReady() {
        let detail = HelperDiagnostics.detail(ready: false, message: "timeout", registration: .enabled, launchText: nil)
        XCTAssertTrue(detail.contains("未收到有效响应"))
    }
    func testLaunchConstraintFailureIsExplainedWithoutClaimingPermissionDenied() {
        let detail = HelperDiagnostics.detail(ready: false, message: "timeout", registration: .enabled,
            launchText: "job state = spawn failed\nlast exit code = 78: EX_CONFIG\nproperties = needs LWCR update | has LWCR")
        XCTAssertTrue(detail.contains("启动签名约束")); XCTAssertFalse(detail.contains("尚未批准"))
    }
    func testJobIdentifierAcceptsOnlyPackagedHelperGenerations() {
        let valid = "com.hotelwifi.RecoveryGuardian." + String(repeating: "a", count: 24)
        XCTAssertEqual(HotelWiFiService.validatedJobIdentifier(valid), valid)
        for value in ["com.apple.service", valid + "/other", "../" + valid, String(repeating: "a", count: 24), valid + "\n"] {
            XCTAssertNil(HotelWiFiService.validatedJobIdentifier(value))
        }
        XCTAssertNil(HotelWiFiService.validatedJobIdentifier(nil))
    }
    func testComparisonOnlyUsesMatchingProviderAndObject() {
        var r = report(samples([0.1,0.2]), validated: true)
        r.windows.insert(.init(label: "baseline", context: knownContext(), samples: samples([1,2])), at: 0)
        XCTAssertEqual(EndpointComparison.from(r).count, 2)
        r.windows[1].samples[0].kind = .bandwidth
        XCTAssertEqual(EndpointComparison.from(r).map(\.id), ["endpoint-b"])
    }
    func testCopiedReportHasActualErrorsAndRedactsNetworkIdentity() {
        var r = report(samples([2,2], failedAt: [0,1]))
        r.windows[0].samples[0].errorDomain = NSURLErrorDomain; r.windows[0].samples[0].errorCode = -1001
        r.current?.serviceName = "secret-hotel"; r.current?.serviceID = "secret-service"
        let text = ReportBuilder.supportText(r)
        XCTAssertTrue(text.contains("-1001")); XCTAssertTrue(text.contains("denied"))
        XCTAssertFalse(text.contains("secret-hotel")); XCTAssertFalse(text.contains("secret-service")); XCTAssertFalse(text.contains("hotel-network-session"))
    }
    func testPolicyStorageDoesNotCreateReportFile() throws {
        let url = URL(fileURLWithPath: "/private/tmp/HotelWiFi-Diagnosis-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = try SecureStore(directory: url), settings = SettingsStore(store: storage)
        try settings.savePolicy(allowedPolicy())
        XCTAssertEqual(try settings.policy(), allowedPolicy())
        XCTAssertNil(try storage.read("history.json"))
    }
}
final class BaselineCollectorTests: XCTestCase {
    func testOfflineSkipsObjectsAndRetainsTwoProvidersForRecovery() async throws {
        var calls = 0
        let result = try await BaselineCollector.collect(endpoints: ProbeEndpoint.defaults, count: 3) { endpoints, count, timeout, label in
            calls += 1; XCTAssertEqual(endpoints.count, 2); XCTAssertEqual(count, 3); XCTAssertEqual(timeout, 3)
            let failed = samples([3,3,3,3,3,3], failedAt: [0,1,2,3,4,5])
            return .init(label: label, context: knownContext(), samples: failed)
        }
        XCTAssertEqual(calls, 1); XCTAssertTrue(result.skippedObjects)
        XCTAssertTrue(result.comparisonEndpoints.allSatisfy { $0.kind == .connectivity })
        XCTAssertTrue(LinkIntent(.reconnect, baseline: result.window.samples).repeatedFailure)
    }
    func testHealthyConnectionMeasuresFixedObjectsAfterConnectivity() async throws {
        var kinds: [ProbeKind] = []
        let result = try await BaselineCollector.collect(endpoints: ProbeEndpoint.defaults, count: 3) { endpoints, count, timeout, label in
            kinds += endpoints.map(\.kind)
            return .init(label: label, context: knownContext(), samples: samples([0.1,0.2,0.1,0.2]))
        }
        XCTAssertEqual(kinds, [.connectivity,.connectivity,.object]); XCTAssertFalse(result.skippedObjects)
        XCTAssertEqual(result.window.samples.count, 8)
    }
    func testEndpointFailureDoesNotWasteTimeDownloadingObjects() async throws {
        let result = try await BaselineCollector.collect(endpoints: ProbeEndpoint.defaults, count: 3) { endpoints, _, _, label in
            XCTAssertEqual(endpoints.count, 2)
            return .init(label: label, context: knownContext(), samples: samples([1,1,1,1], failedAt: [1,3]))
        }
        XCTAssertTrue(result.skippedObjects)
        XCTAssertFalse(LinkIntent(.reconnect, baseline: result.window.samples).repeatedFailure)
    }
}
