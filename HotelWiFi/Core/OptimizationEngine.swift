import Foundation

public enum RunMode: String, Sendable { case diagnose, optimize, dryRun }
public struct EngineProgress: Sendable {
    public var message: String
    public var completed: Int
    public var total: Int
    public init(_ message: String, _ completed: Int = 0, _ total: Int = 0) { self.message = message; self.completed = completed; self.total = total }
}

public actor OptimizationEngine {
    public let settings: SettingsStore
    private let inspector = NetworkInspector()
    private let native = ApplicationProbe()
    private let controlled = ControlledProbe()
    private let dns = DNSProbe()
    private let helper = GuardianClient()
    private var budget: BudgetManager?
    private var running = false
    private var stopped = false
    private var sessionLock: StoreLock?
    private var active: RecoveryRecord?
    private var activeLink: LinkRecord?
    private var selectedCandidate: (WiFiCandidate, Bool)?
    private var pendingLinkVerification: [MeasurementWindow]?
    private var ownsRecovery: Bool { active != nil || activeLink != nil }
    private var nonce = UUID().uuidString
    private var session = UUID()
    private var expected: NetworkContext?
    private var ownTransition = false
    private var heartbeat: Task<Void, Never>?
    private var events: NetworkEvents?
    private var executedChanges: [String] = []
    private var restoredChanges: [String] = []
    private var networkGeneration = 0
    public func networkChangeVersion() -> Int { networkGeneration }
    private var progress: (@Sendable (EngineProgress) -> Void)?
    public init(store: SecureStore) { settings = SettingsStore(store: store) }
    private var privacy: PrivacyFilter { .init(key: Data(nonce.utf8)) }
    private func current() -> NetworkContext { inspector.read(session: session, privacy: privacy).context }
    public func inspectLocal() -> RuntimeNetwork { inspector.read(session: session, privacy: privacy) }
    public func inspect() async -> (RuntimeNetwork, CapabilityRegistry) {
        let p = (try? settings.store.identityKey()) ?? Data(UUID().uuidString.utf8)
        let n = inspector.read(session: UUID(), privacy: .init(key: p))
        let h = await helper.call(.init(.status))
        let curl = BoundedProcess.run("/usr/bin/curl", ["-q", "--version"], timeout: 2)
        let version = String(decoding: curl.data, as: UTF8.self).split(separator: "\n").prefix(4).joined(separator: "\n")
        let detail = HelperDiagnostics.detail(ready: h.ok, message: h.message, registration: HotelWiFiService.registration.status,
                                              launchText: h.ok ? nil : HelperDiagnostics.launchState())
        return (n, inspector.capabilities(n, helper: h.ok, curl: version, helperDetail: detail, associationIdentityReadable: h.associationIdentityReadable))
    }
    public func observeChanges() {
        if events == nil { events = NetworkEvents(keysHandler: { [weak self] keys in Task { [weak self] in await self?.changed(keys) } }) }
    }
    private func changed(_ keys: [String]) async {
        guard !ownTransition, let expected else { return }
        let c = current()
        let linkReset = expected.interface.map { keys.contains("State:/Network/Interface/\($0)/Link") } ?? false
        if linkReset || !sameCurrent(c, expected) {
            networkGeneration += 1
            stopped = true; budget?.stop(); native.cancel(); controlled.cancel()
            progress?(.init("检测到网络或设置变化，正在恢复本程序的临时字段"))
            if ownsRecovery { _ = await restore() }
        }
    }
    private func sameCurrent(_ a: NetworkContext, _ b: NetworkContext) -> Bool {
        let identitySame = a.identity != nil && b.identity != nil ? a.sameNetwork(as: b) :
            a.interface == b.interface && a.serviceID == b.serviceID && a.wifiOn == b.wifiOn && a.hasRoute == b.hasRoute
        return identitySame && a.configurationDigest == b.configurationDigest && a.vpnPresent == b.vpnPresent &&
            a.hasIPv4 == b.hasIPv4 && a.hasIPv6 == b.hasIPv6 && a.hasRoute == b.hasRoute
    }
    private func check() throws {
        if stopped || Task.isCancelled { throw HWError.cancelled }
        if let expected, !sameCurrent(current(), expected) { throw HWError.blocked("用户或系统改变了网络，原优化任务已停止。") }
    }
    public func stop() async -> GuardianResponse {
        stopped = true; budget?.stop(); native.cancel(); controlled.cancel()
        return await restore()
    }
    public func recoveryStatus() async -> GuardianResponse { await helper.call(.init(.status)) }
    public func restore() async -> GuardianResponse {
        heartbeat?.cancel(); heartbeat = nil
        ownTransition = true; defer { ownTransition = false }
        var result = await helper.call(.init(.restoreAll))
        let deadline = Date().addingTimeInterval(35), pulse = NetworkEventPulse()
        while !result.ok && result.linkRecord?.terminal == false && Date() < deadline {
            await pulse.wait()
            let status = await helper.call(.init(.status))
            guard status.ok else { result = status; break }
            if status.linkRecord?.terminal == true { result = .init(ok: true, message: status.linkRecord?.detail ?? "已核对关联恢复状态", linkRecord: status.linkRecord); break }
        }
        if result.record?.configurationRestored == true, let field = result.record?.target.field { restoredChanges.append(field.rawValue) }
        if result.linkRecord?.configurationRestored == true { restoredChanges.append("关联/地址恢复状态已核对") }
        if result.ok || !ownsRecovery {
            active = nil; activeLink = nil; pendingLinkVerification = nil; if !running { sessionLock?.release(); sessionLock = nil }
            expected = current()
        }
        if !result.ok && !ownsRecovery { return .init(ok: true, message: "本进程没有执行网络写入。\(result.message)") }
        return result
    }
    private func step(_ action: GuardianAction, proposal: MutationProposal? = nil, policy: OptimizationPolicy? = nil) async throws -> RecoveryRecord {
        ownTransition = true; defer { ownTransition = false }
        let response = await helper.call(.init(action, transaction: active?.id, nonce: nonce, context: current(), policy: policy, proposal: proposal))
        guard response.ok, let record = response.record else { throw HWError.blocked(response.message) }
        if action == .apply { executedChanges.append(record.target.field.rawValue) }
        if action == .rollback && record.configurationRestored { restoredChanges.append(record.target.field.rawValue) }
        active = record.terminal ? nil : record; expected = current()
        return record
    }
    private func rollbackExperiment() async throws -> Bool {
        guard active != nil else { return true }
        return try await step(.rollback).configurationRestored
    }
    private func begin(_ proposal: MutationProposal, policy: OptimizationPolicy) async throws {
        try check()
        _ = try await step(.prepare, proposal: proposal, policy: policy)
        _ = try await step(.arm)
        _ = try await step(.apply)
        _ = try await step(.verify)
        if heartbeat == nil {
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
                    await self?.beat()
                }
            }
        }
    }
    private func beat() async {
        if let link = activeLink {
            let response = await helper.call(.init(.heartbeatLink, transaction: link.id, nonce: nonce))
            if !response.ok { stopped = true; budget?.stop(); native.cancel(); progress?(.init("关联恢复看护失联，停止实验")) }
            return
        }
        guard let active else { return }
        let result = await helper.call(.init(.heartbeat, transaction: active.id, nonce: nonce))
        if !result.ok { stopped = true; budget?.stop(); native.cancel(); controlled.cancel(); progress?(.init("恢复服务失联，正在停止实验")) }
    }
    private func window(_ label: String, endpoints: [ProbeEndpoint], count: Int, budget: BudgetManager, final: Bool = false, timeout: Double = 8) async throws -> MeasurementWindow {
        let before = current(); var samples: [ProbeSample] = []
        for _ in 0..<count {
            for endpoint in endpoints {
                if !final { try check() }
                if final && current().wifiOn == false { throw HWError.blocked("WiFi 已关闭，保留用户操作。") }
                let s = try await native.run(endpoint, budget: budget, final: final, timeoutLimit: timeout); samples.append(s)
                progress?(.init(label, samples.count, count * endpoints.count))
                if !final { try check() }
                else if !sameCurrent(current(), before) { throw HWError.blocked("最终复测期间连接再次变化，结果不能代表当前状态。") }
            }
        }
        return .init(label: label, context: current(), samples: samples)
    }
    private func propose(baseline: MeasurementWindow, endpoints: [ProbeEndpoint], policy: OptimizationPolicy,
                         budget: BudgetManager, report: inout SessionReport) async throws -> MutationProposal? {
        let c = current()
        guard policy.allowControlledDirect, !c.vpnPresent, !c.splitDNS,
              c.expensive == false || policy.allowMetered else { return nil }
        let failures = baseline.samples.filter { !$0.complete && $0.path == .system }
        guard failures.count >= 4, Set(failures.map(\.provider)).count >= 2 else { return nil }
        progress?(.init("正在比较候选方案"))
        if failures.allSatisfy({ $0.failure == .dns }), !c.proxy.any {
            for server in ["1.1.1.1", "9.9.9.9"] {
                var samples: [ProbeSample] = []
                for _ in 0..<2 {
                    for e in endpoints {
                        try check(); guard let host = e.url.host else { continue }
                        let result = try await dns.resolve(host: host, server: server, budget: budget)
                        guard let address = result.address else { continue }
                        samples.append(try await controlled.run(e, path: .candidateDNS, budget: budget, resolvedIPv4: address))
                    }
                }
                report.windows.append(.init(label: "指定解析器的独立请求（只用于诊断）", context: c, samples: samples))
                let values = server == "1.1.1.1" ? ["1.1.1.1", "1.0.0.1"] : ["9.9.9.9", "149.112.112.112"]
                let proposal = MutationProposal(field: .dnsServers, value: .strings(values), baseline: baseline.samples, controlled: samples)
                if proposal.hasEvidence { return proposal }
            }
        } else if c.proxy.discovery && !c.proxy.manual && !c.proxy.pac && policy.allowAutomaticProxyExperiment {
            var samples: [ProbeSample] = []
            for _ in 0..<2 { for e in endpoints { try check(); samples.append(try await controlled.run(e, path: .direct, budget: budget)) } }
            report.windows.append(.init(label: "直接请求与系统代理路径分开记录", context: c, samples: samples))
            let p = MutationProposal(field: .autoProxyDiscovery, value: .integer(0), baseline: baseline.samples, controlled: samples)
            if p.hasEvidence { return p }
        } else if !c.proxy.any && !policy.allowReconnect {
            for path in [ProbePath.ipv4, .ipv6] {
                var samples: [ProbeSample] = []
                for e in endpoints { try check(); samples.append(try await controlled.run(e, path: path, budget: budget)) }
                report.windows.append(.init(label: "\(path.rawValue) 独立诊断（不修改系统地址族）", context: c, samples: samples))
            }
        }
        return nil
    }
    public func run(mode: RunMode, policy: OptimizationPolicy, endpoints: [ProbeEndpoint],
                    progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }) async throws -> SessionReport {
        guard !running else { throw HWError.busy }
        _ = try policy.validated(); try ProbeEndpoint.validate(endpoints)
        if mode == .optimize && !policy.completedOnboarding { throw HWError.blocked("请先在 HotelWiFi 中完成首次授权并保存策略。") }
        if ownsRecovery { let response = await restore(); guard response.ok else { throw HWError.blocked(response.message) } }
        sessionLock = try settings.store.acquireLock("optimization.lock")
        running = true; stopped = false; self.progress = progress; executedChanges = []; restoredChanges = []
        if selectedCandidate == nil { nonce = UUID().uuidString; session = UUID() }
        expected = current(); observeChanges()
        let b = BudgetManager(bytes: policy.payloadLimit, seconds: policy.durationLimit); budget = b
        defer { running = false; budget = nil; selectedCandidate = nil; if !ownsRecovery { sessionLock?.release(); sessionLock = nil }; self.progress = nil }
        var report = SessionReport(mode: mode.rawValue)
        let helperState = await helper.call(.init(.status))
        if let previous = helperState.record, !previous.terminal { throw HWError.busy }
        if let previous = helperState.linkRecord, !previous.terminal { throw HWError.busy }
        let (network, capabilities) = await inspect(); report.capabilities = capabilities
        report.localBefore = network.facts
        progress(.init("正在检查本机 WiFi、地址、路由与修复服务"))
        if !helperState.ok { report.observations.append(.init(capabilities.capabilities.first(where: { $0.id == "helper" })?.detail ?? helperState.message)) }
        guard DiagnosisBuilder.shouldProbe(network.context, network.facts) else {
            report.current = network.context; report.localAfter = network.facts; report.finished = Date()
            let diagnosis = DiagnosisBuilder.diagnose(context: network.context, facts: network.facts, capabilities: capabilities, policy: policy)
            report.conclusion = diagnosis.title; report.evidence = diagnosis.explanation
            report.observations.append(.init("本机检查已完成；没有无线连接时跳过互联网请求，未执行网络写入。"))
            progress(.init(report.conclusion)); return report
        }
        var selectedEndpoints = endpoints
        let lowLoad = network.context.constrained == true || (network.context.expensive != false && !policy.allowMetered)
        if lowLoad { selectedEndpoints = endpoints.filter { $0.kind == .connectivity }; report.observations.append(.init("低数据模式、计费或计费状态未知：仅运行轻量连通性请求。")) }
        let count = lowLoad ? 1 : policy.initialRequests
        do {
            progress(.init("正在测量当前连接"))
            let baseline = try await BaselineCollector.collect(endpoints: selectedEndpoints, count: count) { endpoints, count, timeout, label in
                try await self.window(label, endpoints: endpoints, count: count, budget: b, timeout: timeout)
            }
            let a1 = baseline.window; selectedEndpoints = baseline.comparisonEndpoints
            if baseline.skippedObjects { report.observations.append(.init("轻量请求未全部通过：跳过对象下载，为离线诊断和恢复保留时间。")) }
            report.windows.append(a1)
            let health = SelectionPolicy.health(a1.samples)
            if health == .endpointLimited { report.observations.append(.init("部分端点成功、部分失败。", inference: "可能是端点或局部路径问题，不能据此判断整个网络中断。")) }
            if a1.samples.contains(where: { $0.failure == .redirect || $0.failure == .body }) {
                report.observations.append(.init("测试响应与预期不一致或发生跳转。", inference: "可能需要完成酒店登录；也可能是端点内容变化。请使用系统登录页面确认。"))
            }
            if a1.context.hasIPv6 == true && a1.context.hasIPv4 == false && a1.samples.contains(where: { $0.complete && $0.addressFamily == "IPv6" }) { report.observations.append(.init("IPv6 路径已完成应用请求，没有 IPv4 不构成 DHCP 故障。")) }
            if mode != .diagnose && helperState.ok, let proposal = try await propose(baseline: a1, endpoints: selectedEndpoints, policy: policy, budget: b, report: &report) {
                report.observations.append(.init("独立诊断形成候选：\(proposal.field.rawValue)。系统实际路径仍需交错复测。"))
                if mode == .dryRun { report.observations.append(.init("dry-run：只生成候选，没有准备或写入任何系统事务。")) }
                else if !helperState.ok { report.observations.append(.init(helperState.message)) }
                else {
                    let experiment = try await ExperimentRunner.run(original: a1, policy: policy, budget: b,
                        begin: { try await self.begin(proposal, policy: policy) },
                        collect: { label in
                            progress(.init(label))
                            return try await self.window(label, endpoints: selectedEndpoints, count: count, budget: b)
                        }, rollback: {
                            progress(.init("正在恢复原设置")); return try await self.rollbackExperiment()
                        }, commit: { _ = try await self.step(.commit) })
                    report.windows += experiment.windows
                    if experiment.retained {
                        report.activeTemporary = [proposal.field.rawValue]
                        report.conclusion = "已保留较优连接"; report.evidence = "两个交错窗口均通过系统路径可靠性及改善门槛"
                    }
                }
            }
            if mode == .optimize && active == nil && health == .failed && policy.allowReconnect {
                try await recoverLink(baseline: a1, endpoints: selectedEndpoints, policy: policy, budget: b, helperReady: helperState.ok, report: &report)
            }
            if report.activeTemporary.isEmpty && report.conclusion == "尚未完成最终验证" {
                report.conclusion = health == .healthy ? "当前连接无需修改" : "诊断完成，当前连接仍需处理"
                report.evidence = "没有形成可保留的重复改善；原连接保持为候选"
            }
        } catch {
            report.interrupted = true; report.observations.append(.init(error.localizedDescription))
            if ownsRecovery {
                progress(.init("正在恢复原设置")); let result = await restore()
                if result.ok { report.restored += report.activeTemporary + report.changes; report.activeTemporary = [] }
                if !result.ok { report.observations.append(.init(result.message)); report.activeTemporary = ["恢复待确认；独立恢复服务负责重试"] }
            }
            report.conclusion = stopped ? "任务已停止，正在核对恢复状态" : "已停止新实验，保留诊断结果"
            report.evidence = "测试不完整，不宣称优化成功"
        }
        progress(.init("正在确认最终连接状态"))
        if current().wifiOn != false {
            do {
                let final = try await window("最终当前连接复测", endpoints: selectedEndpoints, count: 1, budget: b, final: true, timeout: 3)
                report.windows.append(final)
                if final.fullyHealthy { report.currentValidatedAt = Date() }
                else if ownsRecovery {
                    let result = await restore(); report.observations.append(.init(result.message))
                    if result.ok { report.restored += report.activeTemporary; report.activeTemporary = [] }
                    report.conclusion = "候选未通过最终验证，已发起恢复"
                    if let restored = try? await window("恢复后的最终复测", endpoints: selectedEndpoints, count: 1, budget: b, final: true) {
                        report.windows.append(restored); if restored.fullyHealthy { report.currentValidatedAt = Date() }
                    }
                } else if report.conclusion == "当前连接无需修改" {
                    report.conclusion = "当前连接最终验证未通过"
                }
            } catch { report.observations.append(.init("未完成最终应用验证：\(error.localizedDescription)")); report.currentValidatedAt = nil }
        } else { report.observations.append(.init("用户已关闭 WiFi，未尝试打开。")); report.currentValidatedAt = nil }
        if report.currentValidatedAt == nil && ownsRecovery {
            let result = await restore(); report.observations.append(.init(result.message))
            if result.ok { report.restored += report.activeTemporary; report.activeTemporary = [] }
            report.conclusion = "最终验证未完成，已发起恢复"
        }
        if report.currentValidatedAt != nil && activeLink != nil, let verification = pendingLinkVerification {
            do {
                _ = try await linkStep(.commitLink, verification: verification)
                heartbeat?.cancel(); heartbeat = nil; pendingLinkVerification = nil
                report.activeTemporary = []
                report.observations.append(.init("最终关联已交还 macOS 维持；没有 AP 锁定或需带离酒店的无线配置。"))
            } catch {
                let recovery = await restore(); report.observations.append(.init(recovery.message))
                report.currentValidatedAt = nil; report.activeTemporary = []; report.conclusion = "提交前状态变化，已停止并核对恢复"
            }
        }
        report.current = current(); report.payloadBytes = b.bytes; report.finished = Date()
        report.changes = executedChanges; report.restored = restoredChanges
        report.localAfter = inspector.read(session: session, privacy: privacy).facts
        let diagnosis = DiagnosisBuilder.diagnose(context: report.current ?? network.context, facts: report.localAfter ?? network.facts,
            capabilities: capabilities, report: report, policy: policy)
        if report.currentValidatedAt == nil && report.activeTemporary.isEmpty && !stopped {
            report.conclusion = diagnosis.title; report.evidence = diagnosis.explanation
        }
        // Diagnostics stay in memory. Durable recovery journals are independent of report storage.
        progress(.init(report.conclusion)); return report
    }
    public func measureBandwidth(policy: OptimizationPolicy) async throws -> SessionReport {
        guard !running, !ownsRecovery else { throw HWError.busy }
        _ = try policy.validated()
        let context = current()
        guard context.expensive == false || policy.allowMetered else { throw HWError.blocked("计费状态未知或尚未授权计费网络测试。") }
        guard context.constrained != true else { throw HWError.blocked("低数据模式下不运行大对象测试。") }
        let lock = try settings.store.acquireLock("optimization.lock"); defer { lock.release() }
        running = true; stopped = false; expected = context
        defer { running = false; budget = nil }
        let budget = BudgetManager(bytes: 5_200_000, seconds: 30); self.budget = budget
        let e = ProbeEndpoint(id: "cloudflare-manual-5MB", provider: "Cloudflare", url: URL(string: "https://speed.cloudflare.com/__down?bytes=5000000")!, kind: .bandwidth,
                              expectedStatus: 200, body: .length(5_000_000), maxBytes: 5_100_000)
        let sample = try await native.run(e, budget: budget)
        try check()
        var r = SessionReport(mode: "manualBandwidth")
        r.windows = [.init(label: "手动 5 MB 测试对象", context: context, samples: [sample])]
        r.conclusion = sample.complete ? "测试对象下载完成" : "测试对象未完整下载"
        r.evidence = "单提供商、单对象；不能推断酒店最高带宽，也不用于自动优化决策"
        if sample.complete, let total = sample.times.total, total > 0 {
            r.observations.append(.init(String(format: "本次测试对象端到端传输表现 %.2f Mbit/s（含连接建立时间）", Double(sample.bytes) * 8 / total / 1_000_000)))
        }
        r.payloadBytes = budget.bytes; r.finished = Date(); r.current = current()
        return PrivacyFilter.exported(r)
    }
}

