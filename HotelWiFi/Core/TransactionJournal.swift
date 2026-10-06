import Foundation
import CryptoKit

public enum ManagedField: String, Codable, Sendable, CaseIterable {
    case dnsServers, autoProxyDiscovery
    public var entity: String { self == .dnsServers ? "DNS" : "Proxies" }
    public var key: String { self == .dnsServers ? "ServerAddresses" : "ProxyAutoDiscoveryEnable" }
    public var operation: OperationKind { self == .dnsServers ? .dns : .automaticProxyDiscovery }
}
public enum FieldValue: Codable, Equatable, Sendable { case strings([String]), integer(Int) }
public struct FieldSnapshot: Codable, Equatable, Sendable {
    public var value: FieldValue?
    public var existed: Bool { value != nil }
    public init(_ value: FieldValue?) { self.value = value }
}
public struct FieldTarget: Codable, Equatable, Sendable {
    public var serviceID: String
    public var field: ManagedField
    public init(serviceID: String, field: ManagedField) { self.serviceID = serviceID; self.field = field }
}
public enum TransactionPhase: String, Codable, Sendable { case prepared, armed, applied, verified, committed, rollingBack, restored, conflict, waiting }
public struct RecoveryRecord: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var target: FieldTarget
    public var original: FieldSnapshot
    public var written: FieldSnapshot
    public var context: NetworkContext
    public var ownerUID: UInt32
    public var sessionNonce: String
    public var created = Date()
    public var expires: Date
    public var heartbeat = Date()
    public var phase: TransactionPhase = .prepared
    public var configurationRestored = false
    public var connectionReestablished = false
    public var applicationValidated = false
    public var detail: String?
    public var terminal: Bool { phase == .restored || phase == .conflict }
}
private struct JournalEnvelope: Codable {
    var version = 1
    var payload: Data
    var digest: String
}
public protocol JournalPersistence: AnyObject {
    func load() throws -> RecoveryRecord?
    func save(_ record: RecoveryRecord) throws
}
public final class TransactionJournal: JournalPersistence {
    private let store: SecureStore
    public init(store: SecureStore) { self.store = store }
    public func load() throws -> RecoveryRecord? {
        guard let data = try store.read("recovery.json") else { return nil }
        let envelope: JournalEnvelope
        do { envelope = try JSONCoding.decoder.decode(JournalEnvelope.self, from: data) }
        catch { throw HWError.storage("恢复日志损坏；已禁止新写操作。") }
        guard envelope.version == 1, SHA256.hash(data: envelope.payload).hex == envelope.digest else { throw HWError.storage("恢复日志版本或校验失败；已禁止新写操作。") }
        return try JSONCoding.decoder.decode(RecoveryRecord.self, from: envelope.payload)
    }
    public func save(_ record: RecoveryRecord) throws {
        let data = try JSONCoding.encoder.encode(record)
        try store.write(try JSONCoding.encoder.encode(JournalEnvelope(payload: data, digest: SHA256.hash(data: data).hex)), named: "recovery.json")
    }
}
public protocol ConfigurationBackend: AnyObject {
    func read(_ target: FieldTarget) throws -> FieldSnapshot
    /// Implementations MUST lock system preferences and compare again under that lock.
    func compareAndSet(_ target: FieldTarget, expected: FieldSnapshot, desired: FieldSnapshot) throws
}

