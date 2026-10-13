import Foundation
import Testing
@testable import Alwm

@Suite("IPC socket ownership")
struct IPCServerOwnershipTests {
    @Test("stopping a former owner leaves the replacement socket intact")
    func stoppedServerDoesNotUnlinkReplacement() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-ipc-\(UUID().uuidString).sock").path
        let owner = IPCServer()
        try owner.start(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(FileManager.default.fileExists(atPath: path))
        owner.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        try Data().write(to: URL(fileURLWithPath: path))
        owner.stop()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("a second server cannot replace a live owner's socket")
    func secondServerCannotStealLiveSocket() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-ipc-\(UUID().uuidString).sock").path
        let owner = IPCServer()
        try owner.start(path: path)
        defer { owner.stop() }
        let second = IPCServer()
        #expect(throws: POSIXError.self) { try second.start(path: path) }
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
