import Testing
import idevice

struct PairableHostFFITests {
    @Test func bundledFFIExposesPairableHostEntryPoint() {
        let function: Any = pairable_host_accept
        #expect(String(describing: function).isEmpty == false)
    }
}
