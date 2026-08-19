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
    private var listener: NWListener?
    private var activeRelay: RelayPipe?
    private var activeRelayID: UUID?
    private var rustLoopbackPort: UInt16 = 0
    private let queue = DispatchQueue(label: "com.stik.stikdebug.pairable-relay")

    private(set) var hasActiveRelay = false

    func start(
        metadata: PairableHostMetadata,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        stop()
        rustLoopbackPort = metadata.port

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
            self.listener = listener
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    func stop() {
        activeRelay?.cancel()
        activeRelay = nil
        activeRelayID = nil
        hasActiveRelay = false
        listener?.cancel()
        listener = nil
        rustLoopbackPort = 0
    }

    private func accept(_ inbound: NWConnection) {
        activeRelay?.cancel()
        activeRelay = nil
        activeRelayID = nil
        hasActiveRelay = false

        guard rustLoopbackPort > 0,
              let port = NWEndpoint.Port(rawValue: rustLoopbackPort) else {
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
            guard let self, self.activeRelayID == relayID else { return }
            self.activeRelay = nil
            self.activeRelayID = nil
            self.hasActiveRelay = false
        }
        activeRelay = relay
        activeRelayID = relayID
        hasActiveRelay = true
        relay.start()
    }
}

private final class RelayPipe {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue = DispatchQueue(label: "com.stik.stikdebug.pairable-pipe")
    private let onEnd: () -> Void
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
        guard !ended else { return }
        ended = true
        inbound.cancel()
        outbound.cancel()
        onEnd()
    }

    private func pump(from source: NWConnection?, to destination: NWConnection?) {
        guard let source, let destination, !ended else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.ended else { return }
            if error != nil || isComplete {
                self.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                self.pump(from: source, to: destination)
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.ended else { return }
                if error != nil {
                    self.cancel()
                } else {
                    self.pump(from: source, to: destination)
                }
            })
        }
    }
}
