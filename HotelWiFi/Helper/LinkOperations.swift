import Foundation
import HotelWiFiCore

extension RecoveryGuardian {
    func linkContext(_ r: LinkRecord) -> NetworkContext {
        var c = inspector.read(session: r.context.sessionID, privacy: .init(key: Data(r.nonce.utf8))).context
        c.proxy.managed = managed; return c
    }
    func linkObservation(_ r: LinkRecord) throws -> LinkObservation {
        nativeLink.observe(try links.journal.plan(id: r.id), context: r.context, nonce: r.nonce)
    }
    func linkGate(_ intent: LinkIntent, context: NetworkContext, policy: OptimizationPolicy, nonce: String) -> GateInput {
        let n = inspector.read(session: context.sessionID, privacy: .init(key: Data(nonce.utf8)))
        traffic.sample(interface: context.interface)
        var gate = GateInput(operation: intent.operation, context: context, policy: policy, helperReady: startupError == nil,
            snapshotSaved: true, guardianArmed: true, originalKnown: true, reproducibleEvidence: intent.repeatedFailure,
            health: SelectionPolicy.health(intent.baseline), importantTraffic: traffic.importantTraffic(policy: policy))
        gate.dhcpConfigured = n.dhcp
        gate.addressFault = (context.hasIPv4 == false && context.hasIPv6 == false) || context.hasRoute == false
        gate.candidateAuthorized = intent.candidateID != nil && intent.approvePossibleCost
        gate.recoveryAssociationReady = true // Set only after native preflight in PREPARE; rechecked before APPLY.
        return gate
    }
    func performLink(_ request: GuardianRequest, connection: UUID, uid: UInt32) throws -> GuardianResponse {
        if request.action == .scanCandidates {
            guard !linkBusy, try coordinator.journal.load()?.terminal != false, try links.journal.load()?.terminal != false else { throw HWError.busy }
            guard Date().timeIntervalSince(lastScan) >= 60, let context = request.context, let nonce = request.nonce,
                  UUID(uuidString: nonce) != nil else { throw HWError.blocked("扫描每分钟最多一次；需要本次网络上下文。") }
            let actual = inspector.read(session: context.sessionID, privacy: .init(key: Data(nonce.utf8))).context
            guard context.sameNetwork(as: actual), context.configurationDigest == actual.configurationDigest else { throw HWError.blocked("扫描上下文已变化或缺少网络权限。") }
            lastScan = Date(); candidates.removeAll()
            for (candidate, snapshot) in try nativeLink.scan(context: actual) { candidates[candidate.id] = (candidate, snapshot, connection, actual.identity) }
            return .init(ok: true, message: "仅列出已保存且安全类型受支持的候选；费用和用途需要本次确认", candidates: candidates.values.map { $0.0 })
        }
        if request.action == .prepareLink {
            guard !linkBusy, try coordinator.journal.load()?.terminal != false, try links.journal.load()?.terminal != false else { throw HWError.busy }
            guard let supplied = request.context, let nonce = request.nonce, UUID(uuidString: nonce) != nil,
                  let intent = request.linkIntent, let policy = request.policy else { throw HWError.invalid("缺少关联授权上下文。") }
            _ = try policy.validated()
            guard (attempts[nonce] ?? 0) < 3 else { throw HWError.blocked("本次会话已达到三次恢复请求上限。") }
            managed = Self.readManagedProfiles()
            var current = inspector.read(session: supplied.sessionID, privacy: .init(key: Data(nonce.utf8))).context; current.proxy.managed = managed
            guard supplied.sameNetwork(as: current), supplied.configurationDigest == current.configurationDigest else { throw HWError.blocked("准备操作前网络已变化。") }
            let gate = linkGate(intent, context: current, policy: policy, nonce: nonce)
            if let reason = OperationGate.rejection(gate) { throw HWError.blocked(reason) }
            let original = try nativeLink.snapshot(context: current)
            var target = original
            if intent.action == .associate {
                guard let id = intent.candidateID, let (candidate, snapshot, owner, origin) = candidates[id], owner == connection,
                      candidate.expires > Date(), intent.approvePossibleCost,
                      origin != nil, origin == current.identity,
                      snapshot.interface == original.interface, snapshot.serviceID == original.serviceID,
                      snapshot.configurationDigest == original.configurationDigest else { throw HWError.blocked("候选授权过期或不属于当前连接，请重新扫描。") }
                target = snapshot
            }
            if intent.action != .renewDHCP { try nativeLink.preflight(original); try nativeLink.preflight(target) }
            let record = try links.prepare(plan: .init(action: intent.action, original: original, target: target), context: current, uid: uid, nonce: nonce)
            linkOwnerConnection = connection; linkPolicy = policy; linkIntent = intent; linkStopRequested = false
            return .init(ok: true, message: "关联/地址恢复材料已加密保存", linkRecord: record)
        }
        guard let id = request.transaction, let nonce = request.nonce, linkOwnerConnection == connection else { throw HWError.blocked("关联事务未绑定当前连接。") }
        let r = try links.record(id)
        guard r.ownerUID == uid, r.nonce == nonce, !r.terminal else { throw HWError.blocked("关联授权会话不匹配或已结束。") }
        switch request.action {
        case .armLink: return .init(ok: true, message: "关联恢复服务已接管", linkRecord: try links.arm(id))
        case .applyLink:
            guard !linkBusy, let policy = linkPolicy, let intent = linkIntent else { throw HWError.busy }
            managed = Self.readManagedProfiles()
            let current = linkContext(r)
            guard r.context.sameNetwork(as: current), r.context.configurationDigest == current.configurationDigest else { throw HWError.blocked("执行前出现外部网络修改。") }
            let p = try links.journal.plan(id: id)
            if p.action != .renewDHCP { try nativeLink.preflight(p.original); try nativeLink.preflight(p.target) }
            let plan = try links.beginApply(id, gate: linkGate(intent, context: current, policy: policy, nonce: nonce))
            attempts[nonce, default: 0] += 1
            if attempts.count > 32 { attempts = [nonce: attempts[nonce]!] }
            linkBusy = true
            linkWorker.async {
                var failure: String?
                do { try self.nativeLink.execute(plan, context: r.context, nonce: nonce) } catch { failure = error.localizedDescription }
                let observedFailure = failure
                self.queue.async {
                    self.linkBusy = false
                    do {
                        _ = try self.links.observe(id, self.linkObservation(r), error: observedFailure)
                        if self.linkStopRequested { try self.restoreLink(startup: false) }
                    } catch { self.startupError = error.localizedDescription }
                }
            }
            return .init(ok: true, message: "已发出一次系统请求，等待实际连接与地址事件", linkRecord: try links.record(id))
        case .commitLink:
            guard !linkBusy, let windows = request.verification, windows.allSatisfy({ $0.context.sameNetwork(as: linkContext(r)) && $0.samples.allSatisfy { $0.started >= r.created } }) else { throw HWError.blocked("复测不对应当前实际关联。") }
            return .init(ok: true, message: "当前关联已通过两次应用复测", linkRecord: try links.commit(id, windows: windows))
        case .heartbeatLink:
            try links.beat(id); return .init(ok: true, message: "关联会话仍受看护", linkRecord: try links.record(id))
        default: throw HWError.invalid("关联操作顺序无效。")
        }
    }
    func restoreLink(startup: Bool) throws {
        guard let r = try links.journal.load(), !r.terminal else { return }
        linkStopRequested = true
        if linkBusy { return } // The native blocking API cannot be safely cancelled; never race a second association.
        let observation = try linkObservation(r)
        guard let original = try links.beginRestore(r.id, observation: observation, startup: startup) else { return }
        linkBusy = true
        linkWorker.async {
            // Re-check power and current ownership immediately before the single recovery attempt.
            let latest = try? self.linkObservation(r)
            if latest?.wifiOn == true && latest?.ssid == observation.ssid && latest?.configurationDigest == observation.configurationDigest {
                try? self.nativeLink.associate(original)
            }
            self.queue.async {
                self.linkBusy = false
                do { _ = try self.links.finishRestore(r.id, observation: self.linkObservation(r)) }
                catch { self.startupError = error.localizedDescription }
            }
        }
    }
    func tickLink() {
        guard !sleeping, !linkBusy else { return }
        do {
            guard let r = try links.journal.load(), !r.terminal else { return }
            if linkStopRequested || Date() >= r.expires || Date().timeIntervalSince(r.heartbeat) > 45 { try restoreLink(startup: false); return }
            let current = linkContext(r), observed = try linkObservation(r)
            if current.vpnPresent || current.splitDNS || current.proxy.any || current.configurationDigest != r.context.configurationDigest || observed.wifiOn != true {
                try restoreLink(startup: true); return
            }
            if r.phase == .waiting || r.phase == .applying { _ = try links.observe(r.id, observed) }
            if r.phase == .committed {
                let p = try links.journal.plan(id: r.id)
                if observed.ssid != p.target.ssid {
                    // A user roaming away releases ownership; beginRestore preserves unknown/new networks.
                    try restoreLink(startup: true)
                }
            }
        } catch { startupError = error.localizedDescription }
    }
}
