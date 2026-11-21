import Foundation
import NotchCore

/// What the notch is showing.
public enum NotchState: String, Sendable, CaseIterable, Equatable {
    /// Exactly the hardware notch; nothing visible.
    case closed
    /// Wings beside the notch showing the arbiter's live activity.
    case activity
    /// The pointer dwelt on the notch: a small swell, no content.
    case hover
    /// A file drag is near: one large drop target below the notch band.
    case drop
    /// The full panel: page icons in the band, Home or a page below.
    case expanded

    /// Drop and expanded draw glass and content below the band.
    public var isOpen: Bool { self == .drop || self == .expanded }
}

/// Timers the state machine asks its owner to run.
public enum NotchTimer: Sendable, Hashable, CaseIterable {
    /// Pointer resting on the notch long enough to count as hover.
    case dwell
    /// Pointer has left a panel that hover opened.
    case leave
    /// Mouse released over the drop target: wait briefly for the drop to be delivered before treating it as cancelled.
    case dropGrace
}

public enum NotchEvent: Sendable, Equatable {
    /// The pointer moved into / out of the currently visible shape.
    case pointerEntered, pointerExited
    /// Primary click inside the visible shape.
    case click
    /// Any click outside the visible shape.
    case clickOutside
    case escape
    /// The global hotkey.
    case hotkey
    /// `NotchControlling` API.
    case expand(page: ModuleID?)
    case collapse
    case toggle
    /// A page icon in the band (`nil` = Home).
    case selectPage(ModuleID?)
    /// Whether the arbiter currently has an activity to show.
    case activityChanged(Bool)
    case setOpenOnHover(Bool)
    /// An external file drag is in flight and the pointer came within reach of the notch / moved away again.
    case dragNear, dragFar
    /// The mouse button was released somewhere (the drag is over).
    case dragEnded
    /// The dragged items entered / left the drop target.
    case dropTargetEntered, dropTargetExited
    /// The drop was delivered to us.
    case dropped
    case timer(NotchTimer)
}

public enum NotchEffect: Sendable, Equatable {
    case schedule(NotchTimer, at: Date)
    case cancel(NotchTimer)
    /// `Haptics.tick()`.
    case hapticTick
}

/// The notch's behaviour as a pure value type. The controller feeds it events with the current time, runs the timers
/// it asks for and renders `state`; tests drive it with injected time.
public struct NotchStateMachine: Sendable, Equatable {
    public static let dwellDelay: TimeInterval = 0.12
    public static let leaveDelay: TimeInterval = 0.30
    public static let dropGrace: TimeInterval = 0.30

    public private(set) var state: NotchState
    /// Page shown while expanded (`nil` = Home).
    public private(set) var page: ModuleID?
    /// Expanded by hover alone: closes again when the pointer leaves for `leaveDelay`. A click inside pins it.
    public private(set) var openedByHover = false
    public private(set) var dropTargeted: Bool
    public private(set) var hasActivity: Bool
    public private(set) var pointerInside = false
    public var openOnHover: Bool
    /// Pending timers and when they are due.
    public private(set) var deadlines: [NotchTimer: Date] = [:]
    /// A drag interrupted the expanded panel; cancelling the drag brings it back.
    private var resumeExpanded = false
    private var resumePage: ModuleID?

    public init(
        state: NotchState = .closed, page: ModuleID? = nil, hasActivity: Bool = false, openOnHover: Bool = false,
        dropTargeted: Bool = false
    ) {
        self.state = state; self.page = page; self.hasActivity = hasActivity; self.openOnHover = openOnHover
        self.dropTargeted = state == .drop && dropTargeted
    }

    /// Where the notch returns to when nothing is going on.
    public var restState: NotchState { hasActivity ? .activity : .closed }

    /// The parts that change what is drawn.
    public struct Visual: Equatable, Sendable {
        public var state: NotchState
        public var page: ModuleID?
        public var dropTargeted: Bool
        public var hasActivity: Bool
    }

    public var visual: Visual { Visual(state: state, page: page, dropTargeted: dropTargeted, hasActivity: hasActivity) }

