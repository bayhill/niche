import CoreGraphics
import NotchCore

/// Positions of the Home dashboard cards inside `PanelLayout.pageSize`.
///
/// Cards always get exactly `PanelLayout.cardSize(for:)`. Columns that have no card are removed and the remaining
/// columns are centred; a lone leading card keeps its own (top or bottom) position.
public enum DashboardLayout {
    public static func frames(for slots: Set<DashboardSlot>, in area: CGSize = PanelLayout.pageSize) -> [DashboardSlot: CGRect] {
        let gap = PanelLayout.gap
        var columns: [[DashboardSlot]] = []
        let leading = [DashboardSlot.leadingTop, .leadingBottom].filter(slots.contains)
        if !leading.isEmpty { columns.append(leading) }
        if slots.contains(.center) { columns.append([.center]) }
        if slots.contains(.trailing) { columns.append([.trailing]) }
        guard !columns.isEmpty else { return [:] }

        let widths = columns.map { PanelLayout.cardSize(for: $0[0]).width }
        let total = widths.reduce(0, +) + gap * CGFloat(columns.count - 1)
        var x = ((area.width - total) / 2).rounded(.down)
        var frames: [DashboardSlot: CGRect] = [:]
        for (column, width) in zip(columns, widths) {
            var y: CGFloat = 0
            for slot in column {
                let size = PanelLayout.cardSize(for: slot)
                // A lone bottom card still sits at the bottom so it lines up with where it would normally be.
                if slot == .leadingBottom && column.count == 1 { y = area.height - size.height }
                frames[slot] = CGRect(x: x, y: y, width: size.width, height: size.height)
                y += size.height + gap
            }
            x += width + gap
        }
        return frames
    }
}

/// One card on Home.
struct DashboardCard: Identifiable {
    let id: ModuleID
    let slot: DashboardSlot
    let module: any NotchModule
}

/// One icon in the band.
struct PageEntry: Identifiable, Equatable {
    let id: ModuleID
    let title: String
    let symbol: String
}

@MainActor
enum PanelContent {
    /// `.page` modules by `order`, ties keeping module order.
    static func pages(_ modules: [any NotchModule]) -> [PageEntry] {
        modules.enumerated()
            .compactMap { index, module -> (Int, Int, PageEntry)? in
                guard case .page(let order) = module.placement else { return nil }
                return (order, index, PageEntry(id: module.id, title: module.title, symbol: module.symbol))
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
    }

    /// The first module claiming each slot, in slot order.
    static func dashboard(_ modules: [any NotchModule]) -> [DashboardCard] {
        var taken: [DashboardSlot: any NotchModule] = [:]
        for module in modules {
            if case .dashboard(let slot) = module.placement, taken[slot] == nil { taken[slot] = module }
        }
        return DashboardSlot.allCases.compactMap { slot in
            taken[slot].map { DashboardCard(id: $0.id, slot: slot, module: $0) }
        }
    }

    static func pageModule(_ id: ModuleID?, in modules: [any NotchModule]) -> (any NotchModule)? {
        guard let id, let module = modules.first(where: { $0.id == id }), case .page = module.placement else { return nil }
        return module
    }
}
