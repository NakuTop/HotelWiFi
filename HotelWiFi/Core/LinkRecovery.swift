import Foundation
import CryptoKit

public struct LinkRecoveryPolicy: Codable, Equatable, Sendable {
    public var allowDHCPRenew = false
    /// Remains off by default: idle counters cannot establish that a call/session is unimportant.
    public var allowIdleInterruption = false
    public init() {}
}
public enum LinkAction: String, Codable, Sendable { case renewDHCP, reconnect, associate }
public struct LinkIntent: Codable, Sendable {
    public var action: LinkAction
    public var candidateID: UUID?
    public var approvePossibleCost: Bool
    public var baseline: [ProbeSample]
    public init(_ action: LinkAction, candidateID: UUID? = nil, approvePossibleCost: Bool = false, baseline: [ProbeSample]) {
        self.action = action; self.candidateID = candidateID; self.approvePossibleCost = approvePossibleCost; self.baseline = baseline
    }
    public var repeatedFailure: Bool {
        let s = baseline.filter { $0.path == .system }
        return s.count >= 4 && Set(s.map(\.provider)).count >= 2 &&
            Dictionary(grouping: s, by: \.provider).values.allSatisfy { $0.count >= 2 } &&
            s.allSatisfy { !$0.complete && [.dns, .connect, .timeout, .transport].contains($0.failure) &&
                Date().timeIntervalSince($0.completed) <= 180 && $0.completed <= Date().addingTimeInterval(1) }
    }
    public var operation: OperationKind { action == .renewDHCP ? .dhcpRenew : action == .reconnect ? .reconnect : .associate }
}
/// Returned only for a user-initiated scan, never written into history or exported reports.
public struct WiFiCandidate: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bssid: String?
    public var channel: Int?
    public var rssi: Int?
    public var currentNetwork: Bool
    public var expires: Date
    public init(id: UUID = UUID(), name: String, bssid: String?, channel: Int?, rssi: Int?, currentNetwork: Bool, expires: Date) {
        self.id = id; self.name = name; self.bssid = bssid; self.channel = channel; self.rssi = rssi; self.currentNetwork = currentNetwork; self.expires = expires
    }
}
/// Sensitive recovery material. Only stored in an AES-GCM envelope in the root private store.
/// Passwords are never part of this value; the backend reads existing keychain credentials on demand.
public struct AssociationSnapshot: Codable, Equatable, Sendable {
    public var interface: String
    public var serviceID: String
    public var ssid: Data
    public var bssid: String?
    public var security: Int
    public var configurationDigest: String
    public init(interface: String, serviceID: String, ssid: Data, bssid: String?, security: Int, configurationDigest: String) {
        self.interface = interface; self.serviceID = serviceID; self.ssid = ssid; self.bssid = bssid; self.security = security; self.configurationDigest = configurationDigest
    }
}
public struct LinkPlan: Codable, Sendable {
    public var action: LinkAction
    public var original: AssociationSnapshot
    public var target: AssociationSnapshot
    public init(action: LinkAction, original: AssociationSnapshot, target: AssociationSnapshot) { self.action = action; self.original = original; self.target = target }
}
public struct LinkObservation: Sendable {
    public var wifiOn: Bool?
    public var ssid: Data?
    public var bssid: String?
    public var configurationDigest: String?
    public var hasUsableAddress: Bool
    public var protectedPathChanged: Bool
    public init(wifiOn: Bool?, ssid: Data?, bssid: String?, configurationDigest: String?, hasUsableAddress: Bool, protectedPathChanged: Bool = false) {
        self.wifiOn = wifiOn; self.ssid = ssid; self.bssid = bssid; self.configurationDigest = configurationDigest; self.hasUsableAddress = hasUsableAddress
        self.protectedPathChanged = protectedPathChanged
    }
}
public enum LinkPhase: String, Codable, Sendable { case prepared, armed, applying, verifying, committed, restoring, restored, conflict, waiting }
public struct LinkRecord: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var action: LinkAction
    public var context: NetworkContext
    public var ownerUID: UInt32
    public var nonce: String
    public var phase: LinkPhase = .prepared
    public var created = Date()
    public var expires: Date
    public var heartbeat = Date()
    public var restoreAttempts = 0
    public var configurationRestored = false
    public var connectionReestablished = false
    public var applicationValidated = false
    public var requestedAPObserved: Bool?
    public var actualAPDigest: String?
    public var detail = "尚未执行"
    // A committed association has no temporary system configuration to undo. macOS maintains it.
    // Never break a validated connection on exit just to return to a historical AP/network.
    public var terminal: Bool { phase == .restored || phase == .conflict || phase == .committed }
}
public protocol LinkJournalPersistence: AnyObject {
    func load() throws -> LinkRecord?
    func save(_ record: LinkRecord) throws
    func savePlan(_ plan: LinkPlan, id: UUID) throws
    func plan(id: UUID) throws -> LinkPlan
}
public final class LinkJournal: LinkJournalPersistence {
    let store: SecureStore
    public init(store: SecureStore) { self.store = store }
    private struct Envelope: Codable { var version = 1; var data: Data; var digest: String }
    public func load() throws -> LinkRecord? {
        guard let data = try store.read("link-recovery.json") else { return nil }
        guard let envelope = try? JSONCoding.decoder.decode(Envelope.self, from: data), envelope.version == 1,
              SHA256.hash(data: envelope.data).hex == envelope.digest else { throw HWError.storage("关联恢复日志损坏；禁止新操作。") }
        return try JSONCoding.decoder.decode(LinkRecord.self, from: envelope.data)
    }
    public func save(_ record: LinkRecord) throws {
        let data = try JSONCoding.encoder.encode(record)
        try store.write(JSONCoding.encoder.encode(Envelope(data: data, digest: SHA256.hash(data: data).hex)), named: "link-recovery.json")
    }
    public func savePlan(_ plan: LinkPlan, id: UUID) throws {
        let key = SymmetricKey(data: try store.identityKey())
        let box = try AES.GCM.seal(JSONCoding.encoder.encode(plan), using: key, authenticating: Data(id.uuidString.utf8))
        guard let data = box.combined else { throw HWError.storage("无法加密恢复材料。") }
        try store.write(data, named: "link-plan.sealed")
    }
    public func plan(id: UUID) throws -> LinkPlan {
        guard let data = try store.read("link-plan.sealed") else { throw HWError.storage("关联恢复材料不存在。") }
        let clear = try AES.GCM.open(.init(combined: data), using: .init(data: store.identityKey()), authenticating: Data(id.uuidString.utf8))
        return try JSONCoding.decoder.decode(LinkPlan.self, from: clear)
    }
}