/// State machine shared by the privileged guardian and fault-injection tests. Caller serializes access.
public final class RecoveryCoordinator {
    public let backend: ConfigurationBackend
    public let journal: JournalPersistence
    public init(backend: ConfigurationBackend, journal: JournalPersistence) { self.backend = backend; self.journal = journal }
    public func prepare(target: FieldTarget, value: FieldValue, context: NetworkContext, uid: UInt32, nonce: String, now: Date = Date()) throws -> RecoveryRecord {
        if let old = try journal.load(), !old.terminal { throw HWError.busy }
        let original = try backend.read(target)
        guard original != FieldSnapshot(value) else { throw HWError.blocked("候选值与当前配置相同。") }
        let record = RecoveryRecord(target: target, original: original, written: .init(value), context: context,
                                    ownerUID: uid, sessionNonce: nonce, expires: now.addingTimeInterval(120))
        try journal.save(record); return record
    }
    public func arm(_ id: UUID) throws -> RecoveryRecord {
        var r = try record(id); guard r.phase == .prepared else { throw HWError.blocked("恢复登记状态不正确。") }
        guard r.expires > Date() else { throw HWError.blocked("事务已到期。") }
        r.phase = .armed; try journal.save(r)
        guard try journal.load()?.phase == .armed else { throw HWError.storage("恢复登记未持久化。") }
        return r
    }
    public func apply(_ id: UUID, gate: GateInput) throws -> RecoveryRecord {
        var r = try record(id)
        guard r.phase == .armed else { throw HWError.blocked("恢复服务尚未接管。") }
        guard r.expires > Date(), Date().timeIntervalSince(r.heartbeat) <= 45 else { throw HWError.blocked("授权会话或事务已到期。") }
        if let reason = OperationGate.rejection(gate) { throw HWError.blocked(reason) }
        // ARMED is durable before the write. A crash here is recoverable regardless of APPLY log success.
        try backend.compareAndSet(r.target, expected: r.original, desired: r.written)
        guard try backend.read(r.target) == r.written else { throw HWError.blocked("系统未确认实际写入值。") }
        r.phase = .applied; try journal.save(r); return r
    }
    public func verify(_ id: UUID) throws -> RecoveryRecord {
        var r = try record(id)
        guard r.phase == .applied, try backend.read(r.target) == r.written else { throw HWError.blocked("实际配置已发生变化。") }
        r.phase = .verified; try journal.save(r); return r
    }
    public func commit(_ id: UUID, now: Date = Date()) throws -> RecoveryRecord {
        var r = try record(id)
        guard r.phase == .verified, try backend.read(r.target) == r.written else { throw HWError.blocked("未验证的事务不能提交。") }
        guard now < r.expires else { throw HWError.blocked("到期事务不能提交。") }
        r.phase = .committed; r.expires = now.addingTimeInterval(6 * 3600); r.heartbeat = now
        try journal.save(r); return r
    }
    public func beat(_ id: UUID, now: Date = Date()) throws {
        var r = try record(id); guard !r.terminal else { return }; r.heartbeat = now; try journal.save(r)
    }
    @discardableResult public func rollback(_ id: UUID, reason: String) throws -> RecoveryRecord {
        var r = try record(id); if r.terminal { return r }
        r.phase = .rollingBack; r.detail = reason
        // Even if storage has become full, use the already durable original snapshot to attempt cleanup.
        let persistError: Error?
        do { try journal.save(r); persistError = nil } catch { persistError = error }
        do {
            let current = try backend.read(r.target)
            if current == r.original {
                r.phase = .restored; r.configurationRestored = true
            } else if current == r.written {
                try backend.compareAndSet(r.target, expected: r.written, desired: r.original)
                guard try backend.read(r.target) == r.original else { throw HWError.storage("恢复写入尚未确认。") }
                r.phase = .restored; r.configurationRestored = true
            } else {
                r.phase = .conflict; r.detail = "当前字段已被外部修改，保留后续修改。"
            }
        } catch {
            r.phase = .waiting; r.detail = "等待目标服务可读取后重试恢复。"
            try? journal.save(r); throw error
        }
        try journal.save(r)
        if let persistError { throw persistError }
        return r
    }
    public func recoverOnStartup() throws -> RecoveryRecord? {
        guard let r = try journal.load(), !r.terminal else { return try journal.load() }
        return try rollback(r.id, reason: "辅助服务启动时处理遗留事务")
    }
    public func tick(now: Date, sleeping: Bool, sameContext: Bool) throws -> RecoveryRecord? {
        guard let r = try journal.load(), !r.terminal else { return nil }
        if sleeping { return r }
        if !sameContext || now >= r.expires || now.timeIntervalSince(r.heartbeat) > 45 {
            return try rollback(r.id, reason: !sameContext ? "网络变化；只清理本程序的字段" : "会话到期或主应用失联")
        }
        return r
    }
    public func record(_ id: UUID) throws -> RecoveryRecord {
        guard let r = try journal.load(), r.id == id else { throw HWError.invalid("恢复事务不存在。") }; return r
    }
}
