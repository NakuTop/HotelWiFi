import XCTest
@testable import HotelWiFiCore

final class RadioOptimizationTests: XCTestCase {
    func snapshot(_ bssid: String = "a", ssid: Data = Data("hotel".utf8), digest: String = "config") -> AssociationSnapshot {
        .init(interface: "en0", serviceID: "wifi", ssid: ssid, bssid: bssid, security: 0, configurationDigest: digest)
    }
    func testOnlyActualTargetMayRestoreAndExternalChangesArePreserved() {
        let record = RadioRecord(nonce: "test", plan: .init(action: .associate, original: snapshot(), target: snapshot("b")))
        XCTAssertTrue(RadioOptimizationGate.mayRestore(record, current: snapshot("b"), wifiOn: true))
        XCTAssertFalse(RadioOptimizationGate.mayRestore(record, current: snapshot("c"), wifiOn: true))
        XCTAssertFalse(RadioOptimizationGate.mayRestore(record, current: snapshot("b", ssid: Data("other".utf8)), wifiOn: true))
        XCTAssertFalse(RadioOptimizationGate.mayRestore(record, current: snapshot("b", digest: "user-changed"), wifiOn: true))
        XCTAssertFalse(RadioOptimizationGate.mayRestore(record, current: snapshot("b"), wifiOn: false))
        XCTAssertFalse(RadioOptimizationGate.mayRestore(record, current: nil, wifiOn: true))
    }
    func testWeakOrSmallImprovementDoesNotCauseSwitch() {
        let current = AccessPointReading(current: true, rssi: -40, noise: -90, channel: 11, band: "2.4 GHz")
        let similar = AccessPointReading(current: false, rssi: -43, noise: -90, channel: 1, band: "2.4 GHz")
        let weak = AccessPointReading(current: false, rssi: -80, noise: -95, channel: 36, band: "5 GHz")
        XCTAssertFalse(RadioOptimizationGate.better(similar, than: current))
        XCTAssertFalse(RadioOptimizationGate.better(weak, than: current))
        let bad = AccessPointReading(current: true, rssi: -80, noise: -85, channel: 6, band: "2.4 GHz", neighbors: 8)
        XCTAssertTrue(RadioOptimizationGate.better(similar, than: bad))
    }
    func testCommitRequiresTwoRealWindowsAndExactAP() {
        let context = NetworkContext(interface: "en0", serviceID: "wifi", identity: "hotel", apIdentity: "AP-b", wifiOn: true)
        func window(ap: String = "AP-b", success: Bool = true) -> MeasurementWindow {
            var c = context; c.apIdentity = ap
            let samples = ["Apple", "Google"].map { provider -> ProbeSample in
                var s = ProbeSample(endpoint: provider, provider: provider, path: .system, kind: .connectivity)
                s.complete = success; if !success { s.failure = .timeout }; return s
            }
            return .init(label: "AP verification", context: c, samples: samples)
        }
        XCTAssertTrue(RadioOptimizationGate.validCommit([window(), window()], context: context))
        XCTAssertFalse(RadioOptimizationGate.validCommit([window()], context: context))
        XCTAssertFalse(RadioOptimizationGate.validCommit([window(), window(ap: "AP-c")], context: context))
        XCTAssertFalse(RadioOptimizationGate.validCommit([window(), window(success: false)], context: context))
    }
    func testRecoveryJournalEncryptsIdentitiesAndRejectsTampering() throws {
        let base = URL(fileURLWithPath: "/private/tmp/HotelWiFiRadioTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try SecureStore(directory: base), journal = RadioJournal(store: store)
        let record = RadioRecord(nonce: "nonce", plan: .init(action: .associate, original: snapshot(), target: snapshot("b")))
        try journal.save(record)
        XCTAssertEqual(try journal.load()?.id, record.id)
        let bytes = try XCTUnwrap(store.read("radio-recovery.sealed"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("hotel"))
        var tampered = bytes; tampered[0] ^= 1; try store.write(tampered, named: "radio-recovery.sealed")
        XCTAssertThrowsError(try journal.load())
    }
    func testLegacyPolicyDoesNotEnableNewNetworkWriterWithoutAuthorization() throws {
        let old = try JSONCoding.encoder.encode(OptimizationPolicy())
        XCTAssertNil(try JSONCoding.decoder.decode(OptimizationPolicy.self, from: old).allowAutomaticAP)
    }
    func testPrivilegedDisconnectRejectsWrongClientStaleRequestAndChangedInterface() {
        var policy = OptimizationPolicy(); policy.allowAutomaticAP = true
        let context = knownContext()
        let request = GuardianRequest(.disassociateForAP, transaction: UUID(), nonce: UUID().uuidString, context: context, policy: policy)
        XCTAssertTrue(RadioPrivilegeGate.permits(request, actual: context, managed: false, radioPeer: true))
        XCTAssertFalse(RadioPrivilegeGate.permits(request, actual: context, managed: false, radioPeer: false))
        XCTAssertFalse(RadioPrivilegeGate.permits(request, actual: context, managed: nil, radioPeer: true))
        XCTAssertFalse(RadioPrivilegeGate.permits(request, actual: context, managed: false, radioPeer: true, now: Date().addingTimeInterval(20)))
        var changed = context; changed.configurationDigest = "changed"
        XCTAssertFalse(RadioPrivilegeGate.permits(request, actual: changed, managed: false, radioPeer: true))
        changed = context; changed.interface = "en9"
        XCTAssertFalse(RadioPrivilegeGate.permits(request, actual: changed, managed: false, radioPeer: true))
    }
    func testPublicAgentReplyDoesNotExposeRecoveryMaterial() throws {
        let record = RadioRecord(nonce: "private-nonce", plan: .init(action: .associate, original: snapshot(), target: snapshot("b")))
        let response = RadioResponse(ok: true, message: "prepared", record: record)
        let text = String(decoding: try JSONCoding.encoder.encode(response), as: UTF8.self)
        XCTAssertFalse(text.contains("private-nonce")); XCTAssertFalse(text.contains("ssid")); XCTAssertFalse(text.contains("config"))
    }
}
