import NotchCore
import Observation
import SwiftUI

/// Local servers listening on this Mac: open, copy the address, stop.
/// Placeholder: the shape the app is wired against. The module's own work replaces the body, not the public surface.
@MainActor
@Observable
public final class DevServersModule: NotchModule {
    public let id: ModuleID = .devServers
    public let title = "Dev servers"
    public let symbol = "server.rack"
    public let placement: PanelPlacement = .page(order: 50)

    public init() {}

    public static func live() -> DevServersModule { DevServersModule() }
    public static func sample() -> DevServersModule { DevServersModule() }

    public func start(_ context: ModuleContext) async { context.log.notice("started") }

    public func panelView() -> AnyView {
        AnyView(EmptyState(symbol: symbol, title: "Dev servers"))
    }
}
