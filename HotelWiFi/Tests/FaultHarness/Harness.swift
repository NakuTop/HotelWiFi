import Foundation
import HotelWiFiCore
import Darwin

/// Test-only executable, never copied into the application bundle. It cannot write system networking.
private final class FileSimulation: ConfigurationBackend {
    let store: SecureStore
    init(_ store: SecureStore) { self.store = store }
    func read(_ target: FieldTarget) throws -> FieldSnapshot {
        guard let d = try store.read("simulated-field.json") else { return .init(nil) }
        return try JSONCoding.decoder.decode(FieldSnapshot.self,from:d)
    }
    func compareAndSet(_ target: FieldTarget, expected: FieldSnapshot, desired: FieldSnapshot) throws {
        try store.withExclusiveLock("field.lock") {
            guard try read(target) == expected else { throw HWError.blocked("external conflict") }
            try store.write(JSONCoding.encoder.encode(desired),named:"simulated-field.json")
        }
    }
}
@main enum Harness {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let mode = CommandLine.arguments[1], path = CommandLine.arguments[2]
        guard path.hasPrefix("/private/tmp/HotelWiFiFault-"), !path.contains("..") else { exit(64) }
        let store = try SecureStore(directory:URL(fileURLWithPath:path,isDirectory:true)), backend = FileSimulation(store)
        let journal = TransactionJournal(store:store), recovery = RecoveryCoordinator(backend:backend,journal:journal)
        if mode == "apply-and-wait" {
            var proxy = ProxySummary(); proxy.managed = false
            let context = NetworkContext(interface:"simulated",serviceID:"fixture-service",identity:"fixture-network",confidence:.sessionOnly,wifiOn:true,hasIPv4:true,hasRoute:true,proxy:proxy,expensive:false,configurationDigest:"fixture-config")
            var policy = OptimizationPolicy(); policy.completedOnboarding = true; policy.allowTemporaryDNS = true
            let r = try recovery.prepare(target:.init(serviceID:"fixture-service",field:.dnsServers),value:.strings(["1.1.1.1","1.0.0.1"]),context:context,uid:getuid(),nonce:UUID().uuidString)
            _ = try recovery.arm(r.id)
            let gate = GateInput(operation:.dns,context:context,policy:policy,helperReady:true,snapshotSaved:true,guardianArmed:true,originalKnown:true,reproducibleEvidence:true,health:.failed)
            _ = try recovery.apply(r.id,gate:gate); _ = try recovery.verify(r.id); _ = try recovery.commit(r.id)
            try store.write(Data("ready".utf8),named:"ready")
            while true { pause() }
        } else if mode == "recover" {
            let result = try recovery.recoverOnStartup()
            guard result?.configurationRestored == true, try backend.read(result!.target).value == nil else { exit(1) }
            print("Recovered simulated configuration in a separate process; connectivity remains unverified.")
        } else { exit(64) }
    }
}
