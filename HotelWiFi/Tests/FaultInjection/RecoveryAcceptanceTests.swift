import XCTest
@testable import HotelWiFiCore

final class RecoveryAcceptanceTests: XCTestCase {
    func testExpiredArmedTransactionCannotApply() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j); _ = try c.arm(r.id)
        j.record?.expires = Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try c.apply(r.id,gate:allowedGate())); XCTAssertEqual(b.writes,0)
    }
    func testWriteRequiresSnapshotArmAndGuardianAcknowledgment() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        XCTAssertThrowsError(try c.apply(r.id, gate: allowedGate())); XCTAssertEqual(b.writes,0)
        _ = try c.arm(r.id); var gate = allowedGate(); gate.guardianArmed = false
        XCTAssertThrowsError(try c.apply(r.id, gate: gate)); XCTAssertEqual(b.writes,0)
    }
    func testApplicationCrashAfterApplyIsRecoveredByNewGuardian() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate())
        let restarted = RecoveryCoordinator(backend: b, journal: j)
        let recovered = try restarted.recoverOnStartup()
        XCTAssertEqual(b.value, .init(nil)); XCTAssertEqual(recovered?.phase,.restored)
        XCTAssertEqual(recovered?.applicationValidated,false); XCTAssertEqual(recovered?.connectionReestablished,false)
    }
    func testCrashBetweenSystemWriteAndApplyLogRemainsRecoverable() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); j.failAt = 3
        XCTAssertThrowsError(try c.apply(r.id, gate: allowedGate())); XCTAssertEqual(j.record?.phase,.armed)
        j.failAt = nil; _ = try RecoveryCoordinator(backend: b, journal: j).recoverOnStartup()
        XCTAssertEqual(b.value, .init(nil))
    }
    func testPrepareOrArmDiskFailurePreventsSystemWrite() throws {
        for fail in [1,2] {
            let b = MemoryConfiguration(), j = MemoryJournal(); j.failAt = fail
            do { let (c,r) = try prepared(b,j); _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate()); XCTFail("must fail") } catch {}
            XCTAssertEqual(b.writes,0)
        }
    }
    func testDiskFailureDuringRollbackStillRestoresKnownOriginal() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate()); j.failAt = j.writes + 1
        XCTAssertThrowsError(try c.rollback(r.id, reason: "disk failure")); XCTAssertEqual(b.value,.init(nil))
    }
    func testUserDNSModificationWinsAndConflictIsRecorded() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate()); b.value = .init(.strings(["10.30.40.50"]))
        let recovered = try c.rollback(r.id, reason: "stop")
        XCTAssertEqual(recovered.phase,.conflict); XCTAssertFalse(recovered.configurationRestored)
        XCTAssertEqual(b.value,.init(.strings(["10.30.40.50"]))); XCTAssertEqual(b.writes,1)
    }
    func testExternalChangeAtCASCannotBeOverwritten() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j); _ = try c.arm(r.id)
        b.beforeCAS = { b.value = .init(.strings(["10.1.1.2"])) }
        XCTAssertThrowsError(try c.apply(r.id, gate: allowedGate())); XCTAssertEqual(b.writes,0)
    }
    func testUserTurnsOffWiFiNoActionTurnsItBackOn() throws {
        var g = allowedGate(); g.context.wifiOn = false
        XCTAssertNotNil(OperationGate.rejection(g))
        // RecoveryBackend exposes fields only: there is no power/association restoration operation.
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate())
        _ = try c.tick(now: Date(), sleeping: false, sameContext: false)
        XCTAssertEqual(b.value,.init(nil)); XCTAssertFalse(try c.record(r.id).connectionReestablished)
    }
    func testLeavingHotelCleansFieldWithoutRestoringHotelIP() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate()); _ = try c.verify(r.id); _ = try c.commit(r.id)
        let result = try c.tick(now: Date(), sleeping: false, sameContext: false)
        XCTAssertEqual(result?.phase,.restored); XCTAssertEqual(b.value,.init(nil))
    }
    func testRestoreAbsentDNSRestoresAutomaticModeNotDHCPRuntimeAddresses() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        XCTAssertFalse(r.original.existed)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate()); _ = try c.rollback(r.id, reason: "no gain")
        XCTAssertEqual(b.value,.init(nil))
    }
    func testSleepDoesNotTurnMissedHeartbeatIntoNetworkFailure() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate())
        let result = try c.tick(now: Date().addingTimeInterval(1000), sleeping: true, sameContext: false)
        XCTAssertEqual(result?.phase,.applied); XCTAssertEqual(b.writes,1)
        _ = try c.tick(now: Date().addingTimeInterval(1001), sleeping: false, sameContext: true)
        XCTAssertEqual(b.value,.init(nil))
    }
    func testPermissionRevocationWaitsAndRetriesIdempotently() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate()); b.unavailable = true
        XCTAssertThrowsError(try c.rollback(r.id, reason: "permission revoked")); XCTAssertEqual(j.record?.phase,.waiting)
        b.unavailable = false; _ = try c.rollback(r.id, reason: "retry"); let writes = b.writes
        _ = try c.rollback(r.id, reason: "repeat"); XCTAssertEqual(b.writes,writes)
    }
    func testOnlyOneTransactionAcrossSimultaneousClients() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); _ = try prepared(b,j)
        XCTAssertThrowsError(try prepared(b,j))
    }
    func testCorruptJournalBlocksNewWritesAndDoesNotInventOriginal() {
        let b = MemoryConfiguration(), j = MemoryJournal(); j.corrupted = true
        XCTAssertThrowsError(try prepared(b,j)); XCTAssertEqual(b.writes,0)
    }
    func testUnknownImportantSessionsBlockDisruptiveOperations() {
        var g = allowedGate(operation: .reconnect); g.policy.allowReconnect = true; g.importantTraffic = nil
        XCTAssertNotNil(OperationGate.rejection(g)); g.importantTraffic = true; XCTAssertNotNil(OperationGate.rejection(g))
    }
    func testDeniedPermissionsAndUnavailableGuardianNeverWrite() {
        for field in 0..<6 {
            var g = allowedGate()
            switch field { case 0: g.helperReady = false; case 1: g.snapshotSaved = false; case 2: g.guardianArmed = false
            case 3: g.originalKnown = false; case 4: g.context.confidence = .unknown; default: g.context.proxy.managed = nil }
            XCTAssertNotNil(OperationGate.rejection(g))
        }
    }
    func testVPNManagedAndSplitDNSAreProtectedEvenWithAuthorization() {
        var g = allowedGate(); g.context.vpnPresent = true; XCTAssertNotNil(OperationGate.rejection(g))
        g = allowedGate(); g.context.proxy.managed = true; XCTAssertNotNil(OperationGate.rejection(g))
        g = allowedGate(); g.context.splitDNS = true; XCTAssertNotNil(OperationGate.rejection(g))
    }
}
