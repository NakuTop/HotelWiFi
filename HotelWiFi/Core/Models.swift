import Foundation
import CryptoKit

public enum HWError: Error, LocalizedError, Equatable {
    case blocked(String), invalid(String), storage(String), busy, budget, cancelled
    public var errorDescription: String? {
        switch self {
        case .blocked(let s), .invalid(let s), .storage(let s): return s
        case .busy: return "另一个优化会话仍在运行，请先停止并恢复。"
        case .budget: return "已达到测试预算，停止新实验。"
        case .cancelled: return "任务已停止。"
        }
    }
}

public struct OptimizationPolicy: Codable, Equatable, Sendable {
    public var completedOnboarding = false
    public var allowTemporaryDNS = false
    public var allowAutomaticProxyExperiment = false
    public var allowControlledDirect = false
    public var allowReconnect = false
    public var allowSavedNetworks = false
    public var allowMetered = false
    // Optional for backward-compatible decoding of existing saved policies.
    public var linkRecovery: LinkRecoveryPolicy?
    public var payloadLimit = 30_000_000
    public var durationLimit: Double = 180
    public var initialRequests = 3
    public var relativeImprovement = 0.20
    public var absoluteImprovement: Double = 0.100
    public var monitorInterval: Double = 60
    public init() {}
    public func validated() throws -> Self {
        guard (1...5).contains(initialRequests), (100_000...30_000_000).contains(payloadLimit),
              (30...180).contains(durationLimit), (0.05...0.8).contains(relativeImprovement),
              (0.05...5).contains(absoluteImprovement), monitorInterval >= 60 else {
            throw HWError.invalid("策略参数超出安全边界。")
        }
        return self
    }
}

public enum CapabilityState: String, Codable, Sendable { case available, unavailable, unknown, permissionRequired, unverified }
public struct Capability: Codable, Identifiable, Sendable {
    public var id: String
    public var state: CapabilityState
    public var detail: String
    public init(_ id: String, _ state: CapabilityState, _ detail: String) { self.id = id; self.state = state; self.detail = detail }
}
public struct CapabilityRegistry: Codable, Sendable {
    public var osVersion: String
    public var capabilities: [Capability]
    public func available(_ id: String) -> Bool { capabilities.contains { $0.id == id && $0.state == .available } }
}

public enum Confidence: String, Codable, Sendable { case unknown, sessionOnly, corroborated }
public struct RadioReading: Codable, Equatable, Sendable {
    public var rssi: Int?
    public var noise: Int?
    public var transmitMbps: Double?
    public var channel: Int?
    public var band: String?
    public var cca: Double?
    public init(rssi: Int? = nil, noise: Int? = nil, transmitMbps: Double? = nil, channel: Int? = nil, band: String? = nil, cca: Double? = nil) {
        self.rssi = rssi; self.noise = noise; self.transmitMbps = transmitMbps; self.channel = channel; self.band = band; self.cca = cca
    }
}
public struct ProxySummary: Codable, Equatable, Sendable {
    public var manual = false
    public var pac = false
    public var discovery = false
    public var environment = false
    public var managed: Bool? = nil
    public var any: Bool { manual || pac || discovery }
    public init() {}
}

