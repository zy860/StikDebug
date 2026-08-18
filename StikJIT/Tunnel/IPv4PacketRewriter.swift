//
//  IPv4PacketRewriter.swift
//  StikDebug
//

import Darwin
import Foundation

enum IPv4PacketRewriter {
    static func rewritePackets(
        _ packets: [Data],
        protocols: [NSNumber]
    ) -> [Data] {
        var rewrittenPackets = packets

        for index in rewrittenPackets.indices {
            guard index < protocols.count,
                  protocols[index].int32Value == AF_INET else {
                continue
            }

            var bytes = [UInt8](rewrittenPackets[index])
            guard isIPv4Packet(bytes) else {
                continue
            }

            swapEndpoints(in: &bytes)
            rewrittenPackets[index] = Data(bytes)
        }

        return rewrittenPackets
    }

    static func isIPv4Packet(_ packet: [UInt8]) -> Bool {
        packet.count >= 20 && packet[0] >> 4 == 4
    }

    static func swapEndpoints(in packet: inout [UInt8]) {
        guard isIPv4Packet(packet) else {
            return
        }

        for offset in 0..<4 {
            packet.swapAt(12 + offset, 16 + offset)
        }
    }
}
