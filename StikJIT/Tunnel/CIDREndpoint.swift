//
//  CIDREndpoint.swift
//  StikDebug
//
//  Based on the CIDR endpoint implementation from LocalDevVPN / StosVPN.
//  Original project: https://github.com/jkcoxson/LocalDevVPN
//  Copyright (c) 2025 SideStore Team.
//  The original permissive license and attribution are retained here.
//

import Foundation

struct CIDREndpoint: Equatable {
    let raw: String
    let ip: String
    let prefix: Int
    let subnetMask: String

    var formattedCIDR: String {
        "\(ip)/\(prefix)"
    }

    init(_ input: String, defaultPrefix: Int = 32) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = trimmed

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let ipPart = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
        ip = ipPart.isEmpty ? "0.0.0.0" : ipPart

        if parts.count == 2,
           let parsedPrefix = Int(parts[1].trimmingCharacters(in: .whitespaces)),
           (0...32).contains(parsedPrefix) {
            prefix = parsedPrefix
        } else {
            prefix = defaultPrefix
        }

        subnetMask = Self.prefixToSubnetMask(prefix)
    }

    static func prefixToMaskRaw(_ prefix: Int) -> UInt32 {
        guard prefix > 0 else { return 0 }
        guard prefix < 32 else { return 0xFFFFFFFF }
        return ~((1 << (32 - prefix)) - 1)
    }

    static func prefixToSubnetMask(_ prefix: Int) -> String {
        guard (0...32).contains(prefix) else {
            return "255.255.255.255"
        }

        let mask = prefixToMaskRaw(prefix)
        let b1 = (mask >> 24) & 0xFF
        let b2 = (mask >> 16) & 0xFF
        let b3 = (mask >> 8) & 0xFF
        let b4 = mask & 0xFF
        return "\(b1).\(b2).\(b3).\(b4)"
    }
}
