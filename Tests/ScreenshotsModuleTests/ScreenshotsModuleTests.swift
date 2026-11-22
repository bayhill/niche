import NotchCore
import NotchCoreTesting
import Testing
@testable import ScreenshotsModule

@MainActor @Suite struct ScreenshotsModuleTests {
    @Test func isAPage() {
        let module = ScreenshotsModule.sample()
        #expect(module.id == .screenshots)
        #expect(module.placement == .page(order: 30))
    }
}
