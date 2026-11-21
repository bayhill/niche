import Foundation
import NotchCore
import Testing
@testable import NotchUI

private let t0 = ContinuousClock.now
private func at(_ seconds: Double) -> NotchInstant { t0 + .milliseconds(Int((seconds * 1000).rounded())) }


/// A machine plus a clock, so tests read as timelines.
private struct Driver {
    var machine: NotchStateMachine
    var now = t0
    var effects: [NotchEffect] = []

    init(_ machine: NotchStateMachine = NotchStateMachine()) { self.machine = machine }

    @discardableResult
    mutating func send(_ event: NotchEvent) -> [NotchEffect] {
        effects = machine.send(event, now: now)
        return effects
    }

    /// Moves the clock and fires every timer that has come due on the way.
    mutating func wait(_ seconds: Double) {
        now = now + .milliseconds(Int((seconds * 1000).rounded()))
        effects = machine.advance(to: now)
    }

    var state: NotchState { machine.state }
}

private func ms(_ value: Int) -> Duration { .milliseconds(value) }

@Suite("State machine")
struct StateMachineTests {
    // MARK: Rest states

    @Test func restStateFollowsTheActivity() {
        var d = Driver()
        #expect(d.state == .closed)
        d.send(.activityChanged(true))
        #expect(d.state == .activity)
        d.send(.activityChanged(false))
        #expect(d.state == .closed)
    }

    // MARK: Hover dwell

    @Test func hoverNeedsTheDwell() {
        var d = Driver()
        #expect(d.send(.pointerEntered) == [.schedule(.dwell, at: t0 + NotchStateMachine.dwellDelay)])
        d.wait(0.05)
        #expect(d.state == .closed)
        // A timer delivered early is not lost: it is re-armed for its original instant.
        #expect(d.machine.send(.timer(.dwell), now: at(0.06)) == [.schedule(.dwell, at: t0 + NotchStateMachine.dwellDelay)])
        #expect(d.machine.deadlines[.dwell] == t0 + NotchStateMachine.dwellDelay)
        d.wait(0.07)
        #expect(d.state == .hover)
        #expect(d.machine.deadlines.isEmpty)
    }

    @Test func leavingBeforeTheDwellCancelsIt() {
        var d = Driver(NotchStateMachine(hasActivity: true, openOnHover: false))
        d.send(.activityChanged(true))
        d.send(.pointerEntered)
        d.now = at(0.1)
        #expect(d.send(.pointerExited) == [.cancel(.dwell)])
        // The stale timer firing later does nothing.
        #expect(d.machine.send(.timer(.dwell), now: at(0.2)) == [])
        #expect(d.state == .activity)
    }

    @Test func leavingHoverReturnsToRest() {
        var d = Driver()
        d.send(.activityChanged(true))
        d.send(.pointerEntered)
        d.wait(0.12)
        #expect(d.state == .hover)
        d.send(.pointerExited)
        #expect(d.state == .activity)
    }

    @Test func clickExpandsFromAnyRestingState() {
        for setup in [NotchState.closed, .activity, .hover] {
            var d = Driver(NotchStateMachine(state: setup, hasActivity: setup != .closed))
            d.send(.click)
            #expect(d.state == .expanded)
            #expect(!d.machine.transient)
            #expect(d.machine.page == nil)
        }
    }

    @Test func clickBeforeTheDwellExpandsAndCancelsIt() {
        var d = Driver()
        d.send(.pointerEntered)
        d.now = at(0.05)
        #expect(d.send(.click) == [.cancel(.dwell)])
        #expect(d.state == .expanded)
        d.wait(1)
        #expect(d.state == .expanded)
    }

    // MARK: Open on hover

    @Test func openOnHoverOpensAfterTheDwellAndClosesAfterLeaving() {
        var d = Driver(NotchStateMachine(openOnHover: true))
        d.send(.pointerEntered)
        d.wait(0.12)
        #expect(d.state == .expanded)
        #expect(d.machine.transient)

        d.send(.pointerExited)
        #expect(d.effects == [.schedule(.leave, at: d.now + NotchStateMachine.leaveDelay)])
        d.wait(0.2)
        #expect(d.state == .expanded)
        // Coming back in time cancels the close.
        #expect(d.send(.pointerEntered) == [.cancel(.leave)])
        d.wait(1)
        #expect(d.state == .expanded)

        d.send(.pointerExited)
        d.wait(0.3)
        #expect(d.state == .closed)
    }

    @Test func aClickPinsAHoverOpenedPanel() {
        var d = Driver(NotchStateMachine(openOnHover: true))
        d.send(.pointerEntered)
        d.wait(0.12)
        d.send(.click)
        #expect(!d.machine.transient)
        d.send(.pointerExited)
        #expect(d.effects.isEmpty)
        d.wait(2)
        #expect(d.state == .expanded)
    }

