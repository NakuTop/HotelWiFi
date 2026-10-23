import Foundation
import ServiceManagement

public enum RadioService {
    public static let identifier = "com.hotelwifi.RadioAgent"
    public static let plist = "com.hotelwifi.RadioAgent.plist"
    public static var registration: SMAppService { .agent(plistName: plist) }
}
public enum RadioAction: String, Codable, Sendable { case status, survey, prepare, apply, heartbeat, commit, restore }
public struct RadioRequest: Codable, Sendable {
    public var action: RadioAction
    public var nonce: String?
    public var transaction: UUID?
    public var context: NetworkContext?
    public var policy: OptimizationPolicy?
    public var windows: [MeasurementWindow]?
    public var validationRoundTrip: Bool
    public init(_ action: RadioAction, nonce: String? = nil, transaction: UUID? = nil, context: NetworkContext? = nil,
                policy: OptimizationPolicy? = nil, windows: [MeasurementWindow]? = nil, validationRoundTrip: Bool = false) {
        self.action = action; self.nonce = nonce; self.transaction = transaction; self.context = context
        self.policy = policy; self.windows = windows; self.validationRoundTrip = validationRoundTrip
    }
}
public enum RadioPhase: String, Codable, Sendable { case prepared, applying, waiting, committed, restored, conflict }
public struct RadioRecord: Codable, Sendable {
    public var id = UUID()
    public var phase: RadioPhase = .prepared
    public var created = Date()
    public var heartbeat = Date()
    public var expires = Date().addingTimeInterval(180)
    public var nonce: String
    public var plan: LinkPlan
    public var validationRoundTrip: Bool
    public var targetObserved = false
    public var lastError: String?
    public var detail = "尚未执行"
    public var restoreAttempts = 0
    public var terminal: Bool { [.committed, .restored, .conflict].contains(phase) }
    public init(nonce: String, plan: LinkPlan, validationRoundTrip: Bool = false) {
        self.nonce = nonce; self.plan = plan; self.validationRoundTrip = validationRoundTrip
    }
}
/// Public XPC results contain no SSID, BSSID, passwords or raw recovery snapshots.
public struct RadioResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var identityReadable: Bool?
    public var survey: RadioSurvey?
    public var transaction: UUID?
    public var phase: RadioPhase?
    public var targetObserved: Bool?
    public var lastError: String?
    public init(ok: Bool, message: String, identityReadable: Bool? = nil, survey: RadioSurvey? = nil, record: RadioRecord? = nil) {
        self.ok = ok; self.message = message; self.identityReadable = identityReadable; self.survey = survey
        transaction = record?.id; phase = record?.phase; targetObserved = record?.targetObserved; lastError = record?.lastError
    }
}
public final class RadioAgentClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    public init() {}
    deinit { connection?.invalidate() }
    public func call(_ request: RadioRequest) async -> RadioResponse {
        guard let requirement = CodeSigningTrust.current()?.requirement(identifiers: ["com.hotelwifi.radioagent"]),
              let data = try? JSONCoding.encoder.encode(request), data.count <= 512_000 else {
            return .init(ok: false, message: "无线会话服务签名或请求格式不可用。")
        }
        let connection = lock.withLock { () -> NSXPCConnection in
            if let connection = self.connection { return connection }
            let c = NSXPCConnection(machServiceName: RadioService.identifier, options: [])
            c.setCodeSigningRequirement(requirement); c.remoteObjectInterface = NSXPCInterface(with: GuardianXPC.self)
            c.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
            c.resume(); self.connection = c; return c
        }
        return await withCheckedContinuation { continuation in
            let once = RadioReplyOnce { continuation.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + (request.action == .survey || request.action == .prepare ? 25 : 5)) {
                once.resolve(.init(ok: false, message: "无线会话服务响应超时，未确认切换结果。"))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                once.resolve(.init(ok: false, message: "无线会话服务未连接；请检查后台授权。"))
            }) as? GuardianXPC else { once.resolve(.init(ok: false, message: "无线会话连接不可用。")); return }
            proxy.request(data) { data in
                guard data.count <= 512_000, let r = try? JSONCoding.decoder.decode(RadioResponse.self, from: data) else {
                    once.resolve(.init(ok: false, message: "无线会话服务返回格式异常。")); return
                }
                once.resolve(r)
            }
        }
    }
}
private final class RadioReplyOnce: @unchecked Sendable {
    let lock = NSLock()
    var callback: ((RadioResponse) -> Void)?
    init(_ callback: @escaping (RadioResponse) -> Void) { self.callback = callback }
    func resolve(_ r: RadioResponse) { let cb = lock.withLock { let cb = callback; callback = nil; return cb }; cb?(r) }
}