/// Runtime addresses/configuration are not persisted by this model. Identity hashes are keyed locally.
public struct NetworkContext: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var interface: String?
    public var serviceID: String?
    public var serviceName: String?
    public var identity: String?
    public var apIdentity: String?
    public var confidence: Confidence
    public var security: String?
    public var wifiOn: Bool?
    public var hasIPv4: Bool?
    public var hasIPv6: Bool?
    public var hasRoute: Bool?
    public var vpnPresent: Bool
    public var splitDNS: Bool
    public var proxy: ProxySummary
    public var constrained: Bool?
    public var expensive: Bool?
    public var radio: RadioReading
    public var configurationDigest: String?
    public init(sessionID: UUID = UUID(), interface: String? = nil, serviceID: String? = nil,
                serviceName: String? = nil, identity: String? = nil, apIdentity: String? = nil,
                confidence: Confidence = .unknown, security: String? = nil, wifiOn: Bool? = nil,
                hasIPv4: Bool? = nil, hasIPv6: Bool? = nil, hasRoute: Bool? = nil,
                vpnPresent: Bool = false, splitDNS: Bool = false, proxy: ProxySummary = .init(),
                constrained: Bool? = nil, expensive: Bool? = nil, radio: RadioReading = .init(), configurationDigest: String? = nil) {
        self.sessionID = sessionID; self.interface = interface; self.serviceID = serviceID; self.serviceName = serviceName
        self.identity = identity; self.apIdentity = apIdentity; self.confidence = confidence; self.security = security
        self.wifiOn = wifiOn; self.hasIPv4 = hasIPv4; self.hasIPv6 = hasIPv6; self.hasRoute = hasRoute
        self.vpnPresent = vpnPresent; self.splitDNS = splitDNS; self.proxy = proxy
        self.constrained = constrained; self.expensive = expensive; self.radio = radio; self.configurationDigest = configurationDigest
    }
    public func sameNetwork(as other: Self) -> Bool {
        guard let identity, identity == other.identity, interface == other.interface, serviceID == other.serviceID,
              wifiOn == true, other.wifiOn == true else { return false }
        // BSSID is deliberately excluded: roaming within the current network is not a history lookup.
        return true
    }
}

public enum ProbePath: String, Codable, Sendable { case system, direct, ipv4, ipv6, candidateDNS }
public enum ProbeKind: String, Codable, Sendable { case connectivity, object, bandwidth }
public enum BodyRule: Codable, Equatable, Sendable {
    case exactText(String), sha256(String, Int), empty, length(Int)
    public func accepts(_ data: Data) -> Bool {
        switch self {
        case .exactText(let s): return data == Data(s.utf8)
        case .sha256(let hash, let length): return data.count == length && SHA256.hash(data: data).hex == hash
        case .empty: return data.isEmpty
        case .length(let n): return data.count == n
        }
    }
}
public struct ProbeEndpoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var url: URL
    public var kind: ProbeKind
    public var expectedStatus: Int
    public var body: BodyRule
    public var maxBytes: Int
    public init(id: String, provider: String, url: URL, kind: ProbeKind, expectedStatus: Int, body: BodyRule, maxBytes: Int) {
        self.id = id; self.provider = provider; self.url = url; self.kind = kind; self.expectedStatus = expectedStatus; self.body = body; self.maxBytes = maxBytes
    }
    public static let defaults: [Self] = [
        .init(id: "apple-connectivity", provider: "Apple", url: URL(string: "https://www.apple.com/library/test/success.html")!, kind: .connectivity,
              expectedStatus: 200, body: .exactText("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"), maxBytes: 4096),
        .init(id: "google-connectivity", provider: "Google", url: URL(string: "https://www.gstatic.com/generate_204")!, kind: .connectivity,
              expectedStatus: 204, body: .empty, maxBytes: 4096),
        .init(id: "google-fixed-webp", provider: "Google", url: URL(string: "https://www.gstatic.com/webp/gallery/1.sm.webp")!, kind: .object,
              expectedStatus: 200, body: .sha256("eb0b7786cc8f0852e974d91e81b7863cd78413008098ce903deeeda849707512", 10474), maxBytes: 32768)
    ]
    public static func validate(_ items: [Self]) throws {
        guard (2...8).contains(items.count), Set(items.map(\.provider)).count >= 2,
              Set(items.map(\.id)).count == items.count else { throw HWError.invalid("测试端点必须包含至少两个独立服务商且 ID 唯一。") }
        for e in items {
            guard e.url.scheme == "https", e.url.host != nil, e.url.user == nil, e.url.password == nil,
                  e.url.fragment == nil, e.url.query == nil, e.maxBytes > 0, e.maxBytes <= 1_000_000,
                  !e.provider.isEmpty, !e.id.isEmpty else { throw HWError.invalid("端点必须为无凭据、无查询参数的 HTTPS 地址，响应上限为 1 MB。") }
        }
    }
}

