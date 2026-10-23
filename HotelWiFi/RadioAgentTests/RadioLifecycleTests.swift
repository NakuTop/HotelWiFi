import XCTest
import HotelWiFiCore
@testable import HotelWiFiRadioAgent

/// These tests run the production service/worker queues with a fake radio and clock.
/// No CoreWLAN calls, privileged service registration or real network writes occur.
final class RadioLifecycleTests: XCTestCase {
    var directory: URL!
    var store: SecureStore!
    var environment: TestRadio!
    var clock: TestRadioClock!
    var agent: RadioAgent!
    let owner = UUID()
    var value: RadioRecord!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/HotelWiFiRadioLifecycle-" + UUID().uuidString)
        store = try SecureStore(directory: directory)
        environment = TestRadio(); clock = TestRadioClock()
        let radio = environment!, time = clock!
        let traffic = TrafficMonitor(clock: { time.date.timeIntervalSince1970 }, counter: { _ in 0 })
        time.advance(-5); traffic.sample(interface: "en0")
        time.advance(2); traffic.sample(interface: "en0")
        time.advance(3); traffic.sample(interface: "en0")
        agent = try RadioAgent(store: store, environment: radio, traffic: traffic, now: { time.date }, startWatchdog: false,
                               disconnect: { _ in radio.noteDisconnect() })
        value = RadioRecord(nonce: UUID().uuidString, plan: .init(action: .associate, original: radio.original, target: radio.target))
        value.created = clock.date; value.heartbeat = clock.date; value.expires = clock.date.addingTimeInterval(180)
        try agent.queue.sync { try agent.save(value); agent.owner = owner; agent.restoreRequested = false }
    }
    override func tearDownWithError() throws {
        settle(); agent = nil; store = nil
        try FileManager.default.removeItem(at: directory)
    }
    func call(_ action: RadioAction, windows: [MeasurementWindow]? = nil) throws -> RadioResponse {
        try agent.queue.sync { try agent.perform(.init(action, nonce: value.nonce, transaction: value.id, windows: windows), owner: owner, managed: false) }
    }
    func settle() { for _ in 0..<4 { agent.worker.sync {}; agent.queue.sync {} } }
    var record: RadioRecord { agent.queue.sync { agent.record! } }
    func apply() throws { XCTAssertTrue(try call(.apply).ok); settle() }
    func verification() -> [MeasurementWindow] {
        let context = environment.context(nonce: value.nonce, session: UUID())
        return (1...2).map { index in
            let samples = ["Apple", "Google"].map { provider -> ProbeSample in
                var sample = ProbeSample(endpoint: provider, provider: provider, path: .system, kind: .connectivity)
                sample.complete = true; sample.started = clock.date; return sample
            }
            return .init(label: "window \(index)", context: context, samples: samples)
        }
    }

    func testActualTargetAndTwoHealthyWindowsCanCommit() throws {
        try apply()
        XCTAssertEqual(record.phase, .waiting); XCTAssertTrue(record.targetObserved)
        XCTAssertTrue(try call(.commit, windows: verification()).ok)
        XCTAssertEqual(record.phase, .committed)
        clock.advance(300); agent.queue.sync { agent.tick() }; settle()
        XCTAssertEqual(environment.writes, [environment.target]); XCTAssertEqual(environment.disconnects, 1)
    }
    func testTwoStableScansPrepareThenApplyAndCommitFullServiceWorkflow() throws {
        try agent.queue.sync { var r = agent.record!; r.phase = .restored; try agent.save(r) }
        var policy = OptimizationPolicy(); policy.allowAutomaticAP = true
        let context = environment.context(nonce: value.nonce, session: UUID())
        let prepare = RadioRequest(.prepare, nonce: value.nonce, context: context, policy: policy)
        let first = try agent.queue.sync { try agent.perform(prepare, owner: owner, managed: false) }
        XCTAssertTrue(first.ok); XCTAssertNil(first.transaction)
        _ = try agent.queue.sync { try agent.perform(.init(.survey, nonce: value.nonce), owner: owner, managed: false) }
        let second = try agent.queue.sync { try agent.perform(prepare, owner: owner, managed: false) }
        XCTAssertNotNil(second.transaction); value = record
        XCTAssertEqual(try RadioJournal(store: store).load()?.phase, .prepared)
        try apply(); _ = try call(.commit, windows: verification())
        XCTAssertEqual(record.phase, .committed); XCTAssertEqual(environment.current, environment.target)
    }
    func testAPIReturnSuccessDoesNotCountAsObservedSwitch() throws {
        environment.acceptAssociation = false
        try apply()
        XCTAssertFalse(record.targetObserved); XCTAssertEqual(record.phase, .waiting)
        XCTAssertThrowsError(try call(.commit, windows: verification()))
        _ = try call(.restore); settle()
        XCTAssertEqual(record.phase, .restored)
        XCTAssertEqual(environment.writes.count, 1)
    }
    func testAssociationErrorAfterChangeRestoresActualOriginal() throws {
        environment.failNextAssociationAfterChange = true
        try apply()
        XCTAssertEqual(record.phase, .restored); XCTAssertEqual(record.restoreAttempts, 1)
        XCTAssertEqual(environment.current, environment.original)
        XCTAssertEqual(environment.writes, [environment.target, environment.original])
    }
    func testStopWhileScanningPreventsDisconnectAndAssociation() throws {
        environment.beforeWrite = { [self] in
            agent.queue.sync { agent.restoreRequested = true; try? agent.restore() }
        }
        try apply()
        XCTAssertEqual(record.phase, .restored)
        XCTAssertTrue(environment.writes.isEmpty); XCTAssertEqual(environment.disconnects, 0)
    }
    func testExpiryDuringScanPreventsLateDisconnect() throws {
        environment.beforeWrite = { [self] in clock.advance(181) }
        try apply()
        XCTAssertEqual(record.phase, .restored)
        XCTAssertTrue(environment.writes.isEmpty); XCTAssertEqual(environment.disconnects, 0)
    }
    func testUserSwitchWhileScanningIsPreservedAtFinalWriteBoundary() throws {
        var other = environment.original; other.ssid = Data("other-user-choice".utf8); other.bssid = "external"
        environment.beforeWrite = { [self] in environment.current = other }
        try apply()
        XCTAssertEqual(record.phase, .conflict)
        XCTAssertEqual(environment.current, other)
        XCTAssertTrue(environment.writes.isEmpty); XCTAssertEqual(environment.disconnects, 0)
    }
    func testHeartbeatLossRestoresTargetWithoutFurtherClientRequests() throws {
        try apply(); clock.advance(46)
        agent.queue.sync { agent.tick() }; settle()
        XCTAssertEqual(record.phase, .restored); XCTAssertEqual(environment.current, environment.original)
    }
    func testOnlyOwningClientDisconnectTriggersRecovery() throws {
        try apply()
        agent.queue.sync { agent.connectionEnded(UUID()) }; settle()
        XCTAssertEqual(record.phase, .waiting)
        agent.queue.sync { agent.connectionEnded(owner) }; settle()
        XCTAssertEqual(record.phase, .restored); XCTAssertEqual(environment.current, environment.original)
    }
    func testRestoreRequestCannotBeOverriddenByLateCommit() throws {
        try apply(); environment.current = nil
        _ = try call(.restore); settle()
        environment.current = environment.target
        XCTAssertThrowsError(try call(.commit, windows: verification()))
        agent.queue.sync { agent.tick() }; settle()
        XCTAssertEqual(record.phase, .restored)
    }
    func testUserSwitchDuringRollbackScanIsAlsoPreserved() throws {
        try apply()
        var other = environment.original; other.bssid = "external-choice"
        environment.beforeWrite = { [self] in environment.current = other }
        _ = try call(.restore); settle()
        XCTAssertEqual(record.phase, .conflict); XCTAssertEqual(environment.current, other)
        XCTAssertEqual(environment.writes.count, 1); XCTAssertEqual(environment.disconnects, 1)
    }
    func testAbsoluteExpiryRestoresEvenWithFreshHeartbeat() throws {
        try apply(); clock.advance(179); _ = try call(.heartbeat); clock.advance(2)
        agent.queue.sync { agent.tick() }; settle()
        XCTAssertEqual(record.phase, .restored)
    }
    func testRestartLoadsEncryptedLeaseAndRestoresBeforeNewWork() throws {
        try apply(); agent = nil
        let radio = environment!, time = clock!
        agent = try RadioAgent(store: store, environment: radio, now: { time.date }, startWatchdog: false,
                               disconnect: { _ in radio.noteDisconnect() })
        XCTAssertTrue(agent.restoreRequested)
        XCTAssertThrowsError(try agent.queue.sync { try agent.perform(.init(.survey), owner: owner, managed: false) })
        agent.queue.sync { agent.tick() }; settle()
        XCTAssertEqual(record.phase, .restored); XCTAssertEqual(environment.current, environment.original)
    }
    func testUnknownIdentityDoesNotPretendRecoveryOrStartAnotherExperiment() throws {
        try apply(); environment.current = nil
        _ = try call(.restore); settle()
        XCTAssertFalse(record.terminal); XCTAssertEqual(environment.writes.count, 1)
        XCTAssertThrowsError(try agent.queue.sync { try agent.perform(.init(.survey), owner: owner, managed: false) })
        environment.current = environment.target
        agent.queue.sync { agent.tick() }; settle()
        XCTAssertEqual(record.phase, .restored)
    }
    func testManualWiFiOffIsNeverPoweredOnOrReassociated() throws {
        try apply(); environment.wifiOn = false
        _ = try call(.restore); settle()
        XCTAssertEqual(record.phase, .conflict); XCTAssertFalse(environment.wifiOn)
        XCTAssertEqual(environment.writes.count, 1)
    }
    func testExternalConfigurationChangePreventsRollback() throws {
        try apply()
        var changed = environment.target; changed.configurationDigest = "manual-config"
        environment.current = changed
        _ = try call(.restore); settle()
        XCTAssertEqual(record.phase, .conflict); XCTAssertEqual(environment.current, changed)
        XCTAssertEqual(environment.writes.count, 1)
    }
    func testUnconfirmedRollbackIsBoundedAndReportedAsConflict() throws {
        try apply(); environment.acceptAssociation = false
        _ = try call(.restore); settle()
        XCTAssertEqual(record.phase, .conflict); XCTAssertEqual(record.restoreAttempts, 1)
        for _ in 0..<3 { agent.queue.sync { agent.tick() }; _ = try call(.restore) }
        settle(); XCTAssertEqual(environment.writes.count, 2)
    }
    func testWrongOwnerNonceOrTransactionCannotWrite() throws {
        for request in [RadioRequest(.apply, nonce: "wrong", transaction: value.id),
                        RadioRequest(.apply, nonce: value.nonce, transaction: UUID())] {
            XCTAssertThrowsError(try agent.queue.sync { try agent.perform(request, owner: owner, managed: false) })
        }
        XCTAssertThrowsError(try agent.queue.sync { try agent.perform(.init(.apply, nonce: value.nonce, transaction: value.id), owner: UUID(), managed: false) })
        settle(); XCTAssertTrue(environment.writes.isEmpty); XCTAssertEqual(environment.disconnects, 0)
    }
    func testUnhealthyWindowsAndValidationModeCannotCommit() throws {
        try apply()
        XCTAssertThrowsError(try call(.commit, windows: Array(verification().prefix(1))))
        try agent.queue.sync { var r = agent.record!; r.validationRoundTrip = true; try agent.save(r) }
        XCTAssertThrowsError(try call(.commit, windows: verification()))
        XCTAssertEqual(record.phase, .waiting)
    }
}

