import Foundation
import Combine
import UIKit
import idevice

/// Runs the iOS 27 pairable-host handshake on the device itself.
///
/// This service only obtains the RPPairing file. It does not start or stop the
/// embedded VPN and it does not change the existing device transport.
@MainActor
final class PairOnDeviceService: ObservableObject {
    static let shared = PairOnDeviceService()

    @Published private(set) var phase: PairOnDevicePhase = .idle
    @Published private(set) var pin: String?
    @Published private(set) var debugPort: UInt16?

    private var worker: Thread?
    private var activeBox: PairCallbackBox?
    private var generation = UUID()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var keepAliveActive = false
    private let advertiser = PairableHostAdvertiser()

    var isBusy: Bool {
        phase.isBusy || worker?.isExecuting == true
    }

    func start() {
        guard !isBusy else { return }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            phase = .failed("On-device pairing requires iOS 27 or later.")
            return
        }

        let currentGeneration = UUID()
        generation = currentGeneration
        phase = .advertising
        pin = nil
        debugPort = nil
        beginKeepAlive()

        let directoryURL = PairingFileStore.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let outputURL = directoryURL.appendingPathComponent(
            "." + PairingFileStore.fileName + "." + UUID().uuidString + ".generated"
        )
        let box = PairCallbackBox(owner: self, generation: currentGeneration)
        activeBox = box

        let worker = Thread {
            autoreleasepool {
                Self.runBlockingAccept(outputURL: outputURL, box: box)
                try? FileManager.default.removeItem(at: outputURL)
                Task { @MainActor [weak self] in
                    self?.workerFinished(box)
                }
            }
        }
        worker.name = "stikdebug.pairable-host"
        worker.qualityOfService = .userInitiated
        self.worker = worker
        worker.start()
    }

    func stop() {
        generation = UUID()
        activeBox?.cancel()
        advertiser.stop()
        endKeepAlive()
        worker?.cancel()
        phase = .idle
        pin = nil
        debugPort = nil
    }

    func acknowledgeFailure() {
        guard case .failed = phase else { return }
        stop()
    }

    fileprivate func handleListening(
        generation: UUID,
        port: UInt16,
        serviceIdentifier: String,
        name: String,
        model: String,
        authTag: String,
        version: String,
        minimumVersion: String
    ) {
        guard generation == self.generation, phase.isBusy else { return }
        debugPort = port
        advertiser.start(
            metadata: PairableHostMetadata(
                port: port,
                serviceIdentifier: serviceIdentifier,
                name: name,
                model: model,
                authTag: authTag,
                version: version,
                minimumVersion: minimumVersion
            ),
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handleFailure(generation: generation, message: "Bonjour listener failed: \(message)")
                }
            }
        )
        phase = .advertising
    }

    fileprivate func handleConnected(generation: UUID) {
        guard generation == self.generation, phase.isBusy else { return }
        phase = .deviceConnected
    }

    fileprivate func handlePIN(generation: UUID, value: String) {
        guard generation == self.generation, phase.isBusy else { return }
        pin = value
        phase = .awaitingPIN(value)
    }

    fileprivate func handleSuccess(generation: UUID) {
        guard generation == self.generation else { return }
        advertiser.stop()
        endKeepAlive()
        pin = nil
        phase = .succeeded
    }

    fileprivate func handleFailure(generation: UUID, message: String) {
        guard generation == self.generation else { return }
        advertiser.stop()
        endKeepAlive()
        pin = nil
        phase = .failed(message)
    }

    private func workerFinished(_ box: PairCallbackBox) {
        guard activeBox === box else { return }
        activeBox = nil
        worker = nil
    }

    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true
        BackgroundAudioManager.shared.requestStart()
        BackgroundLocationManager.shared.requestStart()
        keepAliveActive = true

        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "stikdebug.pairable-host") { [weak self] in
            self?.endKeepAlive()
        }
    }

    private func endKeepAlive() {
        guard keepAliveActive || backgroundTask != .invalid else { return }
        keepAliveActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private nonisolated static func runBlockingAccept(
        outputURL: URL,
        box: PairCallbackBox
    ) {
        let name = "StikDebug"
        let model = "Mac17,7"
        var hostAltIRK = [UInt8](repeating: 0, count: 16)
        var pairingFile: RpPairingFileHandle?

        let ffiError: UnsafeMutablePointer<IdeviceFfiError>? = name.withCString { namePointer in
            model.withCString { modelPointer in
                pairable_host_accept(
                    namePointer,
                    modelPointer,
                    0,
                    pairOnDevicePINTrampoline,
                    Unmanaged.passUnretained(box).toOpaque(),
                    pairOnDeviceListeningTrampoline,
                    Unmanaged.passUnretained(box).toOpaque(),
                    pairOnDeviceConnectedTrampoline,
                    Unmanaged.passUnretained(box).toOpaque(),
                    &hostAltIRK,
                    &pairingFile
                )
            }
        }

        if let ffiError {
            let message = Self.ffiErrorMessage(ffiError)
            idevice_error_free(ffiError)
            guard !box.isCancelled else { return }
            Self.dispatchFailure(box, message: message)
            return
        }

        guard let pairingFile else {
            Self.dispatchFailure(box, message: "Pairing finished but no pairing file was returned.")
            return
        }
        defer { rp_pairing_file_free(pairingFile) }
        guard !box.isCancelled else { return }

        let writeError = outputURL.path.withCString { path in
            rp_pairing_file_write(pairingFile, path)
        }
        if let writeError {
            let message = Self.ffiErrorMessage(writeError)
            idevice_error_free(writeError)
            Self.dispatchFailure(box, message: "Paired, but failed to write the generated file: \(message)")
            return
        }

        guard !box.isCancelled else { return }
        do {
            try PairingFileStore.commitGeneratedPairingFile(sourceURL: outputURL)
        } catch {
            Self.dispatchFailure(box, message: "Paired, but failed to save the generated file: \(error.localizedDescription)")
            return
        }
        Self.dispatchSuccess(box)
    }

    private nonisolated static func ffiErrorMessage(
        _ error: UnsafeMutablePointer<IdeviceFfiError>
    ) -> String {
        if let message = error.pointee.message {
            return String(cString: message)
        }
        return "Unknown pairing error (\(error.pointee.code))."
    }

    private nonisolated static func dispatchFailure(
        _ box: PairCallbackBox,
        message: String
    ) {
        DispatchQueue.main.async {
            Task { @MainActor in
                box.owner?.handleFailure(generation: box.generation, message: message)
            }
        }
    }

    private nonisolated static func dispatchSuccess(_ box: PairCallbackBox) {
        DispatchQueue.main.async {
            Task { @MainActor in
                box.owner?.handleSuccess(generation: box.generation)
            }
        }
    }
}

