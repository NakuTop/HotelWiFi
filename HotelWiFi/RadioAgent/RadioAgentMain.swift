import Foundation
import CoreWLAN
import CoreLocation
import SystemConfiguration
import HotelWiFiCore
import Darwin

final class RadioAgent: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "HotelWiFi.RadioAgent.control")
    let worker = DispatchQueue(label: "HotelWiFi.RadioAgent.association")
    let privileged = GuardianClient()
    let native: RadioEnvironment
    let traffic: TrafficMonitor
    let now: () -> Date
    let disconnect: ((RadioRecord) throws -> Void)?
    let journal: RadioJournal
    let lock: StoreLock
    var record: RadioRecord?
    var owner: UUID?
    var busy = false
    var restoring = false
    var restoreRequested = false
    var timer: DispatchSourceTimer?
    var startupError: String?
    var previousSurvey: (Date, AssociationSnapshot, [(AccessPointReading, AssociationSnapshot)])?
    init(store: SecureStore, environment: RadioEnvironment = NativeRadioEnvironment(),
         traffic: TrafficMonitor = TrafficMonitor(), now: @escaping () -> Date = Date.init,
         startWatchdog: Bool = true, disconnect: ((RadioRecord) throws -> Void)? = nil) throws {
        self.native = environment; self.traffic = traffic; self.now = now; self.disconnect = disconnect
        lock = try store.acquireLock("radio-agent.lock"); journal = RadioJournal(store: store)
        super.init()
        do { record = try journal.load(); if record?.terminal == false { restoreRequested = true } }
        catch { startupError = "无线恢复记录不可读取，禁止新操作。" }
        guard startWatchdog else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
    }
    func context(nonce: String, session: UUID = UUID()) -> NetworkContext {
        native.context(nonce: nonce, session: session)
    }
    func save(_ value: RadioRecord) throws { try journal.save(value); record = value }
    func connectionEnded(_ id: UUID) {
        guard owner == id, record?.terminal == false else { return }
        restoreRequested = true; try? restore()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var console: uid_t = 0, group: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &console, &group) != nil, console == geteuid(),
              connection.effectiveUserIdentifier == geteuid(), connection.auditSessionIdentifier > 0,
              let requirement = CodeSigningTrust.current()?.requirement(identifiers: ["com.hotelwifi.app", "com.hotelwifi.cli"]) else { return false }
        let id = UUID()
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: GuardianXPC.self)
        connection.exportedObject = RadioEndpoint(agent: self, id: id)
        connection.invalidationHandler = { [weak self] in self?.queue.async { [weak self] in
            self?.connectionEnded(id)
        } }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume(); return true
    }
    func scan(nonce: String) throws -> RadioScan { try native.scan(nonce: nonce) }
    func perform(_ r: RadioRequest, owner caller: UUID, managed: Bool?) throws -> RadioResponse {
        if r.action == .status {
            let readable = native.identityReadable
            return .init(ok: startupError == nil, message: startupError ?? record?.detail ?? "无线会话服务已就绪", identityReadable: readable, record: record)
        }
        if r.action == .restore { restoreRequested = true; try restore(); return .init(ok: true, message: record?.detail ?? "没有待恢复的无线切换。", record: record) }
        guard startupError == nil else { throw HWError.blocked(startupError!) }
        if r.action == .survey {
            guard !busy, record?.terminal != false else { throw HWError.busy }
            let (survey, original, points) = try scan(nonce: r.nonce ?? UUID().uuidString)
            previousSurvey = (now(), original, points)
            return .init(ok: true, message: survey.recommendation, identityReadable: true, survey: survey)
        }
        if r.action == .prepare {
            guard !busy, record?.terminal != false else { throw HWError.busy }
            guard r.policy?.allowAutomaticAP == true, let nonce = r.nonce, UUID(uuidString: nonce) != nil,
                  let supplied = r.context ?? (r.validationRoundTrip ? context(nonce: nonce) : nil) else { throw HWError.blocked("尚未授权同网络 AP 自动优化。") }
            guard managed == false else { throw HWError.blocked("受管理网络状态未确认，未执行无线切换。") }
            let current = context(nonce: nonce, session: supplied.sessionID)
            guard current.sameNetwork(as: supplied), current.configurationDigest == supplied.configurationDigest else { throw HWError.blocked("当前连接与本次优化上下文不一致。") }
            guard r.validationRoundTrip || (traffic.recentRate.map { $0 < 32_768 } == true) else { throw HWError.blocked("正在传输数据或流量观察尚未完成，暂不打断连接。") }
            let (survey, original, points) = try scan(nonce: nonce)
            guard let currentPoint = points.first(where: { $0.0.current })?.0 else { throw HWError.blocked("扫描未确认当前接入点。") }
            let sorted = points.filter { !$0.0.current && ($0.0.rssi ?? -120) >= -70 }.sorted { ($0.0.score ?? -1) > ($1.0.score ?? -1) }
            guard let (targetPoint, target) = sorted.first,
                  r.validationRoundTrip || RadioOptimizationGate.better(targetPoint, than: currentPoint) else {
                return .init(ok: true, message: "当前 AP 未发现足够改善的候选；已自动保留当前连接。", survey: survey)
            }
            if !r.validationRoundTrip {
                guard let previous = previousSurvey, now().timeIntervalSince(previous.0) < 60,
                      previous.1 == original,
                      let oldCurrent = previous.2.first(where: { $0.0.current })?.0,
                      let oldTarget = previous.2.first(where: { $0.1.bssid == target.bssid })?.0,
                      RadioOptimizationGate.better(oldTarget, than: oldCurrent) else {
                    return .init(ok: true, message: "候选优势未在两次扫描中重复出现，保留当前 AP。", survey: survey)
                }
            }
            try native.preflight(original); try native.preflight(target)
            var value = RadioRecord(nonce: nonce, plan: .init(action: .associate, original: original, target: target), validationRoundTrip: r.validationRoundTrip)
            value.created = now(); value.heartbeat = value.created; value.expires = value.created.addingTimeInterval(180)
            value.detail = r.validationRoundTrip ? "实机往返验证已准备；此模式只能恢复，不能保留候选" : "更优 AP 已准备，原 AP 恢复材料已加密保存"
            try save(value); owner = caller; restoreRequested = false
            return .init(ok: true, message: value.detail, survey: survey, record: value)
        }
        guard var value = record, !value.terminal, owner == caller,
              r.transaction == value.id, r.nonce == value.nonce else { throw HWError.blocked("无线事务不属于当前授权连接或已结束。") }
        guard now() < value.expires else { restoreRequested = true; try restore(); throw HWError.blocked("无线优化会话已过期，已请求恢复。") }
        switch r.action {
        case .heartbeat:
            value.heartbeat = now(); try save(value)
        case .apply:
            guard !busy, value.phase == .prepared else { throw HWError.busy }
            let current = context(nonce: value.nonce)
            let observed = try native.snapshot(context: current)
            guard observed == value.plan.original, value.validationRoundTrip || (traffic.recentRate.map { $0 < 32_768 } == true) else { throw HWError.blocked("执行前网络或现有流量已变化。") }
            value.phase = .applying; value.detail = "已请求关联目标 AP，等待实际 BSSID 和地址确认"; try save(value)
            busy = true
            worker.async { [self, value] in
                var failure: String?
                do { try native.associate(value.plan.target, beforeAssociation: { try privilegedDisassociate(value, expected: value.plan.original, applying: true) }) } catch { failure = error.localizedDescription }
                let result = failure
                queue.async { [self] in
                    busy = false
                    do {
                        guard var latest = record, latest.id == value.id else { return }
                        let now = try? native.snapshot(context: context(nonce: latest.nonce))
                        latest.targetObserved = now?.bssid == latest.plan.target.bssid && now?.ssid == latest.plan.target.ssid
                        latest.phase = .waiting
                        latest.lastError = result
                        latest.detail = result ?? (latest.targetObserved ? "实际 BSSID 已切换到目标 AP，等待应用复测" : "系统请求已完成，但尚未观察到目标 AP")
                        try save(latest)
                        if result != nil || restoreRequested { restoreRequested = true; try restore() }
                    } catch { startupError = error.localizedDescription }
                }
            }
        case .commit:
            guard !busy, !restoreRequested, value.phase == .waiting, !value.validationRoundTrip else { throw HWError.blocked("当前无线事务不能保留候选。") }
            let current = context(nonce: value.nonce)
            let observed = try native.snapshot(context: current)
            guard observed.bssid == value.plan.target.bssid, observed.ssid == value.plan.target.ssid,
                  observed.configurationDigest == value.plan.original.configurationDigest,
                  let windows = r.windows, RadioOptimizationGate.validCommit(windows, context: current),
                  windows.flatMap(\.samples).allSatisfy({ $0.started >= value.created }) else { throw HWError.blocked("目标 AP 或两轮正常系统路径复测未通过。") }
            value.targetObserved = true; value.phase = .committed; value.detail = "更优 AP 已通过两轮正常应用复测，保留当前关联"; try save(value)
        default: throw HWError.invalid("无线操作顺序无效。")
        }
        return .init(ok: true, message: record?.detail ?? "已完成", record: record)
    }
    /// Only the dedicated signed Agent can request this bounded privileged primitive.
    /// The worker waits; the control queue and recovery watchdog remain responsive.
    func privilegedDisassociate(_ value: RadioRecord, expected: AssociationSnapshot, applying: Bool) throws {
        // Scanning and keychain access can block. Recheck the live lease after that work,
        // at the final boundary before either privileged disconnect or association.
        let permitted = queue.sync {
            guard startupError == nil, let latest = record, latest.id == value.id, !latest.terminal else { return false }
            if applying {
                return latest.phase == .applying && !restoreRequested && owner != nil &&
                    now() < latest.expires && now().timeIntervalSince(latest.heartbeat) <= 45 &&
                    (latest.validationRoundTrip || traffic.recentRate.map { $0 < 32_768 } == true)
            }
            return restoring && restoreRequested
        }
        guard permitted else { throw HWError.blocked("无线操作已停止或会话已失效，未继续断开连接。") }
        let current = context(nonce: value.nonce)
        guard try native.snapshot(context: current) == expected else {
            throw HWError.blocked("扫描期间连接或配置已变化，保留用户当前选择。")
        }
        if let disconnect { try disconnect(value); return }
        var policy = OptimizationPolicy(); policy.allowAutomaticAP = true
        let semaphore = DispatchSemaphore(value: 0), resultLock = NSLock()
        var result: GuardianResponse?
        Task {
            let response = await privileged.call(.init(.disassociateForAP, transaction: value.id, nonce: value.nonce, context: current, policy: policy))
            resultLock.withLock { result = response }; semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 11) == .success,
              let response = resultLock.withLock({ result }), response.ok else {
            throw HWError.blocked(resultLock.withLock { result?.message } ?? "特权无线断开结果未确认。")
        }
    }
    func restore() throws {
        guard var value = record, !value.terminal, !busy else { return }
        let current = context(nonce: value.nonce)
        let observed = try? native.snapshot(context: current)
        if observed?.bssid == value.plan.original.bssid && observed?.ssid == value.plan.original.ssid {
            value.phase = .restored; value.detail = "原 AP 关联已确认"; try save(value); restoreRequested = false; return
        }
        guard RadioOptimizationGate.mayRestore(value, current: observed, wifiOn: current.wifiOn == true) else {
            // A permission loss is temporary; never pretend recovery succeeded without observing identity.
            if current.wifiOn == true && observed == nil { return }
            value.phase = .conflict; value.detail = "用户、系统或网络已改变连接，保留后续选择，未抢回原 AP"; try save(value); restoreRequested = false; return
        }
        guard value.restoreAttempts < 1 else {
            value.phase = .conflict; value.detail = "已发出一次原 AP 恢复请求，未确认恢复；请查看当前连接"; try save(value); return
        }
        value.restoreAttempts += 1; value.detail = "正在恢复原 AP"; try save(value); busy = true; restoring = true
        worker.async { [self, value] in
            var issue: String?
            do { try native.associate(value.plan.original, beforeAssociation: { try privilegedDisassociate(value, expected: value.plan.target, applying: false) }) } catch { issue = error.localizedDescription }
            let failure = issue
            queue.async { [self] in
                busy = false; restoring = false
                do {
                    guard var latest = record, latest.id == value.id else { return }
                    let observed = try? native.snapshot(context: context(nonce: latest.nonce))
                    if observed?.bssid == latest.plan.original.bssid && observed?.ssid == latest.plan.original.ssid {
                        latest.phase = .restored; latest.detail = "已实际恢复原 AP"
                    } else { latest.phase = .conflict; latest.detail = failure ?? "恢复请求已完成，原 AP 状态仍未确认" }
                    try save(latest); restoreRequested = false
                } catch { startupError = error.localizedDescription }
            }
        }
    }
    func tick() {
        traffic.sample(interface: native.interfaceName)
        guard var currentRecord = self.record, !currentRecord.terminal, !busy else { return }
        if currentRecord.phase == .waiting {
            let observed = try? native.snapshot(context: context(nonce: currentRecord.nonce))
            if observed?.bssid == currentRecord.plan.target.bssid && observed?.ssid == currentRecord.plan.target.ssid,
               !currentRecord.targetObserved {
                currentRecord.targetObserved = true; currentRecord.detail = "实际 BSSID 已切换到目标 AP，等待应用复测"
                try? save(currentRecord)
            }
        }
        let record = currentRecord
        if now() > record.expires || now().timeIntervalSince(record.heartbeat) > 45 { restoreRequested = true }
        if restoreRequested { try? restore() }
    }
}
final class RadioEndpoint: NSObject, GuardianXPC, @unchecked Sendable {
    unowned let agent: RadioAgent
    let id: UUID
    init(agent: RadioAgent, id: UUID) { self.agent = agent; self.id = id }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        guard data.count <= 512_000, let request = try? JSONCoding.decoder.decode(RadioRequest.self, from: data) else {
            reply((try? JSONCoding.encoder.encode(RadioResponse(ok: false, message: "无线请求格式异常。"))) ?? Data()); return
        }
        Task {
            var managed: Bool?
            if request.action == .prepare {
                let status = await GuardianClient().call(.init(.status)); managed = status.ok ? status.managedConfiguration : nil
            }
            let status = managed
            agent.queue.async { [self] in
                let response: RadioResponse
                do { response = try agent.perform(request, owner: id, managed: status) }
                catch { response = .init(ok: false, message: error.localizedDescription) }
                reply((try? JSONCoding.encoder.encode(response)) ?? Data())
            }
        }
    }
}
@main enum RadioAgentMain {
    static func main() {
        guard geteuid() != 0, CodeSigningTrust.current() != nil else { exit(78) }
        let location = CLLocationManager()
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let store = try SecureStore(directory: base.appendingPathComponent("HotelWiFi/RadioAgent", isDirectory: true))
            let agent = try RadioAgent(store: store)
            let listener = NSXPCListener(machServiceName: RadioService.identifier); listener.delegate = agent; listener.resume()
            withExtendedLifetime((agent, listener, location)) { CFRunLoopRun() }
        } catch { fputs("RadioAgent recovery storage unavailable; no new operations accepted.\n", stderr); exit(74) }
    }
}