    @Test func aClickOpenedPanelIgnoresTheLeaveTimer() {
        var d = Driver(NotchStateMachine(openOnHover: true))
        d.send(.pointerEntered)
        d.send(.click)
        d.send(.pointerExited)
        d.wait(1)
        #expect(d.state == .expanded)
    }

    @Test func openOnHoverCanBeToggledAtRuntime() {
        var d = Driver()
        d.send(.setOpenOnHover(true))
        d.send(.pointerEntered)
        d.wait(0.12)
        #expect(d.state == .expanded)
    }

    // MARK: Expanded

    @Test func expandedClosesOnEscapeClickOutsideHotkeyCollapseAndToggle() {
        for event in [NotchEvent.escape, .clickOutside, .hotkey, .collapse, .toggle] {
            var d = Driver(NotchStateMachine(state: .expanded, page: .shelf, hasActivity: true))
            d.send(event)
            #expect(d.state == .activity, "\(event)")
        }
    }

    @Test func hotkeyAndToggleOpenHome() {
        for event in [NotchEvent.hotkey, .toggle] {
            var d = Driver()
            d.send(event)
            #expect(d.state == .expanded)
            #expect(d.machine.page == nil)
            #expect(d.machine.transient)
        }
    }

    // MARK: Opened away from the pointer (hotkey, API)

    @Test func aHotkeyPanelTheUserIgnoresClosesAfterTheIdleDelay() {
        var d = Driver(NotchStateMachine(hasActivity: true))
        d.send(.activityChanged(true))
        #expect(d.send(.hotkey) == [.schedule(.idle, at: t0 + NotchStateMachine.idleDelay)])
        d.wait(3.9)
        #expect(d.state == .expanded)
        d.wait(0.1)
        #expect(d.state == .activity)
    }

    @Test func visitingAHotkeyPanelCancelsTheIdleCloseAndLeavingUsesTheLeaveDelay() {
        var d = Driver()
        d.send(.expand(page: .shelf))
        d.wait(1)
        #expect(d.send(.pointerEntered) == [.cancel(.idle)])
        d.wait(10)
        #expect(d.state == .expanded)
        #expect(d.send(.pointerExited) == [.schedule(.leave, at: d.now + NotchStateMachine.leaveDelay)])
        d.wait(0.3)
        #expect(d.state == .closed)
    }

    @Test func clickingAHotkeyPanelPinsIt() {
        var d = Driver()
        d.send(.hotkey)
        d.send(.pointerEntered)
        d.send(.click)
        #expect(!d.machine.transient)
        d.send(.pointerExited)
        d.wait(10)
        #expect(d.state == .expanded)
    }

    @Test func aHotkeyWithThePointerAlreadyInsideArmsNoIdleTimer() {
        var d = Driver(NotchStateMachine(state: .hover))
        d.send(.pointerEntered)
        #expect(d.send(.hotkey) == [])
        #expect(d.machine.transient)
        d.wait(10)
        #expect(d.state == .expanded)
    }

    @Test func escapeOnlyComesFromTheKeyPanelAndStillCloses() {
        var d = Driver()
        d.send(.hotkey)
        d.send(.escape)
        #expect(d.state == .closed)
        #expect(d.machine.deadlines.isEmpty)
    }

    @Test func expandAPIOpensOnAPageAndSwitchesPagesWhileOpen() {
        var d = Driver()
        d.send(.expand(page: .shelf))
        #expect(d.state == .expanded && d.machine.page == .shelf)
        d.send(.selectPage(nil))
        #expect(d.machine.page == nil)
        d.send(.expand(page: .clipboard))
        #expect(d.machine.page == .clipboard)
    }

    @Test func selectPageIsIgnoredWhenNotExpanded() {
        var d = Driver()
        d.send(.selectPage(.shelf))
        #expect(d.machine.page == nil && d.state == .closed)
    }

    @Test func escapeAndClickOutsideDoNothingAtRest() {
        var d = Driver(NotchStateMachine(state: .activity, hasActivity: true))
        d.send(.escape)
        d.send(.clickOutside)
        d.send(.collapse)
        #expect(d.state == .activity)
    }

    @Test func activityChangesWhileExpandedApplyOnCollapse() {
        var d = Driver(NotchStateMachine(state: .expanded))
        d.send(.activityChanged(true))
        #expect(d.state == .expanded)
        d.send(.escape)
        #expect(d.state == .activity)
    }

    // MARK: Drop

    @Test func hoverIsInterruptedByADrag() {
        var d = Driver()
        d.send(.activityChanged(true))
        d.send(.pointerEntered)
        d.wait(0.12)
        #expect(d.state == .hover)
        d.send(.dragNear)
        #expect(d.state == .drop)
        d.send(.dragFar)
        #expect(d.state == .activity)
    }

