import Foundation
import Testing
@testable import StikDebug

struct PairOnDeviceStateTests {
    @Test func onlyActivePairingPhasesAreBusy() {
        #expect(!PairOnDevicePhase.idle.isBusy)
        #expect(PairOnDevicePhase.advertising.isBusy)
        #expect(PairOnDevicePhase.deviceConnected.isBusy)
        #expect(PairOnDevicePhase.awaitingPIN("123456").isBusy)
        #expect(!PairOnDevicePhase.succeeded.isBusy)
        #expect(!PairOnDevicePhase.failed("failed").isBusy)
    }

    @Test func validGeneratedPairingFileReplacesExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent(PairingFileStore.fileName)
        let generated = directory.appendingPathComponent("generated.plist")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: generated)

        try PairingFileStore.commitGeneratedPairingFile(
            sourceURL: generated,
            destinationURL: destination,
            validator: { _ in }
        )

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test func invalidGeneratedPairingFileDoesNotReplaceExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent(PairingFileStore.fileName)
        let generated = directory.appendingPathComponent("generated.plist")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: generated)

        #expect(throws: PairingFileStoreError.self) {
            try PairingFileStore.commitGeneratedPairingFile(
                sourceURL: generated,
                destinationURL: destination,
                validator: { _ in throw PairingFileStoreError.validationFailed }
            )
        }

        #expect(try Data(contentsOf: destination) == Data("old".utf8))
    }
}
