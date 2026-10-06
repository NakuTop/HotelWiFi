import Foundation
import AppKit
import ApplicationServices

// Explicit developer smoke check. Opens settings pages and presses status
// refresh buttons only; never changes a network or permission switch.
guard CommandLine.arguments.contains("--allow-open-settings") else {
    print("Usage: swift Scripts/verify-permission-ui.swift --allow-open-settings")
    exit(2)
}

enum SmokeError: Error { case failed(String) }
func require(_ value: Bool, _ message: String) throws { if !value { throw SmokeError.failed(message) } }
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func strings(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }
}
func elements(_ root: AXUIElement) -> [AXUIElement] {
    var queue = [root], result: [AXUIElement] = []
    while !queue.isEmpty && result.count < 1800 {
        let e = queue.removeFirst(); result.append(e)
        queue += attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return result
}
func waitUntil(_ message: String, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if condition() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    throw SmokeError.failed(message)
}
do {
try require(AXIsProcessTrusted(), "Accessibility is unavailable; no permission prompt was requested")
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hotelwifi.app").first else { throw SmokeError.failed("HotelWiFi is not running") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func windowElements() -> [AXUIElement] {
    (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).flatMap(elements)
}
func button(_ title: String) -> AXUIElement? {
    windowElements().first { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && strings($0).contains(title) }
}
func timestamp() -> String? { windowElements().flatMap(strings).first { $0.hasPrefix("更新于 ") } }
func hasText(_ text: String) -> Bool { windowElements().contains { strings($0).contains(where: { $0.contains(text) }) } }
try waitUntil("The fresh connection finding was not rendered") { hasText("名称已读取，自动重连暂不可用") }
try require(!hasText("重连所需的网络身份尚未确认"), "Old misleading finding is still visible")
guard let recheck = button("重新检查") else { throw SmokeError.failed("Recheck button not found") }
try require(attribute(recheck, kAXEnabledAttribute) as? Bool == true, "Recheck is disabled")
try require(AXUIElementPerformAction(recheck, kAXPressAction as CFString) == .success, "Recheck did not accept a press")
try waitUntil("Recheck did not finish with fresh capability feedback") { hasText("状态已更新：名称读取正常，自动重连仍暂不可用") && button("重新检查") != nil }
guard let before = timestamp(), let settings = button("打开 WiFi 设置") else { throw SmokeError.failed("Timestamp or settings button missing") }
try require(attribute(settings, kAXEnabledAttribute) as? Bool == true, "WiFi settings action is disabled")
try require(AXUIElementPerformAction(settings, kAXPressAction as CFString) == .success, "Settings button did not accept a press")
try waitUntil("Settings button did not open System Settings") { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" }
RunLoop.current.run(until: Date().addingTimeInterval(1.2))
app.activate(options: [])
try waitUntil("Returning to HotelWiFi did not refresh its capability timestamp") { timestamp().map { $0 != before } == true }
let beforeLocation = timestamp()
guard let repairSettings = button("修复设置") else { throw SmokeError.failed("Repair settings button missing") }
try require(AXUIElementPerformAction(repairSettings, kAXPressAction as CFString) == .success, "Could not open repair settings")
try waitUntil("Already-authorized app did not offer the actual settings action") { button("打开定位权限设置") != nil }
guard let locationSettings = button("打开定位权限设置") else { throw SmokeError.failed("Location settings button missing") }
try require(AXUIElementPerformAction(locationSettings, kAXPressAction as CFString) == .success, "Location settings press failed")
try waitUntil("Location button did not open System Settings") { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" }
guard let systemSettings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
    throw SmokeError.failed("System Settings not running")
}
let settingsAX = AXUIElementCreateApplication(systemSettings.processIdentifier)
try waitUntil("Location Services pane was not found") {
    let windows = attribute(settingsAX, kAXWindowsAttribute) as? [AXUIElement] ?? []
    return windows.flatMap(elements).flatMap(strings).contains { ["定位服务", "Location Services"].contains($0) }
}
RunLoop.current.run(until: Date().addingTimeInterval(1.2))
app.activate(options: [])
try waitUntil("App did not return to its repair settings sheet") { button("完成") != nil }
if let done = button("完成") { try require(AXUIElementPerformAction(done, kAXPressAction as CFString) == .success, "Could not close settings sheet") }
try waitUntil("Location settings round trip did not refresh status") { timestamp().map { $0 != beforeLocation } == true }
let build = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String } ?? "unknown"
let result: [String: Any] = ["build": build, "recheckButtonPressed": true, "freshFeedbackShown": true, "settingsButtonOpenedSystemSettings": true,
                            "foregroundReturnRefreshedStatus": true, "oldPermissionFindingAbsent": true,
                            "authorizedLocationSettingsButtonOpenedCorrectPane": true, "locationReturnRefreshedStatus": true,
                            "timestampBefore": before, "timestampAfter": timestamp() ?? "unknown", "networkOperationsRequested": false]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("UI smoke check failed: \(error)\n".utf8))
    exit(1)
}