    @Test func aDragDuringTheDwellCancelsIt() {
        var d = Driver()
        d.send(.pointerEntered)
        d.now = at(0.05)
        #expect(d.send(.dragNear) == [.cancel(.dwell)])
        #expect(d.state == .drop)
        d.wait(1)
        #expect(d.state == .drop)
    }

    @Test func enteringTheTargetHighlightsItWithOneTick() {
        var d = Driver()
        d.send(.dragNear)
        #expect(d.send(.dropTargetEntered) == [.hapticTick])
        #expect(d.machine.dropTargeted)
        #expect(d.send(.dropTargetEntered) == [])
        d.send(.dropTargetExited)
        #expect(!d.machine.dropTargeted)
        #expect(d.send(.dropTargetEntered) == [.hapticTick])
    }

    @Test func droppingCollapsesToTheActivity() {
        var d = Driver(NotchStateMachine(hasActivity: true))
        d.send(.activityChanged(true))
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        d.send(.dropped)
        #expect(d.state == .activity)
        #expect(!d.machine.dropTargeted)
    }

    @Test func dropWhileExpandedReturnsToTheSamePageIfCancelled() {
        var d = Driver(NotchStateMachine(state: .expanded, page: .shelf))
        d.send(.dragNear)
        #expect(d.state == .drop)
        d.send(.dragFar)
        #expect(d.state == .expanded && d.machine.page == .shelf)
        d.send(.dragNear)
        d.send(.dragEnded)
        #expect(d.state == .expanded && d.machine.page == .shelf)
    }

    @Test func aHoverOpenedPanelStaysTransientAcrossACancelledDrag() {
        var d = Driver(NotchStateMachine(openOnHover: true))
        d.send(.pointerEntered)
        d.wait(0.12)
        #expect(d.state == .expanded && d.machine.transient)
        d.send(.dragNear)
        d.send(.pointerExited)
        // Cancelled away from the panel: it comes back transient and closes after the leave delay.
        #expect(d.send(.dragFar) == [.schedule(.leave, at: d.now + NotchStateMachine.leaveDelay)])
        #expect(d.state == .expanded && d.machine.transient)
        d.wait(0.3)
        #expect(d.state == .closed)
    }

    @Test func aPinnedPanelStaysPinnedAcrossACancelledDrag() {
        var d = Driver(NotchStateMachine(state: .expanded))
        d.send(.dragNear)
        d.send(.dragFar)
        #expect(d.state == .expanded && !d.machine.transient)
        d.wait(10)
        #expect(d.state == .expanded)
    }

    @Test func dropWhileExpandedCollapsesAfterTheDrop() {
        var d = Driver(NotchStateMachine(state: .expanded, page: .shelf, hasActivity: true))
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        d.send(.dropped)
        #expect(d.state == .activity)
        // The next drag starts fresh and does not resurrect the panel.
        d.send(.dragNear)
        d.send(.dragFar)
        #expect(d.state == .activity)
    }

    @Test func releasingOverTheTargetWaitsBrieflyForTheDrop() {
        var d = Driver()
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        #expect(d.send(.dragEnded) == [.schedule(.dropGrace, at: t0 + NotchStateMachine.dropGrace)])
        #expect(d.state == .drop)
        d.now = at(0.05)
        #expect(d.send(.dropped) == [.cancel(.dropGrace)])
        #expect(d.state == .closed)
    }

    @Test func releasingOverTheTargetWithoutADropGivesUpAfterTheGrace() {
        var d = Driver()
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        d.send(.dragEnded)
        d.wait(0.2)
        #expect(d.state == .drop)
        d.wait(0.1)
        #expect(d.state == .closed)
    }

    @Test func aLateDropAfterAHighlightedTargetGaveUpIsStillAccepted() {
        var d = Driver(NotchStateMachine(state: .expanded, page: .shelf))
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        d.send(.dragEnded)
        d.wait(0.3)
        #expect(d.state == .expanded)
        #expect(d.machine.acceptsDrop(now: d.now))
        d.wait(1.4)
        #expect(d.machine.acceptsDrop(now: d.now))
        d.send(.dropped)
        #expect(d.state == .closed)
        #expect(!d.machine.acceptsDrop(now: d.now))
    }

    @Test func theLateDropWindowCloses() {
        var d = Driver()
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        d.send(.dragEnded)
        d.wait(0.3)
        d.wait(1.6)
        #expect(!d.machine.acceptsDrop(now: d.now))
        d.send(.dropped)
        #expect(d.state == .closed)
    }

    @Test func noLateDropWithoutAHighlightedTarget() {
        var d = Driver()
        d.send(.dragNear)
        d.send(.dragEnded)
        #expect(!d.machine.acceptsDrop(now: d.now))
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        d.send(.dropTargetExited)
        d.send(.dragFar)
        #expect(!d.machine.acceptsDrop(now: d.now))
    }

