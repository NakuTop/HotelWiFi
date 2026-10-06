import Foundation
import SystemConfiguration
import CoreWLAN
import Network
import ServiceManagement
import CryptoKit
import Darwin

public struct RuntimeNetwork {
    public var context: NetworkContext
    public var ssid: String?
    public var bssid: String?
    public var dnsServers: [String]
    public var configuredDNS: [String]?
    public var dhcp: Bool?
    public var associated: Bool? = nil
    public var facts: LocalConnectionFacts { .init(location: .read(), associated: associated, nameReadable: ssid != nil, dhcp: dhcp, dnsCount: dnsServers.count, manualDNS: configuredDNS?.isEmpty == false) }
}

public final class NetworkInspector: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    public init() {
        monitor.pathUpdateHandler = { [weak self] p in self?.lock.withLock { self?.path = p } }
        monitor.start(queue: DispatchQueue(label: "HotelWiFi.path"))
    }
    deinit { monitor.cancel() }
    public func read(session: UUID, privacy: PrivacyFilter) -> RuntimeNetwork {
        let store = SCDynamicStoreCreate(nil, "HotelWiFi" as CFString, nil, nil)
        var absentKeys: Set<String> = []
        func state(_ key: String) -> [String: Any] {
            guard let store else { return [:] }
            if let value = SCDynamicStoreCopyValue(store,key as CFString) as? [String:Any] { return value }
            if SCError() == kSCStatusNoKey { absentKeys.insert(key) }
            return [:]
        }
        let prefs = SCPreferencesCreate(nil, "HotelWiFi.Read" as CFString, nil)
        let services = prefs.flatMap { SCNetworkServiceCopyAll($0) as? [SCNetworkService] } ?? []
        let global4 = state("State:/Network/Global/IPv4"), global6 = state("State:/Network/Global/IPv6")
        let primary = (global4["PrimaryInterface"] as? String) ?? (global6["PrimaryInterface"] as? String)
        let allWiFi = CWWiFiClient.shared().interfaces() ?? []
        let wifi = allWiFi.first(where: { $0.interfaceName == primary }) ?? allWiFi.first(where: { $0.ssid() != nil && $0.powerOn() }) ?? CWWiFiClient.shared().interface()
        let interface = wifi?.interfaceName
        let matchingServices = services.filter { s in
            guard let i = SCNetworkServiceGetInterface(s), let interface else { return false }
            return (SCNetworkInterfaceGetBSDName(i) as String?) == interface
        }
        let primaryService = (global4["PrimaryService"] as? String) ?? (global6["PrimaryService"] as? String)
        let service = matchingServices.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == primaryService }) ?? matchingServices.first(where: { SCNetworkServiceGetEnabled($0) })
        let serviceID = service.flatMap { SCNetworkServiceGetServiceID($0) as String? }
        let ipv4 = serviceID.map { state("State:/Network/Service/\($0)/IPv4") } ?? [:]
        let ipv6 = serviceID.map { state("State:/Network/Service/\($0)/IPv6") } ?? [:]
        let dns = serviceID.map { state("State:/Network/Service/\($0)/DNS") } ?? [:]
        let dhcpState = serviceID.map { state("State:/Network/Service/\($0)/DHCP") } ?? [:]
        var configs: [String: [String: Any]] = [:]
        if let service {
            for entity in ["DNS", "IPv4", "IPv6", "Proxies"] {
                if let p = SCNetworkServiceCopyProtocol(service, entity as CFString) {
                    configs[entity] = SCNetworkProtocolGetConfiguration(p) as? [String: Any] ?? [:]
                }
            }
        }
        let liveProxies = state("State:/Network/Global/Proxies")
        let proxies = configs["Proxies"] ?? [:]
        func on(_ keys: [String]) -> Bool { keys.contains { (proxies[$0] as? NSNumber)?.boolValue == true || (liveProxies[$0] as? NSNumber)?.boolValue == true } }
        var proxy = ProxySummary()
        proxy.manual = on(["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "FTPEnable"])
        proxy.pac = on(["ProxyAutoConfigEnable"])
        proxy.discovery = on(["ProxyAutoDiscoveryEnable"])
        proxy.environment = ProcessInfo.processInfo.environment.keys.contains { ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains($0.lowercased()) }
        // Configuration profile ownership cannot be inferred from a checkbox. Helper may establish this separately.
        proxy.managed = nil
        let p = lock.withLock { path }
        let vpnKeys = store.flatMap { SCDynamicStoreCopyKeyList($0, "State:/Network/Service/.*/(PPP|IPSec|VPN)" as CFString) as? [String] } ?? []
        let vpn = primary?.hasPrefix("utun") == true || primary?.hasPrefix("ppp") == true || !vpnKeys.isEmpty || (p?.availableInterfaces.contains { $0.type == .other && ($0.name.hasPrefix("utun") || $0.name.hasPrefix("ppp")) } ?? false)
        let supplemental = store.flatMap { SCDynamicStoreCopyKeyList($0, "State:/Network/Service/.*/DNS" as CFString) as? [String] } ?? []
        let split = supplemental.contains { key in
            let d = state(key)
            return !(d["SupplementalMatchDomains"] as? [String] ?? []).isEmpty || !(d["SearchDomains"] as? [String] ?? []).isEmpty
        } || !(configs["DNS"]?["SearchDomains"] as? [String] ?? []).isEmpty
        let ssid = wifi?.ssid(), bssid = wifi?.bssid()
        let power = wifi?.powerOn()
        let gateway = (ipv4["Router"] as? String) ?? (ipv6["Router"] as? String)
        // System-provided network signature/router identity distinguishes equal SSIDs with equal private IP ranges.
        // These values are used only in memory and enter persistence solely through keyed digests.
        let networkSignature = (ipv4["NetworkSignature"] as? String) ?? (ipv6["NetworkSignature"] as? String)
        let routerIdentity = ipv4["ARPResolvedHardwareAddress"] as? String
        let security = wifi.flatMap { $0.security() == .unknown ? nil : String($0.security().rawValue) }
        let v4Key = serviceID.map { "State:/Network/Service/\($0)/IPv4" }
        let v6Key = serviceID.map { "State:/Network/Service/\($0)/IPv6" }
        let usefulV4: Bool? = v4Key.flatMap { absentKeys.contains($0) ? false : (ipv4["Addresses"] as? [String]).map { $0.contains { !$0.hasPrefix("169.254.") && !$0.hasPrefix("127.") } } }
        let usefulV6: Bool? = v6Key.flatMap { absentKeys.contains($0) ? false : (ipv6["Addresses"] as? [String]).map { $0.contains { !$0.lowercased().hasPrefix("fe80:") && $0 != "::1" } } }
        let route: Bool? = primary.map { $0 == interface || vpn } ??
            (absentKeys.contains("State:/Network/Global/IPv4") && absentKeys.contains("State:/Network/Global/IPv6") ? false : nil)
        let fingerprint: String? = {
            guard let interface, let serviceID, ssid != nil || networkSignature != nil else { return nil }
            let subnet = (ipv4["SubnetMasks"] as? [String] ?? []).joined(separator: ",")
            let server = (dhcpState["ServerIdentifier"] as? String) ?? "unknown"
            // A system network signature can establish identity even when TCC hides SSID.
            // With no gateway/signature, bind recovery to this session and observed AP, not a historical SSID.
            let identitySource = networkSignature ?? routerIdentity
            guard gateway != nil || bssid != nil else { return nil }
            return privacy.digest([identitySource == nil ? (ssid ?? "unknown") : "system-signature", interface, serviceID,
                identitySource == nil ? (security ?? "unknown") : "system", gateway ?? "no-route", subnet, server,
                identitySource ?? (gateway == nil ? session.uuidString + (bssid ?? "unknown") : "session")])
        }()
        // Sorted serialization avoids false external-change events from dictionary iteration order.
        let enableKeys = ["HTTPEnable","HTTPSEnable","SOCKSEnable","FTPEnable","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"]
        let knownProxyShape = enableKeys.allSatisfy { key in
            [proxies,liveProxies].allSatisfy { d in d[key] == nil || d[key] is NSNumber }
        }
        let knownDNSShape = ["ServerAddresses","SearchDomains","SupplementalMatchDomains"].allSatisfy { key in
            [dns,configs["DNS"] ?? [:]].allSatisfy { d in d[key] == nil || d[key] is [String] }
        }
        let confData = knownProxyShape && knownDNSShape ? try? JSONSerialization.data(withJSONObject: configs, options: [.sortedKeys]) : nil
        let configDigest = confData.map { privacy.digest([$0.base64EncodedString()]) }
        let channel = wifi?.wlanChannel()
        let radio = RadioReading(rssi: wifi.flatMap { let n = $0.rssiValue(); return n < 0 ? n : nil },
                                 noise: wifi.flatMap { let n = $0.noiseMeasurement(); return n < 0 ? n : nil },
                                 transmitMbps: wifi.flatMap { let n = $0.transmitRate(); return n > 0 ? n : nil },
                                 channel: channel.flatMap { $0.channelNumber > 0 ? $0.channelNumber : nil }, band: channel.flatMap {
            switch $0.channelBand { case .band2GHz: return "2.4 GHz"; case .band5GHz: return "5 GHz"; case .band6GHz: return "6 GHz"; default: return nil }
        })
        let context = NetworkContext(sessionID: session, interface: interface, serviceID: serviceID,
            serviceName: service.flatMap { SCNetworkServiceGetName($0) as String? }, identity: fingerprint,
            apIdentity: bssid.map { privacy.digest([$0]) }, confidence: fingerprint == nil ? .unknown : (networkSignature != nil || routerIdentity != nil ? .corroborated : .sessionOnly),
            security: security, wifiOn: power, hasIPv4: usefulV4, hasIPv6: usefulV6,
            hasRoute: route, vpnPresent: vpn, splitDNS: split, proxy: proxy,
            constrained: p?.isConstrained, expensive: p?.isExpensive, radio: radio, configurationDigest: configDigest)
        let method = configs["IPv4"]?["ConfigMethod"] as? String
        return RuntimeNetwork(context: context, ssid: ssid, bssid: bssid, dnsServers: dns["ServerAddresses"] as? [String] ?? [],
                              configuredDNS: configs["DNS"]?["ServerAddresses"] as? [String], dhcp: method.map { $0 == "DHCP" },
                              associated: ssid != nil ? true : interface.flatMap { state("State:/Network/Interface/\($0)/Link")["Active"] as? Bool })
    }
    public func capabilities(_ n: RuntimeNetwork, helper: Bool, curl: String, helperDetail: String? = nil, associationIdentityReadable: Bool? = nil) -> CapabilityRegistry {
        let reconnect = Self.reconnectCapability(nameReadable: n.ssid != nil, helperReady: helper, helperIdentityReadable: associationIdentityReadable)
        return .init(osVersion: ProcessInfo.processInfo.operatingSystemVersionString, capabilities: [
            .init("wifiInterface", n.context.interface == nil ? .unknown : .available, n.context.interface ?? "unknown"),
            .init("networkService", n.context.serviceID == nil ? .unknown : .available, n.context.serviceName ?? "unknown"),
            .init("CoreWLAN", CWWiFiClient.shared().interface() == nil ? .unavailable : .available, "公开 CoreWLAN API；无线读数仅用于解释"),
            .init("locationEntitlement", CodeSigningTrust.hasLocationEntitlement() ? .available : .unavailable, CodeSigningTrust.hasLocationEntitlement() ? "本进程签名已包含定位声明" : "本进程签名不含定位声明；请在主应用申请网络名称读取权限"),
            .init("SSID", n.ssid == nil ? .permissionRequired : .available, n.ssid == nil ? n.facts.location.explanation : "仅在内存使用"),
            .init("BSSID", n.bssid == nil ? .permissionRequired : .available, n.bssid == nil ? "unknown；不宣称指定 AP" : "持久化前使用本地密钥摘要"),
            .init("scan", .unverified, "SDK 提供公开扫描 API；本次未扫描，避免额外负载"),
            .init("associationAPI", reconnect.state, "公开 CoreWLAN 关联执行器；需已保存网络、恢复凭据和独立授权"),
            .init("APLock", .unavailable, "未发现公开且可维持的 AP 锁定能力"),
            reconnect,
            .init("DHCPRenew", helper && n.dhcp == true ? .available : .permissionRequired, "公开配置刷新 API；仅原本 DHCP 且 IPv4/IPv6/路由故障成立时请求"),
            .init("helper", helper ? .available : (CodeSigningTrust.current() == nil ? .unavailable : .permissionRequired), helperDetail ?? (helper ? "经过双向 XPC 签名校验的恢复服务已响应" : "需要注册恢复服务并在系统设置批准")),
            .init("codeSigning", CodeSigningTrust.current() == nil ? .unavailable : .available, CodeSigningTrust.current()?.description ?? "未签名或临时签名；安装本机证书版可使用特权服务"),
            .init("configurationRead", n.context.serviceID == nil ? .unknown : .available, "SystemConfiguration；配置值与 DHCP 运行值分别读取"),
            .init("configurationWrite", helper ? .unverified : .unavailable, "还需逐项授权、恢复登记、管理状态与证据门禁"),
            .init("curl", curl.isEmpty ? .unavailable : .available, curl.isEmpty ? "unknown" : curl),
            .init("managedConfiguration", .unknown, "配置归属无法确认时，禁止自动写入"),
            .init("trafficSessions", .unknown, "持续传输时不重连；无法识别会话重要性，低流量中断须单独授权")
        ])
    }
    public static func reconnectCapability(nameReadable: Bool, helperReady: Bool, helperIdentityReadable: Bool?) -> Capability {
        guard helperReady else { return .init("reconnect", .unavailable, "后台恢复服务未就绪，当前不能执行自动重连。") }
        guard nameReadable else { return .init("reconnect", .unknown, "尚未读取到当前连接名称，需要先核对前台读取状态。") }
        switch helperIdentityReadable {
        case true?: return .init("reconnect", .available, "单次重新关联请求；不关闭 WiFi，异常持续且授权和业务门禁通过时执行")
        case false?: return .init("reconnect", .unavailable, "HotelWiFi 已能读取网络名称。后台执行进程本次仍无法读取网络身份，当前不能安全执行自动重连；这不表示你尚未授权。可以重新检查，或打开 WiFi 设置手动处理。")
        case nil: return .init("reconnect", .unknown, "网络名称已读取，但尚未收到后台身份能力的有效结果。请重新检查；不会推断为你未授权。")
        }
    }
}

