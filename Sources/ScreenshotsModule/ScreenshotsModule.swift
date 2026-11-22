import NotchCore
import Observation
import SwiftUI

/// Recent screenshots, ready to drag out, convert or shelve.
/// Placeholder: the shape the app is wired against. The module's own work replaces the body, not the public surface.
@MainActor
@Observable
public final class ScreenshotsModule: NotchModule {
    public let id: ModuleID = .screenshots
    public let title = "Screenshots"
    public let symbol = "camera.viewfinder"
    public let placement: PanelPlacement = .page(order: 30)

    public init() {}

    public static func live() -> ScreenshotsModule { ScreenshotsModule() }
    public static func sample() -> ScreenshotsModule { ScreenshotsModule() }

    public func start(_ context: ModuleContext) async { context.log.notice("started") }

    public func panelView() -> AnyView {
        AnyView(EmptyState(symbol: symbol, title: "Screenshots"))
    }
}
