import Foundation
import HotelWiFiCore
import HotelWiFiPlatform
import SystemConfiguration
import IOKit
import IOKit.pwr_mgt

enum CallerValidation {
    static func requirement() -> String? {
        CodeSigningTrust.current()?.requirement(identifiers: ["com.hotelwifi.app", "com.hotelwifi.cli"])
    }
    static func consoleUser(_ uid: uid_t) -> Bool {
        var console: uid_t = 0, group: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &console, &group) != nil else { return false }
        return uid != 0 && uid == console
    }
}

final class RecoveryGuardian: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "HotelWiFi.Guardian.serial")
    let coordinator: RecoveryCoordinator
    let links: LinkRecoveryCoordinator
    let nativeLink = NativeLinkBackend()
    let traffic = TrafficMonitor()
    let linkWorker = DispatchQueue(label: "HotelWiFi.Guardian.association")
    var linkBusy = false
    var linkStopRequested = false
    var linkOwnerConnection: UUID?
    var linkPolicy: OptimizationPolicy?
    var linkIntent: LinkIntent?
    var candidates: [UUID: (WiFiCandidate, AssociationSnapshot, UUID, String?)] = [:]
    var lastScan = Date.distantPast
    var attempts: [String: Int] = [:]
    let inspector = NetworkInspector()
    let storeLock: StoreLock
    var timer: DispatchSourceTimer?
    var networkEvents: NetworkEvents?
    var sleeping = false
    var ownerConnection: UUID?
    var policy: OptimizationPolicy?
    var proposal: MutationProposal?
    var expectedContext: NetworkContext?
    var managed: Bool?
    var startupError: String?
    var powerPort: IONotificationPortRef?
    var powerNotifier: io_object_t = 0
    var powerConnection: io_connect_t = 0

    init(store: SecureStore) throws {
        storeLock = try store.acquireLock("guardian.lock")
        coordinator = RecoveryCoordinator(backend: SystemConfigurationBackend(), journal: TransactionJournal(store: store))
        links = LinkRecoveryCoordinator(journal: LinkJournal(store: store))
        super.init()
        // No new request is accepted until all durable state has been read and recovery attempted.
        do { _ = try coordinator.recoverOnStartup() } catch { startupError = error.localizedDescription }
        do { try restoreLink(startup: true) } catch { startupError = error.localizedDescription }
        managed = Self.readManagedProfiles()
        let t = DispatchSource.makeTimerSource(queue: queue); t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.tick() }; timer = t; t.resume()
        networkEvents = NetworkEvents(keysHandler: { [weak self] keys in
            self?.queue.async {
                guard let self, !self.sleeping else { return }
                self.tickLink()
                guard let r = try? self.coordinator.journal.load(), !r.terminal else { return }
                if let interface = r.context.interface, keys.contains("State:/Network/Interface/\(interface)/Link") {
                    self.cleanup("无线链路重建；结束旧会话，不复用同名网络策略")
                } else { self.tick() }
            }
        })
        if networkEvents?.available != true { startupError = "无法登记网络变化事件；禁止写操作。" }
        installPowerNotifications()
    }
    static func readManagedProfiles() -> Bool? {
        let result = BoundedProcess.run("/usr/bin/profiles", ["show", "-type", "configuration", "-output", "stdout-xml"], timeout: 5, maxBytes: 262144)
        guard result.status == 0, let object = try? PropertyListSerialization.propertyList(from: result.data, options: [], format: nil), let profiles = object as? [String: Any] else { return nil }
        // Empty profile inventories establish absence. Any installed/unknown profile remains protected.
        if profiles.isEmpty { return false }
        if profiles.values.allSatisfy({ ($0 as? [Any])?.isEmpty == true }) { return false }
        return true
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = CallerValidation.requirement(), CallerValidation.consoleUser(connection.effectiveUserIdentifier), connection.auditSessionIdentifier > 0 else { return false }
        let id = UUID(), uid = connection.effectiveUserIdentifier
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: GuardianXPC.self)
        connection.exportedObject = GuardianEndpoint(guardian: self, id: id, uid: uid)
        connection.invalidationHandler = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                if self.ownerConnection == id { self.cleanup("主应用连接失联") }
                if self.linkOwnerConnection == id { try? self.restoreLink(startup: false) }
            }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume(); return true
    }
    func context(_ r: RecoveryRecord) -> NetworkContext {
        var c = inspector.read(session: r.context.sessionID, privacy: .init(key: Data(r.sessionNonce.utf8))).context
        c.proxy.managed = managed; return c
    }
    func cleanup(_ reason: String) {
        do {
            if let r = try coordinator.journal.load(), !r.terminal { _ = try coordinator.rollback(r.id, reason: reason) }
            ownerConnection = nil; expectedContext = nil; policy = nil; proposal = nil
            try restoreLink(startup: false)
        } catch { startupError = error.localizedDescription }
    }
    func sameProtectedContext(_ original: RecoveryRecord, _ current: NetworkContext) -> Bool {
        original.context.sameNetwork(as:current) && original.context.vpnPresent == current.vpnPresent &&
        original.context.splitDNS == current.splitDNS && original.context.proxy.manual == current.proxy.manual &&
        original.context.proxy.pac == current.proxy.pac && original.context.constrained == current.constrained &&
        (original.context.confidence == .corroborated || original.context.apIdentity == current.apIdentity) &&
        (original.target.field == .autoProxyDiscovery || original.context.proxy.discovery == current.proxy.discovery) &&
        (current.expensive == false || policy?.allowMetered == true)
    }
    func tick() {
        guard !sleeping else { return }
        let currentInterface = inspector.read(session: UUID(), privacy: .init(key: Data("traffic-sampling".utf8))).context.interface
        traffic.sample(interface: currentInterface)
        tickLink()
        do {
            guard let r = try coordinator.journal.load(), !r.terminal else { return }
            let current = context(r)
            let matches = sameProtectedContext(r, current)
            let configMatches = expectedContext.map { $0.configurationDigest == current.configurationDigest } ?? false
            _ = try coordinator.tick(now: Date(), sleeping: sleeping, sameContext: matches && configMatches)
        } catch { startupError = error.localizedDescription }
    }
    func perform(_ request: GuardianRequest, connection: UUID, uid: uid_t) throws -> GuardianResponse {
        guard CallerValidation.consoleUser(uid) else { throw HWError.blocked("调用者不再是当前登录用户。") }
        if request.action == .status {
            if let startupError { return .init(ok: false, message: startupError, managedConfiguration: managed) }
            let r = try coordinator.journal.load()
            let l = try links.journal.load()
            let visible = inspector.read(session: UUID(), privacy: .init(key: Data("capability-read".utf8))).ssid != nil
            return .init(ok: true, message: "恢复服务已就绪", record: r?.ownerUID == uid ? r : nil, managedConfiguration: managed,
                         linkRecord: l?.ownerUID == uid ? l : nil, trafficObservationReady: traffic.recentRate != nil, associationIdentityReadable: visible)
        }
        if request.action == .restoreAll {
            if let l = try links.journal.load(), !l.terminal {
                guard l.ownerUID == uid else { throw HWError.blocked("不能操作其他用户的关联事务。") }
                try restoreLink(startup: false)
                let after = try links.journal.load()
                return .init(ok: after?.terminal == true, message: after?.detail ?? "正在恢复关联", linkRecord: after)
            }
            guard let r = try coordinator.journal.load() else { return .init(ok: true, message: "没有需要恢复的配置。") }
            guard r.ownerUID == uid else { throw HWError.blocked("不能操作其他用户的事务。") }
            let restored = try coordinator.rollback(r.id, reason: "用户请求停止并恢复")
            ownerConnection = nil; expectedContext = nil
            return .init(ok: true, message: restored.phase == .conflict ? "保留外部修改，已记录冲突" : "已恢复配置；连接和应用状态需另行复测", record: restored)
        }
        guard startupError == nil, !sleeping else { throw HWError.blocked(startupError ?? "系统正在睡眠，暂停操作。") }
        if [.scanCandidates, .prepareLink, .armLink, .applyLink, .commitLink, .heartbeatLink].contains(request.action) {
            return try performLink(request, connection: connection, uid: uid)
        }
        if request.action == .prepare {
            guard !linkBusy, try links.journal.load()?.terminal != false else { throw HWError.busy }
            guard let p = request.policy, let candidate = request.proposal, let supplied = request.context,
                  let nonce = request.nonce, UUID(uuidString: nonce) != nil,
                  let service = supplied.serviceID else { throw HWError.invalid("授权上下文不完整。") }
            _ = try p.validated()
            guard candidate.hasEvidence else { throw HWError.blocked("候选没有足够的可重复证据。") }
            switch candidate.field {
            case .dnsServers:
                guard candidate.value == .strings(["1.1.1.1", "1.0.0.1"]) || candidate.value == .strings(["9.9.9.9", "149.112.112.112"]) else { throw HWError.blocked("DNS 候选不在固定白名单中。") }
            case .autoProxyDiscovery:
                guard candidate.value == .integer(0) else { throw HWError.blocked("只允许单字段自动发现关闭实验。") }
            }
            var current = inspector.read(session: supplied.sessionID, privacy: .init(key: Data(nonce.utf8))).context
            managed = Self.readManagedProfiles(); current.proxy.managed = managed
            guard supplied.sameNetwork(as: current), supplied.configurationDigest == current.configurationDigest,
                  service == current.serviceID else { throw HWError.blocked("目标服务或网络上下文已变化。") }
            // Preflight checks use anticipated durable states; APPLY checks the actual persisted states again.
            let gate = GateInput(operation: candidate.field.operation, context: current, policy: p, helperReady: true,
                                 snapshotSaved: true, guardianArmed: true, originalKnown: true, reproducibleEvidence: candidate.hasEvidence,
                                 health: SelectionPolicy.health(candidate.baseline))
            if let reason = OperationGate.rejection(gate) { throw HWError.blocked(reason) }
            let record = try coordinator.prepare(target: .init(serviceID: service, field: candidate.field), value: candidate.value,
                                                 context: current, uid: uid, nonce: nonce)
            ownerConnection = connection; policy = p; proposal = candidate; expectedContext = current
            return .init(ok: true, message: "PREPARE 已持久化", record: record)
        }
        guard let id = request.transaction, let nonce = request.nonce, ownerConnection == connection else { throw HWError.blocked("事务未绑定当前授权连接。") }
        let r = try coordinator.record(id)
        guard r.ownerUID == uid, r.sessionNonce == nonce else { throw HWError.blocked("授权会话不匹配。") }
        if request.action == .rollback {
            let result = try coordinator.rollback(id, reason: "实验无收益或任务停止")
            expectedContext = nil; return .init(ok: true, message: "已核对字段恢复状态", record: result)
        }
        let current = context(r)
        guard sameProtectedContext(r, current), expectedContext?.configurationDigest == current.configurationDigest else {
            cleanup("检测到用户或系统的后续网络操作"); throw HWError.blocked("网络或配置已被外部修改，停止优化。")
        }
        var result = r
        switch request.action {
        case .arm: result = try coordinator.arm(id)
        case .apply:
            guard let policy, let proposal else { throw HWError.blocked("会话授权已失效。") }
            // Re-evaluate profiles at the write boundary, not merely when the app opened.
            managed = Self.readManagedProfiles(); var checked = current; checked.proxy.managed = managed
            let gate = GateInput(operation: r.target.field.operation, context: checked, policy: policy, helperReady: true,
                                 snapshotSaved: r.phase == .armed, guardianArmed: r.phase == .armed, originalKnown: true,
                                 reproducibleEvidence: proposal.hasEvidence, health: SelectionPolicy.health(proposal.baseline))
            result = try coordinator.apply(id, gate: gate); expectedContext = context(result)
        case .verify: result = try coordinator.verify(id)
        case .commit: result = try coordinator.commit(id)
        case .heartbeat: try coordinator.beat(id); result = try coordinator.record(id)
        default: throw HWError.invalid("操作顺序无效。")
        }
        return .init(ok: true, message: result.phase.rawValue, record: result)
    }
    func installPowerNotifications() {
        let ref = Unmanaged.passUnretained(self).toOpaque()
        powerConnection = IORegisterForSystemPower(ref, &powerPort, { ref, _, type, argument in
            guard let ref else { return }
            let guardian = Unmanaged<RecoveryGuardian>.fromOpaque(ref).takeUnretainedValue()
            if type == HWSystemWillSleep() {
                guardian.queue.sync { guardian.sleeping = true }
                IOAllowPowerChange(guardian.powerConnection, Int(bitPattern: argument))
            } else if type == HWCanSystemSleep() {
                IOAllowPowerChange(guardian.powerConnection, Int(bitPattern: argument))
            } else if type == HWSystemHasPoweredOn() {
                guardian.queue.async { guardian.sleeping = false; guardian.cleanup("唤醒后清理临时配置，需重新测量") }
            }
        }, &powerNotifier)
        if let powerPort, let source = IONotificationPortGetRunLoopSource(powerPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if powerConnection == 0 { startupError = "无法登记系统睡眠通知；禁止写操作。" }
    }
}
final class GuardianEndpoint: NSObject, GuardianXPC {
    unowned let guardian: RecoveryGuardian
    let id: UUID; let uid: uid_t
    init(guardian: RecoveryGuardian, id: UUID, uid: uid_t) { self.guardian = guardian; self.id = id; self.uid = uid }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        guardian.queue.async {
            let response: GuardianResponse
            do {
                guard data.count <= 512_000 else { throw HWError.invalid("XPC 请求超限。") }
                response = try self.guardian.perform(JSONCoding.decoder.decode(GuardianRequest.self, from: data), connection: self.id, uid: self.uid)
            } catch { response = .init(ok: false, message: error.localizedDescription) }
            reply((try? JSONCoding.encoder.encode(response)) ?? Data())
        }
    }
}
@main enum GuardianMain {
    static func main() {
        guard geteuid() == 0, CallerValidation.requirement() != nil else {
            fputs("RecoveryGuardian requires a registered privileged service with verified project signing.\n", stderr); exit(78)
        }
        do {
            let store = try SecureStore(directory: URL(fileURLWithPath: "/Library/Application Support/HotelWiFi", isDirectory: true))
            let guardian = try RecoveryGuardian(store: store)
            let listener = NSXPCListener(machServiceName: HotelWiFiService.identifier); listener.delegate = guardian; listener.resume()
            withExtendedLifetime((guardian, listener)) { CFRunLoopRun() }
        } catch { fputs("RecoveryGuardian storage unavailable; no new writes accepted.\n", stderr); exit(74) }
    }
}
