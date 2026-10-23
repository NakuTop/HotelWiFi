import Foundation
import CoreWLAN
import HotelWiFiCore

typealias RadioScan = (RadioSurvey, AssociationSnapshot, [(AccessPointReading, AssociationSnapshot)])

/// The service state machine can be exercised without touching the machine's radio.
protocol RadioEnvironment: AnyObject {
    var identityReadable: Bool { get }
    var interfaceName: String? { get }
    func context(nonce: String, session: UUID) -> NetworkContext
    func snapshot(context: NetworkContext) throws -> AssociationSnapshot
    func scan(nonce: String) throws -> RadioScan
    func preflight(_ snapshot: AssociationSnapshot) throws
    func associate(_ snapshot: AssociationSnapshot, beforeAssociation: (() throws -> Void)?) throws
}

final class NativeRadioEnvironment: RadioEnvironment {
    private let native = NativeLinkBackend(), inspector = NetworkInspector()
    var identityReadable: Bool { CWWiFiClient.shared().interface()?.bssid() != nil }
    var interfaceName: String? { CWWiFiClient.shared().interface()?.interfaceName }
    func context(nonce: String, session: UUID) -> NetworkContext {
        inspector.read(session: session, privacy: .init(key: Data(nonce.utf8))).context
    }
    func snapshot(context: NetworkContext) throws -> AssociationSnapshot { try native.snapshot(context: context) }
    func preflight(_ snapshot: AssociationSnapshot) throws { try native.preflight(snapshot) }
    func associate(_ snapshot: AssociationSnapshot, beforeAssociation: (() throws -> Void)?) throws {
        try native.associate(snapshot, beforeAssociation: beforeAssociation)
    }
    func scan(nonce: String) throws -> RadioScan {
        let c = context(nonce: nonce, session: UUID()), original = try native.snapshot(context: c)
        let saved = try native.scan(context: c)
        guard let interface = CWWiFiClient.shared().interface(withName: original.interface), interface.ssidData() == original.ssid,
              interface.bssid() == original.bssid else { throw HWError.blocked("无线扫描期间连接已变化。") }
        let all = interface.cachedScanResults() ?? []
        let points: [(AccessPointReading, AssociationSnapshot)] = saved.filter { $0.1.ssid == original.ssid && $0.1.security == original.security }.map { candidate, snapshot in
            let network = all.first { $0.bssid == snapshot.bssid }
            let ch = network?.wlanChannel
            let band = ch?.channelBand == .band2GHz ? "2.4 GHz" : ch?.channelBand == .band5GHz ? "5 GHz" : ch?.channelBand == .band6GHz ? "6 GHz" : "未知频段"
            let neighbors = all.filter { other in
                guard let ch, let otherCh = other.wlanChannel, other.bssid != snapshot.bssid,
                      ch.channelBand == otherCh.channelBand, other.rssiValue >= -80 else { return false }
                return ch.channelBand == .band2GHz ? abs(ch.channelNumber - otherCh.channelNumber) < 5 : ch.channelNumber == otherCh.channelNumber
            }.count
            let noise = network?.noiseMeasurement
            return (.init(current: snapshot.bssid == original.bssid, rssi: candidate.rssi,
                          noise: noise.flatMap { (-120 ..< -1).contains($0) ? $0 : nil }, channel: candidate.channel, band: band, neighbors: neighbors), snapshot)
        }
        return (.init(points: points.map(\.0), detail: "用户会话 Agent 已读取 AP 身份；同网络、同安全类型候选可自动切换并复测。"), original, points)
    }
}
