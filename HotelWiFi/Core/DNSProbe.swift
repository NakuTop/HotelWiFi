import Foundation
import Network

public struct DNSResult: Codable, Sendable {
    public var address: String?
    public var duration: Double?
    public var receivedBytes: Int
    public var valid: Bool
}
public enum DNSWire {
    public static func query(host: String, id: UInt16) throws -> Data {
        let labels = host.split(separator: ".")
        guard host.utf8.count <= 253, !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.utf8.allSatisfy { $0 >= 33 && $0 <= 126 } }) else { throw HWError.invalid("DNS 名称无效。") }
        var d = Data([UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in labels { d.append(UInt8(label.utf8.count)); d.append(contentsOf: label.utf8) }
        d.append(contentsOf: [0, 0, 1, 0, 1]); return d
    }
    public static func address(response: Data, query: Data) -> String? {
        let b = [UInt8](response), q = [UInt8](query)
        guard b.count >= q.count, q.count >= 17, b[0] == q[0], b[1] == q[1], b[2] & 0x80 != 0,
              b[2] & 0x02 == 0, b[3] & 0x0f == 0, b[4] == 0, b[5] == 1,
              Array(b[12..<q.count]) == Array(q[12...]) else { return nil }
        func word(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i+1]) }
        var p = q.count
        for _ in 0..<min(word(6), 64) {
            var labels = 0
            var compressed = false
            while p < b.count && b[p] != 0 {
                if b[p] & 0xc0 == 0xc0 { guard p + 1 < b.count else { return nil }; p += 2; compressed = true; break }
                let n = Int(b[p]); guard n <= 63, p + n + 1 < b.count, labels < 128 else { return nil }
                p += n + 1; labels += 1
            }
            if !compressed && p < b.count && b[p] == 0 { p += 1 }
            guard p + 10 <= b.count else { return nil }
            let type = word(p), cls = word(p+2), len = word(p+8); p += 10
            guard p + len <= b.count else { return nil }
            if type == 1 && cls == 1 && len == 4 { return b[p..<p+4].map(String.init).joined(separator: ".") }
            p += len
        }
        return nil
    }
}
public final class DNSProbe: @unchecked Sendable {
    public init() {}
    public func resolve(host: String, server: String, budget: BudgetManager) async throws -> DNSResult {
        guard ["1.1.1.1", "9.9.9.9"].contains(server) else { throw HWError.invalid("DNS 候选不在白名单中。") }
        try budget.takeDNSQuery(); let timeout = min(2, try budget.startRequest())
        let query = try DNSWire.query(host: host, id: UInt16.random(in: 1...UInt16.max))
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let queue = DispatchQueue(label: "HotelWiFi.dns"), start = Date()
                var done = false
                func finish(_ result: DNSResult) { guard !done else { return }; done = true; connection.cancel(); continuation.resume(returning: result) }
                queue.asyncAfter(deadline: .now() + timeout) { finish(.init(address: nil, duration: nil, receivedBytes: 0, valid: false)) }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: query, completion: .contentProcessed { error in
                            if error != nil { finish(.init(address: nil, duration: nil, receivedBytes: 0, valid: false)); return }
                            connection.receiveMessage { data, _, _, _ in
                                let d = data ?? Data(); let within = budget.consume(d.count)
                                let a = within ? DNSWire.address(response: d, query: query) : nil
                                finish(.init(address: a, duration: Date().timeIntervalSince(start), receivedBytes: d.count, valid: a != nil))
                            }
                        })
                    case .failed, .cancelled: finish(.init(address: nil, duration: nil, receivedBytes: 0, valid: false))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }, onCancel: { connection.cancel() })
    }
}

public struct MutationProposal: Codable, Sendable {
    public var field: ManagedField
    public var value: FieldValue
    public var baseline: [ProbeSample]
    public var controlled: [ProbeSample]
    public init(field: ManagedField, value: FieldValue, baseline: [ProbeSample], controlled: [ProbeSample]) {
        self.field = field; self.value = value; self.baseline = baseline; self.controlled = controlled
    }
    public var hasEvidence: Bool {
        let failing = baseline.filter { $0.path == .system && !$0.complete }
        guard Set(failing.map(\.provider)).count >= 2, failing.count >= 4,
              controlled.count >= 4, controlled.allSatisfy(\.complete), Set(controlled.map(\.provider)).count >= 2 else { return false }
        for id in Set(baseline.map(\.endpoint)) {
            guard baseline.filter({ $0.endpoint == id }).count >= 2,
                  controlled.filter({ $0.endpoint == id }).count >= 2 else { return false }
        }
        switch field {
        case .dnsServers:
            return failing.allSatisfy { $0.failure == .dns } && controlled.allSatisfy { $0.path == .candidateDNS }
        case .autoProxyDiscovery:
            // Authentication, certificate, portal, and content errors are not evidence to disable a proxy.
            return baseline.allSatisfy { !$0.complete && $0.path == .system && ($0.failure == .connect || $0.failure == .timeout) && $0.status != 401 && $0.status != 407 }
                && controlled.allSatisfy { $0.path == .direct }
        }
    }
}
