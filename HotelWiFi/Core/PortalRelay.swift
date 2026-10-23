import Foundation
import Network

/// Short-lived, authenticated loopback SOCKS5 relay, used only by the login web view.
/// All upstream connections are bound to the selected physical WiFi interface.
public final class PortalRelay: @unchecked Sendable {
    public let username = UUID().uuidString
    public let password = UUID().uuidString
    private let queue = DispatchQueue(label: "com.hotelwifi.portal-relay")
    private let parameters: () -> NWParameters
    private let allowsHost: (String) -> Bool
    private let resolveHost: (String) -> String
    private var listener: NWListener?
    private var clients: [UUID: PortalRelayClient] = [:]
    private var stopped = false
    public init(interface: NWInterface) {
        parameters = { let p = NWParameters.tcp; p.requiredInterface = interface; p.preferNoProxies = true; return p }
        allowsHost = PortalRelayPolicy.allowed; resolveHost = { $0 }
    }
    // Injectable transport enables deterministic loopback acceptance tests without hotel/VPN access.
    init(parameters: @escaping () -> NWParameters, allowsHost: @escaping (String) -> Bool, resolveHost: @escaping (String) -> String = { $0 }) {
        self.parameters = parameters; self.allowsHost = allowsHost; self.resolveHost = resolveHost
    }
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !stopped, listener == nil else { continuation.resume(throwing: HWError.cancelled); return }
                do {
                    let p = NWParameters.tcp
                    p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: p); self.listener = listener
                    var answered = false
                    func answer(_ result: Result<UInt16, Error>) {
                        guard !answered else { return }; answered = true; continuation.resume(with: result)
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            if let port = listener.port { answer(.success(port.rawValue)) }
                            else { answer(.failure(HWError.blocked("无法分配认证窗口端口。"))) }
                        case .failed(let error): answer(.failure(error)); self?.stop()
                        case .cancelled: answer(.failure(HWError.cancelled)); listener.stateUpdateHandler = nil
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, !self.stopped, self.clients.count < 48 else { connection.cancel(); return }
                        let id = UUID()
                        let client = PortalRelayClient(connection, parameters: self.parameters, allowsHost: self.allowsHost, resolveHost: self.resolveHost, queue: self.queue,
                            username: self.username, password: self.password) { [weak self] in self?.clients.removeValue(forKey: id) }
                        self.clients[id] = client; client.start()
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 3) {
                        if !answered { answer(.failure(HWError.blocked("登录通道启动超时。"))); self.stop() }
                    }
                    queue.asyncAfter(deadline: .now() + 600) { self.stop() }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func stop() {
        queue.async { [self] in
            stopped = true; listener?.cancel(); listener = nil
            let active = Array(clients.values); clients.removeAll()
            active.forEach { $0.close() }
        }
    }
}

private final class PortalRelayClient {
    let local: NWConnection
    var remote: NWConnection?
    let parameters: () -> NWParameters
    let allowsHost: (String) -> Bool
    let resolveHost: (String) -> String
    let queue: DispatchQueue
    let username: String, password: String
    var onClose: (() -> Void)?
    var closed = false
    init(_ local: NWConnection, parameters: @escaping () -> NWParameters, allowsHost: @escaping (String) -> Bool, resolveHost: @escaping (String) -> String, queue: DispatchQueue, username: String, password: String, onClose: @escaping () -> Void) {
        self.local = local; self.parameters = parameters; self.allowsHost = allowsHost; self.resolveHost = resolveHost; self.queue = queue
        self.username = username; self.password = password; self.onClose = onClose
    }
    func start() {
        local.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.close() } }
        local.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in if self?.remote == nil { self?.close() } }
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.close() }
        read(2) { [self] head in
            guard head[0] == 5, head[1] > 0 else { close(); return }
            read(Int(head[1])) { [self] methods in
                guard methods.contains(2) else { close(); return }
                send(Data([5, 2])) { [self] in authenticate() }
            }
        }
    }
    func read(_ count: Int, then: @escaping ([UInt8]) -> Void) {
        guard !closed, count > 0 else { close(); return }
        local.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == count else { self.close(); return }
            then(Array(data))
        }
    }
    func send(_ data: Data, then: @escaping () -> Void) {
        local.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() } else { then() }
        })
    }
    func authenticate() {
        read(2) { [self] header in
            guard header[0] == 1, header[1] > 0 else { close(); return }
            read(Int(header[1])) { [self] user in
                read(1) { [self] length in
                    read(Int(length[0])) { [self] secret in
                        guard String(bytes: user, encoding: .utf8) == username,
                              String(bytes: secret, encoding: .utf8) == password else { close(); return }
                        send(Data([1, 0])) { [self] in request() }
                    }
                }
            }
        }
    }
    func request() {
        read(4) { [self] header in
            guard header[0] == 5, header[1] == 1, header[2] == 0 else { close(); return }
            switch header[3] {
            case 1: read(4) { [self] bytes in destination(bytes.map(String.init).joined(separator: ".")) }
            case 3: read(1) { [self] size in read(Int(size[0])) { [self] bytes in
                guard let host = String(bytes: bytes, encoding: .utf8), !host.isEmpty else { close(); return }
                destination(host)
            } }
            case 4: read(16) { [self] bytes in
                let host = stride(from: 0, to: 16, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }.joined(separator: ":")
                destination(host)
            }
            default: close()
            }
        }
    }
    func destination(_ host: String) {
        read(2) { [self] bytes in
            let port = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            guard port > 0, allowsHost(host) else { close(); return }
            let p = parameters()
            let remote = NWConnection(host: .init(resolveHost(host)), port: .init(rawValue: port)!, using: p); self.remote = remote
            var connected = false
            remote.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !connected else { return }; connected = true
                    self.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])) { [weak self] in
                        guard let self else { return }; self.pump(self.local, remote); self.pump(remote, self.local)
                    }
                case .failed: self.close()
                default: break
                }
            }
            remote.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in if !connected { self?.close() } }
        }
    }
    func pump(_ source: NWConnection, _ target: NWConnection) {
        guard !closed else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(); return }
            target.send(content: data, isComplete: complete, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || complete { self.close() } else { self.pump(source, target) }
            })
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        local.stateUpdateHandler = nil; remote?.stateUpdateHandler = nil
        local.cancel(); remote?.cancel(); remote = nil
        let callback = onClose; onClose = nil; callback?()
    }
}
public enum PortalRelayPolicy {
    public static func allowed(host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return !h.isEmpty && h != "localhost" && !h.hasSuffix(".localhost") &&
            !h.hasPrefix("127.") && h != "0.0.0.0" && h != "::" && h != "::1" &&
            h != "0:0:0:0:0:0:0:1" && !h.hasPrefix("::ffff:127.")
    }
}
