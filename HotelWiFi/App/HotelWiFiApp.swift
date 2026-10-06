import SwiftUI
import AppKit
import CoreLocation
import CoreServices
import ServiceManagement
import HotelWiFiCore
import Darwin

@MainActor final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var busy = false
    @Published var helperBusy = false
    @Published var status = "正在检查本机连接…"
    @Published var policy = OptimizationPolicy()
    @Published var network: NetworkContext?
    @Published var facts = LocalConnectionFacts()
    @Published var networkName = "正在读取 WiFi"
    @Published var capabilities: CapabilityRegistry?
    @Published var report: SessionReport?
    @Published var error: String?
    @Published var showSettings = false
    @Published var showDetails = false
    @Published var completed = 0
    @Published var total = 0
    @Published var liveStatusValid = false
    @Published var copyStatus = ""
    @Published var locationMessage = ""
    @Published var locationRequestPending = false
    @Published var checkingStatus = false
    @Published var capabilitiesCheckedAt: Date?
    @Published var candidates: [WiFiCandidate] = []
    @Published var candidateID: UUID?
    @Published var candidateCostApproved = false
    let engine: OptimizationEngine?
    let settings: SettingsStore?
    let location = CLLocationManager()
    var events: NetworkEvents?
    var task: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var sleepObservers: [NSObjectProtocol] = []
    var activationObserver: NSObjectProtocol?
    let statusRefresh = StatusRefreshCoordinator()
    var preparedForUpdate = false
    override init() {
        do { let s = try SecureStore.user(); settings = SettingsStore(store: s); engine = OptimizationEngine(store: s) }
        catch { settings = nil; engine = nil }
        super.init(); location.delegate = self
        do { policy = try settings?.policy() ?? .init() } catch { self.error = error.localizedDescription }
        if engine == nil { error = "无法打开私有恢复存储。请复制诊断，检查 HotelWiFi 数据目录的权限。" }
        events = NetworkEvents { [weak self] in Task { @MainActor in
            guard let self else { return }
            self.liveStatusValid = false
            self.refreshTask?.cancel()
            self.refreshTask = Task { try? await Task.sleep(nanoseconds: 300_000_000); if !Task.isCancelled { await self.refresh() } }
        } }
        sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.liveStatusValid = false; _ = await self?.engine?.stop() }
        })
        sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.liveStatusValid = false; self?.status = "已唤醒，请重新检查当前连接"; await self?.refresh() }
        })
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // TCC and background-service approval changes need not generate a
            // network event. Re-read both whenever the user returns to the app.
            Task { @MainActor in await self?.refresh() }
        }
        Task {
            await engine?.observeChanges(); await refresh()
            if CommandLine.arguments.contains("--repair-helper") || CommandLine.arguments.contains("--register-helper") { repairHelper() }
            if CommandLine.arguments.contains("--unregister-helper") { await unregisterHelper() }
            if CommandLine.arguments.contains("--prepare-update") { await prepareForUpdate() }
        }
    }
    var diagnosis: ConnectionDiagnosis {
        var currentReport = report
        if !liveStatusValid { currentReport?.currentValidatedAt = nil }
        return DiagnosisBuilder.diagnose(context: network ?? .init(), facts: facts, capabilities: capabilities, report: currentReport, policy: policy)
    }
    func refresh() async {
        guard let engine else { return }
        await statusRefresh.refresh {
            let local = await engine.inspectLocal(); updateLocal(local)
            let (latest, c) = await engine.inspect(); updateLocal(latest); capabilities = c
            capabilitiesCheckedAt = Date()
        }
        if report == nil && !busy && !helperBusy && !checkingStatus { status = "本机检查已完成；点击下方按钮测试并修复连接" }
    }
    func recheckStatus() {
        guard !checkingStatus else { return }
        guard engine != nil else { error = "私有状态存储不可用，暂时无法重新检查。"; return }
        checkingStatus = true
        if !busy && !helperBusy { status = "正在重新检查名称权限和后台连接能力" }
        Task {
            defer { checkingStatus = false }
            await refresh()
            guard !busy && !helperBusy else { return }
            if capabilities?.available("helper") != true { status = "状态已更新：后台服务尚未就绪，请查看下方原因" }
            else if facts.nameReadable {
                status = capabilities?.available("reconnect") == true ? "状态已更新：名称读取和后台身份均已确认" : "状态已更新：名称读取正常，自动重连仍暂不可用"
            } else { status = "状态已更新：" + facts.location.explanation }
        }
    }
    func updateLocal(_ n: RuntimeNetwork) {
        network = n.context; facts = n.facts
        facts.location = CLLocationManager.locationServicesEnabled() ? .from(location.authorizationStatus) : .servicesOff
        networkName = DiagnosisBuilder.name(ssid: n.ssid, context: n.context, facts: facts)
        if facts.nameReadable || facts.location == .authorized {
            locationRequestPending = false
            locationMessage = ""
        }
    }
    func authorizeLocation() {
        guard !locationRequestPending else { return }
        guard CodeSigningTrust.hasLocationEntitlement() else {
            locationMessage = "当前安装包缺少签名中的定位声明，macOS 不会弹出授权。请更新 HotelWiFi；无需反复点击。"
            return
        }
        if LocationAccess.from(location.authorizationStatus) == .authorized && CLLocationManager.locationServicesEnabled() {
            locationMessage = ""
            Task { await refresh() }
        } else if location.authorizationStatus == .notDetermined && CLLocationManager.locationServicesEnabled() {
            NSApp.activate(ignoringOtherApps: true)
            locationMessage = "已向 macOS 请求权限，请在系统弹窗中允许读取网络名称。"
            locationRequestPending = true
            location.requestWhenInUseAuthorization()
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                locationRequestPending = false
                if location.authorizationStatus == .notDetermined {
                    locationMessage = "系统尚未返回授权结果。若没有弹窗，请打开定位权限设置；无需连续点击。"
                }
                await refresh()
            }
        } else {
            locationMessage = "已打开系统定位权限设置，请检查“定位服务”总开关及 HotelWiFi。"
            perform(.locationSettings)
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            locationRequestPending = false
            if LocationAccess.from(location.authorizationStatus) == .authorized {
                locationMessage = ""
            } else if location.authorizationStatus == .denied { locationMessage = "系统拒绝了定位权限，可在定位权限设置中重新允许。" }
            await refresh()
        }
    }
    func savePolicy() {
        do { policy.completedOnboarding = true; try settings?.savePolicy(policy) }
        catch { self.error = error.localizedDescription }
    }
    func optimize(dry: Bool = false) {
        guard !busy, !helperBusy, let engine else { return }
        if !policy.completedOnboarding { savePolicy(); if error != nil { return } }
        busy = true; report = nil; copyStatus = ""; liveStatusValid = false; completed = 0; total = 0
        status = "正在检查本机 WiFi、地址和权限"
        task = Task {
            defer { busy = false }
            do {
                try await engine.selectCandidate(candidates.first(where: { $0.id == candidateID }), approvePossibleCost: candidateCostApproved)
                report = try await engine.run(mode: dry ? .dryRun : .optimize, policy: policy, endpoints: settings?.endpoints() ?? ProbeEndpoint.defaults) { [weak self] p in
                    Task { @MainActor in self?.status = p.message; self?.completed = p.completed; self?.total = p.total }
                }
                liveStatusValid = report?.currentValidatedAt != nil
                status = report?.conclusion ?? "检查结束"; await refresh()
            } catch {
                let restoration = await engine.stop()
                self.error = error.localizedDescription
                var partial = localReport(); partial.interrupted = true
                partial.conclusion = "检查未完成"; partial.observations += [.init(error.localizedDescription), .init(restoration.message)]
                report = partial; status = "检查未完成，可复制已有诊断"; await refresh()
            }
        }
    }
    func stop() {
        Task { status = "正在停止并恢复原设置"; let r = await engine?.stop(); status = r?.message ?? "未创建网络事务"; liveStatusValid = false; await refresh() }
    }
    func localReport() -> SessionReport {
        var r = SessionReport(mode: "local-only"); r.current = network; r.localBefore = facts; r.localAfter = facts
        r.capabilities = capabilities; r.finished = Date(); r.conclusion = diagnosis.title; r.evidence = diagnosis.explanation
        r.observations = diagnosis.findings.map { .init($0.title + "：" + $0.detail) }; return r
    }
    var reportText: String {
        let state = busy ? "检查仍在进行；以下仅为已完成内容。" : liveStatusValid ? "测试完成时当前连接已验证。" : "当前连接尚未验证或此后已有网络变化；勿把旧结果视为当前正常。"
        var latest = report ?? localReport()
        latest.capabilities = capabilities; latest.localAfter = facts
        if let checked = capabilitiesCheckedAt {
            latest.observations.append(.init("本机权限和后台能力核对时间：" + checked.ISO8601Format() + "；请求结果保留各自的实际测量时间。"))
        }
        return ReportBuilder.supportText(latest, currentState: state)
    }
    func copyReport() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(reportText, forType: .string) { copyStatus = "已复制，可粘贴给 ChatGPT" }
        else { error = "剪贴板写入失败，请打开详情选择文本复制。" }
    }
    func perform(_ action: SupportAction) {
        switch action {
        case .networkSettings, .locationSettings, .portal:
            if let url = action.destinationURL { open(url.absoluteString) }
        case .locationPermission: authorizeLocation()
        case .refreshStatus: recheckStatus()
        case .repairHelper: repairHelper()
        case .recoverySettings: showSettings = true
        case .copy: copyReport()
        }
    }
    func open(_ address: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            error = "系统未能打开目标页面。可直接打开“系统设置”中的 WiFi 或“隐私与安全性 → 定位服务”。"
            return
        }
    }
    func repairHelper() {
        guard !busy, !helperBusy else { return }; helperBusy = true
        Task {
            defer { helperBusy = false }
            var registrationError: String?
            do {
                guard CodeSigningTrust.current() != nil else { throw HWError.blocked("此构建的项目签名无法验证，请重新安装签名版本。") }
                guard Bundle.main.bundleURL.path == "/Applications/HotelWiFi.app" else {
                    throw HWError.blocked("请将 HotelWiFi 安装到系统“应用程序”目录后再启用修复服务。当前 macOS 无法从用户目录可靠启动此后台服务。")
                }
                status = "正在核对并修复后台服务登记"
                let h = await engine?.recoveryStatus()
                if h?.ok == true {
                    status = "后台修复服务已就绪"; await refresh(); return
                }
                let service = HotelWiFiService.registration
                if service.status == .requiresApproval {
                    status = "请在系统设置批准 HotelWiFi 后台服务"; SMAppService.openSystemSettingsLoginItems()
                } else {
                    if service.status == .enabled {
                        // Only repair a job that launchd confirms could not spawn and has no running PID.
                        // Journals are preserved; the restarted guardian recovers them before accepting writes.
                        guard HelperDiagnostics.canRepairRegistration(HelperDiagnostics.launchState()) else {
                            throw HWError.blocked("服务失联且无法确认启动状态。已保留后台服务；请复制报告检查启动日志。")
                        }
                        try await service.unregister()
                    }
                    let registration = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
                    guard registration == noErr else { throw HWError.blocked("系统应用登记刷新失败（\(registration)），未宣称修复服务已就绪。") }
                    for attempt in 0..<3 {
                        do { try service.register(); break }
                        catch {
                            if service.status == .requiresApproval { break }
                            guard service.status == .notRegistered && attempt < 2 else { throw error }
                            // ServiceManagement can finish unregister before its registration database settles.
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                    if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    status = "已重新登记，正在确认后台服务是否真正响应"
                }
            } catch {
                registrationError = "\((error as NSError).domain)/\((error as NSError).code): \(error.localizedDescription)"
                self.error = error.localizedDescription
            }
            await refresh()
            let response = await engine?.recoveryStatus()
            struct Snapshot: Encodable { var at = Date(); var systemStatus: Int; var helperReady: Bool; var detail: String; var registrationError: String?; let guardianLabel = HotelWiFiService.jobIdentifier }
            let snapshot = Snapshot(systemStatus: HotelWiFiService.registration.status.rawValue, helperReady: response?.ok == true,
                detail: response?.message ?? "无响应", registrationError: registrationError)
            if let data = try? JSONCoding.encoder.encode(snapshot) { try? settings?.store.write(data, named: "helper-registration.json") }
            status = response?.ok == true ? "后台修复服务已就绪" : "后台服务仍未响应；问题原因已列在下方"
        }
    }
    func unregisterHelper() async {
        guard !busy, !helperBusy, let engine else { return }
        let result = await engine.stop()
        guard result.ok else { error = result.message; return }
        let response = await engine.recoveryStatus()
        var st = stat(); let absent = lstat("/Library/Application Support/HotelWiFi", &st) != 0 && errno == ENOENT
        guard (response.ok && response.record?.terminal != false && response.linkRecord?.terminal != false) || absent else {
            error = "尚未确认遗留事务已恢复，不能移除恢复服务。"; return
        }
        do { try await HotelWiFiService.registration.unregister(); status = "服务已注销；退出后可将应用移到废纸篓。" }
        catch { self.error = error.localizedDescription }
        await refresh()
    }
    /// Called by the updater before replacing this bundle. Unlike uninstall, a
    /// confirmed non-running daemon may be reinstalled with its journals intact.
    func prepareForUpdate() async {
        guard !busy, !helperBusy, let engine else { return }
        helperBusy = true; defer { helperBusy = false }
        do {
            let stopped = await engine.stop()
            guard stopped.ok else { throw HWError.blocked(stopped.message) }
            let response = await engine.recoveryStatus()
            let service = HotelWiFiService.registration
            let drained = response.ok && response.record?.terminal != false && response.linkRecord?.terminal != false
            let neverRunning = HelperDiagnostics.canRepairRegistration(HelperDiagnostics.launchState())
            guard drained || neverRunning || service.status == .notRegistered else {
                throw HWError.blocked("服务仍在运行或恢复状态不明，不能替换应用。")
            }
            if service.status != .notRegistered { try await service.unregister() }
            status = "已准备更新；恢复日志保留，新服务启动后优先处理"
            struct Ready: Encodable { let at = Date(); let ready = true; let journalsPreserved = true; let guardianLabel = HotelWiFiService.jobIdentifier }
            try settings?.store.write(JSONCoding.encoder.encode(Ready()), named: "update-ready.json")
            preparedForUpdate = true
            NSApplication.shared.terminate(nil)
        } catch { self.error = error.localizedDescription }
    }
    func scanCandidates() {
        guard !busy, !helperBusy, let engine else { return }; busy = true
        Task {
            defer { busy = false }
            do { candidates = try await engine.scanSavedCandidates(); candidateID = nil; candidateCostApproved = false }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let engine = model.engine else { return .terminateNow }
        if model.preparedForUpdate { return .terminateNow }
        model.status = "退出前正在清理临时配置"
        Task { let result = await engine.stop(); if !result.ok { model.error = result.message }; sender.reply(toApplicationShouldTerminate: result.ok) }
        return .terminateLater
    }
}
@main struct HotelWiFiApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("HotelWiFi", id: "main") {
            MainWindow(model: model).onAppear { delegate.model = model }.frame(minWidth: 650, minHeight: 640)
        }.defaultSize(width: 760, height: 820).commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("HotelWiFi", systemImage: "wifi.circle.fill") { MenuContent(model: model) }
        Settings { RepairSettings(model: model).padding(24).frame(width: 580, height: 650) }
    }
}
private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.status)
        Button("打开 HotelWiFi") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("一键检查并修复") { model.optimize() }.disabled(model.busy || model.helperBusy)
        Button("停止并恢复") { model.stop() }
        Button("复制测试报告") { model.copyReport() }
        Divider(); Button("退出 HotelWiFi") { NSApp.terminate(nil) }
    }
}
private let accent = Color(red: 0.06, green: 0.48, blue: 0.39)
private struct MainWindow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Label("HotelWiFi", systemImage: "wifi").font(.title2.bold())
                    Spacer(); Button("修复设置", systemImage: "slider.horizontal.3") { model.showSettings = true }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.networkName).font(.system(size: 27, weight: .semibold)).textSelection(.enabled)
                    HStack(spacing: 20) {
                        Text(model.network?.radio.rssi.map { "信号 \($0) dBm" } ?? "信号未读取")
                        Text(model.network?.radio.band ?? "频段未读取")
                        Text(model.network?.vpnPresent == true ? "保留 VPN 路径" : model.network?.proxy.any == true ? "保留系统代理" : "系统默认路径")
                    }.font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text(model.diagnosis.title).font(.title3.weight(.semibold))
                    Text(model.diagnosis.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                if !model.locationMessage.isEmpty && !model.facts.nameReadable && model.facts.location != .authorized {
                    HStack(alignment: .top) {
                        Text(model.locationMessage).font(.callout)
                        Spacer()
                        Button(SupportAction.locationSettings.title) { model.perform(.locationSettings) }
                    }.padding(14).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                if let report = model.report { results(report) }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("检查到了什么").font(.headline)
                        Spacer()
                        if let checked = model.capabilitiesCheckedAt {
                            Text("更新于 " + checked.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("刷新") { model.recheckStatus() }.disabled(model.checkingStatus)
                    }
                    ForEach(model.diagnosis.findings) { finding in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: finding.level == .good ? "checkmark.circle.fill" : finding.level == .failure ? "exclamationmark.circle.fill" : "info.circle")
                                .foregroundStyle(finding.level == .good ? accent : finding.level == .failure ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(finding.title).font(.callout.weight(.semibold))
                                Text(finding.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if let action = finding.action {
                                    HStack(spacing: 10) {
                                        Button(model.checkingStatus && action == .refreshStatus ? "正在检查…" : action.title) { model.perform(action) }
                                            .disabled((model.helperBusy && action == .repairHelper) || (model.checkingStatus && action == .refreshStatus))
                                        if let secondary = finding.secondaryAction { Button(secondary.title) { model.perform(secondary) } }
                                    }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }; Spacer(minLength: 0)
                        }
                    }
                }
                HStack {
                    Button("查看测试详情") { model.showDetails = true }
                    Spacer()
                    if !model.copyStatus.isEmpty { Text(model.copyStatus).font(.caption).foregroundStyle(accent) }
                }
                Text("断网时也能检查本机并执行已授权的修复。酒店密码、网页登录及酒店设备故障会说明下一步。测试报告只在本次会话保留。").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .tint(accent)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if model.busy || model.helperBusy || model.checkingStatus { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).lineLimit(2)
                    Spacer()
                    if model.busy && model.total > 0 { Text("\(model.completed)/\(model.total)").font(.caption.monospacedDigit()) }
                }
                HStack {
                    Button("复制测试报告", systemImage: "doc.on.doc") { model.copyReport() }
                    Spacer(); Button("停止并恢复") { model.stop() }
                    Button("一键检查并修复") { model.optimize() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.helperBusy).keyboardShortcut(.return, modifiers: .command)
                }
            }.padding(18).background(.bar)
        }
        .sheet(isPresented: $model.showSettings) { RepairSettings(model: model).padding(24).frame(width: 600, height: 680) }
        .sheet(isPresented: $model.showDetails) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("本次测试详情").font(.title2); Spacer(); Button("复制给 ChatGPT") { model.copyReport() }; Button("关闭") { model.showDetails = false } }
                ScrollView { Text(model.reportText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(24).frame(width: 740, height: 620)
        }
        .alert("HotelWiFi", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("复制诊断") { model.copyReport(); model.error = nil }; Button("关闭") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func results(_ r: SessionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("这次有什么变化").font(.headline); Spacer(); Text(model.liveStatusValid ? "最终请求已验证" : "当前状态待验证").font(.caption).foregroundStyle(model.liveStatusValid ? accent : .secondary) }
            Text(r.changes.isEmpty ? "未执行系统修改" : "实际操作：" + r.changes.map(ReportBuilder.operationName).joined(separator: "、")).font(.callout)
            ForEach(EndpointComparison.from(r)) { comparison in
                VStack(alignment: .leading, spacing: 4) {
                    Text(comparison.id).font(.caption.weight(.semibold))
                    Text("完整成功：\(comparison.before.successes)/\(comparison.before.count) → \(comparison.after.successes)/\(comparison.after.count)    加载中位数：\(ReportBuilder.milliseconds(comparison.before.median)) → \(ReportBuilder.milliseconds(comparison.after.median))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !r.restored.isEmpty { Text("已撤销：" + r.restored.map(ReportBuilder.operationName).joined(separator: "、")).font(.caption) }
            if !r.activeTemporary.isEmpty { Text("仍受恢复服务看护：" + r.activeTemporary.map(ReportBuilder.operationName).joined(separator: "、")).font(.caption) }
            Text(r.evidence).font(.caption).foregroundStyle(.secondary)
            if !r.windows.isEmpty { Text("前后按相同端点比较。少量样本的变快不直接算作修复收益。").font(.caption2).foregroundStyle(.secondary) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}
private struct RepairSettings: View {
    @ObservedObject var model: AppModel
    @State var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("修复设置").font(.title2); Spacer(); Button("完成") { model.savePolicy(); model.showSettings = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("授权保存在本机。之后一键执行，先确认故障，再修复并复测。").font(.callout).foregroundStyle(.secondary)
                    Toggle("允许验证有效的临时 DNS 修复", isOn: $model.policy.allowTemporaryDNS)
                    Toggle("允许单次请求比较 DNS 和直接连接", isOn: $model.policy.allowControlledDirect)
                    Toggle("持续断网时允许短暂重连", isOn: $model.policy.allowReconnect)
                    Toggle("地址异常时允许请求 DHCP 续租", isOn: linkBinding(\.allowDHCPRenew))
                    Toggle("允许低流量时短暂中断已有会话", isOn: linkBinding(\.allowIdleInterruption))
                    Text("即使开启，正在持续传输或连接健康时也不重连；WiFi 被手动关闭后不自动打开。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        let locationAction: SupportAction = model.facts.location == .notRequested ? .locationPermission : .locationSettings
                        Button(locationAction.title) { model.perform(locationAction) }
                        Button("修复后台服务") { model.repairHelper() }.disabled(model.helperBusy)
                    }
                    DisclosureGroup("更多选项", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("允许验证普通自动代理发现故障", isOn: $model.policy.allowAutomaticProxyExperiment)
                            Toggle("允许计费网络测试", isOn: $model.policy.allowMetered)
                            Toggle("允许比较其他已保存网络", isOn: $model.policy.allowSavedNetworks)
                            Button("扫描已保存候选") { model.scanCandidates() }.disabled(model.busy)
                            ForEach(model.candidates) { c in
                                Button((model.candidateID == c.id ? "✓ " : "") + c.name + (c.currentNetwork ? " · 当前网络" : " · 已保存")) { model.candidateID = c.id; model.candidateCostApproved = false }
                            }
                            if model.candidateID != nil { Toggle("确认所选网络用途，并允许本次可能计费的连接", isOn: $model.candidateCostApproved) }
                            Text("候选仅本次有效。macOS 未提供经验证的持续 AP 锁定能力，不以反复断网模拟锁定。").font(.caption).foregroundStyle(.secondary)
                            Button("只检查，不修改系统") { model.savePolicy(); model.showSettings = false; model.optimize(dry: true) }.disabled(model.busy)
                            Button("卸载前恢复并注销服务") { Task { await model.unregisterHelper() } }.disabled(model.busy)
                        }.padding(.top, 12)
                    }
                }.padding(.vertical, 8)
            }
        }.tint(accent)
    }
    private func linkBinding(_ key: WritableKeyPath<LinkRecoveryPolicy, Bool>) -> Binding<Bool> {
        Binding(get: { model.policy.linkRecovery?[keyPath: key] ?? false }, set: { value in
            var p = model.policy.linkRecovery ?? .init(); p[keyPath: key] = value; model.policy.linkRecovery = p
        })
    }
}
