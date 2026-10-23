import XCTest
@testable import HotelWiFiCore

final class RadioSurveyTests: XCTestCase {
    func testWeakFiveGHzDoesNotBeatStrongTwoGHzByBandAlone() {
        let strong = AccessPointReading(current: true, rssi: -45, noise: -92, channel: 6, band: "2.4 GHz")
        let weak = AccessPointReading(current: false, rssi: -82, noise: -92, channel: 36, band: "5 GHz")
        XCTAssertGreaterThan(strong.score!, weak.score!)
        let survey = RadioSurvey(points: [strong, weak], detail: "test")
        XCTAssertTrue(survey.recommendation.contains("未发现明显更优"))
    }
    func testStrongUncrowdedCandidateIsRecommendedWithoutClaimingSwitch() {
        let current = AccessPointReading(current: true, rssi: -72, noise: -85, channel: 6, band: "2.4 GHz", neighbors: 7)
        let candidate = AccessPointReading(current: false, rssi: -52, noise: -94, channel: 36, band: "5 GHz", neighbors: 1)
        let survey = RadioSurvey(points: [current, candidate], detail: "test")
        XCTAssertEqual(survey.ranked.first?.id, candidate.id)
        XCTAssertTrue(survey.recommendation.contains("切换后的复测"))
        XCTAssertFalse(survey.recommendation.contains("已切换"))
    }
    func testUnknownSignalCannotBecomeWinningMeasuredCandidate() {
        let unknown = AccessPointReading(current: false, rssi: nil, noise: nil, channel: 36, band: "5 GHz")
        let current = AccessPointReading(current: true, rssi: -65, noise: -90, channel: 1, band: "2.4 GHz")
        XCTAssertNil(unknown.score)
        XCTAssertEqual(RadioSurvey(points: [unknown, current], detail: "test").ranked.first?.id, current.id)
    }
    func testSurveyExportsNoNetworkNameOrHardwareAddress() throws {
        let survey = RadioSurvey(points: [.init(current: true, rssi: -50, noise: -90, channel: 6, band: "2.4 GHz")], detail: "test")
        let text = String(decoding: try JSONCoding.encoder.encode(survey), as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("ssid")); XCTAssertFalse(text.contains("macaddress"))
    }
}
