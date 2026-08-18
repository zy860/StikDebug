//
//  PacketTunnelProvider.swift
//  StikDebugTunnel
//

import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelIfaceIP = StikDebugTunnelConfiguration.default.interfaceIP
    private var tunnelPeerIP = StikDebugTunnelConfiguration.default.peerIP
    private var packetLoopActive = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let providerConfiguration =
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let value = options?[StikDebugTunnelConfiguration.interfaceIPKey] as? String
            ?? providerConfiguration?[StikDebugTunnelConfiguration.interfaceIPKey] as? String
            ?? options?[StikDebugTunnelConfiguration.legacyInterfaceIPKey] as? String
            ?? providerConfiguration?[StikDebugTunnelConfiguration.legacyInterfaceIPKey] as? String {
            tunnelIfaceIP = value
        }
        if let value = options?[StikDebugTunnelConfiguration.peerIPKey] as? String
            ?? providerConfiguration?[StikDebugTunnelConfiguration.peerIPKey] as? String
            ?? options?[StikDebugTunnelConfiguration.legacyPeerIPKey] as? String
            ?? providerConfiguration?[StikDebugTunnelConfiguration.legacyPeerIPKey] as? String {
            tunnelPeerIP = value
        }

        let ifaceEndpoint = CIDREndpoint(tunnelIfaceIP, defaultPrefix: 32)
        let peerEndpoint = CIDREndpoint(tunnelPeerIP, defaultPrefix: 32)
        let ipv4Settings = NEIPv4Settings(
            addresses: [ifaceEndpoint.ip],
            subnetMasks: [ifaceEndpoint.subnetMask]
        )
        ipv4Settings.includedRoutes = [
            NEIPv4Route(
                destinationAddress: peerEndpoint.ip,
                subnetMask: peerEndpoint.subnetMask
            )
        ]
        ipv4Settings.excludedRoutes = [.default()]

        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: peerEndpoint.ip
        )
        settings.ipv4Settings = ipv4Settings

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }

            if let error {
                completionHandler(error)
                return
            }

            packetLoopActive = true
            setPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        packetLoopActive = false
        completionHandler()
    }

    private func setPackets() {
        guard packetLoopActive else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.packetLoopActive else { return }

            var modified = packets
            for index in modified.indices
                where index < protocols.count
                && protocols[index].int32Value == AF_INET
                && modified[index].count >= 20 {
                modified[index].withUnsafeMutableBytes { bytes in
                    guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else {
                        return
                    }

                    let source = pointer[3]
                    let destination = pointer[4]
                    pointer[3] = destination
                    pointer[4] = source
                }
            }

            self.packetFlow.writePackets(
                modified,
                withProtocols: protocols
            )
            self.setPackets()
        }
    }
}
