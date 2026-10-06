import XCTest
import Security
@testable import HotelWiFiCore

private final class MemoryLinkJournal: LinkJournalPersistence {
    var record: LinkRecord?
    var savedPlan: LinkPlan?
    var saves = 0
    var failAt: Int?
    func load() throws -> LinkRecord? { record }
    func save(_ r: LinkRecord) throws { saves += 1; if failAt == saves { throw HWError.storage("disk full") }; record = r }
    func savePlan(_ p: LinkPlan, id: UUID) throws { savedPlan = p }
    func plan(id: UUID) throws -> LinkPlan { guard let savedPlan else { throw HWError.storage("lost secret") }; return savedPlan }
}
final class LinkRecoveryTests: XCTestCase {
    private func fixture(_ action: LinkAction = .associate) throws -> (LinkRecoveryCoordinator, MemoryLinkJournal, LinkRecord, LinkPlan) {
        let j = MemoryLinkJournal(), c = LinkRecoveryCoordinator(journal: j)
        let original = AssociationSnapshot(interface: "test-wifi", serviceID: "test-service", ssid: Data("Original hotel".utf8), bssid: "original-ap", security: 4, configurationDigest: "original-config")
        var target = original
        if action == .associate { target.ssid = Data("Candidate hotel".utf8); target.bssid = "target-ap" }
        let p = LinkPlan(action: action, original: original, target: target)
        let r = try c.prepare(plan: p, context: knownContext(), uid: 501, nonce: UUID().uuidString)
        return (c,j,r,p)
    }
    private func gate(_ operation: OperationKind = .associate) -> GateInput {
        var g = allowedGate(operation: operation); g.policy.allowReconnect = true; g.policy.allowSavedNetworks = true
        g.policy.linkRecovery = .init(); g.policy.linkRecovery?.allowDHCPRenew = true; g.policy.linkRecovery?.allowIdleInterruption = true
        g.candidateAuthorized = true; g.recoveryAssociationReady = true; return g
    }
    private func observation(_ snapshot: AssociationSnapshot, power: Bool? = true, address: Bool = true) -> LinkObservation {
        .init(wifiOn: power, ssid: snapshot.ssid, bssid: snapshot.bssid, configurationDigest: snapshot.configurationDigest, hasUsableAddress: address)
    }
    func testLocalCertificateTrustIsPinnedAndDoesNotAcceptArbitraryIdentifiers() throws {
        let trust = try XCTUnwrap(CodeSigningTrust(team: nil, certificateSHA1: String(repeating: "a",count:40), certificateName: "HotelWiFi Local fixture"))
        let text = try XCTUnwrap(trust.requirement(identifiers: ["com.hotelwifi.app","com.hotelwifi.cli"]))
        XCTAssertTrue(text.contains("anchor = H")); XCTAssertFalse(text.contains("anchor trusted"))
        var r: SecRequirement?; XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &r),errSecSuccess)
        XCTAssertNil(trust.requirement(identifiers: ["com.attacker.anything"]))
        XCTAssertNil(CodeSigningTrust(team: nil, certificateSHA1: nil, certificateName: nil))
        XCTAssertNil(CodeSigningTrust(team: nil, certificateSHA1: "bad\" or true", certificateName: "HotelWiFi Local x"))
        XCTAssertNil(CodeSigningTrust(team: nil, certificateSHA1: String(repeating:"a",count:40), certificateName:"Unrelated Local Signing"))
    }
    func testOldPolicyDecodesWithRecoveryOptInsOff() throws {
        let data = try JSONCoding.encoder.encode(OptimizationPolicy())
        var d = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]); d.removeValue(forKey:"linkRecovery")
        let p = try JSONCoding.decoder.decode(OptimizationPolicy.self,from:JSONSerialization.data(withJSONObject:d))
        XCTAssertNil(p.linkRecovery); XCTAssertFalse(p.allowReconnect); XCTAssertFalse(p.allowSavedNetworks)
    }
    func testHealthyApplicationNeverTriggersAuthorizedReconnect() {
        var g = gate(.reconnect); g.health = .healthy
        XCTAssertNotNil(OperationGate.rejection(g))
        g.health = .failed; g.importantTraffic = nil; XCTAssertNotNil(OperationGate.rejection(g))
        g.importantTraffic = true; XCTAssertNotNil(OperationGate.rejection(g))
        g.importantTraffic = false; XCTAssertNil(OperationGate.rejection(g))
    }
    func testDHCPCanRepairMissingAddressButNotManualOrIPv6Healthy() {
        var g = gate(.dhcpRenew); g.context.hasIPv4 = false; g.context.hasIPv6 = false; g.context.hasRoute = false
        g.dhcpConfigured = true; g.addressFault = true; XCTAssertNil(OperationGate.rejection(g))
        g.context.hasIPv6 = true; XCTAssertNotNil(OperationGate.rejection(g))
        g.context.hasIPv6 = false; g.dhcpConfigured = false; XCTAssertNotNil(OperationGate.rejection(g))
        g.dhcpConfigured = true; g.policy.linkRecovery?.allowDHCPRenew = false; XCTAssertNotNil(OperationGate.rejection(g))
    }
    func testUnknownOrUnapprovedSavedNetworkIsRejected() {
        var g = gate(); g.candidateAuthorized = false; XCTAssertNotNil(OperationGate.rejection(g))
        g.candidateAuthorized = true; g.policy.allowSavedNetworks = false; XCTAssertNotNil(OperationGate.rejection(g))
        g.policy.allowSavedNetworks = true; g.recoveryAssociationReady = false; XCTAssertNotNil(OperationGate.rejection(g))
    }
    func testPortalTLSAndSingleFailureCannotTriggerRadioRecovery() {
        let failures = samples([1,1,1,1],failedAt:[0,1,2,3])
        XCTAssertTrue(LinkIntent(.reconnect,baseline:failures).repeatedFailure)
        for reason in [ProbeFailure.tls,.body,.redirect,.http] {
            XCTAssertFalse(LinkIntent(.reconnect,baseline:samples([1,1,1,1],failedAt:[0,1,2,3],failure:reason)).repeatedFailure)
        }
        XCTAssertFalse(LinkIntent(.reconnect,baseline:Array(failures.prefix(1))).repeatedFailure)
        XCTAssertFalse(LinkIntent(.reconnect,baseline:samples([1,1,1,1],path:.direct)).repeatedFailure)
    }
    func testDurableArmIsRequiredAndDiskFailurePreventsApply() throws {
        let (c,j,r,_) = try fixture()
        XCTAssertThrowsError(try c.beginApply(r.id,gate:gate()))
        j.failAt = j.saves+1; XCTAssertThrowsError(try c.arm(r.id))
        XCTAssertEqual(j.record?.phase,.prepared)
        j.failAt = nil; _ = try c.arm(r.id)
        j.failAt = j.saves+1; XCTAssertThrowsError(try c.beginApply(r.id,gate:gate()))
        XCTAssertEqual(j.record?.phase,.armed)
    }
    func testCrashAfterApplyAllowsOnlyOneOriginalNetworkRequest() throws {
        let (c,j,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate())
        let restarted = LinkRecoveryCoordinator(journal:j)
        let original = try restarted.beginRestore(r.id,observation:observation(p.target),startup:true)
        XCTAssertEqual(original,p.original); XCTAssertEqual(j.record?.restoreAttempts,1)
        XCTAssertNil(try restarted.beginRestore(r.id,observation:observation(p.target),startup:true))
        XCTAssertEqual(j.record?.phase,.conflict)
    }
    func testUserSwitchesNetworkOrTurnsOffWiFiNoReassociation() throws {
        for off in [false,true] {
            let (c,j,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate())
            var observed = observation(p.target,power:!off)
            if !off { observed.ssid = Data("Company".utf8) }
            XCTAssertNil(try c.beginRestore(r.id,observation:observed,startup:false))
            XCTAssertEqual(j.record?.phase,.conflict); XCTAssertFalse(j.record!.connectionReestablished)
        }
    }
    func testSameSSIDInAnotherLocationDoesNotRejoinOldHotel() throws {
        let (c,j,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate())
        var observed = observation(p.target); observed.bssid = "other-hotel-ap"
        XCTAssertNil(try c.beginRestore(r.id,observation:observed,startup:true)); XCTAssertEqual(j.record?.phase,.conflict)
    }
    func testDisconnectedAfterRestartWaitsInsteadOfTurningWiFiOn() throws {
        let (c,j,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate())
        var observed = observation(p.target,address:false); observed.ssid = nil; observed.bssid = nil
        XCTAssertNil(try c.beginRestore(r.id,observation:observed,startup:true)); XCTAssertEqual(j.record?.phase,.waiting)
        XCTAssertEqual(j.record?.restoreAttempts,0)
    }
    func testAPRequestIsObservedSeparatelyFromAssociationAndNeverLocked() throws {
        let (c,_,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate())
        var observed = observation(p.target); observed.bssid = "system-chose-another-ap"
        let result = try c.observe(r.id,observed)
        XCTAssertEqual(result.phase,.verifying); XCTAssertEqual(result.requestedAPObserved,false)
        XCTAssertFalse(result.applicationValidated)
        observed.bssid = nil; XCTAssertNil(try c.observe(r.id,observed).requestedAPObserved)
    }
    func testValidatedAssociationIsNotBrokenOnExitOrRestart() throws {
        let (c,j,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate()); _ = try c.observe(r.id,observation(p.target))
        let w = [window([0.2,0.3,0.2,0.3]),window([0.3,0.2,0.3,0.2])]
        let committed = try c.commit(r.id,windows:w); XCTAssertTrue(committed.terminal); XCTAssertTrue(committed.applicationValidated)
        XCTAssertNil(try LinkRecoveryCoordinator(journal:j).beginRestore(r.id,observation:observation(p.target),startup:true))
        XCTAssertEqual(j.record?.phase,.committed); XCTAssertEqual(j.record?.restoreAttempts,0)
    }
    func testSingleGoodWindowOrChangedNetworkCannotCommit() throws {
        let (c,_,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate()); _ = try c.observe(r.id,observation(p.target))
        let a = window([0.1,0.1,0.1,0.1]); XCTAssertThrowsError(try c.commit(r.id,windows:[a]))
        var b = a; b.context.identity = "different-hotel"; XCTAssertThrowsError(try c.commit(r.id,windows:[a,b]))
        b = window([0.1,0.1,0.1,0.1],failedAt:[1]); XCTAssertThrowsError(try c.commit(r.id,windows:[a,b]))
    }
    func testDHCPRecoveryNeverRestoresOldLeaseOrChangesMode() throws {
        let (c,j,r,p) = try fixture(.renewDHCP); _ = try c.arm(r.id)
        var g = gate(.dhcpRenew); g.dhcpConfigured = true; g.addressFault = true; g.context.hasIPv4 = false; g.context.hasIPv6 = false
        _ = try c.beginApply(r.id,gate:g)
        XCTAssertNil(try c.beginRestore(r.id,observation:observation(p.original,address:false),startup:true))
        XCTAssertTrue(j.record!.configurationRestored); XCTAssertFalse(j.record!.connectionReestablished); XCTAssertFalse(j.record!.applicationValidated)
    }
    func testUserEnablesVPNOrChangesConfigurationPreservesLaterOperation() throws {
        for vpn in [false,true] {
            let (c,j,r,p) = try fixture(); _ = try c.arm(r.id); _ = try c.beginApply(r.id,gate:gate())
            var observed = observation(p.target); if vpn { observed.protectedPathChanged = true } else { observed.configurationDigest = "new-config" }
            XCTAssertNil(try c.beginRestore(r.id,observation:observed,startup:false)); XCTAssertEqual(j.record?.phase,.conflict)
        }
    }
    func testEncryptedRecoveryMaterialsAndPublicStatusExcludeRawSSIDAndNonce() throws {
        let directory = URL(fileURLWithPath:"/private/tmp/HotelWiFiTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try SecureStore(directory:directory), journal = LinkJournal(store:store)
        let (_,_,r,p) = try fixture(); try journal.savePlan(p,id:r.id); try journal.save(r)
        XCTAssertEqual(try journal.plan(id:r.id).original,p.original)
        let sealed = try XCTUnwrap(store.read("link-plan.sealed")); XCTAssertNil(sealed.range(of:p.original.ssid))
        XCTAssertThrowsError(try journal.plan(id:UUID()))
        let publicData = try JSONCoding.encoder.encode(RecoveryStatusReport(.init(ok:true,message:"status",linkRecord:r)))
        XCTAssertNil(publicData.range(of:Data(r.nonce.utf8))); XCTAssertNil(publicData.range(of:p.original.ssid))
        try store.write(Data("broken".utf8),named:"link-recovery.json"); XCTAssertThrowsError(try journal.load())
    }
    func testOnlyOneLinkTransactionAndMaximumThreeRequests() throws {
        let (c,_,r,p) = try fixture()
        XCTAssertThrowsError(try c.prepare(plan:p,context:knownContext(),uid:501,nonce:r.nonce))
        let budget = BudgetManager(); try budget.takeLinkRequest(); try budget.takeLinkRequest(); try budget.takeLinkRequest()
        XCTAssertThrowsError(try budget.takeLinkRequest())
    }
    func testRapidPrepareAndApplyChecksKeepTrafficWarmupAndBlockNewTransfer() {
        var time = 0.0, bytes: UInt64 = 0
        let monitor = TrafficMonitor(clock: { time },counter: { _ in bytes })
        for t in [0.0,3.0,6.0,6.01,6.02] { time = t; monitor.sample(interface:"test-wifi") }
        var policy = allowedPolicy(); XCTAssertNil(monitor.importantTraffic(policy:policy))
        policy.linkRecovery = .init(); policy.linkRecovery?.allowIdleInterruption = true
        XCTAssertEqual(monitor.importantTraffic(policy:policy),false)
        time = 6.12; bytes = 100_000; monitor.sample(interface:"test-wifi")
        XCTAssertEqual(monitor.importantTraffic(policy:policy),true)
        time = 6.22; bytes = 0; monitor.sample(interface:"test-wifi")
        XCTAssertNil(monitor.importantTraffic(policy:policy))
    }
    func testOldFailureSamplesDoNotAuthorizeNewRadioRecovery() {
        let old = samples([1,1,1,1],failedAt:[0,1,2,3]).map { value -> ProbeSample in
            var s = value; s.completed = Date().addingTimeInterval(-181); return s
        }
        XCTAssertFalse(LinkIntent(.reconnect,baseline:old).repeatedFailure)
    }
    func testAnySuccessfulFreshRequestVetoesDisruptiveRecovery() {
        let current = samples([1,1,1,1],failedAt:[0,1,2])
        XCTAssertFalse(LinkIntent(.reconnect,baseline:current).repeatedFailure)
        var g = gate(.reconnect); g.health = SelectionPolicy.health(current)
        XCTAssertNotNil(OperationGate.rejection(g))
    }
}
