import XCTest
import Network
@testable import HotelWiFiCore

final class FixtureURLProtocol: URLProtocol {
    static var handler: ((FixtureURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(_ status: Int = 200, data: Data, error: Error? = nil) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if let error {
            // Model a timeout AFTER the response and body callbacks have reached URLSession.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { self.client?.urlProtocol(self, didFailWithError: error) }
        } else { client?.urlProtocolDidFinishLoading(self) }
    }
}
final class ApplicationProbeTests: XCTestCase {
    let endpoint = ProbeEndpoint(id: "fixture", provider: "fixture", url: URL(string: "https://fixture.invalid/object")!, kind: .object, expectedStatus: 200, body: .exactText("complete"), maxBytes: 64)
    func config() -> URLSessionConfiguration { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FixtureURLProtocol.self]; return c }
    override func tearDown() { FixtureURLProtocol.handler = nil }
    func testHTTP200WithBodyTimeoutIsFailure() async throws {
        // A loopback server is needed: URLProtocol may collapse response callbacks when followed by an error.
        let server = try PartialResponseServer(); let port = await server.start()
        defer { server.close() }
        var local = endpoint; local.url = URL(string: "http://127.0.0.1:\(port)/fixture")!
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let result = try await ApplicationProbe().run(local, budget: .init(seconds: 2), configuration: configuration)
        XCTAssertEqual(result.status,200); XCTAssertFalse(result.complete); XCTAssertEqual(result.failure,.timeout)
        XCTAssertEqual(result.bytes,4); XCTAssertEqual(result.errorDomain,NSURLErrorDomain)
    }
    func testHTTP200WrongContentIsFailure() async throws {
        FixtureURLProtocol.handler = { $0.respond(data: Data("login".utf8)) }
        let result = try await ApplicationProbe().run(endpoint, budget: .init(), configuration: config())
        XCTAssertFalse(result.complete); XCTAssertEqual(result.failure,.body)
    }
    func testActualReceivedBytesEnforceCapWithoutContentLength() async throws {
        FixtureURLProtocol.handler = { $0.respond(data: Data(repeating: 42, count: 2048)) }
        let budget = BudgetManager(bytes: 1000)
        let result = try await ApplicationProbe().run(endpoint, budget: budget, configuration: config())
        XCTAssertFalse(result.complete); XCTAssertEqual(result.failure,.byteLimit)
        XCTAssertEqual(budget.bytes,2048); XCTAssertEqual(result.bytes,2048)
        XCTAssertThrowsError(try budget.startRequest())
    }
    func testFullValidatedBodySuccessAndCacheDisabled() async throws {
        FixtureURLProtocol.handler = { p in
            XCTAssertEqual(p.request.value(forHTTPHeaderField: "Cache-Control"),"no-cache, no-store")
            p.respond(data: Data("complete".utf8))
        }
        let result = try await ApplicationProbe().run(endpoint, budget: .init(), configuration: config())
        XCTAssertTrue(result.complete); XCTAssertEqual(result.bytes,8)
    }
    func testCancelledBudgetStopsExperimentsButAllowsFinalReservation() {
        let b = BudgetManager(); b.stop()
        XCTAssertThrowsError(try b.startRequest()); XCTAssertNoThrow(try b.startRequest(final: true))
    }
    func testBudgetExhaustionDoesNotPreventRecovery() throws {
        let budget = BudgetManager(bytes: 2000); XCTAssertFalse(budget.consume(3000))
        let b = MemoryConfiguration(), j = MemoryJournal(); let (c,r) = try prepared(b,j)
        _ = try c.arm(r.id); _ = try c.apply(r.id, gate: allowedGate())
        _ = try c.rollback(r.id, reason: "budget exhausted"); XCTAssertEqual(b.value,.init(nil))
    }
}

private final class PartialResponseServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "HotelWiFi.Tests.loopback")
    var connections: [NWConnection] = []
    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
    }
    func start() async -> UInt16 {
        await withCheckedContinuation { c in
            listener.stateUpdateHandler = { [self] state in if case .ready = state { c.resume(returning: listener.port!.rawValue); listener.stateUpdateHandler = nil } }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 16\r\nContent-Type: text/plain\r\n\r\npart".utf8), completion: .contentProcessed { _ in })
                }
            }
            listener.start(queue: queue)
        }
    }
    func close() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }
}
