//
//  DeviceTransport.swift
//  StikDebug
//

import Darwin
import Foundation
import idevice

struct RPPairingEndpoint {
    static let port: UInt16 = 49152

    let ip: String
    let port: UInt16

    init(ip: String) throws {
        var address = in_addr()
        let result = ip.withCString { pointer in
            inet_pton(AF_INET, pointer, &address)
        }
        guard result == 1 else {
            throw DeviceTransportError.invalidIPAddress(ip)
        }

        self.ip = ip
        self.port = Self.port
    }

    var sockaddr: sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = ip.withCString { pointer in
            inet_pton(AF_INET, pointer, &address.sin_addr)
        }
        return address
    }
}

enum RPPairingRecoveryPolicy {
    static let maximumAttempts = 2
    static let retryDelay: TimeInterval = 0.35

    static func shouldRetry(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("connection reset by peer")
            || normalized.contains("os error 54")
            || normalized.contains("code: 54")
    }

    static func failureSuffix(
        for message: String,
        recoveryRetried: Bool = false
    ) -> String {
        if shouldRetry(message) || recoveryRetried {
            return " The embedded VPN route reached the device, but the device reset the RPPairing handshake. A recovery retry was attempted; if this persists, refresh the RPPairing pairing file and confirm the device is unlocked and trusted."
        }

        return " The pairing file was read successfully; make sure the embedded VPN is connected and the target device tunnel is listening."
    }
}

struct RPPairingTunnel {
    var adapter: OpaquePointer?
    var handshake: OpaquePointer?

    init(adapter: OpaquePointer? = nil, handshake: OpaquePointer? = nil) {
        self.adapter = adapter
        self.handshake = handshake
    }

    mutating func free() {
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
}

enum DeviceTransportError: LocalizedError, Equatable {
    case invalidIPAddress(String)
    case pairingFileMissing(String)
    case pairingFileReadFailed(String)
    case vpnUnavailable(String)
    case ffiFailure(String)
    case incompleteTunnel

    var errorDescription: String? {
        switch self {
        case .invalidIPAddress(let ip):
            return "Invalid RPPairing IPv4 address: \(ip)"
        case .pairingFileMissing(let path):
            return "Pairing file not found at \(path)"
        case .pairingFileReadFailed(let message):
            return "Failed to read the RPPairing file: \(message)"
        case .vpnUnavailable(let message):
            return "Embedded VPN unavailable: \(message)"
        case .ffiFailure(let message):
            return "RPPairing tunnel creation failed: \(message)"
        case .incompleteTunnel:
            return "RPPairing returned incomplete tunnel handles for \(DeviceConnectionContext.targetIPAddress):\(RPPairingEndpoint.port). The pairing file was read successfully; make sure the embedded VPN is connected."
        }
    }
}

protocol DeviceTransport {
    func ensureReady() throws
    func makeRPPairingTunnel(
        hostname: String,
        targetIPAddress: String,
        pairingFileURL: URL
    ) throws -> RPPairingTunnel
}

final class EmbeddedDeviceTransport: DeviceTransport {
    static let shared = EmbeddedDeviceTransport()

    private init() {}

    func ensureReady() throws {
        do {
            try StikDebugVPNManager.shared.ensureReady()
        } catch let error as StikDebugVPNError {
            throw DeviceTransportError.vpnUnavailable(error.localizedDescription)
        } catch {
            throw DeviceTransportError.vpnUnavailable(error.localizedDescription)
        }
    }

    func makeRPPairingTunnel(
        hostname: String,
        targetIPAddress: String,
        pairingFileURL: URL
    ) throws -> RPPairingTunnel {
        try ensureReady()

        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw DeviceTransportError.pairingFileMissing(pairingFileURL.path)
        }

        let endpoint = try RPPairingEndpoint(ip: targetIPAddress)

        var recoveryRetried = false
        for attempt in 0 ..< RPPairingRecoveryPolicy.maximumAttempts {
            var pairingFile: OpaquePointer?
            let pairingError = pairingFileURL.path.withCString { path in
                rp_pairing_file_read(path, &pairingFile)
            }
            if let pairingError {
                if let pairingFile {
                    rp_pairing_file_free(pairingFile)
                }
                throw DeviceTransportError.pairingFileReadFailed(
                    consumeFFIError(pairingError, fallback: "unknown pairing-file error")
                )
            }

            guard let pairingFile else {
                throw DeviceTransportError.pairingFileReadFailed("empty pairing handle")
            }

            var address = endpoint.sockaddr
            var tunnel = RPPairingTunnel()
            let ffiError = hostname.withCString { hostnamePointer in
                withUnsafePointer(to: &address) { addressPointer in
                    addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hostnamePointer,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
                    }
                }
            }

            if let ffiError {
                let message = consumeFFIError(ffiError, fallback: "unknown RPPairing error")
                tunnel.free()
                rp_pairing_file_free(pairingFile)

                if attempt + 1 < RPPairingRecoveryPolicy.maximumAttempts,
                   RPPairingRecoveryPolicy.shouldRetry(message) {
                    recoveryRetried = true
                    Thread.sleep(forTimeInterval: RPPairingRecoveryPolicy.retryDelay)
                    continue
                }

                throw DeviceTransportError.ffiFailure(
                    "\(message) [target \(endpoint.ip):\(endpoint.port)]."
                        + RPPairingRecoveryPolicy.failureSuffix(
                            for: message,
                            recoveryRetried: recoveryRetried
                        )
                )
            }

            guard tunnel.adapter != nil, tunnel.handshake != nil else {
                tunnel.free()
                rp_pairing_file_free(pairingFile)
                throw DeviceTransportError.incompleteTunnel
            }

            rp_pairing_file_free(pairingFile)
            return tunnel
        }

        throw DeviceTransportError.ffiFailure(
            "RPPairing recovery exhausted [target \(endpoint.ip):\(endpoint.port)]."
                + RPPairingRecoveryPolicy.failureSuffix(
                    for: "Connection reset by peer",
                    recoveryRetried: recoveryRetried
                )
        )
    }

    private func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>,
        fallback: String
    ) -> String {
        let message = String(validatingUTF8: ffiError.pointee.message) ?? fallback
        idevice_error_free(ffiError)
        return message
    }
}
