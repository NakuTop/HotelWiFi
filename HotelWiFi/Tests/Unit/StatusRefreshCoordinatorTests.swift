import XCTest
@testable import HotelWiFiCore

final class StatusRefreshCoordinatorTests: XCTestCase {
    @MainActor func testAuthorizationChangeDuringReadIsAppliedBeforeEitherCallerReturns() async {
        let coordinator = StatusRefreshCoordinator()
        let firstReading = expectation(description: "initial read pending")
        let secondRequestStarted = expectation(description: "authorization change refresh requested")
        let secondReading = expectation(description: "fresh read pending")
        var firstRelease: CheckedContinuation<Void, Never>?
        var secondRelease: CheckedContinuation<Void, Never>?
        var reads = 0, activeReads = 0, maximumActive = 0
        var granted = false, displayed = false, firstFinished = false, secondFinished = false
        let read: @MainActor () async -> Void = {
            reads += 1; activeReads += 1; maximumActive = max(maximumActive, activeReads)
            let snapshot = granted
            if reads == 1 {
                await withCheckedContinuation { firstRelease = $0; firstReading.fulfill() }
            } else {
                await withCheckedContinuation { secondRelease = $0; secondReading.fulfill() }
            }
            displayed = snapshot; activeReads -= 1
        }
        let first = Task { await coordinator.refresh(read); firstFinished = true }
        await fulfillment(of: [firstReading], timeout: 2)
        granted = true
        let second = Task { secondRequestStarted.fulfill(); await coordinator.refresh(read); secondFinished = true }
        await fulfillment(of: [secondRequestStarted], timeout: 2)
        firstRelease?.resume()
        await fulfillment(of: [secondReading], timeout: 2)
        XCTAssertFalse(firstFinished); XCTAssertFalse(secondFinished)
        XCTAssertFalse(displayed, "Old snapshot is still pending replacement")
        secondRelease?.resume()
        await first.value; await second.value
        XCTAssertTrue(displayed); XCTAssertTrue(firstFinished); XCTAssertTrue(secondFinished)
        XCTAssertEqual(reads, 2); XCTAssertEqual(maximumActive, 1); XCTAssertFalse(coordinator.running)
    }
    @MainActor func testLaterForegroundActivationPerformsAnotherRead() async {
        let coordinator = StatusRefreshCoordinator(); var reads = 0
        await coordinator.refresh { reads += 1 }
        await coordinator.refresh { reads += 1 }
        XCTAssertEqual(reads, 2); XCTAssertFalse(coordinator.running)
    }
}
