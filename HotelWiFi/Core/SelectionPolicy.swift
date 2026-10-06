import Foundation

public enum NetworkHealth: String, Codable { case healthy, endpointLimited, failed, insufficient }
public enum SelectionPolicy {
    public static func health(_ samples: [ProbeSample]) -> NetworkHealth {
        let s = samples.filter { $0.path == .system }
        guard s.count >= 2, Set(s.map(\.provider)).count >= 2 else { return .insufficient }
        if s.allSatisfy(\.complete) { return .healthy }
        if s.contains(where: \.complete) { return .endpointLimited }
        return .failed
    }
    /// Each independent repeat must improve, with matched endpoint/method and no reliability regression.
    /// Radio/ICMP and direct diagnostic paths never participate in winner selection.
    public static func wins(baselines: [MeasurementWindow], candidates: [MeasurementWindow], policy: OptimizationPolicy) -> Bool {
        guard baselines.count >= 2, candidates.count >= 2, baselines.count == candidates.count else { return false }
        for (a, b) in zip(baselines, candidates) {
            guard a.context.sameNetwork(as: b.context), a.context.vpnPresent == b.context.vpnPresent,
                  a.context.splitDNS == b.context.splitDNS, a.context.proxy.manual == b.context.proxy.manual,
                  a.context.proxy.pac == b.context.proxy.pac else { return false }
            let aa = a.samples.filter { $0.path == .system }, bb = b.samples.filter { $0.path == .system }
            guard Set(aa.map(\.provider)).count >= 2, Set(aa.map(\.endpoint)) == Set(bb.map(\.endpoint)) else { return false }
            var improved = false
            for id in Set(aa.map(\.endpoint)) {
                let xs = aa.filter { $0.endpoint == id }, ys = bb.filter { $0.endpoint == id }
                guard xs.count >= 2, ys.count == xs.count,
                      Set(xs.map(\.kind)) == Set(ys.map(\.kind)),
                      xs.allSatisfy({ $0.reused == false }), ys.allSatisfy({ $0.reused == false }) else { return false }
                let x = SampleStatistics(xs), y = SampleStatistics(ys)
                guard y.successes >= x.successes, y.successes == y.count else { return false }
                if x.successes == 0 { improved = true; continue }
                guard let xm = x.median, let ym = y.median else { return false }
                let natural = max((x.medianAbsoluteDeviation ?? 0) * 2, 0.025)
                // A slower endpoint or higher spread vetoes an otherwise faster candidate.
                guard ym - xm <= max(0.050, xm * 0.10),
                      (y.maximum ?? ym) <= max((x.maximum ?? xm) * 1.25, (x.maximum ?? xm) + 0.100) else { return false }
                if x.successes < y.successes { improved = true }
                if xm - ym >= max(policy.absoluteImprovement, natural), xm > 0, (xm - ym)/xm >= policy.relativeImprovement { improved = true }
            }
            guard improved else { return false }
        }
        return true
    }
}

public enum OperationKind: String, Codable, Sendable { case dns, automaticProxyDiscovery, reconnect, dhcpRenew, associate }
public struct GateInput {
    public var operation: OperationKind
    public var context: NetworkContext
    public var policy: OptimizationPolicy
    public var helperReady: Bool
    public var snapshotSaved: Bool
    public var guardianArmed: Bool
    public var originalKnown: Bool
    public var reproducibleEvidence: Bool
    public var health: NetworkHealth
    public var importantTraffic: Bool?
    public var externalChange = false
    public var dhcpConfigured: Bool? = nil
    public var addressFault: Bool? = nil
    public var candidateAuthorized = false
    public var recoveryAssociationReady = false
    public init(operation: OperationKind, context: NetworkContext, policy: OptimizationPolicy, helperReady: Bool,
                snapshotSaved: Bool, guardianArmed: Bool, originalKnown: Bool, reproducibleEvidence: Bool,
                health: NetworkHealth, importantTraffic: Bool? = nil) {
        self.operation = operation; self.context = context; self.policy = policy; self.helperReady = helperReady
        self.snapshotSaved = snapshotSaved; self.guardianArmed = guardianArmed; self.originalKnown = originalKnown
        self.reproducibleEvidence = reproducibleEvidence; self.health = health; self.importantTraffic = importantTraffic
    }
}
public enum OperationGate {
    public static func rejection(_ i: GateInput) -> String? {
        guard i.policy.completedOnboarding else { return "尚未保存优化授权策略" }
        guard !i.externalChange, i.context.wifiOn == true, i.context.confidence != .unknown, i.context.identity != nil else { return "网络身份不明或用户已更改连接" }
        guard i.helperReady && i.snapshotSaved && i.guardianArmed && i.originalKnown else { return "快照、恢复登记或辅助服务尚未就绪" }
        guard i.context.serviceID != nil else { return "无法确认目标网络服务" }
        guard i.context.configurationDigest != nil else { return "无法确认原始网络配置" }
        let link = [.reconnect, .associate, .dhcpRenew].contains(i.operation)
        if !link && !(i.context.hasRoute == true && (i.context.hasIPv4 == true || i.context.hasIPv6 == true)) { return "目标 WiFi 不是已确认可用的系统路由，保留其他网络路径" }
        guard i.reproducibleEvidence else { return "没有可重复的应用表现改善证据" }
        guard !i.context.vpnPresent && !i.context.splitDNS else { return "保留 VPN 和分流 DNS 的既有用途" }
        guard i.context.proxy.managed == false else { return "无法排除受管理网络配置" }
        guard i.context.expensive == false || i.policy.allowMetered else { return "计费属性未知或尚未授权计费连接" }
        switch i.operation {
        case .dns:
            guard i.policy.allowTemporaryDNS && !i.context.proxy.any else { return "DNS 实验未授权或代理路径需要保留" }
        case .automaticProxyDiscovery:
            guard i.policy.allowAutomaticProxyExperiment && i.policy.allowControlledDirect,
                  !i.context.proxy.manual && !i.context.proxy.pac && i.context.proxy.discovery else { return "自动代理实验不在授权范围内" }
        case .reconnect, .dhcpRenew, .associate:
            guard i.health == .failed && i.importantTraffic == false && i.policy.allowReconnect else { return "保护可用连接和现有业务；没有断开授权" }
            guard !i.context.proxy.any else { return "保留现有代理路径；先诊断代理用途" }
            if i.operation == .dhcpRenew {
                guard i.policy.linkRecovery?.allowDHCPRenew == true, i.dhcpConfigured == true,
                      i.addressFault == true, i.context.hasIPv6 == false else { return "未授权 DHCP 恢复、原配置不是 DHCP 或地址故障未成立" }
            } else {
                guard i.recoveryAssociationReady else { return "无法确认原网络仍可重新关联" }
                if i.operation == .associate && !(i.policy.allowSavedNetworks && i.candidateAuthorized) { return "候选不是本次明确授权的已保存网络" }
            }
        }
        return nil
    }
}
