import NotchCore
import NotchCoreTesting
import Testing
@testable import DevServersModule

@MainActor @Suite struct DevServersModuleTests {
    @Test func isAPage() {
        let module = DevServersModule.sample()
        #expect(module.id == .devServers)
        #expect(module.placement == .page(order: 50))
    }
}