public enum InterfaceResolver {
    /// Map a task metric's local address to its actual local interface without persisting the address.
    public static func name(for address: String?) -> String? {
        guard let address else { return nil }
        let needle = address.lowercased().split(separator: "%").first.map(String.init) ?? address
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }; defer { freeifaddrs(list) }
        var item = list
        while let i = item {
            defer { item = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == AF_INET || a.pointee.sa_family == AF_INET6 else { continue }
            let length = a.pointee.sa_family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
            var buffer = [CChar](repeating:0,count:Int(NI_MAXHOST))
            guard getnameinfo(a,socklen_t(length),&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST) == 0 else { continue }
            let local = String(cString:buffer).lowercased().split(separator:"%").first.map(String.init)
            if local == needle { return String(cString:i.pointee.ifa_name) }
        }
        return nil
    }
}

/// No public arbitrary paths or arbitrary key writes. Only the two FieldTarget enum cases are reachable.
public final class SystemConfigurationBackend: ConfigurationBackend {
    public init() {}
    private func access<T>(_ target: FieldTarget, write: Bool, _ body: (SCPreferences, SCNetworkProtocol, [String: Any]) throws -> T) throws -> T {
        guard !target.serviceID.isEmpty, target.serviceID.count <= 128,
              let prefs = SCPreferencesCreate(nil, "HotelWiFi.Guardian" as CFString, nil) else { throw HWError.blocked("目标服务无效。") }
        // Never stall the recovery queue waiting for another application's preferences lock.
        if write { guard SCPreferencesLock(prefs, false) else { throw HWError.busy } }
        defer { if write { SCPreferencesUnlock(prefs) } }
        SCPreferencesSynchronize(prefs)
        guard let service = SCNetworkServiceCopy(prefs, target.serviceID as CFString),
              let interface = SCNetworkServiceGetInterface(service),
              (SCNetworkInterfaceGetInterfaceType(interface) as String?) == (kSCNetworkInterfaceTypeIEEE80211 as String),
              let proto = SCNetworkServiceCopyProtocol(service, target.field.entity as CFString),
              SCNetworkServiceGetEnabled(service), SCNetworkProtocolGetEnabled(proto) else { throw HWError.blocked("目标不是可读取的已启用 WiFi 服务。") }
        return try body(prefs, proto, SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:])
    }
    private func snapshot(_ target: FieldTarget, _ dict: [String: Any]) throws -> FieldSnapshot {
        guard let value = dict[target.field.key] else { return .init(nil) }
        switch target.field {
        case .dnsServers: guard let strings = value as? [String] else { throw HWError.invalid("DNS 配置字段类型未知。") }; return .init(.strings(strings))
        case .autoProxyDiscovery: guard let n = value as? NSNumber, [0, 1].contains(n.intValue) else { throw HWError.invalid("代理字段类型未知。") }; return .init(.integer(n.intValue))
        }
    }
    public func read(_ target: FieldTarget) throws -> FieldSnapshot { try access(target, write: false) { _, _, d in try snapshot(target, d) } }
    public func compareAndSet(_ target: FieldTarget, expected: FieldSnapshot, desired: FieldSnapshot) throws {
        try access(target, write: true) { prefs, proto, current in
            guard try snapshot(target, current) == expected else { throw HWError.blocked("字段已被外部修改；拒绝覆盖。") }
            var next = current
            switch desired.value {
            case .none: next.removeValue(forKey: target.field.key)
            case .strings(let values): guard target.field == .dnsServers else { throw HWError.invalid("字段类型不匹配。") }; next[target.field.key] = values
            case .integer(let value): guard target.field == .autoProxyDiscovery else { throw HWError.invalid("字段类型不匹配。") }; next[target.field.key] = value
            }
            guard SCNetworkProtocolSetConfiguration(proto, next as CFDictionary), SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
                throw HWError.storage("系统未接受配置，恢复服务将核对原值并清理。")
            }
        }
    }
}
