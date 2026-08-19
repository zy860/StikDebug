import Testing
@testable import StikDebug

struct PairOnDeviceServiceTests {
    @Test @MainActor func serviceDoesNotStartUntilRequested() {
        let service = PairOnDeviceService()

        #expect(service.phase == .idle)
        #expect(!service.phase.isBusy)
    }

    @Test @MainActor func stoppingServiceLeavesItIdle() {
        let service = PairOnDeviceService()

        service.stop()

        #expect(service.phase == .idle)
        #expect(!service.phase.isBusy)
    }
}
