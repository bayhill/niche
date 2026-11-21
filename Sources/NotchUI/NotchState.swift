import Foundation
import NotchCore

/// The machine's clock: monotonic, so wall-clock steps (NTP, manual changes, time zones) never drop or stall a timer.
public typealias NotchInstant = ContinuousClock.Instant

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
    /// Pointer has left a transient panel.
    case leave
    /// A transient panel opened away from the pointer (hotkey, API) that the pointer never visited.
    case idle
    /// Mouse released over the drop target: wait briefly for the drop to be delivered before treating it as cancelled.
    case dropGrace
}

public enum NotchEvent: Sendable, Equatable {
    /// The pointer moved into / out of the interactive rect.
    case pointerEntered, pointerExited
    /// Primary click inside the interactive rect.
    case click
    /// Any click outside the interactive rect.
    case clickOutside
    /// Esc pressed while the panel is the key window.
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
    /// A file drag that some module accepts came within reach of the notch / moved away again.
    case dragNear, dragFar
    /// The mouse button was released somewhere (the drag is over).
    case dragEnded
    /// The dragged items entered / left the drop target.
    case dropTargetEntered, dropTargetExited
    /// The drop was delivered to us (check `acceptsDrop(now:)` first).
    case dropped
    case timer(NotchTimer)
}

public enum NotchEffect: Sendable, Equatable {
    case schedule(NotchTimer, at: NotchInstant)
    case cancel(NotchTimer)
    /// `Haptics.tick()`.
    case hapticTick
}

/// The notch's behaviour as a pure value type. The controller feeds it events with the current monotonic instant, runs
/// the timers it asks for and renders `state`; tests drive it with injected instants.
public struct NotchStateMachine: Sendable, Equatable {
    public static let dwellDelay: Duration = .milliseconds(120)
    public static let leaveDelay: Duration = .milliseconds(300)
    /// A panel opened by hotkey or API closes by itself if the pointer never comes to it.
    public static let idleDelay: Duration = .seconds(4)
    public static let dropGrace: Duration = .milliseconds(300)
    /// After the grace expires on a highlighted target, a drop that still arrives is accepted for this long.
    public static let lateDropWindow: Duration = .milliseconds(1500)

    /// How the panel was opened.
    public enum Opening: Sendable, Equatable {
        /// A click on the notch: stays until dismissed.
        case click
        /// Dwell with `openOnHover`: closes after the pointer leaves.
        case hover
        /// Hotkey or API, away from the pointer: closes if the pointer never comes, or after it leaves.
        case request
    }

    public private(set) var state: NotchState
    /// Page shown while expanded (`nil` = Home).
    public private(set) var page: ModuleID?
    /// Opened by hover, hotkey or API and not yet clicked: closes by itself when not in use. A click inside pins it.
    public private(set) var transient = false
    public private(set) var dropTargeted: Bool
    public private(set) var hasActivity: Bool
    public private(set) var pointerInside = false
    public var openOnHover: Bool
    /// Pending timers and when they are due.
    public private(set) var deadlines: [NotchTimer: NotchInstant] = [:]
    /// A drag interrupted the expanded panel; cancelling the drag brings it back as it was.
    private var resume: (page: ModuleID?, transient: Bool)?
    private var lateDropUntil: NotchInstant?

