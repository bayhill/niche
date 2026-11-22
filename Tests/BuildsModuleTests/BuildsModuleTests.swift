import NotchCore
import NotchCoreTesting
import Testing
@testable import BuildsModule

@MainActor @Suite struct BuildsModuleTests {
    @Test func isAPage() {
        let module = BuildsModule.sample()
        #expect(module.id == .builds)
        #expect(module.placement == .page(order: 60))
    }
}
