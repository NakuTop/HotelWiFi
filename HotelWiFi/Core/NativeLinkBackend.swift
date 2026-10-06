import Foundation
import CoreWLAN
import SystemConfiguration
import Security
import Darwin

/// Privileged executor with a deliberately small public surface. No subprocesses or arbitrary keys.
public final class NativeLinkBackend {
    private let inspector = NetworkInspector()
    public init() {}
    private func interface(_ name: String) throws -> CWInterface {
        guard let i = CWWiFiClient.shared().interface(withName: name), i.interfaceName == name, i.powerOn() else { throw HWError.blocked("WiFi 已关闭或目标接口不存在；不会自动打开。") }; return i
    }
    private func supported(_ security: CWSecurity) -> Bool { [.none, .wpa2Personal, .wpa3Personal, .wpa3Transition].contains(security) }
    private func profiles(_ i: CWInterface) -> [CWNetworkProfile] { i.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? [] }
    private func credential(_ ssid: Data, security: Int) throws -> String? {
        guard let kind = CWSecurity(rawValue: security), supported(kind) else { throw HWError.blocked("此安全类型不进入自动关联；保留企业认证及现有配置。") }
        if kind == .none { return nil }
        // This service must never present password/UI requests on behalf of an automatic experiment.
        SecKeychainSetUserInteractionAllowed(false)
        var password: NSString?
        guard CWKeychainFindWiFiPassword(.system, ssid, &password) == errSecSuccess, let password, password.length > 0 else {
            throw HWError.blocked("系统钥匙串未提供可无交互使用的已保存凭据，未尝试关联。")
        }
        return password as String
    }
    public func snapshot(context: NetworkContext) throws -> AssociationSnapshot {
        guard let name = context.interface, let service = context.serviceID, let digest = context.configurationDigest else { throw HWError.blocked("缺少接口、服务或配置快照。") }
        let i = try interface(name)
        guard let ssid = i.ssidData(), !ssid.isEmpty, i.security() != .unknown else { throw HWError.blocked("系统未授权读取当前网络身份，无法建立关联恢复材料。") }
        return .init(interface: name, serviceID: service, ssid: ssid, bssid: i.bssid(), security: i.security().rawValue, configurationDigest: digest)
    }
    public func scan(context: NetworkContext) throws -> [(WiFiCandidate, AssociationSnapshot)] {
        let original = try snapshot(context: context), i = try interface(original.interface)
        let saved = profiles(i).filter { supported($0.security) }
        let scanned: Set<CWNetwork>
        do { scanned = try i.scanForNetworks(withSSID: nil) }
        catch { throw HWError.blocked("CoreWLAN 扫描失败（代码 \((error as NSError).code)），当前连接未修改。") }
        return scanned.compactMap { n in
            guard !n.ibss, let ssid = n.ssidData, let name = n.ssid,
                  let profile = saved.first(where: { $0.ssidData == ssid && n.supportsSecurity($0.security) }),
                  n.bssid != nil else { return nil }
            let snapshot = AssociationSnapshot(interface: original.interface, serviceID: original.serviceID, ssid: ssid,
                bssid: n.bssid, security: profile.security.rawValue, configurationDigest: original.configurationDigest)
            let candidate = WiFiCandidate(name: name, bssid: n.bssid, channel: n.wlanChannel?.channelNumber,
                rssi: n.rssiValue < 0 ? n.rssiValue : nil, currentNetwork: original.ssid == ssid, expires: Date().addingTimeInterval(90))
            return (candidate, snapshot)
        }.prefix(32).map { $0 }
    }
    public func preflight(_ snapshot: AssociationSnapshot) throws {
        let i = try interface(snapshot.interface)
        guard profiles(i).contains(where: { $0.ssidData == snapshot.ssid && $0.security.rawValue == snapshot.security }) else { throw HWError.blocked("目标不是已有配置中的网络，未加入候选。") }
        _ = try credential(snapshot.ssid, security: snapshot.security)
        // A cached observation is sufficient for preflight; the execution re-scans this SSID.
        guard (i.ssidData() == snapshot.ssid && i.bssid() == snapshot.bssid) ||
            i.cachedScanResults()?.contains(where: { $0.ssidData == snapshot.ssid && !$0.ibss }) == true else { throw HWError.blocked("无法确认原网络仍在范围内；请先扫描已保存候选。") }
    }
    public func observe(_ plan: LinkPlan, context: NetworkContext, nonce: String) -> LinkObservation {
        let current = inspector.read(session: context.sessionID, privacy: .init(key: Data(nonce.utf8))).context
        let i = CWWiFiClient.shared().interface(withName: plan.original.interface)
        return .init(wifiOn: i?.powerOn(), ssid: i?.ssidData(), bssid: i?.bssid(), configurationDigest: current.configurationDigest,
                     hasUsableAddress: current.hasRoute == true && (current.hasIPv4 == true || current.hasIPv6 == true),
                     protectedPathChanged: current.vpnPresent || current.splitDNS || current.proxy.any)
    }
    public func execute(_ plan: LinkPlan, context: NetworkContext, nonce: String) throws {
        let observed = observe(plan, context: context, nonce: nonce)
        guard observed.wifiOn == true, observed.ssid == plan.original.ssid,
              observed.configurationDigest == plan.original.configurationDigest else { throw HWError.blocked("执行前网络或配置已变化，未操作。") }
        if plan.action == .renewDHCP { try renewDHCP(plan.original) }
        else { try associate(plan.target) }
    }
    public func associate(_ snapshot: AssociationSnapshot) throws {
        let i = try interface(snapshot.interface)
        guard profiles(i).contains(where: { $0.ssidData == snapshot.ssid && $0.security.rawValue == snapshot.security }) else { throw HWError.blocked("已保存网络已被用户移除。") }
        let password = try credential(snapshot.ssid, security: snapshot.security)
        guard let security = CWSecurity(rawValue: snapshot.security) else { throw HWError.blocked("未知安全类型。") }
        let results: Set<CWNetwork>
        do { results = try i.scanForNetworks(withSSID: snapshot.ssid) }
        catch { throw HWError.blocked("CoreWLAN 目标扫描失败（代码 \((error as NSError).code)）。") }
        // If a specific AP was requested, do not silently replace it with the strongest radio signal.
        guard let network = results.first(where: { !$0.ibss && $0.ssidData == snapshot.ssid && $0.supportsSecurity(security) && (snapshot.bssid == nil || $0.bssid == snapshot.bssid) }) else {
            throw HWError.blocked("本次目标网络/AP 不在范围内，未尝试其他网络。")
        }
        guard i.powerOn() else { throw HWError.blocked("用户已关闭 WiFi。") }
        do { try i.associate(to: network, password: password) }
        catch { throw HWError.blocked("系统关联请求未完成（代码 \((error as NSError).code)）；必须以实际网络事件确认状态。") }
        // CoreWLAN return is only request completion; the guardian reads actual association and address events.
    }
    private func renewDHCP(_ snapshot: AssociationSnapshot) throws {
        guard let prefs = SCPreferencesCreate(nil, "HotelWiFi.DHCP" as CFString, nil),
              let service = SCNetworkServiceCopy(prefs, snapshot.serviceID as CFString), SCNetworkServiceGetEnabled(service),
              let i = SCNetworkServiceGetInterface(service), (SCNetworkInterfaceGetBSDName(i) as String?) == snapshot.interface,
              (SCNetworkInterfaceGetInterfaceType(i) as String?) == (kSCNetworkInterfaceTypeIEEE80211 as String),
              let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4),
              let config = SCNetworkProtocolGetConfiguration(proto) as? [String: Any], config["ConfigMethod"] as? String == "DHCP" else { throw HWError.blocked("目标服务不是 DHCP；保留手动地址方式。") }
        guard SCNetworkInterfaceForceConfigurationRefresh(i) else { throw HWError.blocked("系统未接受 DHCP 刷新请求。") }
    }
}

