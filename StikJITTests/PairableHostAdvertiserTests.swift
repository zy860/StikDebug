import Testing
@testable import StikDebug

struct PairableHostAdvertiserTests {
    @Test func metadataPreservesFFIValues() {
        let metadata = PairableHostMetadata(
            port: 49153,
            serviceIdentifier: "ABCDEF",
            name: "StikDebug",
            model: "Mac17,7",
            authTag: "tag",
            version: "27",
            minimumVersion: "17"
        )

        #expect(metadata.port == 49153)
        #expect(metadata.serviceIdentifier == "ABCDEF")
        #expect(metadata.name == "StikDebug")
        #expect(metadata.model == "Mac17,7")
        #expect(metadata.authTag == "tag")
        #expect(metadata.version == "27")
        #expect(metadata.minimumVersion == "17")
    }

    @Test func advertiserStartsWithoutAnActiveRelay() {
        let advertiser = PairableHostAdvertiser()
        #expect(!advertiser.hasActiveRelay)

        advertiser.stop()

        #expect(!advertiser.hasActiveRelay)
    }
}
