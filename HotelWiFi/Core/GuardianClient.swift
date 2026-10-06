import Foundation
import ServiceManagement
import Security

public enum HotelWiFiService {
    public static let identifier = "com.hotelwifi.RecoveryGuardian"
    public static let plist = "com.hotelwifi.RecoveryGuardian.plist"
    public static var registration: SMAppService { .daemon(plistName: plist) }
    public static func validatedJobIdentifier(_ value: String?) -> String? {
        guard let value, value.range(of: "^com\\.hotelwifi\\.RecoveryGuardian\\.[a-f0-9]{24}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    public static var jobIdentifier: String {
        let executable = Bundle.main.executableURL
        let containingApp = executable.flatMap { Bundle(url: $0.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let value = (Bundle.main.object(forInfoDictionaryKey: "HotelWiFiGuardianLabel") ?? containingApp?.object(forInfoDictionaryKey: "HotelWiFiGuardianLabel")) as? String
        return validatedJobIdentifier(value) ?? identifier
    }
    public static func ownTeamID() -> String? {
        var code: SecCode?; guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
@objc public protocol GuardianXPC {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}
public enum GuardianAction: String, Codable { case status, prepare, arm, apply, verify, commit, heartbeat, rollback, restoreAll, scanCandidates, prepareLink, armLink, applyLink, commitLink, heartbeatLink }
public struct GuardianRequest: Codable {
    public var action: GuardianAction
    public var transaction: UUID?
    public var nonce: String?
    public var context: NetworkContext?
    public var policy: OptimizationPolicy?
    public var proposal: MutationProposal?
    public var linkIntent: LinkIntent?
    public var verification: [MeasurementWindow]?
    public init(_ action: GuardianAction, transaction: UUID? = nil, nonce: String? = nil,
                context: NetworkContext? = nil, policy: OptimizationPolicy? = nil, proposal: MutationProposal? = nil,
                linkIntent: LinkIntent? = nil, verification: [MeasurementWindow]? = nil) {
        self.action = action; self.transaction = transaction; self.nonce = nonce; self.context = context; self.policy = policy; self.proposal = proposal
        self.linkIntent = linkIntent; self.verification = verification
    }
}
public struct GuardianResponse: Codable {
    public var ok: Bool
    public var message: String
    public var record: RecoveryRecord?
    public var managedConfiguration: Bool?
    public var linkRecord: LinkRecord?
    public var candidates: [WiFiCandidate]?
    public var trafficObservationReady: Bool?
    public var associationIdentityReadable: Bool?
    public init(ok: Bool, message: String, record: RecoveryRecord? = nil, managedConfiguration: Bool? = nil, linkRecord: LinkRecord? = nil, candidates: [WiFiCandidate]? = nil, trafficObservationReady: Bool? = nil, associationIdentityReadable: Bool? = nil) {
        self.ok = ok; self.message = message; self.record = record; self.managedConfiguration = managedConfiguration
        self.linkRecord = linkRecord; self.candidates = candidates
        self.trafficObservationReady = trafficObservationReady; self.associationIdentityReadable = associationIdentityReadable
    }
}
/// Public logs/CLI expose references and status only. Original field values and session tokens stay private.
public struct RecoveryStatusReport: Codable {
    public var ok: Bool
    public var message: String
    public var transactionID: UUID?
    public var field: ManagedField?
    public var phase: TransactionPhase?
    public var configurationRestored: Bool?
    public var connectionReestablished: Bool?
    public var applicationValidated: Bool?
    public var detail: String?
    public var linkAction: LinkAction?
    public var linkPhase: LinkPhase?
    public init(_ response: GuardianResponse) {
        ok = response.ok; message = response.message; transactionID = response.record?.id
        field = response.record?.target.field; phase = response.record?.phase
        configurationRestored = response.record?.configurationRestored
        connectionReestablished = response.record?.connectionReestablished
        applicationValidated = response.record?.applicationValidated; detail = response.record?.detail
        linkAction = response.linkRecord?.action; linkPhase = response.linkRecord?.phase
        if let link = response.linkRecord {
            transactionID = link.id; configurationRestored = link.configurationRestored
            connectionReestablished = link.connectionReestablished; applicationValidated = link.applicationValidated; detail = link.detail
        }
    }
}
private final class ReplyOnce: @unchecked Sendable {
    let lock = NSLock()
    var callback: ((GuardianResponse) -> Void)?
    init(_ callback: @escaping (GuardianResponse) -> Void) { self.callback = callback }
    func resolve(_ value: GuardianResponse) { let c = lock.withLock { let c = callback; callback = nil; return c }; c?(value) }
}
public final class GuardianClient: @unchecked Sendable {
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    public init() {}
    deinit { connection?.invalidate() }
    public func call(_ request: GuardianRequest) async -> GuardianResponse {
        guard let requirement = CodeSigningTrust.current()?.requirement(identifiers: ["com.hotelwifi.helper"]) else {
            return .init(ok: false, message: "此构建没有可验证的项目签名。请安装本机证书签名版或 Developer ID 版。")
        }
        guard let data = try? JSONCoding.encoder.encode(request), data.count <= 512_000 else { return .init(ok: false, message: "请求过大或编码失败。") }
        let c = lock.withLock { () -> NSXPCConnection in
            if let connection { return connection }
            let c = NSXPCConnection(machServiceName: HotelWiFiService.identifier, options: .privileged)
            c.setCodeSigningRequirement(requirement)
            c.remoteObjectInterface = NSXPCInterface(with: GuardianXPC.self)
            c.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
            c.resume(); connection = c; return c
        }
        return await withCheckedContinuation { continuation in
            let once = ReplyOnce { continuation.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + (request.action == .status ? 3 : 10)) {
                once.resolve(.init(ok: false, message: "辅助服务响应超时；停止新写操作。"))
            }
            guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in once.resolve(.init(ok: false, message: "辅助服务不可用或授权已撤销。")) }) as? GuardianXPC else {
                once.resolve(.init(ok: false, message: "无法建立经过验证的辅助服务连接。")); return
            }
            proxy.request(data) { response in
                guard response.count <= 512_000, let result = try? JSONCoding.decoder.decode(GuardianResponse.self, from: response) else { once.resolve(.init(ok: false, message: "辅助服务返回格式异常。")); return }
                once.resolve(result)
            }
        }
    }
}
