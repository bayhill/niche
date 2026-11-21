import Foundation
import UniformTypeIdentifiers

/// One thing dragged onto the notch (or pasted to a module programmatically).
public enum DropItem: Sendable, Equatable {
    case file(URL)
    /// Raw encoded image bytes with no file behind them (e.g. dragged from a browser).
    case imageData(Data, suggestedName: String?)
    case text(String)

    public var fileURL: URL? { if case .file(let u) = self { u } else { nil } }

    /// Uniform type derived from the file extension; `.image` for raw image data; `.plainText` for text.
    public var contentType: UTType? {
        switch self {
        case .file(let url): UTType(filenameExtension: url.pathExtension.lowercased())
        case .imageData: .image
        case .text: .plainText
        }
    }

    public var isImage: Bool { contentType?.conforms(to: .image) ?? false }
}

public enum DropTarget: Sendable, Equatable {
    /// The notch itself: route by module preference.
    case notch
    /// A specific module's area inside the expanded panel.
    case module(ModuleID)
}

public struct DropPayload: Sendable, Equatable {
    public var items: [DropItem]
    /// ⌥ held at drop time: bypass conversion and send to the shelf.
    public var optionKey: Bool
    public var target: DropTarget

    public init(items: [DropItem], optionKey: Bool = false, target: DropTarget = .notch) {
        self.items = items; self.optionKey = optionKey; self.target = target
    }
}

public enum DropAcceptance: Sendable, Equatable {
    case reject
    /// Higher weight wins the item. Use the `DropWeight` constants.
    case accept(weight: Int)
}

public enum DropWeight {
    /// "I can hold anything" (the shelf).
    public static let fallback = 10
    /// "This is exactly my kind of content" (images for Convert).
    public static let preferred = 100
}

/// Text for the drop target while the user is still dragging.
public struct DropHint: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var symbol: String
    public init(title: String, subtitle: String? = nil, symbol: String) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
    }
}

public struct DropRoute: Sendable, Equatable {
    public var module: ModuleID
    public var payload: DropPayload
    public init(module: ModuleID, payload: DropPayload) { self.module = module; self.payload = payload }
}

public enum DropRouter {
    /// Splits a payload between modules. Rules, in order:
    /// 1. `target == .module(id)`: that module gets every item it accepts; the rest are discarded.
    /// 2. `optionKey`: the shelf module gets every item it accepts; the rest are discarded.
    /// 3. Otherwise each item goes to the module with the highest accept weight (ties: earlier in `modules`).
    /// Routes are returned in `modules` order; item order is preserved inside each route.
    @MainActor
    public static func route(_ payload: DropPayload, among modules: [any NotchModule]) -> [DropRoute] {
        var buckets: [ModuleID: [DropItem]] = [:]

        func weight(_ module: any NotchModule, _ item: DropItem) -> Int? {
            if case .accept(let w) = module.dropAcceptance(for: item) { w } else { nil }
        }

        var forced: ModuleID?
        if case .module(let id) = payload.target { forced = id } else if payload.optionKey { forced = .shelf }

        if let forced {
            guard let module = modules.first(where: { $0.id == forced }) else { return [] }
            buckets[forced] = payload.items.filter { weight(module, $0) != nil }
        } else {
            for item in payload.items {
                var best: (id: ModuleID, weight: Int)?
                for module in modules {
                    guard let w = weight(module, item) else { continue }
                    if best == nil || w > best!.weight { best = (module.id, w) }
                }
                if let best { buckets[best.id, default: []].append(item) }
            }
        }

        return modules.compactMap { module in
            guard let items = buckets[module.id], !items.isEmpty else { return nil }
            return DropRoute(module: module.id, payload: DropPayload(items: items, optionKey: payload.optionKey, target: payload.target))
        }
    }

    /// The hint to show while dragging: from the module that would receive the most items.
    @MainActor
    public static func hint(for payload: DropPayload, among modules: [any NotchModule]) -> DropHint? {
        let routes = route(payload, among: modules)
        guard let top = routes.max(by: { $0.payload.items.count < $1.payload.items.count }),
              let module = modules.first(where: { $0.id == top.module })
        else { return nil }
        return module.dropHint(for: top.payload.items)
    }
}