/// Shared durable state machine. The daemon serializes methods; native association runs off that queue.
/// No method can switch WiFi power, occupy an old address, alter saved networks or claim an AP lock.
public final class LinkRecoveryCoordinator {
    public let journal: LinkJournalPersistence
    public init(journal: LinkJournalPersistence) { self.journal = journal }
    public func record(_ id: UUID) throws -> LinkRecord {
        guard let r = try journal.load(), r.id == id else { throw HWError.invalid("关联事务不存在。") }; return r
    }
    public func prepare(plan: LinkPlan, context: NetworkContext, uid: UInt32, nonce: String) throws -> LinkRecord {
        if let old = try journal.load(), !old.terminal { throw HWError.busy }
        let r = LinkRecord(action: plan.action, context: context, ownerUID: uid, nonce: nonce, expires: Date().addingTimeInterval(120))
        try journal.savePlan(plan, id: r.id); try journal.save(r); return r
    }
    public func arm(_ id: UUID) throws -> LinkRecord {
        var r = try record(id)
        guard r.phase == .prepared, r.expires > Date() else { throw HWError.blocked("关联恢复登记无效或已到期。") }
        _ = try journal.plan(id: id); r.phase = .armed; try journal.save(r)
        guard try record(id).phase == .armed else { throw HWError.storage("未确认关联恢复登记。") }; return r
    }
    public func beginApply(_ id: UUID, gate: GateInput) throws -> LinkPlan {
        var r = try record(id)
        guard r.phase == .armed, r.expires > Date(), Date().timeIntervalSince(r.heartbeat) < 45 else { throw HWError.blocked("关联恢复服务尚未接管或授权到期。") }
        if let reason = OperationGate.rejection(gate) { throw HWError.blocked(reason) }
        let plan = try journal.plan(id: id)
        r.phase = .applying; r.detail = "已登记单次系统请求，等待网络事件"; try journal.save(r); return plan
    }
    public func observe(_ id: UUID, _ observed: LinkObservation, error: String? = nil) throws -> LinkRecord {
        var r = try record(id); guard !r.terminal else { return r }
        let plan = try journal.plan(id: id)
        if observed.protectedPathChanged || observed.wifiOn != true || observed.configurationDigest != plan.original.configurationDigest ||
            (observed.ssid != nil && observed.ssid != plan.original.ssid && observed.ssid != plan.target.ssid) {
            r.phase = .conflict; r.detail = "网络、电源或配置已被外部改变；不争夺控制权"
        } else if observed.ssid == plan.target.ssid && observed.hasUsableAddress {
            r.phase = .verifying; r.detail = "已观察到目标网络及可用地址；等待应用复测"
            r.actualAPDigest = observed.bssid.map { PrivacyFilter(key: Data(r.nonce.utf8)).digest([$0]) }
            r.requestedAPObserved = plan.target.bssid.flatMap { wanted in observed.bssid.map { $0 == wanted } }
        } else { r.phase = .waiting; r.detail = error ?? "等待系统地址和路由事件，不重复发起重连" }
        try journal.save(r); return r
    }
    public func commit(_ id: UUID, windows: [MeasurementWindow]) throws -> LinkRecord {
        var r = try record(id)
        guard r.phase == .verifying, r.expires > Date(), LinkSelection.acceptsRecovery(windows) else { throw HWError.blocked("两次当前网络应用验证尚未通过。") }
        r.phase = .committed; r.applicationValidated = true; r.heartbeat = Date(); r.expires = Date().addingTimeInterval(6*3600)
        r.detail = "当前关联通过两次应用复测；不宣称严格 A/B 或持续 AP 锁定"; try journal.save(r); return r
    }
    public func beat(_ id: UUID) throws {
        var r = try record(id); guard !r.terminal else { return }; r.heartbeat = Date(); try journal.save(r)
    }
    /// Returns at most one recovery association. Off/unknown/another network always wins.
    /// After restart a disconnected interface is never made to join an old hotel.
    public func beginRestore(_ id: UUID, observation: LinkObservation, startup: Bool) throws -> AssociationSnapshot? {
        var r = try record(id); guard !r.terminal else { return nil }
        let p = try journal.plan(id: id)
        if r.phase == .prepared || r.phase == .armed {
            r.phase = .restored; r.configurationRestored = true; r.detail = "尚未发出系统请求，无修改需要撤销"
        } else if observation.protectedPathChanged || observation.wifiOn != true || observation.configurationDigest != p.original.configurationDigest ||
            (observation.ssid != nil && observation.ssid != p.target.ssid && observation.ssid != p.original.ssid) {
            r.phase = .conflict; r.detail = "保留用户后续切网、关 WiFi 或设置修改"
        } else if p.action == .renewDHCP || observation.ssid == p.original.ssid {
            r.phase = .restored; r.configurationRestored = true
            r.connectionReestablished = observation.ssid == p.original.ssid && observation.hasUsableAddress
            r.detail = p.action == .renewDHCP ? "DHCP 配置方式未更改；不强占旧租约或重复续租" : "当前已在原网络；原 AP 未被保证"
        } else if observation.ssid == p.target.ssid && observation.bssid.map({ PrivacyFilter(key: Data(r.nonce.utf8)).digest([$0]) }) != (r.actualAPDigest ?? p.target.bssid.map { PrivacyFilter(key: Data(r.nonce.utf8)).digest([$0]) }) {
            r.phase = .conflict; r.detail = "AP 已变化，无法确认仍在本次候选网络；不重新加入旧酒店"
        } else if r.restoreAttempts > 0 && observation.ssid != nil {
            r.phase = .conflict; r.detail = "单次恢复未回到原网络；保留实际连接，不循环重连"
        } else if (startup && observation.ssid == nil) || r.restoreAttempts > 0 {
            r.phase = .waiting; r.detail = "等待网络重新出现；不会循环重连或重新加入旧酒店"
        } else if observation.ssid == p.target.ssid {
            r.phase = .restoring; r.restoreAttempts += 1; r.detail = "已登记一次原网络恢复请求"
            try journal.save(r); return p.original
        } else { r.phase = .waiting; r.detail = "当前关联不可辨认，保留用户可能的断开操作；等待原网络重新出现" }
        try journal.save(r); return nil
    }
    public func finishRestore(_ id: UUID, observation: LinkObservation) throws -> LinkRecord {
        var r = try record(id); let p = try journal.plan(id: id)
        guard !r.terminal else { return r }
        if observation.wifiOn != true || (observation.ssid != nil && observation.ssid != p.original.ssid) {
            r.phase = .conflict; r.detail = "原网络未恢复；保留当前实际连接，不重复尝试"
        } else if observation.ssid == p.original.ssid {
            r.phase = .restored; r.configurationRestored = true; r.connectionReestablished = observation.hasUsableAddress
            r.detail = "已观察到原网络，地址/应用连通性分别确认；未宣称恢复原 AP"
        } else { r.phase = .waiting; r.detail = "单次恢复请求已返回，等待网络事件" }
        r.applicationValidated = false; try journal.save(r); return r
    }
}
public enum LinkSelection {
    public static func acceptsRecovery(_ windows: [MeasurementWindow]) -> Bool {
        guard windows.count == 2, windows.allSatisfy(\.fullyHealthy),
              windows[0].context.sameNetwork(as: windows[1].context),
              Set(windows[0].samples.map(\.endpoint)) == Set(windows[1].samples.map(\.endpoint)) else { return false }
        return windows.allSatisfy { $0.samples.count >= 4 && Dictionary(grouping: $0.samples, by: \.provider).values.allSatisfy { $0.count >= 2 } }
    }
}
