import NotchCore
import Observation
import SwiftUI

/// The latest GitHub Actions runs for chosen repositories, through the user's own `gh` login.
/// Placeholder: the shape the app is wired against. The module's own work replaces the body, not the public surface.
@MainActor
@Observable
public final class BuildsModule: NotchModule {
    public let id: ModuleID = .builds
    public let title = "Builds"
    public let symbol = "hammer"
    public let placement: PanelPlacement = .page(order: 60)

    public init() {}

    public static func live() -> BuildsModule { BuildsModule() }
    public static func sample() -> BuildsModule { BuildsModule() }

    public func start(_ context: ModuleContext) async { context.log.notice("started") }

    public func panelView() -> AnyView {
        AnyView(EmptyState(symbol: symbol, title: "Builds"))
    }
}
