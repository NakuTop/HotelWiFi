import Foundation
import HotelWiFiCore
import Darwin

@main enum HotelWiFiCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst()), command = arguments.first ?? "help"
            guard ["diagnose", "optimize", "restore", "monitor", "report", "capabilities", "help", "--help"].contains(command) else { throw HWError.invalid("未知命令。运行 hotelwifi help 查看用法。") }
            if command == "help" || command == "--help" {
                print("""
                HotelWiFi — macOS 原生网络诊断与会话内选优
                hotelwifi diagnose [--json]
                hotelwifi optimize [--dry-run] [--json]
                hotelwifi restore [--json]
                hotelwifi monitor [--once] [--json]
                hotelwifi report [--json]
                hotelwifi capabilities [--json]
                授权策略和端点在 HotelWiFi 图形界面设置。SIGINT/SIGTERM 会停止并恢复。
                optimize 若保留临时修改，将维持前台会话，退出前恢复。报告按需诊断并输出，不自动保存历史。
                """); return
            }
            let store = try SecureStore.user(), settings = SettingsStore(store: store), engine = OptimizationEngine(store: store)
            let json = arguments.contains("--json")
            func output<T: Encodable>(_ value: T) throws { print(String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)) }
            if command == "capabilities" {
                let (_, capabilities) = await engine.inspect()
                if json { try output(capabilities) } else { print(capabilities.osVersion); for c in capabilities.capabilities { print("\(c.id): \(c.state.rawValue) — \(c.detail)") } }; return
            }
            if command == "restore" {
                let client = GuardianClient(), pulse = NetworkEventPulse(), deadline = Date().addingTimeInterval(35)
                var result = await client.call(.init(.restoreAll))
                while !result.ok && result.linkRecord?.terminal == false && Date() < deadline {
                    await pulse.wait()
                    let status = await client.call(.init(.status))
                    guard status.ok else { result = status; break }
                    if status.linkRecord?.terminal == true { result = .init(ok:true, message:status.linkRecord?.detail ?? "已核对恢复状态",linkRecord:status.linkRecord); break }
                }
                if json { try output(RecoveryStatusReport(result)) } else { print(result.message) }
                if !result.ok { exit(69) }; return
            }
            let signalState = SignalState()
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let s = DispatchSource.makeSignalSource(signal: number, queue: .main)
                s.setEventHandler { signalState.stop(); Task { _ = await engine.stop() } }; s.resume(); return s
            }
            defer { for s in signals { s.cancel() } }
            var policy = try settings.policy()
            var endpoints = try settings.endpoints()
            if command == "monitor" { policy.initialRequests = 1; policy.durationLimit = 30; endpoints = endpoints.filter { $0.kind == .connectivity } }
            repeat {
                let mode: RunMode = command == "optimize" ? (arguments.contains("--dry-run") ? .dryRun : .optimize) : .diagnose
                let report = try await engine.run(mode: mode, policy: policy, endpoints: endpoints) { p in
                    if !json { fputs("\(p.message)\(p.total > 0 ? " (\(p.completed)/\(p.total))" : "")\n", stderr) }
                }
                if json { try output(PrivacyFilter.exported(report)) } else { print(ReportBuilder.text(report)) }
                if !report.activeTemporary.isEmpty {
                    fputs("临时配置由前台会话维护；按 Ctrl+C 停止并恢复。\n", stderr)
                    while !signalState.stopped {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let s = await GuardianClient().call(.init(.status))
                        if s.record?.terminal != false { break }
                    }
                    let result = await engine.stop(); if !result.ok { throw HWError.blocked(result.message) }
                }
                if command != "monitor" || arguments.contains("--once") || signalState.stopped { break }
                // Healthy monitoring defaults to 60s; no scans or large-object downloads.
                let generation = await engine.networkChangeVersion()
                for _ in 0..<Int(policy.monitorInterval) {
                    let currentGeneration = await engine.networkChangeVersion()
                    if signalState.stopped || currentGeneration != generation { break }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } while !signalState.stopped
        } catch { fputs("HotelWiFi: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
private final class SignalState: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}
