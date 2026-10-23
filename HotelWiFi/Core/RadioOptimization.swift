import Foundation
import CryptoKit

public final class RadioJournal {
    let store: SecureStore
    public init(store: SecureStore) { self.store = store }
    public func load() throws -> RadioRecord? {
        guard let bytes = try store.read("radio-recovery.sealed") else { return nil }
        let clear = try AES.GCM.open(.init(combined: bytes), using: SymmetricKey(data: store.identityKey()), authenticating: Data("HotelWiFi.Radio.v1".utf8))
        return try JSONCoding.decoder.decode(RadioRecord.self, from: clear)
    }
    public func save(_ r: RadioRecord) throws {
        let box = try AES.GCM.seal(JSONCoding.encoder.encode(r), using: SymmetricKey(data: store.identityKey()), authenticating: Data("HotelWiFi.Radio.v1".utf8))
        guard let data = box.combined else { throw HWError.storage("无法保存无线恢复记录。") }
        try store.write(data, named: "radio-recovery.sealed")
    }
}
public enum RadioOptimizationGate {
    public static func better(_ candidate: AccessPointReading, than original: AccessPointReading) -> Bool {
        guard !candidate.current, let next = candidate.score, let old = original.score,
              let rssi = candidate.rssi, rssi >= -70 else { return false }
        return next - old >= 12
    }
    public static func mayRestore(_ record: RadioRecord, current: AssociationSnapshot?, wifiOn: Bool) -> Bool {
        guard wifiOn, let current, current.interface == record.plan.original.interface,
              current.serviceID == record.plan.original.serviceID, current.ssid == record.plan.original.ssid,
              current.security == record.plan.original.security,
              current.configurationDigest == record.plan.original.configurationDigest else { return false }
        return current.bssid == record.plan.target.bssid
    }
    public static func validCommit(_ windows: [MeasurementWindow], context: NetworkContext) -> Bool {
        windows.count >= 2 && windows.allSatisfy { w in
            w.context.sameNetwork(as: context) && w.context.apIdentity != nil && w.context.apIdentity == context.apIdentity &&
            w.fullyHealthy && Set(w.samples.filter { $0.path == .system }.map(\.provider)).count >= 2
        }
    }
}

/// The root service checks only its physical interface/configuration. SSID/BSSID remain the
/// responsibility of the signed per-user Agent that macOS authorizes to read those identifiers.
public enum RadioPrivilegeGate {
    public static func permits(_ request: GuardianRequest, actual: NetworkContext, managed: Bool?, radioPeer: Bool, now: Date = Date()) -> Bool {
        guard radioPeer, request.action == .disassociateForAP, request.policy?.allowAutomaticAP == true,
              let at = request.requestedAt, now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) < 10,
              let nonce = request.nonce, UUID(uuidString: nonce) != nil, request.transaction != nil,
              let supplied = request.context, supplied.wifiOn == true, actual.wifiOn == true,
              supplied.interface != nil, supplied.serviceID != nil, actual.interface == supplied.interface,
              actual.serviceID == supplied.serviceID, actual.configurationDigest != nil,
              actual.configurationDigest == supplied.configurationDigest, managed == false else { return false }
        return true
    }
}
