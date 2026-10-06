import Foundation
import CoreLocation
import ServiceManagement

public enum LocationAccess: String, Codable, Sendable {
    case notRequested, denied, restricted, servicesOff, authorized, unknown
    public static func read() -> Self {
        guard CLLocationManager.locationServicesEnabled() else { return .servicesOff }
        return from(CLLocationManager().authorizationStatus)
    }
    public static func from(_ status: CLAuthorizationStatus) -> Self {
        switch status {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .unknown
        }
    }
    public var explanation: String {
        switch self {
        case .notRequested: return "尚未授权读取网络名称。macOS 将 WiFi 名称归入定位权限；点击“允许读取名称”即可申请。"
        case .denied: return "HotelWiFi 的定位权限被拒绝。请在系统设置 → 隐私与安全性 → 定位服务中允许 HotelWiFi。"
        case .restricted: return "定位权限受到系统或管理策略限制，应用不能自行解除。"
        case .servicesOff: return "系统定位服务已关闭，因此 macOS 隐藏了网络名称。"
        case .authorized: return "定位权限已允许，但 CoreWLAN 仍未返回名称；不能据此判定 WiFi 断开。"
        case .unknown: return "系统未提供可确认的名称读取权限状态。"
        }
    }
}

/// Non-sensitive local facts. No Internet connection or successful request is needed to collect them.
public struct LocalConnectionFacts: Codable, Sendable {
    public var location: LocationAccess
    public var associated: Bool?
    public var nameReadable: Bool
    public var dhcp: Bool?
    public var dnsCount: Int
    public var manualDNS: Bool
    public init(location: LocationAccess = .unknown, associated: Bool? = nil, nameReadable: Bool = false,
                dhcp: Bool? = nil, dnsCount: Int = 0, manualDNS: Bool = false) {
        self.location = location; self.associated = associated; self.nameReadable = nameReadable
        self.dhcp = dhcp; self.dnsCount = dnsCount; self.manualDNS = manualDNS
    }
}
public enum SupportAction: String, Codable, Sendable {
    case networkSettings, locationPermission, locationSettings, refreshStatus, repairHelper, portal, recoverySettings, copy
    public var title: String {
        switch self {
        case .networkSettings: return "打开 WiFi 设置"
        case .locationPermission: return "允许读取名称"
        case .locationSettings: return "打开定位权限设置"
        case .refreshStatus: return "重新检查"
        case .repairHelper: return "修复后台服务"
        case .portal: return "打开酒店登录检测页面"
        case .recoverySettings: return "调整修复授权"
        case .copy: return "复制诊断给 ChatGPT"
        }
    }
    public var destinationURL: URL? {
        switch self {
        case .networkSettings: return URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")
        case .locationSettings: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        case .portal: return URL(string: "http://captive.apple.com/hotspot-detect.html")
        default: return nil
        }
    }
}
public enum FindingLevel: String, Codable, Sendable { case good, warning, failure, unknown }
public struct ConnectionFinding: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var level: FindingLevel
    public var action: SupportAction?
    public var secondaryAction: SupportAction?
    public init(_ id: String, _ title: String, _ detail: String, _ level: FindingLevel, _ action: SupportAction? = nil, secondaryAction: SupportAction? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.level = level; self.action = action
        self.secondaryAction = secondaryAction
    }
}
public struct ConnectionDiagnosis: Sendable {
    public var title: String
    public var explanation: String
    public var findings: [ConnectionFinding]
}
public enum DiagnosisBuilder {
    public static func name(ssid: String?, context: NetworkContext, facts: LocalConnectionFacts) -> String {
        if context.wifiOn == false { return "WiFi 已关闭" }
        if let ssid, !ssid.isEmpty { return ssid }
        if facts.associated == false { return "尚未连接 WiFi" }
        return facts.location == .authorized ? "已读取连接状态，名称未返回" : "WiFi 名称受系统权限保护"
    }
    public static func diagnose(context c: NetworkContext, facts f: LocalConnectionFacts,
                                capabilities: CapabilityRegistry? = nil, report: SessionReport? = nil,
                                policy: OptimizationPolicy = .init()) -> ConnectionDiagnosis {
        var findings: [ConnectionFinding] = []
        if c.interface == nil {
            findings.append(.init("interface", "未发现可用的 WiFi 接口", "系统没有返回 WiFi 接口，无法对无线连接执行修复。", .failure, .networkSettings))
        } else if c.wifiOn == false {
            findings.append(.init("power", "WiFi 已关闭", "请在系统 WiFi 菜单中打开无线网络。程序不会反复打开你关闭的 WiFi。", .failure, .networkSettings))
        } else if f.associated == false {
            findings.append(.init("association", "尚未连接到酒店 WiFi", "无线链路尚未建立。请在 WiFi 菜单选择已知网络；新网络的密码需要由你输入。", .failure, .networkSettings))
        } else if c.hasIPv4 == false && c.hasIPv6 == false {
            findings.append(.init("address", "没有可用的网络地址", f.dhcp == true ? "当前使用 DHCP，但尚未获得可用的 IPv4 或 IPv6 地址。已授权的地址恢复会在重复验证失败后尝试。" : "当前地址不可用；不会把手动地址擅自改成 DHCP。", .failure, .recoverySettings))
        } else if c.hasRoute == false {
            findings.append(.init("route", "没有通向当前 WiFi 的有效路由", "已读取到路由异常。需要核对酒店分配的网关和地址；IPv6 可用时不会仅因缺少 IPv4 续租。", .failure, .networkSettings))
        } else {
            findings.append(.init("local", "本机连接检查", "WiFi：\(state(c.wifiOn)) · 无线链路：\(state(f.associated)) · 地址：\(address(c)) · 路由：\(state(c.hasRoute))。本机状态正常不等于互联网已验证。", c.wifiOn == true && c.hasRoute == true ? .good : .unknown))
        }
        let final = report?.windows.last(where: { $0.label.contains("最终") })
        let system = final?.samples.filter { $0.path == .system } ?? []
        if report?.currentValidatedAt != nil {
            findings.append(.init("application", "当前连接已通过应用请求验证", "最终复测 \(system.filter(\.complete).count) / \(system.count) 次完整成功；保留系统代理、VPN 与 TLS 校验。", .good))
        } else if !system.isEmpty {
            let failed = system.filter { !$0.complete }
            if system.contains(where: \.complete) {
                findings.append(.init("endpoints", "部分测试站点无法完成请求", "存在完整成功的请求，不能把某个端点失败当成整个网络断开。失败：\(failureSummary(failed))。", .warning, .copy))
            } else if failed.contains(where: { $0.failure == .redirect || $0.failure == .body || $0.status == 511 }) {
                findings.append(.init("portal", "响应被跳转或与预期不符", "可能需要酒店登录，也可能是端点内容变化。打开登录检测页面确认；程序不会绕过认证。", .warning, .portal))
            } else if failed.allSatisfy({ $0.failure == .dns }) {
                findings.append(.init("dns", "域名解析连续失败", "系统路径尚不能解析测试域名。将比较允许的解析方式；VPN、分流 DNS 和受管理设置仍受保护。", .failure, .copy))
            } else if failed.contains(where: { $0.failure == .tls }) {
                findings.append(.init("tls", "安全连接校验未通过", "请检查系统日期、酒店登录和代理证书。不会忽略证书错误或安装未知根证书。", .failure, .portal))
            } else if c.proxy.any {
                findings.append(.init("proxy", "系统代理路径的请求未完成", "检测到系统代理；无法仅凭本次失败断定代理配置错误。\(failureSummary(failed))。", .failure, .copy))
            } else {
                findings.append(.init("internet", "应用请求仍未完成", "\(failureSummary(failed))。仅凭这些结果还不能确定是酒店出口、网关还是远端服务故障。", .failure, .copy))
            }
        }
        if !f.nameReadable && c.wifiOn != false && f.associated != false {
            let action: SupportAction = f.location == .authorized ? .refreshStatus : f.location == .notRequested ? .locationPermission : .locationSettings
            findings.append(.init("name", "为什么看不到网络名称", f.location.explanation, .warning, action))
        }
        if let helper = capabilities?.capabilities.first(where: { $0.id == "helper" }), helper.state != .available {
            findings.append(.init("helper", "自动修复服务未就绪", helper.detail + " 本次仍可诊断，但需要特权的 DNS、重连和 DHCP 操作不会执行。", .warning, .repairHelper))
        }
        if capabilities?.available("helper") == true, policy.allowReconnect, f.nameReadable, c.wifiOn != false,
           let association = capabilities?.capabilities.first(where: { $0.id == "reconnect" }),
           association.state != .available {
            findings.append(.init("associationPermission", "名称已读取，自动重连暂不可用", association.detail, .warning, .refreshStatus, secondaryAction: .networkSettings))
        }
        if !policy.allowReconnect || policy.linkRecovery?.allowIdleInterruption != true {
            findings.append(.init("authorization", "短暂重连尚未获完整授权", "可在“修复设置”中一次允许异常时重连及低流量中断。持续传输时仍不执行断开操作。", .warning, .recoverySettings))
        }
        let primary = findings.first(where: { $0.level == .failure }) ?? findings.first(where: { ["portal","endpoints"].contains($0.id) })
        if let primary { return .init(title: primary.title, explanation: primary.detail, findings: findings) }
        if report?.currentValidatedAt != nil {
            let changed = !(report?.changes.isEmpty ?? true)
            return .init(title: changed ? (report?.conclusion ?? "当前连接已验证") : "当前连接可用，无需强行修改",
                         explanation: changed ? (report?.evidence ?? "请查看本次执行记录") : "本次真实请求已通过。没有可重复的改善证据时，保留现有连接。", findings: findings)
        }
        return .init(title: report == nil ? "先检查，再修复" : "尚未完成当前连接验证",
                     explanation: report == nil ? "离线也能检查本机 WiFi、地址、路由、权限和修复服务。" : "已保留检查结果；下面列出了已发现的问题与阻塞。", findings: findings)
    }
    public static func state(_ value: Bool?) -> String { value.map { $0 ? "可用" : "不可用" } ?? "未确认" }
    public static func address(_ c: NetworkContext) -> String {
        [c.hasIPv4 == true ? "IPv4" : nil, c.hasIPv6 == true ? "IPv6" : nil].compactMap { $0 }.joined(separator: " + ").nonEmpty ?? "未获得/未确认"
    }
    public static func failureSummary(_ samples: [ProbeSample]) -> String {
        let names: [ProbeFailure: String] = [.dns:"解析失败", .connect:"连接失败", .tls:"证书或 TLS 错误", .timeout:"超时", .cancelled:"已停止", .http:"HTTP 状态异常", .body:"响应未通过校验", .redirect:"跳转受限", .byteLimit:"超过流量上限", .transport:"传输失败", .endpoint:"端点异常", .parse:"数据不可解析"]
        return Dictionary(grouping: samples, by: { $0.failure }).map { "\($0.key.flatMap { names[$0] } ?? "未知错误") \($0.value.count) 次" }.sorted().joined(separator: "、")
    }
    /// Skip remote requests only for observed local impossibility, not for a hidden SSID or IPv4 absence.
    public static func shouldProbe(_ c: NetworkContext, _ f: LocalConnectionFacts) -> Bool {
        c.interface != nil && c.wifiOn != false && f.associated != false
    }
}
private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

