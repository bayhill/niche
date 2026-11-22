import Foundation
import NotchCore

/// One colour picked from the screen.
public struct ColourPick: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var colour: Colour
    public var pickedAt: Date

    public init(id: UUID = UUID(), colour: Colour, pickedAt: Date) {
        self.id = id; self.colour = colour; self.pickedAt = pickedAt
    }
}

/// Recent picks, newest first. A pure value type so the rules are testable without a module.
public struct ColourHistory: Sendable, Equatable {
    public static let defaultCapacity = 12

    public private(set) var picks: [ColourPick]
    public let capacity: Int

    public init(_ picks: [ColourPick] = [], capacity: Int = ColourHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.picks = []
        replace(with: picks)
    }

    /// Puts the pick at the front and returns it as stored. Picking a colour that is already in the history
    /// (one no format can tell apart, `Colour.readsSame(as:)`) moves that entry to the front with the new
    /// time instead of adding a second one; it keeps its id, so a contrast selection on it survives.
    /// The oldest pick falls off past `capacity`.
    @discardableResult
    public mutating func add(_ pick: ColourPick) -> ColourPick {
        var stored = pick
        if let index = picks.firstIndex(where: { $0.colour.readsSame(as: pick.colour) }) {
            stored.id = picks[index].id
            picks.remove(at: index)
        }
        picks.insert(stored, at: 0)
        if picks.count > capacity { picks.removeLast(picks.count - capacity) }
        return stored
    }

    public mutating func removeAll() { picks.removeAll() }

    /// Replaces the list (after loading), keeping the invariants: finite colours, no repeats, newest first, capped.
    public mutating func replace(with newPicks: [ColourPick]) {
        var out: [ColourPick] = []
        for pick in newPicks.sorted(by: { $0.pickedAt > $1.pickedAt }) where pick.colour.isFinite {
            guard !out.contains(where: { $0.id == pick.id || $0.colour.readsSame(as: pick.colour) }) else { continue }
            out.append(pick)
            if out.count == capacity { break }
        }
        picks = out
    }

    public func pick(_ id: ColourPick.ID) -> ColourPick? { picks.first { $0.id == id } }
}

/// Which two picks the contrast card compares.
///
/// Until the user chooses, it compares the two newest picks (pick a text colour, then its background, and the
/// card already answers). In selection mode the user chooses explicitly: a click toggles a swatch, at most two stay
/// chosen, and a third replaces the one chosen first.
public struct ContrastSelection: Sendable, Equatable {
    /// Chosen pick ids, in the order chosen. At most two.
    public private(set) var chosen: [ColourPick.ID] = []

    public init(chosen: [ColourPick.ID] = []) { self.chosen = Array(chosen.suffix(2)) }

    public var isEmpty: Bool { chosen.isEmpty }

    public func isChosen(_ id: ColourPick.ID) -> Bool { chosen.contains(id) }

    public mutating func toggle(_ id: ColourPick.ID) {
        if let index = chosen.firstIndex(of: id) {
            chosen.remove(at: index)
        } else {
            chosen.append(id)
            if chosen.count > 2 { chosen.removeFirst(chosen.count - 2) }
        }
    }

    public mutating func clear() { chosen.removeAll() }

    /// Forgets ids that are no longer in the history.
    public mutating func keep(_ history: ColourHistory) {
        chosen.removeAll { history.pick($0) == nil }
    }

    /// The pair to compare, first chosen first. With nothing chosen and `fallbackToNewest`, the two newest picks.
    /// `nil` when there is no pair yet.
    public func pair(in history: ColourHistory, fallbackToNewest: Bool) -> (ColourPick, ColourPick)? {
        let resolved = chosen.compactMap(history.pick)
        if resolved.count == 2 { return (resolved[0], resolved[1]) }
        if resolved.isEmpty, fallbackToNewest, history.picks.count >= 2 { return (history.picks[0], history.picks[1]) }
        return nil
    }
}

/// The history's JSON file. The only file the module writes.
public enum ColourFiles {
    /// `<appSupport>/Colour/history.json`.
    public static func storeURL(in directories: AppDirectories) -> URL {
        directories.appSupport.appending(path: "Colour", directoryHint: .isDirectory).appending(path: "history.json")
    }

    private struct Envelope: Codable {
        var version = 1
        var picks: [ColourPick]
    }

    /// The saved picks, or none when the file is missing or unreadable.
    public static func load(from url: URL) -> [ColourPick] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.picks ?? []
    }

    public static func save(_ picks: [ColourPick], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(picks: picks))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
