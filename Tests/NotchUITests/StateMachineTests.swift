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

    // MARK: Nudge

    @Test func restStateIsTheNudgeThenTheActivityThenNothing() {
        #expect(NotchStateMachine().restState == .closed)
        #expect(NotchStateMachine(hasActivity: true).restState == .activity)
        #expect(NotchStateMachine(hasNudge: true).restState == .nudge)
        #expect(NotchStateMachine(hasActivity: true, hasNudge: true).restState == .nudge)
    }

    @Test func aNudgeGrowsTheNotchFromRestAndFromHover() {
        for setup in [NotchState.closed, .activity, .hover] {
            var d = Driver(NotchStateMachine(state: setup, hasActivity: setup != .closed))
            d.send(.nudgeChanged(true))
            #expect(d.state == .nudge, "\(setup)")
            #expect(d.machine.hasNudge)
            #expect(d.machine.deadlines.isEmpty)
        }
    }

    @Test func aNudgeDuringTheDwellCancelsIt() {
        var d = Driver()
        d.send(.pointerEntered)
        d.now = at(0.05)
        #expect(d.send(.nudgeChanged(true)) == [.cancel(.dwell)])
        d.wait(1)
        #expect(d.state == .nudge)
    }

    @Test func thePointerComingAndGoingNeitherSwellsNorClosesTheNudge() {
        for openOnHover in [false, true] {
            var d = Driver(NotchStateMachine(openOnHover: openOnHover))
            d.send(.nudgeChanged(true))
            #expect(d.send(.pointerEntered) == [])
            #expect(d.machine.pointerInside)
            d.wait(1)
            #expect(d.state == .nudge)
            #expect(d.send(.pointerExited) == [])
            #expect(!d.machine.pointerInside)
            d.wait(1)
            #expect(d.state == .nudge)
        }
    }

    @Test func clicksEscapeAndClickOutsideLeaveTheNudgeAlone() {
        for event in [NotchEvent.click, .escape, .clickOutside, .collapse, .selectPage(.shelf), .ownDragBegan] {
            var d = Driver(NotchStateMachine(hasActivity: true))
            d.send(.nudgeChanged(true))
            #expect(d.send(event) == [], "\(event)")
            #expect(d.state == .nudge, "\(event)")
            #expect(!d.machine.ownDragInFlight)
        }
    }

    @Test func hotkeyFromTheNudgeOpensThePanelAndClosingItReturnsToTheNudge() {
        var d = Driver(NotchStateMachine(hasActivity: true))
        d.send(.nudgeChanged(true))
        #expect(d.send(.hotkey) == [.schedule(.idle, at: d.now + NotchStateMachine.idleDelay)])
        #expect(d.state == .expanded && d.machine.transient && d.machine.page == nil)
        d.send(.hotkey)
        #expect(d.state == .nudge)
        #expect(d.machine.deadlines.isEmpty)
        // Ignored, the hotkey panel closes by itself back onto the nudge.
        d.send(.toggle)
        #expect(d.state == .expanded)
        d.wait(4)
        #expect(d.state == .nudge)
        // The API opens a page from it too.
        d.send(.expand(page: .shelf))
        #expect(d.state == .expanded && d.machine.page == .shelf)
        d.send(.collapse)
        #expect(d.state == .nudge)
    }

    @Test func aNudgeArrivingWhileExpandedShowsWhenThePanelCloses() {
        for close in [NotchEvent.escape, .clickOutside, .hotkey, .toggle, .collapse] {
            var d = Driver(NotchStateMachine(state: .expanded, page: .shelf, hasActivity: true))
            #expect(d.send(.nudgeChanged(true)) == [])
            #expect(d.state == .expanded && d.machine.page == .shelf, "\(close)")
            #expect(d.machine.hasNudge)
            d.send(close)
            #expect(d.state == .nudge, "\(close)")
        }
    }

    @Test func aTransientPanelClosingByItselfLandsOnThePendingNudge() {
        var d = Driver(NotchStateMachine(openOnHover: true))
        d.send(.pointerEntered)
        d.wait(0.12)
        #expect(d.state == .expanded && d.machine.transient)
        d.send(.nudgeChanged(true))
        d.send(.pointerExited)
        d.wait(0.3)
        #expect(d.state == .nudge)
    }

    @Test func aNudgeClearedWhileExpandedLeavesNothingBehind() {
        var d = Driver(NotchStateMachine(state: .expanded, hasActivity: true))
        d.send(.nudgeChanged(true))
        d.send(.nudgeChanged(false))
        #expect(d.state == .expanded)
        #expect(!d.machine.hasNudge)
        d.send(.escape)
        #expect(d.state == .activity)
    }

    @Test func aNudgeArrivingDuringADropShowsAfterIt() {
        // Dropped.
        var dropped = Driver(NotchStateMachine(hasActivity: true))
        dropped.send(.activityChanged(true))
        dropped.send(.dragNear)
        dropped.send(.nudgeChanged(true))
        #expect(dropped.state == .drop)
        dropped.send(.dropTargetEntered)
        dropped.send(.dropped)
        #expect(dropped.state == .nudge)

        // Cancelled.
        var cancelled = Driver()
        cancelled.send(.dragNear)
        cancelled.send(.nudgeChanged(true))
        cancelled.send(.dragFar)
        #expect(cancelled.state == .nudge)

        // Released over the target, the grace runs out.
        var released = Driver()
        released.send(.dragNear)
        released.send(.dropTargetEntered)
        released.send(.nudgeChanged(true))
        released.send(.dragEnded)
        #expect(released.state == .drop)
        released.wait(0.3)
        #expect(released.state == .nudge)
        // A late drop still lands and leaves the nudge up.
        #expect(released.machine.acceptsDrop(now: released.now))
        released.send(.dropped)
        #expect(released.state == .nudge)
    }

    @Test func aDropCancelledOverTheExpandedPanelReturnsToThePanelThenToTheNudge() {
        var d = Driver(NotchStateMachine(state: .expanded, page: .shelf))
        d.send(.dragNear)
        d.send(.nudgeChanged(true))
        d.send(.dragFar)
        #expect(d.state == .expanded && d.machine.page == .shelf)
        d.send(.escape)
        #expect(d.state == .nudge)
    }

    @Test func aDragFromTheNudgeOpensTheDropTargetWithNothingToResume() {
        var d = Driver(NotchStateMachine(hasActivity: true))
        d.send(.nudgeChanged(true))
        d.send(.dragNear)
        #expect(d.state == .drop)
        d.send(.dragFar)
        #expect(d.state == .nudge)
        d.send(.dragNear)
        d.send(.dropTargetEntered)
        d.send(.dropped)
        #expect(d.state == .nudge)
    }

    @Test func activityChangesWhileNudgingApplyWhenItIsAnswered() {
        var d = Driver()
        d.send(.nudgeChanged(true))
        d.send(.activityChanged(true))
        #expect(d.state == .nudge && d.machine.hasActivity)
        d.send(.activityChanged(false))
        d.send(.activityChanged(true))
        #expect(d.state == .nudge)
        d.send(.nudgeChanged(false))
        #expect(d.state == .activity)
        d.send(.nudgeChanged(true))
        d.send(.activityChanged(false))
        d.send(.nudgeChanged(false))
        #expect(d.state == .closed)
    }

    @Test func aRepeatedNudgeChangeIsHarmless() {
        var d = Driver()
        d.send(.nudgeChanged(true))
        #expect(d.send(.nudgeChanged(true)) == [])
        #expect(d.state == .nudge)
        d.send(.nudgeChanged(false))
        #expect(d.send(.nudgeChanged(false)) == [])
        #expect(d.state == .closed)
    }

    @Test func aNudgeTakesOverTheBarMidwayThroughDraggingItsFilesOut() {
        var m = NotchStateMachine(state: .hover, hasActivity: true)
        m.send(.pointerEntered, now: t0)
        m.send(.ownDragBegan, now: t0)
        m.send(.nudgeChanged(true), now: t0)
        #expect(m.state == .nudge)
        // Still our own drag: it never opens the drop target.
        #expect(m.send(.dragNear, now: t0) == [])
        m.send(.ownDragEnded(accepted: false), now: t0)
        #expect(m.state == .nudge && !m.ownDragInFlight)
    }

    @Test func theNudgeFlagChangesWhatIsDrawnAndTheValue() {
        let a = NotchStateMachine(state: .expanded)
        var b = a
        b.send(.nudgeChanged(true), now: t0)
        #expect(a != b)
        #expect(a.visual != b.visual)
        #expect(a.state == b.state)
    }

    @Test func aNudgeArrivesOnlyWhenItsIdChanges() {
        let sample = Nudge.sample()
        var updated = sample
        updated.message = "Starting now"
        var other = sample
        other.id = "other"
        #expect(NudgeArrival.isNew(sample, after: nil))
        #expect(NudgeArrival.isNew(other, after: sample))
        #expect(!NudgeArrival.isNew(updated, after: sample))
        #expect(!NudgeArrival.isNew(sample, after: sample))
        #expect(!NudgeArrival.isNew(nil, after: sample))
        #expect(!NudgeArrival.isNew(nil, after: nil))
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
            ("nudge+", .nudgeChanged(true)), ("nudge-", .nudgeChanged(false)),
        ]
        // Expected state after each event, per starting state, with hasActivity = true (rest = .activity) and no
        // nudge pending, except in `.nudge`, which starts with one (rest = .nudge).
        let expected: [NotchState: [NotchState]] = [
            //            enter      exit       click      outside    esc        hotkey     expand     collapse   toggle     page       act+       act-     near   far        ended      in     out    dropped    nudge+     nudge-
            .closed:   [.closed,   .closed,   .expanded, .closed,   .closed,   .expanded, .expanded, .closed,   .expanded, .closed,   .activity, .closed, .drop, .closed,   .closed,   .closed, .closed, .closed,   .nudge,    .closed],
            .activity: [.activity, .activity, .expanded, .activity, .activity, .expanded, .expanded, .activity, .expanded, .activity, .activity, .closed, .drop, .activity, .activity, .activity, .activity, .activity, .nudge, .activity],
            .hover:    [.hover,    .activity, .expanded, .hover,    .activity, .expanded, .expanded, .activity, .expanded, .hover,    .hover,    .hover,  .drop, .hover,    .hover,    .hover, .hover, .hover,    .nudge,    .hover],
            .nudge:    [.nudge,    .nudge,    .nudge,    .nudge,    .nudge,    .expanded, .expanded, .nudge,    .expanded, .nudge,    .nudge,    .nudge,  .drop, .nudge,    .nudge,    .nudge,  .nudge,  .nudge,    .nudge,    .activity],
            .drop:     [.drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,     .drop,   .drop, .activity, .activity, .drop,  .drop,  .activity, .drop,      .drop],
            .expanded: [.expanded, .expanded, .expanded, .activity, .activity, .activity, .expanded, .activity, .activity, .expanded, .expanded, .expanded, .drop, .expanded, .expanded, .expanded, .expanded, .expanded, .expanded, .expanded],
        ]
        #expect(Set(expected.keys) == Set(NotchState.allCases))
        for (start, row) in expected {
            #expect(row.count == events.count, "\(start.rawValue)")
            for ((name, event), want) in zip(events, row) {
                // `.closed` with an activity is not a resting state, so it starts without one.
                var m = NotchStateMachine(state: start, hasActivity: start != .closed, hasNudge: start == .nudge)
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
