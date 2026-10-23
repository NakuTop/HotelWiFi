import XCTest
import Network
import WebKit
@testable import HotelWiFiCore

final class CaptivePortalTests: XCTestCase {
    func testHTTPResponsesDistinguishLoginFromFailure() {
        let cases: [(String, PortalState)] = [
            ("HTTP/1.1 200 OK\r\n\r\n<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n", .open),
            ("HTTP/1.1 302 Found\r\nLocation: http://hotel/login?secret=1\r\n\r\n", .loginRequired),
            ("HTTP/1.1 511 Network Authentication Required\r\n\r\n", .loginRequired),
            ("HTTP/1.1 200 OK\r\n\r\n<html>Hotel login, Success</html>", .loginRequired),
            ("HTTP/1.1 503 Unavailable\r\n\r\n", .unreachable),
            ("not HTTP", .unreachable), ("HTTP/1.1 200 OK\r\n", .unreachable)
        ]
        for (response, expected) in cases { XCTAssertEqual(CaptivePortalProbe.classify(Data(response.utf8)), expected) }
    }
    func testPortalTakesPriorityWithoutClaimingInternetIsHealthy() {
        var report = SessionReport(mode: "optimize")
        report.portal = .init(.loginRequired, "酒店拦截 HTTP")
        let context = NetworkContext(interface: "en0", wifiOn: true, hasIPv4: true, hasRoute: true)
        let result = DiagnosisBuilder.diagnose(context: context, facts: .init(associated: true), report: report)
        XCTAssertEqual(result.title, "需要完成酒店 WiFi 登录")
        XCTAssertTrue(result.findings.contains { $0.id == "portalCheck" && $0.action == .portal })
        XCTAssertNil(report.currentValidatedAt)
    }
    func testDirectHTTPDoesNotMislabelFailedProxyAsHotelLogin() {
        var report = SessionReport(mode: "diagnose")
        report.portal = .init(.open, "独立 HTTP 通过")
        var context = NetworkContext(interface: "en0", wifiOn: true, hasIPv4: true, hasRoute: true)
        context.proxy.manual = true
        var failed = ProbeSample(endpoint: "test", provider: "fixture", path: .system, kind: .connectivity)
        failed.failure = .body
        report.windows = [.init(label: "最终当前连接复测", context: context, samples: [failed])]
        let diagnosis = DiagnosisBuilder.diagnose(context: context, facts: .init(associated: true), report: report)
        XCTAssertEqual(diagnosis.title, "WiFi 认证入口可达，系统路径未通过")
        XCTAssertEqual(Set(diagnosis.findings.map(\.id)).count, diagnosis.findings.count)
    }
    func testRelayRejectsLoopbackDestinations() {
        for host in ["localhost", "app.localhost", "127.0.0.1", "[::1]", "0.0.0.0", "::ffff:127.0.0.1"] {
            XCTAssertFalse(PortalRelayPolicy.allowed(host: host), host)
        }
        for host in ["192.168.1.1", "hotel.example", "2001:db8::1"] { XCTAssertTrue(PortalRelayPolicy.allowed(host: host)) }
    }
    func testPortalReportDecodesOlderReports() throws {
        let data = try JSONCoding.encoder.encode(SessionReport(mode: "old"))
        let report = try JSONCoding.decoder.decode(SessionReport.self, from: data)
        XCTAssertNil(report.portal)
    }
    func testAuthenticatedRelayForwardsHTTPAndStops() async throws {
        let queue = DispatchQueue(label: "relay-test")
        let p = NWParameters.tcp; p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let upstream = try NWListener(using: p)
        let ready = expectation(description: "HTTP fixture listening")
        upstream.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard data != nil else { connection.cancel(); return }
                connection.send(content: Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8), completion: .contentProcessed { _ in })
            }
        }
        upstream.start(queue: queue); defer { upstream.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let fixturePort = try XCTUnwrap(upstream.port).rawValue
        let relay = PortalRelay(parameters: { .tcp }, allowsHost: { $0 == "127.0.0.1" })
        let relayPort = try await relay.start(); defer { relay.stop() }
        let client = NWConnection(host: "127.0.0.1", port: .init(rawValue: relayPort)!, using: .tcp)
        client.start(queue: queue); defer { client.cancel() }
        try await send(client, Data([5, 1, 2]))
        let method = try await read(client, 2); XCTAssertEqual(method, Data([5, 2]))
        var auth = Data([1, UInt8(relay.username.utf8.count)]); auth.append(Data(relay.username.utf8))
        auth.append(UInt8(relay.password.utf8.count)); auth.append(Data(relay.password.utf8))
        try await send(client, auth)
        let accepted = try await read(client, 2); XCTAssertEqual(accepted, Data([1, 0]))
        try await send(client, Data([5, 1, 0, 1, 127, 0, 0, 1, UInt8(fixturePort >> 8), UInt8(fixturePort & 255)]))
        let connected = try await read(client, 10); XCTAssertEqual(Array(connected.prefix(2)), [5, 0])
        try await send(client, Data("GET / HTTP/1.0\r\n\r\n".utf8))
        let response = try await read(client, 40)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("200 OK"))
        relay.stop()
    }
    @MainActor func testWebKitLoadsThroughAuthenticatedRelay() async throws {
        let queue = DispatchQueue(label: "webkit-fixture")
        let p = NWParameters.tcp; p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: p)
        let ready = expectation(description: "web fixture listening")
        let requested = expectation(description: "WebKit reached server through SOCKS")
        requested.assertForOverFulfill = false
        server.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard data != nil else { return }
                requested.fulfill()
                let body = "<html><title>HotelWiFi relay verified</title><body>Login</body></html>"
                let response = "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            }
        }
        server.start(queue: queue); defer { server.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.port).rawValue
        let relayed = expectation(description: "WebKit authenticated with the relay")
        relayed.assertForOverFulfill = false
        let relay = PortalRelay(parameters: { .tcp }, allowsHost: { host in relayed.fulfill(); return host == "hotelwifi-fixture.invalid" }, resolveHost: { _ in "127.0.0.1" })
        let relayPort = try await relay.start(); defer { relay.stop() }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: .init(rawValue: relayPort)!))
        proxy.allowFailover = false; proxy.applyCredential(username: relay.username, password: relay.password)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.websiteDataStore.proxyConfigurations = [proxy]
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 480), configuration: config)
        web.load(URLRequest(url: URL(string: "http://hotelwifi-fixture.invalid:\(port)/login")!))
        await fulfillment(of: [relayed, requested], timeout: 12)
        web.stopLoading()
    }
    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func read(_ connection: NWConnection, _ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: HWError.cancelled) }
            }
        }
    }
}
