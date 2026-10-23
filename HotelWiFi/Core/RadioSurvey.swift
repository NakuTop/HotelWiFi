import Foundation
import CoreWLAN

public struct AccessPointReading: Codable, Identifiable, Sendable {
    public var id: UUID
    public var current: Bool
    public var rssi: Int?
    public var noise: Int?
    public var channel: Int?
    public var band: String
    public var neighbors: Int
    public init(id: UUID = UUID(), current: Bool, rssi: Int?, noise: Int?, channel: Int?, band: String, neighbors: Int = 0) {
        self.id = id; self.current = current; self.rssi = rssi; self.noise = noise
        self.channel = channel; self.band = band; self.neighbors = neighbors
    }
    public var snr: Int? { guard let rssi, let noise else { return nil }; return rssi - noise }
    /// A conservative radio ranking, never a measured bandwidth or contention guarantee.
    public var score: Double? {
        guard let rssi else { return nil }
        let signal = min(60, max(0, Double(rssi + 90) * 1.2))
        let quality = snr.map { min(25, max(0, Double($0) * 0.65)) } ?? 10
        let bandBonus: Double = band == "2.4 GHz" || rssi < -70 ? 0 : 8
        return max(0, signal + quality + bandBonus - min(18, Double(neighbors) * 2))
    }
}
public struct RadioSurvey: Codable, Sendable {
    public var checked = Date()
    public var points: [AccessPointReading]
    public var detail: String
    public init(points: [AccessPointReading], detail: String) { self.points = points; self.detail = detail }
    public var ranked: [AccessPointReading] {
        points.sorted { ($0.score ?? -1) > ($1.score ?? -1) }
    }
    public var recommendation: String {
        guard let current = points.first(where: \.current), let score = current.score else { return detail }
        guard let best = ranked.first, best.id != current.id, let bestScore = best.score,
              bestScore - score >= 12, let rssi = best.rssi, rssi >= -70 else {
            return "当前接入点未发现明显更优的无线候选。信号好仍可能受酒店共享出口限速。"
        }
        return "同名网络发现更优无线候选：\(best.band)，信道 \(best.channel.map(String.init) ?? "未知")，\(rssi) dBm。自动优化会确认优势并执行切换，实际结果以切换后的复测为准。"
    }
}
public enum RadioSurveyor {
    /// No other network names or raw BSSIDs leave this scan; a strong stranger's AP is never a candidate.
    public static func scan(interface name: String) async -> RadioSurvey {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let interface = CWWiFiClient.shared().interface(withName: name), interface.powerOn(),
                      let ssid = interface.ssidData(), let bssid = interface.bssid() else {
                    continuation.resume(returning: .init(points: [], detail: "无法读取当前 WiFi 身份；允许名称读取后可比较同网络接入点。")); return
                }
                do {
                    let all = try interface.scanForNetworks(withSSID: nil)
                    guard interface.ssidData() == ssid, interface.bssid() == bssid else {
                        continuation.resume(returning: .init(points: [], detail: "扫描期间接入点已变化，请重新检查。")); return
                    }
                    let security = interface.security()
                    var points = all.filter { !$0.ibss && $0.ssidData == ssid && $0.supportsSecurity(security) && $0.bssid != nil }.map { network -> AccessPointReading in
                        let channel = network.wlanChannel
                        let band: String
                        switch channel?.channelBand {
                        case .band2GHz: band = "2.4 GHz"
                        case .band5GHz: band = "5 GHz"
                        case .band6GHz: band = "6 GHz"
                        default: band = "未知频段"
                        }
                        let neighbors = all.filter { other in
                            guard let a = channel, let b = other.wlanChannel, network.bssid != other.bssid,
                                  a.channelBand == b.channelBand, other.rssiValue >= -80 else { return false }
                            return a.channelBand == .band2GHz ? abs(a.channelNumber - b.channelNumber) < 5 : a.channelNumber == b.channelNumber
                        }.count
                        return .init(current: network.bssid == bssid, rssi: (-100..<0).contains(network.rssiValue) ? network.rssiValue : nil,
                            noise: (-120 ..< -1).contains(network.noiseMeasurement) ? network.noiseMeasurement : nil,
                            channel: channel?.channelNumber, band: band, neighbors: neighbors)
                    }
                    if !points.contains(where: \.current) {
                        let channel = interface.wlanChannel()
                        let band = channel?.channelBand == .band2GHz ? "2.4 GHz" : channel?.channelBand == .band5GHz ? "5 GHz" : channel?.channelBand == .band6GHz ? "6 GHz" : "未知频段"
                        points.append(.init(current: true, rssi: (-100..<0).contains(interface.rssiValue()) ? interface.rssiValue() : nil,
                                            noise: (-120 ..< -1).contains(interface.noiseMeasurement()) ? interface.noiseMeasurement() : nil,
                                            channel: channel?.channelNumber, band: band))
                    }
                    continuation.resume(returning: .init(points: points, detail: "无线排序综合信号、信噪比和附近同频 AP 数；同频数量是拥挤线索，无法读取其他住客实际流量。"))
                } catch {
                    continuation.resume(returning: .init(points: [], detail: "无线扫描未完成（代码 \((error as NSError).code)），当前连接未修改。"))
                }
            }
        }
    }
}
