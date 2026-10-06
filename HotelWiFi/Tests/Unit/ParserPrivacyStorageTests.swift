import XCTest
@testable import HotelWiFiCore

final class ParserPrivacyStorageTests: XCTestCase {
    func testUnavailableAddressRadioAndRouteFieldsRemainUnknown() {
        let context = NetworkContext()
        XCTAssertNil(context.hasIPv4); XCTAssertNil(context.hasIPv6); XCTAssertNil(context.hasRoute)
        XCTAssertNil(context.radio.rssi); XCTAssertNil(context.radio.cca); XCTAssertNil(context.radio.transmitMbps)
        var gate = allowedGate(); gate.context = context; XCTAssertNotNil(OperationGate.rejection(gate))
    }
    let endpoint = ProbeEndpoint(id: "fixed", provider: "fixture", url: URL(string: "https://example.invalid/object")!, kind: .object, expectedStatus: 200, body: .exactText("body"), maxBytes: 100)
    func testCurlCumulativeTimesAreConvertedToDistinctPhases() {
        let d = Data(#"{"http_code":200,"time_total":0.8,"time_namelookup":0.1,"time_connect":0.3,"time_appconnect":0.5,"time_starttransfer":0.6,"num_connects":1,"http_version":"2"}"#.utf8)
        let s = CurlMetricsParser.parse(d, body: Data("body".utf8), endpoint: endpoint, path: .direct, exit: 0)
        XCTAssertEqual(s.times.dns!,0.1,accuracy:0.0001); XCTAssertEqual(s.times.tcp!,0.2,accuracy:0.0001); XCTAssertEqual(s.times.tls!,0.2,accuracy:0.0001)
        XCTAssertTrue(s.complete); XCTAssertEqual(s.times.total,0.8)
    }
    func testCurlTimeoutDespiteHTTP200AndValidPartialPrefixFails() {
        let d = Data(#"{"http_code":200,"time_total":8,"num_connects":1}"#.utf8)
        let s = CurlMetricsParser.parse(d, body: Data("body".utf8), endpoint: endpoint, path: .direct, exit: 28)
        XCTAssertFalse(s.complete); XCTAssertEqual(s.failure,.timeout); XCTAssertEqual(s.exitCode,28)
    }
    func testReusedOrMissingStagesAreNilNotZero() {
        let d = Data(#"{"http_code":200,"time_total":0.2,"time_namelookup":0,"time_connect":0,"time_appconnect":0,"num_connects":0}"#.utf8)
        let s = CurlMetricsParser.parse(d, body: Data("body".utf8), endpoint: endpoint, path: .direct, exit: 0)
        XCTAssertNil(s.times.dns); XCTAssertNil(s.times.tcp); XCTAssertNil(s.times.tls)
        let changed = CurlMetricsParser.parse(Data("{}".utf8), body: Data(), endpoint: endpoint, path: .direct, exit: 0)
        XCTAssertFalse(changed.complete); XCTAssertEqual(changed.failure,.parse); XCTAssertNil(changed.status)
    }
    func testCurlArgvIgnoresCurlrcAndExplicitlyBypassesInheritedProxyOnlyForDiagnostic() {
        let a = ControlledProbe.arguments(endpoint: endpoint, path: .ipv6, timeout: 4)
        XCTAssertEqual(a.first,"-q"); XCTAssertTrue(a.contains("--noproxy")); XCTAssertTrue(a.contains("--ipv6"))
        XCTAssertFalse(a.contains("--insecure")); XCTAssertTrue(a.contains("=https")); XCTAssertTrue(a.contains("--max-filesize"))
    }
    func testDNSParserRejectsTruncationMismatchedIDAndInvalidQuestion() throws {
        let q = try DNSWire.query(host: "example.com", id: 123)
        var response = q; response[2] = 0x81; response[3] = 0x80; response[7] = 1
        response.append(contentsOf:[0xc0,0x0c,0,1,0,1,0,0,0,30,0,4,1,2,3,4])
        XCTAssertEqual(DNSWire.address(response: response, query: q),"1.2.3.4")
        var changed = response; changed[0] = 22; XCTAssertNil(DNSWire.address(response: changed, query: q))
        changed = response; changed[2] = 0x83; XCTAssertNil(DNSWire.address(response: changed, query: q))
        XCTAssertNil(DNSWire.address(response: response.prefix(14), query: q))
        XCTAssertThrowsError(try DNSWire.query(host: String(repeating: "a", count: 64) + ".com", id: 1))
    }
    func testInsufficientOrCrossPathEvidenceDoesNotCreateDNSProposal() {
        let a = samples([2,2,2,2], failedAt:[0,1,2,3], failure:.dns)
        let d = samples([0.2,0.2,0.2,0.2], path:.candidateDNS)
        XCTAssertTrue(MutationProposal(field:.dnsServers,value:.strings(["1.1.1.1"]),baseline:a,controlled:d).hasEvidence)
        XCTAssertFalse(MutationProposal(field:.dnsServers,value:.strings(["1.1.1.1"]),baseline:a,controlled:Array(d.prefix(2))).hasEvidence)
        XCTAssertFalse(MutationProposal(field:.dnsServers,value:.strings(["1.1.1.1"]),baseline:a,controlled:samples([0.2,0.2,0.2,0.2],path:.direct)).hasEvidence)
    }
    func testDefaultPolicyIsNonDisruptiveAndProtectsCostUnknown() {
        let p = OptimizationPolicy(); XCTAssertFalse(p.allowReconnect); XCTAssertFalse(p.allowSavedNetworks); XCTAssertFalse(p.allowMetered)
        var g = allowedGate(); g.context.expensive = nil; XCTAssertNotNil(OperationGate.rejection(g))
    }
    func testProxyAuthenticationAndTLSFailuresCannotAuthorizeDisablingProxy() {
        let direct = samples([0.2,0.2,0.2,0.2],path:.direct)
        for failure in [ProbeFailure.http,.tls,.body,.redirect] {
            let source = samples([2,2,2,2],failedAt:[0,1,2,3],failure:failure)
            XCTAssertFalse(MutationProposal(field:.autoProxyDiscovery,value:.integer(0),baseline:source,controlled:direct).hasEvidence)
        }
    }
    func testEndpointValidationRejectsCredentialsAndNonHTTPS() {
        var e = ProbeEndpoint.defaults; e[0].url = URL(string:"http://example.com/")!
        XCTAssertThrowsError(try ProbeEndpoint.validate(e))
        e = ProbeEndpoint.defaults; e[0].url = URL(string:"https://user:password@example.com/")!
        XCTAssertThrowsError(try ProbeEndpoint.validate(e))
        XCTAssertNoThrow(try ProbeEndpoint.validate(ProbeEndpoint.defaults))
    }
    func tempStore() throws -> SecureStore {
        let dir = URL(fileURLWithPath: "/private/tmp/HotelWiFiTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try SecureStore(directory: dir)
    }
    func testPrivateAtomicStorageRejectsSymlinksAndConcurrentLock() throws {
        let s = try tempStore(); try s.write(Data("safe".utf8),named:"file")
        XCTAssertEqual(try s.read("file"),Data("safe".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath:s.directory.appendingPathComponent("file").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int,0o600)
        try FileManager.default.createSymbolicLink(at:s.directory.appendingPathComponent("evil"),withDestinationURL:s.directory.appendingPathComponent("file"))
        XCTAssertThrowsError(try s.read("evil"))
        let l = try s.acquireLock("lock"); XCTAssertThrowsError(try s.acquireLock("lock")); l.release()
        XCTAssertNoThrow(try s.acquireLock("lock")); XCTAssertThrowsError(try s.read("../file"))
    }
    func testActualJournalRejectsCorruptionAndRoundTripsAbsentFields() throws {
        let s = try tempStore(), j = TransactionJournal(store:s), b = MemoryConfiguration()
        let c = RecoveryCoordinator(backend:b,journal:j)
        let r = try c.prepare(target:.init(serviceID:"test",field:.dnsServers),value:.strings(["1.1.1.1"]),context:knownContext(),uid:501,nonce:UUID().uuidString)
        XCTAssertEqual(try j.load()?.id,r.id); XCTAssertNil(try j.load()?.original.value)
        try s.write(Data("broken".utf8),named:"recovery.json"); XCTAssertThrowsError(try j.load())
        XCTAssertThrowsError(try c.prepare(target:r.target,value:.strings(["9.9.9.9"]),context:knownContext(),uid:501,nonce:"x"))
    }
    func testExportRemovesNetworkIdentityAndServiceName() throws {
        var r = SessionReport(mode:"fixture"); r.current = knownContext(); r.current?.serviceName = "Private hotel SSID"
        r.windows = [window([0.1,0.2,0.1,0.2])]
        let data = try JSONCoding.encoder.encode(PrivacyFilter.exported(r)), text = String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("Private hotel")); XCTAssertFalse(text.contains("hotel-network-session")); XCTAssertFalse(text.contains("ap-1")); XCTAssertFalse(text.contains("test-service"))
    }
    func testIdentityHashNeedsLocalSecretAndKeepsNoRawSSID() {
        let a = PrivacyFilter(key:Data(repeating:1,count:32)), b = PrivacyFilter(key:Data(repeating:2,count:32))
        XCTAssertEqual(a.digest(["Hotel","gateway"]),a.digest(["Hotel","gateway"]))
        XCTAssertNotEqual(a.digest(["Hotel"]),b.digest(["Hotel"])); XCTAssertFalse(a.digest(["Hotel"]).contains("Hotel"))
    }
    func testRecoveryPublicOutputDoesNotExposeOriginalsOrSessionToken() throws {
        let b = MemoryConfiguration(), j = MemoryJournal(); b.value = .init(.strings(["10.30.40.50"]))
        let (_, r) = try prepared(b,j)
        let data = try JSONCoding.encoder.encode(RecoveryStatusReport(.init(ok:true,message:"restored",record:r)))
        let text = String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("10.30.40.50")); XCTAssertFalse(text.contains("1.1.1.1"))
        XCTAssertFalse(text.contains(r.sessionNonce)); XCTAssertFalse(text.contains(r.target.serviceID))
        XCTAssertTrue(text.contains(r.id.uuidString))
    }
}
