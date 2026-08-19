import Testing
import idevice

struct PairableHostFFITests {
    @Test func bundledFFIExposesPairableHostEntryPoint() {
        let function: Any = pairable_host_accept
        #expect(String(describing: function).isEmpty == false)
    }

    @Test func bundledFFIExposesLegacySyslogEntryPoints() {
        let connect: Any = syslog_relay_connect_rsd
        let next: Any = syslog_relay_next

        #expect(String(describing: connect).isEmpty == false)
        #expect(String(describing: next).isEmpty == false)
    }
}
