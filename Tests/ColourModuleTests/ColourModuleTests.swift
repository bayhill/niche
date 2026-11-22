import NotchCore
import NotchCoreTesting
import Testing
@testable import ColourModule

@MainActor @Suite struct ColourModuleTests {
    @Test func isAPage() {
        let module = ColourModule.sample()
        #expect(module.id == .colour)
        #expect(module.placement == .page(order: 40))
    }
}