    @discardableResult
    public mutating func send(_ event: NotchEvent, now: Date) -> [NotchEffect] {
        var fx: [NotchEffect] = []
        switch event {
        case .pointerEntered:
            pointerInside = true
            switch state {
            case .closed, .activity: schedule(.dwell, at: now.addingTimeInterval(Self.dwellDelay), &fx)
            case .expanded: cancel(.leave, &fx)
            case .hover, .drop: break
            }

        case .pointerExited:
            pointerInside = false
            switch state {
            case .closed, .activity: cancel(.dwell, &fx)
            case .hover: go(restState, &fx)
            case .expanded: if openedByHover { schedule(.leave, at: now.addingTimeInterval(Self.leaveDelay), &fx) }
            case .drop: break
            }

        case .timer(let timer):
            // Ignore timers that were cancelled or rescheduled after they were armed.
            guard let due = deadlines[timer], Self.isDue(due, at: now) else { return fx }
            deadlines[timer] = nil
            switch (timer, state) {
            case (.dwell, .closed), (.dwell, .activity):
                guard pointerInside else { break }
                if openOnHover { expand(page: nil, byHover: true, &fx) } else { go(.hover, &fx) }
            case (.leave, .expanded):
                if openedByHover && !pointerInside { go(restState, &fx) }
            case (.dropGrace, .drop):
                endDrag(&fx)
            default: break
            }

        case .click:
            switch state {
            case .closed, .activity, .hover: expand(page: nil, byHover: false, &fx)
            case .expanded:
                if openedByHover { openedByHover = false; cancel(.leave, &fx) }
            case .drop: break
            }

        case .clickOutside:
            if state == .expanded { go(restState, &fx) }

        case .escape:
            if state == .expanded || state == .hover { go(restState, &fx) }

        case .hotkey, .toggle:
            switch state {
            case .expanded: go(restState, &fx)
            case .drop: break
            case .closed, .activity, .hover: expand(page: nil, byHover: false, &fx)
            }

        case .expand(let target):
            if state == .drop {
                resumeExpanded = true; resumePage = target
            } else {
                expand(page: target, byHover: false, &fx)
            }

        case .collapse:
            if state == .drop { resumeExpanded = false } else if state != restState { go(restState, &fx) }

        case .selectPage(let target):
            if state == .expanded { page = target }

        case .activityChanged(let value):
            hasActivity = value
            if state == .closed || state == .activity { state = restState }

        case .setOpenOnHover(let value):
            openOnHover = value

        case .dragNear:
            switch state {
            case .drop: break
            case .expanded:
                resumeExpanded = true; resumePage = page
                go(.drop, &fx)
            case .closed, .activity, .hover:
                resumeExpanded = false
                go(.drop, &fx)
            }

        case .dragFar:
            if state == .drop { endDrag(&fx) }

        case .dragEnded:
            guard state == .drop else { break }
            if dropTargeted { schedule(.dropGrace, at: now.addingTimeInterval(Self.dropGrace), &fx) } else { endDrag(&fx) }

        case .dropTargetEntered:
            if state == .drop && !dropTargeted { dropTargeted = true; fx.append(.hapticTick) }

        case .dropTargetExited:
            if state == .drop { dropTargeted = false }

        case .dropped:
            if state == .drop { resumeExpanded = false; go(restState, &fx) }
        }
        return fx
    }

    /// Fires every timer that is due at `now`, in a stable order. Convenience for tests and simple drivers.
    @discardableResult
    public mutating func advance(to now: Date) -> [NotchEffect] {
        var fx: [NotchEffect] = []
        for timer in NotchTimer.allCases where deadlines[timer].map({ Self.isDue($0, at: now) }) == true {
            fx += send(.timer(timer), now: now)
        }
        return fx
    }

    // MARK: - Helpers

    /// 1 ms of slack absorbs clock rounding between scheduling and firing.
    private static func isDue(_ deadline: Date, at now: Date) -> Bool { now.timeIntervalSince(deadline) >= -0.001 }

    private mutating func go(_ next: NotchState, _ fx: inout [NotchEffect]) {
        if next != .closed && next != .activity { cancel(.dwell, &fx) }
        if next != .expanded { cancel(.leave, &fx); openedByHover = false }
        if next != .drop { cancel(.dropGrace, &fx); dropTargeted = false }
        if state == .drop && next != .drop { dropTargeted = false }
        if next == .drop { dropTargeted = false; cancel(.dwell, &fx) }
        state = next
    }

    private mutating func expand(page target: ModuleID?, byHover: Bool, _ fx: inout [NotchEffect]) {
        let wasExpanded = state == .expanded
        go(.expanded, &fx)
        page = target
        openedByHover = wasExpanded ? (openedByHover && byHover) : byHover
        if !openedByHover { cancel(.leave, &fx) }
    }

    private mutating func endDrag(_ fx: inout [NotchEffect]) {
        if resumeExpanded {
            resumeExpanded = false
            go(.expanded, &fx)
            page = resumePage
        } else {
            go(restState, &fx)
        }
    }

    private mutating func schedule(_ timer: NotchTimer, at date: Date, _ fx: inout [NotchEffect]) {
        deadlines[timer] = date
        fx.append(.schedule(timer, at: date))
    }

    private mutating func cancel(_ timer: NotchTimer, _ fx: inout [NotchEffect]) {
        guard deadlines.removeValue(forKey: timer) != nil else { return }
        fx.append(.cancel(timer))
    }
}