    @Test func releasingAwayFromTheTargetEndsImmediately() {
        var d = Driver()
        d.send(.dragNear)
        d.send(.dragEnded)
        #expect(d.state == .closed)
    }

    @Test func clicksHotkeysAndEscapeAreIgnoredDuringADrag() {
        for event in [NotchEvent.click, .hotkey, .toggle, .escape, .clickOutside, .selectPage(.shelf)] {
            var d = Driver()
            d.send(.dragNear)
            d.send(event)
            #expect(d.state == .drop, "\(event)")
        }
    }

    @Test func expandRequestedDuringADragOpensWhenTheDragIsCancelled() {
        var d = Driver()
        d.send(.dragNear)
        d.send(.expand(page: .clipboard))
        #expect(d.state == .drop)
        d.send(.dragFar)
        #expect(d.state == .expanded && d.machine.page == .clipboard)
    }

    @Test func collapseRequestedDuringADragForgetsTheExpandedPanel() {
        var d = Driver(NotchStateMachine(state: .expanded))
        d.send(.dragNear)
        d.send(.collapse)
        d.send(.dragFar)
        #expect(d.state == .closed)
    }

    @Test func dragEventsOutsideTheDropStateAreHarmless() {
        var d = Driver()
        for event in [NotchEvent.dragFar, .dragEnded, .dropTargetEntered, .dropTargetExited, .dropped] {
            #expect(d.send(event) == [])
            #expect(d.state == .closed)
        }
    }

    // MARK: Full table

    /// Every state × every event, from a clean machine in that state (no pointer inside, no pending timers).
    @Test func transitionTable() {
        let events: [(String, NotchEvent)] = [
            ("enter", .pointerEntered), ("exit", .pointerExited), ("click", .click), ("outside", .clickOutside),
            ("esc", .escape), ("hotkey", .hotkey), ("expand", .expand(page: .shelf)), ("collapse", .collapse),
            ("toggle", .toggle), ("page", .selectPage(.clipboard)), ("act+", .activityChanged(true)),
            ("act-", .activityChanged(false)), ("near", .dragNear), ("far", .dragFar), ("ended", .dragEnded),
            ("in", .dropTargetEntered), ("out", .dropTargetExited), ("dropped", .dropped),
        ]
        // Expected state after each event, per starting state, with hasActivity = true (rest = .activity).
        let expected: [NotchState: [NotchState]] = [
            //            enter      exit       click      outside    esc        hotkey     expand     collapse   toggle     page       act+       act-     near   far        ended      in     out    dropped
            .closed:   [.closed,   .closed,   .expanded, .closed,   .closed,   .expanded, .expanded, .closed,   .expanded, .closed,   .activity, .closed, .drop, .closed,   .closed,   .closed, .closed, .closed],
            .activity: [.activity, .activity, .expanded, .activity, .activity, .expanded, .expanded, .activity, .expanded, .activity, .activity, .closed, .drop, .activity, .activity, .activity, .activity, .activity],
            .hover:    [.hover,    .activity, .expanded, .hover,    .activity, .expanded, .expanded, .activity, .expanded, .hover,    .hover,    .hover,  .drop, .hover,    .hover,    .hover, .hover, .hover],
            .drop:     [.drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,   .drop, .activity, .activity, .drop,  .drop,  .activity],
            .expanded: [.expanded, .expanded, .expanded, .activity, .activity, .activity, .expanded, .activity, .activity, .expanded, .expanded, .expanded, .drop, .expanded, .expanded, .expanded, .expanded, .expanded],
        ]
        for (start, row) in expected {
            for ((name, event), want) in zip(events, row) {
                // `.closed` with an activity is not a resting state, so it starts without one.
                var m = NotchStateMachine(state: start, hasActivity: start != .closed)
                m.send(event, now: t0)
                #expect(m.state == want, "\(start.rawValue) + \(name)")
            }
        }
    }

    @Test func aCancelledOrRescheduledTimerFiringLateDoesNothing() {
        var d = Driver(NotchStateMachine(openOnHover: true))
        d.send(.pointerEntered)
        d.wait(0.12)
        d.send(.pointerExited)          // leave armed for +0.3
        d.now = d.now + ms(100)
        d.send(.pointerEntered)         // cancelled
        #expect(d.machine.send(.timer(.leave), now: d.now + ms(500)) == [])
        #expect(d.machine.state == .expanded)
    }

    @Test func machineIsAValueSoInterruptionsCanBeReplayed() {
        var a = NotchStateMachine()
        a.send(.click, now: t0)
        var b = a
        b.send(.escape, now: t0)
        #expect(a.state == .expanded && b.state == .closed)
    }
}