public struct EndpointComparison: Identifiable, Sendable {
    public var id: String
    public var before: SampleStatistics
    public var after: SampleStatistics
    public static func from(_ report: SessionReport) -> [Self] {
        guard let a = report.windows.first(where: { $0.samples.contains(where: { $0.path == .system }) }),
              let b = report.windows.last(where: { $0.label.contains("最终") }) else { return [] }
        return Set(a.samples.map(\.endpoint)).sorted().compactMap { id in
            let before = a.samples.filter { $0.endpoint == id && $0.path == .system }
            let after = b.samples.filter { $0.endpoint == id && $0.path == .system }
            guard let first = before.first, !after.isEmpty,
                  (before + after).allSatisfy({ $0.provider == first.provider && $0.kind == first.kind }) else { return nil }
            return .init(id: id, before: .init(before), after: .init(after))
        }
    }
}

public enum HelperDiagnostics {
    public static func canRepairRegistration(_ text: String?) -> Bool {
        guard let text else { return false }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.contains("job state = spawn failed") && lines.contains(where: { $0.hasPrefix("last exit code = 78:") }) &&
            !lines.contains(where: { $0.hasPrefix("pid =") || $0 == "state = running" })
    }
    public static func detail(ready: Bool, message: String, registration: SMAppService.Status, launchText: String?) -> String {
        if ready { return "恢复服务已通过双向身份校验并响应。" }
        if registration == .requiresApproval { return "macOS 尚未批准后台修复服务。请打开系统设置批准 HotelWiFi。" }
        if registration == .notRegistered || registration == .notFound { return "后台修复服务尚未安装或登记。" }
        if let launchText, launchText.contains("needs LWCR update") || launchText.contains("OS_REASON_CODESIGNING") {
            return "后台服务的启动签名约束与当前版本不匹配，macOS 已阻止启动。需要通过完整更新流程重新登记当前版本；网络写入已暂停。"
        }
        if let launchText, launchText.contains("EX_CONFIG") || launchText.contains("state = spawn failed") {
            return "后台服务已登记，但启动失败（EX_CONFIG / 启动配置异常）。需要重新登记并验证启动；本机证书签名不代表 macOS 已允许特权服务运行。"
        }
        return "后台服务已登记，但未收到有效响应：\(message)"
    }
    public static func launchState() -> String? {
        let r = BoundedProcess.run("/bin/launchctl", ["print", "system/" + HotelWiFiService.jobIdentifier], timeout: 2, maxBytes: 32768)
        return r.status == 0 ? String(data: r.data, encoding: .utf8) : nil
    }
}