/// Counter-only observation. No destinations, process names or user traffic content are collected.
public final class TrafficMonitor {
    private struct Reading { var name: String; var bytes: UInt64; var time: TimeInterval }
    private var readings: [Reading] = []
    private let clock: () -> TimeInterval
    private let counter: (String) -> UInt64?
    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, counter: ((String) -> UInt64?)? = nil) {
        self.clock = clock; self.counter = counter ?? Self.byteCount
    }
    public func sample(interface: String?) {
        guard let name = interface, let bytes = counter(name) else { readings = []; return }
        let now = clock()
        readings.append(.init(name: name, bytes: bytes, time: now))
        readings = Array(readings.filter { now-$0.time <= 12 }.suffix(32))
    }
    public var recentRate: Double? {
        guard readings.count >= 3, Set(readings.map(\.name)).count == 1,
              let first = readings.first, let last = readings.last, last.time - first.time >= 4,
              clock() - last.time < 10, last.bytes >= first.bytes,
              zip(readings,readings.dropFirst()).allSatisfy({ $1.bytes >= $0.bytes }) else { return nil }
        return zip(readings,readings.dropFirst()).compactMap { a,b in
            b.time > a.time && b.bytes >= a.bytes ? Double(b.bytes-a.bytes)/(b.time-a.time) : nil
        }.max()
    }
    public func importantTraffic(policy: OptimizationPolicy) -> Bool? {
        guard let rate = recentRate else { return nil }
        if rate > 32_768 { return true }
        // Quiet bytes do not prove an important call/session is absent. Explicit opt-in is required.
        return policy.linkRecovery?.allowIdleInterruption == true ? false : nil
    }
    private static func byteCount(_ name: String) -> UInt64? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }; defer { freeifaddrs(list) }
        var item = list
        while let i = item {
            defer { item = i.pointee.ifa_next }
            if String(cString: i.pointee.ifa_name) == name, i.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let data = i.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                return UInt64(data.pointee.ifi_ibytes) + UInt64(data.pointee.ifi_obytes)
            }
        }
        return nil
    }
}
