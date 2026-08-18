//
//  StikJITTests.swift
//  StikJITTests
//
//  Created by Stephen on 3/26/25.
//

import Foundation
import Darwin
import Testing
@testable import StikDebug

struct StikJITTests {

    @Test func transportEndpointUsesRPPairingPort() throws {
        let endpoint = try RPPairingEndpoint(ip: "10.7.0.1")

        #expect(endpoint.port == 49152)
        #expect(endpoint.ip == "10.7.0.1")
    }

    @Test func transportEndpointRejectsMalformedIPv4() {
        #expect(throws: DeviceTransportError.self) {
            try RPPairingEndpoint(ip: "not-an-ip")
        }
    }

    @Test func transportErrorsDoNotReportWiFiAsTheRootCause() {
        let message = DeviceTransportError.vpnUnavailable("permission denied").errorDescription ?? ""

        #expect(!message.localizedCaseInsensitiveContains("wifi"))
        #expect(message.localizedCaseInsensitiveContains("vpn"))
    }

    @Test func rppairingRecoveryRetriesOnlyTransientPeerResets() {
        #expect(RPPairingRecoveryPolicy.shouldRetry("Connection reset by peer"))
        #expect(RPPairingRecoveryPolicy.shouldRetry("os error 54"))
        #expect(!RPPairingRecoveryPolicy.shouldRetry("Connection refused (os error 61)"))
        #expect(!RPPairingRecoveryPolicy.shouldRetry("PairVerifyFailed"))
    }

    @Test func rppairingRecoveryMessageIdentifiesHandshakeBoundary() {
        let message = RPPairingRecoveryPolicy.failureSuffix(
            for: "Socket(Os { code: 54, kind: ConnectionReset, message: \"Connection reset by peer\" })"
        )

        #expect(message.localizedCaseInsensitiveContains("handshake"))
        #expect(message.localizedCaseInsensitiveContains("VPN route reached the device"))
        #expect(message.localizedCaseInsensitiveContains("pairing file"))
    }

    @Test func locationSimulationClassifiesTransportFailuresSeparately() {
        #expect(LocationSimulationStatus.code(for: .vpnUnavailable("permission denied")) == 3)
        #expect(LocationSimulationStatus.code(for: .ffiFailure("connection refused")) == 13)
        #expect(LocationSimulationStatus.code(for: .incompleteTunnel) == 14)
    }

    @Test func vpnStartErrorPreservesUnderlyingMessage() {
        let message = StikDebugVPNError.startFailed("permission denied").errorDescription ?? ""

        #expect(message.localizedCaseInsensitiveContains("permission denied"))
    }

    @Test func vpnStatusMappingRecognizesConnectedAndReasserting() {
        #expect(StikDebugVPNStatus(neStatus: .connected) == .connected)
        #expect(StikDebugVPNStatus(neStatus: .reasserting) == .connecting)
        #expect(StikDebugVPNStatus(neStatus: .disconnected) == .disconnected)
    }

    @Test func vpnManagerConfigurationUsesEmbeddedExtension() {
        let configuration = StikDebugVPNManager.makeProviderConfiguration(
            for: .default
        )

        #expect(configuration[StikDebugTunnelConfiguration.interfaceIPKey] == "10.7.1.1/32")
        #expect(configuration[StikDebugTunnelConfiguration.peerIPKey] == "10.7.0.1/32")
        #expect(StikDebugVPNManager.providerBundleIdentifier == "com.stik.stikdebug.tunnel")
    }

    @Test func embeddedTunnelDefaultsMatchLocalDevVPNEndpoint() {
        let configuration = StikDebugTunnelConfiguration.default

        #expect(configuration.interfaceIP == "10.7.1.1/32")
        #expect(configuration.peerIP == "10.7.0.1/32")
        #expect(configuration.peerPrefixLength == 32)
        #expect(configuration.providerConfiguration["TunnelIfaceIP"] == "10.7.1.1/32")
        #expect(configuration.providerConfiguration["TunnelPeerIP"] == "10.7.0.1/32")
    }

    @Test func localDevVPNCoreParsesCIDREndpoints() {
        let interfaceEndpoint = CIDREndpoint("10.7.1.1/32", defaultPrefix: 24)
        let peerEndpoint = CIDREndpoint("10.7.0.1/32", defaultPrefix: 24)

        #expect(interfaceEndpoint.ip == "10.7.1.1")
        #expect(interfaceEndpoint.prefix == 32)
        #expect(interfaceEndpoint.subnetMask == "255.255.255.255")
        #expect(peerEndpoint.ip == "10.7.0.1")
        #expect(peerEndpoint.prefix == 32)
        #expect(peerEndpoint.subnetMask == "255.255.255.255")
    }

    @Test func ipv4PacketRewriterSwapsPacketEndpoints() {
        var packet = [UInt8](repeating: 0, count: 20)
        packet[0] = 0x45
        packet.replaceSubrange(12..<16, with: [10, 7, 0, 2])
        packet.replaceSubrange(16..<20, with: [10, 7, 0, 1])

        IPv4PacketRewriter.swapEndpoints(in: &packet)

        #expect(Array(packet[12..<16]) == [10, 7, 0, 1])
        #expect(Array(packet[16..<20]) == [10, 7, 0, 2])
    }

    @Test func ipv4PacketRewriterRecognizesOnlyCompleteIPv4Packets() {
        #expect(IPv4PacketRewriter.isIPv4Packet([UInt8(0x45)] + [UInt8](repeating: 0, count: 19)))
        #expect(!IPv4PacketRewriter.isIPv4Packet([UInt8(0x60)] + [UInt8](repeating: 0, count: 19)))
        #expect(!IPv4PacketRewriter.isIPv4Packet([UInt8(0x45)] + [UInt8](repeating: 0, count: 18)))
    }

    @Test func ipv4PacketRewriterLeavesShortPacketsUnchanged() {
        var packet = [UInt8](repeating: 0, count: 19)
        let original = packet

        IPv4PacketRewriter.swapEndpoints(in: &packet)

        #expect(packet == original)
    }

    @Test func ipv4PacketRewriterPreservesAllPacketsAndProtocols() {
        var ipv4Packet = [UInt8](repeating: 0, count: 20)
        ipv4Packet[0] = 0x45
        ipv4Packet.replaceSubrange(12..<16, with: [10, 7, 0, 2])
        ipv4Packet.replaceSubrange(16..<20, with: [10, 7, 0, 1])

        let nonIPv4Packet = Data([0x60] + [UInt8](repeating: 0, count: 19))
        let shortPacket = Data([0x45] + [UInt8](repeating: 0, count: 18))
        let packets = [Data(ipv4Packet), nonIPv4Packet, shortPacket]
        let protocols = [NSNumber(value: AF_INET), NSNumber(value: 999), NSNumber(value: AF_INET)]

        let rewritten = IPv4PacketRewriter.rewritePackets(packets, protocols: protocols)

        #expect(rewritten.count == packets.count)
        #expect(rewritten[0] != packets[0])
        #expect(rewritten[1] == nonIPv4Packet)
        #expect(rewritten[2] == shortPacket)
    }

    @Test func txmDetectionIgnoresFirmwareFileBeforeIOS26() async throws {
        let isSupported = ProcessInfo.hasTXMSupport(
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 7, patchVersion: 2),
            localTXMDetector: { true }
        )

        #expect(isSupported == false)
    }

    @Test func txmDetectionRequiresLocalTXMOnIOS26() async throws {
        let iOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

        #expect(ProcessInfo.hasTXMSupport(operatingSystemVersion: iOS26, localTXMDetector: { false }) == false)
        #expect(ProcessInfo.hasTXMSupport(operatingSystemVersion: iOS26, localTXMDetector: { true }) == true)
    }

}