    public init(
        state: NotchState = .closed, page: ModuleID? = nil, hasActivity: Bool = false, openOnHover: Bool = false,
        dropTargeted: Bool = false
    ) {
        self.state = state; self.page = page; self.hasActivity = hasActivity; self.openOnHover = openOnHover
        self.dropTargeted = state == .drop && dropTargeted
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.state == b.state && a.page == b.page && a.transient == b.transient && a.dropTargeted == b.dropTargeted
            && a.hasActivity == b.hasActivity && a.pointerInside == b.pointerInside && a.openOnHover == b.openOnHover
            && a.deadlines == b.deadlines && a.resume?.page == b.resume?.page && a.resume?.transient == b.resume?.transient
            && a.lateDropUntil == b.lateDropUntil
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

    /// Whether a drop delivered now should be taken: while the target is showing, or shortly after a highlighted
    /// target gave up waiting (a slow source or a busy main thread).
    public func acceptsDrop(now: NotchInstant) -> Bool {
        state == .drop || lateDropUntil.map { now <= $0 } == true
    }

    @discardableResult
    public mutating func send(_ event: NotchEvent, now: NotchInstant) -> [NotchEffect] {
        var fx: [NotchEffect] = []
        switch event {
        case .pointerEntered:
            pointerInside = true
            switch state {
            case .closed, .activity: schedule(.dwell, at: now + Self.dwellDelay, &fx)
            case .expanded: cancel(.leave, &fx); cancel(.idle, &fx)
            case .hover, .drop: break
            }

        case .pointerExited:
            pointerInside = false
            switch state {
            case .closed, .activity: cancel(.dwell, &fx)
            case .hover: go(restState, &fx)
            case .expanded: if transient { cancel(.idle, &fx); schedule(.leave, at: now + Self.leaveDelay, &fx) }
            case .drop: break
            }

        case .timer(let timer):
            guard let due = deadlines[timer] else { return fx }
            // A timer delivered early is re-armed rather than lost.
            guard now >= due else { return [.schedule(timer, at: due)] }
            deadlines[timer] = nil
            switch (timer, state) {
            case (.dwell, .closed), (.dwell, .activity):
                guard pointerInside else { break }
                if openOnHover { expand(page: nil, opening: .hover, now: now, &fx) } else { go(.hover, &fx) }
            case (.leave, .expanded), (.idle, .expanded):
                if transient && !pointerInside { go(restState, &fx) }
            case (.dropGrace, .drop):
                if dropTargeted { lateDropUntil = now + Self.lateDropWindow }
                endDrag(now: now, &fx)
            default: break
            }

        case .click:
            switch state {
            case .closed, .activity, .hover: expand(page: nil, opening: .click, now: now, &fx)
            case .expanded:
                if transient { transient = false; cancel(.leave, &fx); cancel(.idle, &fx) }
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
            case .closed, .activity, .hover: expand(page: nil, opening: .request, now: now, &fx)
            }

        case .expand(let target):
            switch state {
            case .drop: resume = (target, resume?.transient ?? true)
            case .expanded: page = target
            case .closed, .activity, .hover: expand(page: target, opening: .request, now: now, &fx)
            }

        case .collapse:
            if state == .drop { resume = nil } else if state != restState { go(restState, &fx) }

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
                resume = (page, transient)
                go(.drop, &fx)
            case .closed, .activity, .hover:
                resume = nil
                go(.drop, &fx)
            }

        case .dragFar:
            if state == .drop { endDrag(now: now, &fx) }

        case .dragEnded:
            guard state == .drop else { break }
            if dropTargeted { schedule(.dropGrace, at: now + Self.dropGrace, &fx) } else { endDrag(now: now, &fx) }

        case .dropTargetEntered:
            if state == .drop && !dropTargeted { dropTargeted = true; fx.append(.hapticTick) }

        case .dropTargetExited:
            if state == .drop { dropTargeted = false }

        case .dropped:
            if state == .drop {
                resume = nil
                go(restState, &fx)
            } else if acceptsDrop(now: now) {
                // A late drop: the target already gave up, but the content was taken, so finish like a normal drop.
                lateDropUntil = nil
                if state == .expanded { go(restState, &fx) }
            }
        }
        return fx
    }

    /// Fires every timer that is due at `now`, in a stable order. Convenience for tests and simple drivers.
    @discardableResult
    public mutating func advance(to now: NotchInstant) -> [NotchEffect] {
        var fx: [NotchEffect] = []
        for timer in NotchTimer.allCases where deadlines[timer].map({ $0 <= now }) == true {
            fx += send(.timer(timer), now: now)
        }
        return fx
    }

    // MARK: - Helpers

    private mutating func go(_ next: NotchState, _ fx: inout [NotchEffect]) {
        if next != .closed && next != .activity { cancel(.dwell, &fx) }
        if next != .expanded { cancel(.leave, &fx); cancel(.idle, &fx); transient = false }
        if next != .drop { cancel(.dropGrace, &fx) }
        if next == .drop { lateDropUntil = nil }
        dropTargeted = false
        state = next
    }

    private mutating func expand(page target: ModuleID?, opening: Opening, now: NotchInstant, _ fx: inout [NotchEffect]) {
        go(.expanded, &fx)
        page = target
        transient = opening != .click
        if opening == .request && !pointerInside { schedule(.idle, at: now + Self.idleDelay, &fx) }
    }

    private mutating func endDrag(now: NotchInstant, _ fx: inout [NotchEffect]) {
        if let resume {
            self.resume = nil
            go(.expanded, &fx)
            page = resume.page
            transient = resume.transient
            if transient && !pointerInside { schedule(.leave, at: now + Self.leaveDelay, &fx) }
        } else {
            go(restState, &fx)
        }
    }

    private mutating func schedule(_ timer: NotchTimer, at instant: NotchInstant, _ fx: inout [NotchEffect]) {
        deadlines[timer] = instant
        fx.append(.schedule(timer, at: instant))
    }

    private mutating func cancel(_ timer: NotchTimer, _ fx: inout [NotchEffect]) {
        guard deadlines.removeValue(forKey: timer) != nil else { return }
        fx.append(.cancel(timer))
    }
}
