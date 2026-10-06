import XCTest
import AppKit
@testable import HotelWiFiCore

final class SettingsActionTests: XCTestCase {
    @MainActor func testSettingsButtonsResolveToTheNativeSystemSettingsApplication() throws {
        for action in [SupportAction.locationSettings, .networkSettings] {
            let url = try XCTUnwrap(action.destinationURL)
            let app = try XCTUnwrap(NSWorkspace.shared.urlForApplication(toOpen: url))
            XCTAssertEqual(Bundle(url: app)?.bundleIdentifier, "com.apple.systempreferences")
        }
        XCTAssertNil(SupportAction.locationPermission.destinationURL)
        XCTAssertNil(SupportAction.refreshStatus.destinationURL)
        XCTAssertEqual(SupportAction.locationSettings.title, "打开定位权限设置")
        XCTAssertEqual(SupportAction.refreshStatus.title, "重新检查")
    }
}