extension OptimizationEngine {
    public func scanSavedCandidates() async throws -> [WiFiCandidate] {
        guard !running, !ownsRecovery else { throw HWError.busy }
        nonce = UUID().uuidString; session = UUID(); selectedCandidate = nil
        let response = await helper.call(.init(.scanCandidates, nonce: nonce, context: current()))
        guard response.ok else { throw HWError.blocked(response.message) }
        return response.candidates ?? []
    }
    public func selectCandidate(_ candidate: WiFiCandidate?, approvePossibleCost: Bool) throws {
        guard !running, !ownsRecovery else { throw HWError.busy }
        guard let candidate else { selectedCandidate = nil; return }
        guard candidate.expires > Date(), approvePossibleCost else { throw HWError.blocked("需确认本次候选用途及可能的计费，过期候选需重新扫描。") }
        selectedCandidate = (candidate, approvePossibleCost)
    }
    private func linkStep(_ action: GuardianAction, intent: LinkIntent? = nil, policy: OptimizationPolicy? = nil,
                          verification: [MeasurementWindow]? = nil) async throws -> LinkRecord {
        let response = await helper.call(.init(action, transaction: activeLink?.id, nonce: nonce, context: current(),
            policy: policy, linkIntent: intent, verification: verification))
        guard response.ok, let r = response.linkRecord else { throw HWError.blocked(response.message) }
        activeLink = r.terminal ? nil : r
        return r
    }
    private func recoverLink(baseline: MeasurementWindow, endpoints: [ProbeEndpoint], policy: OptimizationPolicy,
                             budget: BudgetManager, helperReady: Bool, report: inout SessionReport) async throws {
        guard helperReady else { report.observations.append(.init("恢复服务尚未就绪，未执行重连、切网或 DHCP 请求。")); return }
        guard LinkIntent(.reconnect, baseline: baseline.samples).repeatedFailure else { return }
        if policy.linkRecovery?.allowIdleInterruption == true {
            let pulse = NetworkEventPulse(), deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                try check()
                let status = await helper.call(.init(.status))
                guard status.ok else { throw HWError.blocked(status.message) }
                if status.trafficObservationReady == true { break }
                progress?(.init("正在观察现有传输；尚未执行重连")); await pulse.wait()
            }
        }
        var actions: [LinkIntent] = []
        let n = inspector.read(session: session, privacy: privacy)
        if policy.linkRecovery?.allowDHCPRenew == true && n.dhcp == true && n.context.hasIPv6 != true &&
            ((n.context.hasIPv4 == false && n.context.hasIPv6 == false) || n.context.hasRoute == false) {
            actions.append(.init(.renewDHCP, baseline: baseline.samples))
        }
        actions.append(.init(.reconnect, baseline: baseline.samples))
        if let (candidate, allowed) = selectedCandidate, policy.allowSavedNetworks, candidate.expires > Date() {
            actions.append(.init(.associate, candidateID: candidate.id, approvePossibleCost: allowed, baseline: baseline.samples))
        }
        var latest = baseline
        for var intent in actions.prefix(3) {
            try check()
            // Earlier DNS/proxy analysis or natural recovery may have made the current connection healthy.
            // Reconfirm immediately before every disruptive request, rather than reusing an old failure window.
            let confirmation = try await window("恢复请求前再次确认当前应用表现", endpoints: endpoints, count: 2, budget: budget, timeout: 3)
            report.windows.append(confirmation); latest = confirmation; intent.baseline = latest.samples
            if confirmation.fullyHealthy {
                report.conclusion = "当前连接无需修改"
                report.evidence = "当前连接已自行恢复；刚完成的原生请求验证通过，未发起下一次重连"
                break
            }
            guard intent.repeatedFailure else { break }
            try budget.takeLinkRequest()
            progress?(.init(intent.action == .renewDHCP ? "正在请求 DHCP 地址恢复" : "正在进行一次已授权的关联恢复"))
            ownTransition = true
            do {
                _ = try await linkStep(.prepareLink, intent: intent, policy: policy)
                _ = try await linkStep(.armLink)
                _ = try await linkStep(.applyLink)
                executedChanges.append(intent.action.rawValue)
                if heartbeat == nil {
                    heartbeat = Task { [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
                            await self?.beat()
                        }
                    }
                }
                let pulse = NetworkEventPulse(), deadline = Date().addingTimeInterval(30)
                var ready: LinkRecord?
                while Date() < deadline && !stopped {
                    let status = await helper.call(.init(.status))
                    guard status.ok, let record = status.linkRecord, record.id == activeLink?.id else { throw HWError.blocked("关联恢复服务状态不可确认。") }
                    if record.terminal { throw HWError.blocked(record.detail) }
                    if record.phase == .verifying { ready = record; break }
                    await pulse.wait()
                }
                guard let ready, !stopped else { throw HWError.blocked("系统尚未建立可验证的地址/路由，已请求恢复。") }
                expected = current(); ownTransition = false
                let first = try await window("关联后的第一次应用验证", endpoints: endpoints, count: 2, budget: budget)
                report.windows.append(first); latest = first
                if !first.fullyHealthy {
                    let response = await restore(); guard response.ok else { throw HWError.blocked(response.message) }
                    continue
                }
                let second = try await window("关联后的第二次应用验证", endpoints: endpoints, count: 2, budget: budget)
                report.windows.append(second); latest = second
                guard LinkSelection.acceptsRecovery([first,second]) else {
                    let response = await restore(); guard response.ok else { throw HWError.blocked(response.message) }; break
                }
                pendingLinkVerification = [first,second] // Commit only after the common final-current-connection check.
                report.activeTemporary = [intent.action == .renewDHCP ? "DHCP 恢复观察会话（地址配置方式未改变）" : "当前关联的会话恢复看护"]
                report.conclusion = "已保留较优连接"
                report.evidence = "持续失败后，两次当前系统路径完整请求通过；关联前后比较，不是严格 AP A/B"
                report.observations.append(.init(ready.requestedAPObserved == true ? "已观察到请求的 AP；系统后续漫游仍由 macOS 决定。" : "仅确认当前实际关联；未确认切到指定 AP，也未锁定 AP。"))
                break // Never leave an already validated good connection just to exhaust the candidate list.
            } catch {
                ownTransition = false
                report.observations.append(.init(error.localizedDescription))
                if activeLink != nil { let response = await restore(); if !response.ok { throw HWError.blocked(response.message) } }
                break
            }
        }
        ownTransition = false
    }
}
