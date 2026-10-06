import XCTest
import Darwin
@testable import HotelWiFiCore

final class ProcessRecoveryTests: XCTestCase {
    func testSIGKILLThenSeparateGuardianRestoresDurableSimulation() throws {
        var root = URL(fileURLWithPath:#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let binary = root.appendingPathComponent(".build/debug/HotelWiFiRecoveryHarness")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:binary.path),"Build HotelWiFiRecoveryHarness before running tests")
        let dir = URL(fileURLWithPath:"/private/tmp/HotelWiFiFault-" + UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let child = Process(); child.executableURL = binary; child.arguments = ["apply-and-wait",dir.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier,SIGKILL); child.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath:dir.appendingPathComponent("ready").path), Date() < deadline, child.isRunning { Thread.sleep(forTimeInterval:0.02) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("ready").path))
        kill(child.processIdentifier,SIGKILL); child.waitUntilExit(); XCTAssertEqual(child.terminationReason,.uncaughtSignal)
        let before = try TransactionJournal(store:SecureStore(directory:dir)).load(); XCTAssertEqual(before?.phase,.committed)
        let guardian = Process(); guardian.executableURL = binary; guardian.arguments = ["recover",dir.path]
        guardian.standardOutput = FileHandle.nullDevice; guardian.standardError = FileHandle.nullDevice
        try guardian.run(); guardian.waitUntilExit(); XCTAssertEqual(guardian.terminationStatus,0)
        let after = try TransactionJournal(store:SecureStore(directory:dir)).load()
        XCTAssertEqual(after?.phase,.restored); XCTAssertEqual(after?.configurationRestored,true)
        XCTAssertEqual(after?.applicationValidated,false); XCTAssertEqual(after?.connectionReestablished,false)
        let again = Process(); again.executableURL = binary; again.arguments = ["recover",dir.path]; again.standardOutput = FileHandle.nullDevice
        try again.run(); again.waitUntilExit(); XCTAssertEqual(again.terminationStatus,0)
    }
}
