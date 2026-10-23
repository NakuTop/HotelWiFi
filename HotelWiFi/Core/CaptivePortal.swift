import Foundation
import Network

public enum PortalState: String, Codable, Sendable { case open, loginRequired, unreachable }
public struct PortalCheck: Codable, Sendable {
    public var state: PortalState
    public var checked = Date()
    public var detail: String
    public init(_ state: PortalState, _ detail: String) { self.state = state; self.detail = detail }
}

/// HTTP is intentional: a captive gateway cannot redirect an HTTPS probe without a certificate error.
/// Never follows or stores a redirect (which may contain a room number or login token).
public enum CaptivePortalProbe {
    public static let startURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    public static func classify(_ data: Data) -> PortalState {
        guard let text = String(data: data, encoding: .utf8),
              let boundary = text.range(of: "\r\n\r\n"),
              let status = text.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return .unreachable }
        if (300...399).contains(status) || status == 511 { return .loginRequired }
        guard status == 200 else { return .unreachable }
        let body = String(text[boundary.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body == "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>" ? .open : .loginRequired
    }
    public static func check(interface: NWInterface) async -> PortalCheck {
        await withCheckedContinuation { continuation in
            let exchange = PortalHTTPExchange(interface: interface) { state in
                let detail: String
                switch state {
                case .open: detail = "WiFi 直连 HTTP 检测通过；仍需复测系统 HTTPS 和 VPN 路径。"
                case .loginRequired: detail = "WiFi 直连响应被重定向或替换，疑似需要酒店认证。"
                case .unreachable: detail = "WiFi 直连认证检测未完成；可能是网关、DNS、VPN 强制接管或检测站点受限。"
                }
                continuation.resume(returning: .init(state, detail))
            }
            exchange.start()
        }
    }
}
private final class PortalHTTPExchange: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.hotelwifi.portal-probe")
    let connection: NWConnection
    var bytes = Data()
    var completion: ((PortalState) -> Void)?
    init(interface: NWInterface, completion: @escaping (PortalState) -> Void) {
        let p = NWParameters.tcp; p.requiredInterface = interface; p.preferNoProxies = true
        connection = NWConnection(host: "captive.apple.com", port: 80, using: p)
        self.completion = completion
    }
    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let request = "GET /hotspot-detect.html HTTP/1.0\r\nHost: captive.apple.com\r\nConnection: close\r\nCache-Control: no-cache\r\nAccept-Encoding: identity\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { [self] error in
                    if error != nil { finish(.unreachable) } else { receive() }
                })
            case .failed: finish(.unreachable)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) { [self] in finish(.unreachable) }
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            if let data { bytes.append(data) }
            if complete || error != nil || bytes.count >= 32768 {
                finish(error == nil ? CaptivePortalProbe.classify(bytes) : .unreachable)
            } else { receive() }
        }
    }
    func finish(_ state: PortalState) {
        guard let completion else { return }; self.completion = nil
        connection.stateUpdateHandler = nil; connection.cancel(); completion(state)
    }
}

/// Locate the named physical interface. A virtual utun must never become the authentication path.
public enum PortalInterface {
    public static func find(named name: String) async -> NWInterface? {
        await withCheckedContinuation { continuation in
            PortalInterfaceLookup(name: name, completion: { continuation.resume(returning: $0) }).start()
        }
    }
}
private final class PortalInterfaceLookup: @unchecked Sendable {
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "com.hotelwifi.portal-interface")
    let name: String
    var completion: ((NWInterface?) -> Void)?
    init(name: String, completion: @escaping (NWInterface?) -> Void) { self.name = name; self.completion = completion }
    func start() {
        monitor.pathUpdateHandler = { [self] path in
            finish(path.availableInterfaces.first { $0.name == name && $0.type == .wifi })
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [self] in finish(nil) }
    }
    func finish(_ interface: NWInterface?) {
        guard let completion else { return }; self.completion = nil
        monitor.pathUpdateHandler = nil; monitor.cancel(); completion(interface)
    }
}