final class TestRadioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
final class TestRadio: RadioEnvironment, @unchecked Sendable {
    let original = AssociationSnapshot(interface: "en0", serviceID: "fixture-service", ssid: Data("fixture-hotel".utf8), bssid: "AP-a", security: 0, configurationDigest: "fixture-config")
    var target: AssociationSnapshot { var s = original; s.bssid = "AP-b"; return s }
    private let lock = NSLock()
    private var state: AssociationSnapshot?
    private var powered = true
    private var associations: [AssociationSnapshot] = []
    private var disconnections = 0
    var current: AssociationSnapshot? { get { lock.withLock { state } } set { lock.withLock { state = newValue } } }
    var wifiOn: Bool { get { lock.withLock { powered } } set { lock.withLock { powered = newValue } } }
    var writes: [AssociationSnapshot] { lock.withLock { associations } }
    var disconnects: Int { lock.withLock { disconnections } }
    var identityReadable: Bool { current?.bssid != nil }
    var interfaceName: String? { original.interface }
    var acceptAssociation = true
    var failNextAssociationAfterChange = false
    var beforeWrite: (() -> Void)?
    init() { state = original }
    func noteDisconnect() { lock.withLock { disconnections += 1 } }
    func context(nonce: String, session: UUID) -> NetworkContext {
        let s = current
        return .init(sessionID: session, interface: original.interface, serviceID: original.serviceID,
                     identity: s.map { String(decoding: $0.ssid, as: UTF8.self) }, apIdentity: s?.bssid,
                     wifiOn: wifiOn, hasRoute: s != nil, configurationDigest: s?.configurationDigest ?? original.configurationDigest)
    }
    func snapshot(context: NetworkContext) throws -> AssociationSnapshot {
        guard wifiOn, let current else { throw HWError.blocked("fixture unavailable") }; return current
    }
    func scan(nonce: String) throws -> RadioScan {
        let original = try snapshot(context: context(nonce: nonce, session: UUID()))
        let points: [(AccessPointReading, AssociationSnapshot)] = [
            (.init(current: true, rssi: -82, noise: -88, channel: 1, band: "2.4 GHz"), original),
            (.init(current: false, rssi: -42, noise: -92, channel: 36, band: "5 GHz"), target)]
        return (.init(points: points.map(\.0), detail: "fixture"), original, points)
    }
    func preflight(_ snapshot: AssociationSnapshot) throws {}
    func associate(_ snapshot: AssociationSnapshot, beforeAssociation: (() throws -> Void)?) throws {
        beforeWrite?()
        try beforeAssociation?()
        lock.withLock { associations.append(snapshot); if acceptAssociation { state = snapshot } }
        if failNextAssociationAfterChange { failNextAssociationAfterChange = false; throw HWError.blocked("fixture post-association error") }
    }
}