private final class PairCallbackBox: @unchecked Sendable {
    private let stateLock = NSLock()
    weak var owner: PairOnDeviceService?
    let generation: UUID
    private var cancelled = false

    init(owner: PairOnDeviceService, generation: UUID) {
        self.owner = owner
        self.generation = generation
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
    }

    var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }
}

private func pairOnDevicePINTrampoline(
    pin: UnsafePointer<CChar>?,
    context: UnsafeMutableRawPointer?
) {
    guard let pin, let context else { return }
    let box = Unmanaged<PairCallbackBox>.fromOpaque(context).takeUnretainedValue()
    guard !box.isCancelled else { return }
    let value = String(cString: pin)
    DispatchQueue.main.async {
        Task { @MainActor in
            box.owner?.handlePIN(generation: box.generation, value: value)
        }
    }
}

private func pairOnDeviceListeningTrampoline(
    port: UInt16,
    serviceIdentifier: UnsafePointer<CChar>?,
    name: UnsafePointer<CChar>?,
    model: UnsafePointer<CChar>?,
    authTag: UnsafePointer<CChar>?,
    version: UnsafePointer<CChar>?,
    minimumVersion: UnsafePointer<CChar>?,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<PairCallbackBox>.fromOpaque(context).takeUnretainedValue()
    guard !box.isCancelled else { return }
    let values = (
        port,
        serviceIdentifier.map { String(cString: $0) } ?? "",
        name.map { String(cString: $0) } ?? "StikDebug",
        model.map { String(cString: $0) } ?? "Mac17,7",
        authTag.map { String(cString: $0) } ?? "",
        version.map { String(cString: $0) } ?? "27",
        minimumVersion.map { String(cString: $0) } ?? "17"
    )
    DispatchQueue.main.async {
        Task { @MainActor in
            box.owner?.handleListening(
                generation: box.generation,
                port: values.0,
                serviceIdentifier: values.1,
                name: values.2,
                model: values.3,
                authTag: values.4,
                version: values.5,
                minimumVersion: values.6
            )
        }
    }
}

private func pairOnDeviceConnectedTrampoline(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<PairCallbackBox>.fromOpaque(context).takeUnretainedValue()
    guard !box.isCancelled else { return }
    DispatchQueue.main.async {
        Task { @MainActor in
            box.owner?.handleConnected(generation: box.generation)
        }
    }
}
