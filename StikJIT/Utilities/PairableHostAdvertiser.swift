import Foundation
import Network

struct PairableHostMetadata: Equatable, Sendable {
    let port: UInt16
    let serviceIdentifier: String
    let name: String
    let model: String
    let authTag: String
    let version: String
    let minimumVersion: String
}

final class PairableHostAdvertiser {
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var activeRelay: RelayPipe?
    private var activeRelayID: UUID?
    private var rustLoopbackPort: UInt16 = 0
    private var stateGeneration = UUID()
    private let queue = DispatchQueue(label: "com.stik.stikdebug.pairable-relay")

    private var activeRelayState = false

    var hasActiveRelay: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRelayState
    }

    func start(
        metadata: PairableHostMetadata,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        stop()
        stateLock.lock()
        rustLoopbackPort = metadata.port
        stateGeneration = UUID()
        stateLock.unlock()

        var txtRecord = NWTXTRecord()
        txtRecord["name"] = metadata.name
        txtRecord["identifier"] = metadata.serviceIdentifier
        txtRecord["authTag"] = metadata.authTag
        txtRecord["model"] = metadata.model
        txtRecord["flags"] = "1"
        txtRecord["ver"] = metadata.version
        txtRecord["minVer"] = metadata.minimumVersion

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: metadata.serviceIdentifier,
                type: "_remotepairing-pairable-host._tcp",
                domain: "local",
                txtRecord: txtRecord
            )
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    onFailure(error.localizedDescription)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            stateLock.lock()
            self.listener = listener
            stateLock.unlock()
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    func stop() {
        stateLock.lock()
        let relay = activeRelay
        let currentListener = listener
        let portToWake = rustLoopbackPort
        activeRelay = nil
        activeRelayID = nil
        activeRelayState = false
        listener = nil
        stateGeneration = UUID()
        rustLoopbackPort = 0
        stateLock.unlock()

        relay?.cancel()
        currentListener?.cancel()
        wakeRustListener(on: portToWake)
    }

    private func accept(_ inbound: NWConnection) {
        stateLock.lock()
        let previousRelay = activeRelay
        let portValue = rustLoopbackPort
        let generationValue = stateGeneration
        activeRelay = nil
        activeRelayID = nil
        activeRelayState = false
        stateLock.unlock()
        previousRelay?.cancel()

        guard portValue > 0,
              let port = NWEndpoint.Port(rawValue: portValue) else {
            inbound.cancel()
            return
        }

        let outbound = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let relayID = UUID()
        let relay = RelayPipe(inbound: inbound, outbound: outbound) { [weak self] in
            self?.clearRelay(id: relayID)
        }
        stateLock.lock()
        guard stateGeneration == generationValue,
              rustLoopbackPort == portValue else {
            stateLock.unlock()
            relay.cancel()
            return
        }
        activeRelay = relay
        activeRelayID = relayID
        activeRelayState = true
        stateLock.unlock()
        relay.start()
    }

    private func wakeRustListener(on portValue: UInt16) {
        guard portValue > 0,
              let port = NWEndpoint.Port(rawValue: portValue) else { return }
        let wake = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        wake.stateUpdateHandler = { [weak wake] state in
            switch state {
            case .ready, .failed, .cancelled:
                wake?.cancel()
            default:
                break
            }
        }
        wake.start(queue: queue)
    }

    private func clearRelay(id: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRelayID == id else { return }
        activeRelay = nil
        activeRelayID = nil
        activeRelayState = false
    }
}

private final class RelayPipe {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue = DispatchQueue(label: "com.stik.stikdebug.pairable-pipe")
    private let onEnd: () -> Void
    private let stateLock = NSLock()
    private var ended = false

    init(inbound: NWConnection, outbound: NWConnection, onEnd: @escaping () -> Void) {
        self.inbound = inbound
        self.outbound = outbound
        self.onEnd = onEnd
    }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cancel()
            default:
                break
            }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else { return }
                self.pump(from: self.inbound, to: self.outbound)
                self.pump(from: self.outbound, to: self.inbound)
            case .failed, .cancelled:
                self?.cancel()
            default:
                break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    func cancel() {
        stateLock.lock()
        guard !ended else {
            stateLock.unlock()
            return
        }
        ended = true
        stateLock.unlock()
        inbound.cancel()
        outbound.cancel()
        onEnd()
    }

    private func pump(from source: NWConnection?, to destination: NWConnection?) {
        guard let source, let destination, !isEnded else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isEnded else { return }
            if error != nil || isComplete {
                self.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                self.pump(from: source, to: destination)
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.isEnded else { return }
                if error != nil {
                    self.cancel()
                } else {
                    self.pump(from: source, to: destination)
                }
            })
        }
    }

    private var isEnded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ended
    }
}
