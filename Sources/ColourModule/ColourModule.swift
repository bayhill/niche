import NotchCore
import Observation
import SwiftUI

/// Pick a colour anywhere on screen; copy it in the format needed.
/// Placeholder: the shape the app is wired against. The module's own work replaces the body, not the public surface.
@MainActor
@Observable
public final class ColourModule: NotchModule {
    public let id: ModuleID = .colour
    public let title = "Colour"
    public let symbol = "eyedropper"
    public let placement: PanelPlacement = .page(order: 40)

    public init() {}

    public static func live() -> ColourModule { ColourModule() }
    public static func sample() -> ColourModule { ColourModule() }

    public func start(_ context: ModuleContext) async { context.log.notice("started") }

    public func panelView() -> AnyView {
        AnyView(EmptyState(symbol: symbol, title: "Colour"))
    }
}
