//
//  StikDebugTunnelConfiguration.swift
//  StikDebug
//

struct StikDebugTunnelConfiguration: Equatable {
    // Match LocalDevVPN's provider keys. The legacy keys are still accepted
    // by the packet provider so existing profiles can be upgraded in place.
    static let interfaceIPKey = "TunnelIfaceIP"
    static let peerIPKey = "TunnelPeerIP"
    static let legacyInterfaceIPKey = "interfaceIP"
    static let legacyPeerIPKey = "peerIP"

    static let `default` = StikDebugTunnelConfiguration(
        interfaceIP: "10.7.1.1/32",
        peerIP: "10.7.0.1/32"
    )

    let interfaceIP: String
    let peerIP: String
    let peerPrefixLength: Int

    init(interfaceIP: String, peerIP: String, peerPrefixLength: Int = 32) {
        self.interfaceIP = interfaceIP
        self.peerIP = peerIP
        self.peerPrefixLength = peerPrefixLength
    }

    var providerConfiguration: [String: String] {
        [
            Self.interfaceIPKey: interfaceIP,
            Self.peerIPKey: peerIP,
        ]
    }
}