public enum ProbeFailure: String, Codable, Sendable { case dns, connect, tls, timeout, cancelled, http, body, redirect, byteLimit, transport, endpoint, parse }
public struct StageTimes: Codable, Equatable, Sendable {
    public var dns: Double?
    public var tcp: Double?
    public var tls: Double?
    public var firstByte: Double?
    public var total: Double?
    public init(dns: Double? = nil, tcp: Double? = nil, tls: Double? = nil, firstByte: Double? = nil, total: Double? = nil) {
        self.dns = dns; self.tcp = tcp; self.tls = tls; self.firstByte = firstByte; self.total = total
    }
}
public struct ProbeSample: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var endpoint: String
    public var provider: String
    public var path: ProbePath
    public var kind: ProbeKind
    public var started = Date()
    public var completed = Date()
    public var status: Int?
    public var originalStatus: Int?
    public var redirectStatuses: [Int] = []
    public var bytes = 0
    public var complete = false
    public var failure: ProbeFailure?
    public var errorCode: Int?
    public var errorDomain: String?
    public var exitCode: Int32?
    public var times = StageTimes()
    public var transportProtocol: String?
    public var reused: Bool?
    public var viaProxy: Bool?
    public var interface: String?
    public var addressFamily: String?
    public init(endpoint: String, provider: String, path: ProbePath = .system, kind: ProbeKind = .connectivity) {
        self.endpoint = endpoint; self.provider = provider; self.path = path; self.kind = kind
    }
}
public struct SampleStatistics: Codable, Sendable {
    public var successes: Int
    public var count: Int
    public var median: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var medianAbsoluteDeviation: Double?
    public var failures: [String: Int]
    public var start: Date?
    public var end: Date?
    public init(_ samples: [ProbeSample]) {
        successes = samples.filter(\.complete).count; count = samples.count
        let values = samples.filter(\.complete).compactMap(\.times.total).sorted()
        median = Self.median(values); minimum = values.first; maximum = values.last
        medianAbsoluteDeviation = median.map { m in Self.median(values.map { abs($0 - m) }.sorted()) ?? 0 }
        failures = Dictionary(grouping: samples.filter { !$0.complete }, by: { $0.failure?.rawValue ?? "unknown" }).mapValues(\.count)
        start = samples.map(\.started).min(); end = samples.map(\.completed).max()
    }
    public static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }; let n = sorted.count
        return n % 2 == 1 ? sorted[n/2] : (sorted[n/2-1] + sorted[n/2])/2
    }
}
public struct MeasurementWindow: Codable, Sendable {
    public var label: String
    public var context: NetworkContext
    public var samples: [ProbeSample]
    public var stats: SampleStatistics { .init(samples.filter { $0.path == .system }) }
    public var fullyHealthy: Bool {
        let s = samples.filter { $0.path == .system }
        return Set(s.map(\.provider)).count >= 2 && !s.isEmpty && s.allSatisfy(\.complete)
    }
    public init(label: String, context: NetworkContext, samples: [ProbeSample]) { self.label = label; self.context = context; self.samples = samples }
}

public struct Observation: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var fact: String
    public var inference: String?
    public init(_ fact: String, inference: String? = nil) { self.fact = fact; self.inference = inference }
}
public struct SessionReport: Codable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var started = Date()
    public var finished: Date?
    public var mode: String
    public var conclusion = "尚未完成最终验证"
    public var evidence = "未验证"
    public var current: NetworkContext?
    public var currentValidatedAt: Date?
    public var windows: [MeasurementWindow] = []
    public var localBefore: LocalConnectionFacts?
    public var localAfter: LocalConnectionFacts?
    public var observations: [Observation] = []
    public var changes: [String] = []
    public var restored: [String] = []
    public var activeTemporary: [String] = []
    public var capabilities: CapabilityRegistry?
    public var payloadBytes = 0
    public var interrupted = false
    public init(mode: String) { self.mode = mode }
}

extension Sequence where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
public enum JSONCoding {
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; e.dateEncodingStrategy = .iso8601; return e }
    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
