import Foundation

public final class SettingsStore: @unchecked Sendable {
    public let store: SecureStore
    public init(store: SecureStore) { self.store = store }
    public func policy() throws -> OptimizationPolicy {
        guard let data = try store.read("policy.json") else { return .init() }
        return try JSONCoding.decoder.decode(OptimizationPolicy.self, from: data).validated()
    }
    public func savePolicy(_ policy: OptimizationPolicy) throws {
        _ = try policy.validated()
        try store.withExclusiveLock("policy.lock") { try store.write(JSONCoding.encoder.encode(policy), named: "policy.json") }
    }
    public func endpoints() throws -> [ProbeEndpoint] {
        guard let data = try store.read("endpoints.json") else { return ProbeEndpoint.defaults }
        let list = try JSONCoding.decoder.decode([ProbeEndpoint].self, from: data); try ProbeEndpoint.validate(list); return list
    }
    public func saveEndpoints(_ list: [ProbeEndpoint]) throws {
        try ProbeEndpoint.validate(list)
        try store.withExclusiveLock("endpoints.lock") { try store.write(JSONCoding.encoder.encode(list), named: "endpoints.json") }
    }

}
public enum ReportBuilder {
    public static func operationName(_ value: String) -> String {
        ["dnsServers": "临时 DNS 调整", "autoProxyDiscovery": "自动代理发现调整", "renewDHCP": "请求 DHCP 地址恢复", "reconnect": "重新关联当前网络", "associate": "请求关联已选网络"][value] ?? value
    }
    public static func supportText(_ report: SessionReport, currentState: String = "结果对应下方测试时间，请先确认当前连接是否变化。") -> String {
        "请根据以下 HotelWiFi 实测报告帮助我排查 macOS WiFi。先区分事实与推测；如需终端命令，请先读取当前状态，再逐项操作并说明恢复方法。不要忽略 TLS、关闭安全功能或覆盖我后续的网络设置。\n\n" + currentState + "\n\n" + text(report)
    }
    public static func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0 * 1000) } ?? "unknown" }
    public static func text(_ source: SessionReport) -> String {
        let r = PrivacyFilter.exported(source)
        var lines = ["HotelWiFi 诊断报告", "格式版本：\(r.schemaVersion)", "时间：\(r.started.formatted())", "模式：\(r.mode)",
                     "结论：\(r.conclusion)", "证据：\(r.evidence)", "实际接收有效载荷：\(r.payloadBytes) 字节",
                     "应用版本：1.2.0",
                     "最终验证时间：\(r.currentValidatedAt?.formatted() ?? "未通过当前连接验证")",
                     "隐私：默认移除网络身份、服务名称和标识；不保存密码、门户参数或响应正文。", ""]
        if let c = r.current {
            lines += ["当前接口：\(c.interface ?? "unknown")", "IPv4：\(c.hasIPv4.map(String.init) ?? "unknown")，IPv6：\(c.hasIPv6.map(String.init) ?? "unknown")，目标 WiFi 路由：\(c.hasRoute.map(String.init) ?? "unknown")",
                      "无线信号：\(c.radio.rssi.map { "\($0) dBm" } ?? "unknown")，频段：\(c.radio.band ?? "unknown")",
                      "VPN 路径迹象：\(c.vpnPresent)，代理：\(c.proxy.any)，管理状态：\(c.proxy.managed.map(String.init) ?? "unknown")", ""]
        }
        if let f = r.localAfter ?? r.localBefore {
            lines += ["本机检查（无需互联网）：", "网络名称可读：\(f.nameReadable)；定位权限：\(f.location.rawValue)",
                      "无线链路：\(DiagnosisBuilder.state(f.associated))；DHCP 配置：\(f.dhcp.map(String.init) ?? "未确认")", "DNS 来源：\(f.manualDNS ? "手动" : "自动/未指定")；运行 DNS 数：\(f.dnsCount)", ""]
        }
        for window in r.windows {
            lines += ["[\(window.label)]", "系统路径完整请求：\(window.stats.successes) / \(window.stats.count)"]
            for id in Set(window.samples.map(\.endpoint)).sorted() {
                for path in Set(window.samples.filter { $0.endpoint == id }.map(\.path)).sorted(by: { $0.rawValue < $1.rawValue }) {
                    let s = window.samples.filter { $0.endpoint == id && $0.path == path }, stat = SampleStatistics(s)
                    lines.append("\(id) / \(path.rawValue)：\(stat.successes)/\(stat.count)，中位 \(milliseconds(stat.median))，范围 \(milliseconds(stat.minimum))–\(milliseconds(stat.maximum))，MAD \(milliseconds(stat.medianAbsoluteDeviation))")
                    if !stat.failures.isEmpty { lines.append("失败类型：\(stat.failures)") }
                    for sample in s {
                        lines.append("  HTTP \(sample.status.map(String.init) ?? "unknown")；\(sample.complete ? "完整成功" : "失败")；错误 \(sample.errorDomain ?? "无") / \(sample.errorCode.map(String.init) ?? "无")；退出码 \(sample.exitCode.map(String.init) ?? "不适用")；原始 HTTP \(sample.originalStatus.map(String.init) ?? "未返回")；跳转 \(sample.redirectStatuses)；路径接口 \(sample.interface ?? "未确认")；地址族 \(sample.addressFamily ?? "未确认")；接收 \(sample.bytes) B；协议 \(sample.transportProtocol ?? "unknown")；复用 \(sample.reused.map(String.init) ?? "unknown")；代理 \(sample.viaProxy.map(String.init) ?? "unknown")；DNS \(milliseconds(sample.times.dns))；TCP \(milliseconds(sample.times.tcp))；TLS \(milliseconds(sample.times.tls))；TTFB \(milliseconds(sample.times.firstByte))；总时长 \(milliseconds(sample.times.total))")
                    }
                }
            }
            lines.append("")
        }
        for o in r.observations { lines.append("观察：\(o.fact)"); if let inference = o.inference { lines.append("推测：\(inference)") } }
        lines += ["执行的修改：\(r.changes.isEmpty ? "无" : r.changes.joined(separator: "；"))",
                  "已恢复的修改：\(r.restored.isEmpty ? "无" : r.restored.joined(separator: "；"))",
                  "报告生成时仍在生效：\(r.activeTemporary.isEmpty ? "无" : r.activeTemporary.joined(separator: "；"))",
                  "阶段耗时缺失表示 unknown/不适用，不按零参与比较。小对象下载表现不等同于酒店最高带宽。",
                  "报告仅在本次内存会话生成，不自动保存；复制时的状态不保证持续不变。"]
        if let registry = r.capabilities { lines.append("\n能力：\(registry.osVersion)"); lines += registry.capabilities.map { "\($0.id)：\($0.state.rawValue) — \($0.detail)" } }
        return lines.joined(separator: "\n")
    }
}
