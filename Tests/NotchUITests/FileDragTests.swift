import CoreGraphics
import Foundation
import NotchCore
import Testing
@testable import NotchUI

@Suite("Dragging files out of the bar")
struct FileDragTests {
    let t0 = ContinuousClock.now
    let file = URL(fileURLWithPath: "/tmp/hero-banner.webp")

    // MARK: Click or drag

    @Test func withoutFilesAPressIsAClickAtOnce() {
        let press = BarPress(at: CGPoint(x: 100, y: 100), hasFiles: false)
        #expect(press.onPress == .click)
        #expect(press.onMove(to: CGPoint(x: 160, y: 100)) == .pending)
        #expect(press.onRelease == .pending)
    }

    @Test func withFilesTheThresholdDecides() {
        let press = BarPress(at: CGPoint(x: 100, y: 100), hasFiles: true)
        #expect(press.onPress == .pending)
        #expect(press.onMove(to: CGPoint(x: 103, y: 100)) == .pending)
        #expect(press.onMove(to: CGPoint(x: 100, y: 96)) == .pending)
        #expect(press.onMove(to: CGPoint(x: 103, y: 103)) == .drag)
        #expect(press.onMove(to: CGPoint(x: 100 - BarPress.dragThreshold - 0.1, y: 100)) == .drag)
        // Released before crossing the threshold: the click that expands.
        #expect(press.onRelease == .click)
    }

    // MARK: Own drags

    @Test func ourOwnDragNeverOpensTheDropTarget() {
        var m = NotchStateMachine(state: .activity, hasActivity: true)
        m.send(.pointerEntered, now: t0)
        m.send(.ownDragBegan, now: t0)
        #expect(m.ownDragInFlight)
        #expect(m.send(.dragNear, now: t0) == [])
        #expect(m.state == .activity)
        m.send(.ownDragEnded(accepted: true), now: t0)
        #expect(!m.ownDragInFlight)
        // Other drags work again afterwards.
        m.send(.dragNear, now: t0)
        #expect(m.state == .drop)
    }

    @Test func aDragCanOnlyStartFromTheBar() {
        for state in [NotchState.closed, .drop, .expanded] {
            var m = NotchStateMachine(state: state, hasActivity: true)
            m.send(.ownDragBegan, now: t0)
            #expect(!m.ownDragInFlight, "\(state)")
            #expect(m.state == state)
        }
        var hover = NotchStateMachine(state: .hover, hasActivity: true)
        hover.send(.ownDragBegan, now: t0)
        #expect(hover.ownDragInFlight)
    }

    @Test func leavingTheBarMidDragDoesNotEndHoverUntilTheDragIsOver() {
        var m = NotchStateMachine(state: .activity, hasActivity: true)
        m.send(.pointerEntered, now: t0)
        m.advance(to: t0 + NotchStateMachine.dwellDelay)
        #expect(m.state == .hover)
        m.send(.ownDragBegan, now: t0 + .seconds(1))
        m.send(.pointerExited, now: t0 + .seconds(1))
        #expect(m.state == .hover)
        // Dropped in Finder: settle back with the closing motion, never expand.
        m.send(.ownDragEnded(accepted: true), now: t0 + .seconds(2))
        #expect(m.state == .activity)
    }

    @Test func aCancelledDragLeavesTheStateSane() {
        // Esc during the drag cancels it: the session ends with no operation.
        var inside = NotchStateMachine(state: .hover, hasActivity: true)
        inside.send(.pointerEntered, now: t0)
        inside.send(.ownDragBegan, now: t0)
        inside.send(.ownDragEnded(accepted: false), now: t0)
        #expect(inside.state == .hover && !inside.ownDragInFlight && inside.deadlines.isEmpty)

        var outside = NotchStateMachine(state: .hover, hasActivity: true)
        outside.send(.pointerEntered, now: t0)
        outside.send(.ownDragBegan, now: t0)
        outside.send(.pointerExited, now: t0)
        outside.send(.ownDragEnded(accepted: false), now: t0)
        #expect(outside.state == .activity && !outside.ownDragInFlight)
        // A stray end without a begin changes nothing.
        #expect(outside.send(.ownDragEnded(accepted: true), now: t0) == [])
        #expect(outside.state == .activity)
        // The bar still clicks open afterwards.
        outside.send(.click, now: t0)
        #expect(outside.state == .expanded)
    }

    // MARK: Hold

    func activity(_ id: String, files: [URL], expired: Bool = false, priority: LiveActivity.Priority = .progress) -> LiveActivity {
        LiveActivity(
            id: id, module: .convert, priority: priority, leading: .symbol("checkmark.circle.fill"), files: files,
            expiresAt: expired ? Date.now.addingTimeInterval(-1) : nil, accessibilityLabel: id
        )
    }

    @Test func holdingNeedsFilesAndUse() {
        let done = activity("done", files: [file])
        let plain = activity("plain", files: [])
        #expect(ActivityHold.isHolding(displayed: done, pointerOnBar: true, ownDragInFlight: false, releaseAt: nil, now: t0))
        #expect(ActivityHold.isHolding(displayed: done, pointerOnBar: false, ownDragInFlight: true, releaseAt: nil, now: t0))
        #expect(ActivityHold.isHolding(displayed: done, pointerOnBar: false, ownDragInFlight: false, releaseAt: t0 + .milliseconds(300), now: t0))
        #expect(!ActivityHold.isHolding(displayed: done, pointerOnBar: false, ownDragInFlight: false, releaseAt: t0, now: t0 + .milliseconds(1)))
        #expect(!ActivityHold.isHolding(displayed: done, pointerOnBar: false, ownDragInFlight: false, releaseAt: nil, now: t0))
        #expect(!ActivityHold.isHolding(displayed: plain, pointerOnBar: true, ownDragInFlight: true, releaseAt: nil, now: t0))
        #expect(!ActivityHold.isHolding(displayed: nil, pointerOnBar: true, ownDragInFlight: true, releaseAt: nil, now: t0))
    }

    @Test func aHeldActivitySurvivesExpiryAndHigherPriorities() {
        let done = activity("done", files: [file], expired: true)
        let urgent = activity("claude", files: [], priority: .attention)
        // Held: stays, even expired and outranked.
        #expect(ActivityHold.select([done, urgent], now: .now, fullscreen: false, displayed: done, holding: true)?.id == "done")
        // Held after the module withdrew it: still the displayed one.
        #expect(ActivityHold.select([urgent], now: .now, fullscreen: false, displayed: done, holding: true)?.id == "done")
        // Released: back to the arbiter (expired dropped, attention wins).
        #expect(ActivityHold.select([done, urgent], now: .now, fullscreen: false, displayed: done, holding: false)?.id == "claude")
        #expect(ActivityHold.select([done], now: .now, fullscreen: false, displayed: done, holding: false) == nil)
        // The module's newer version of the held activity is shown.
        var newer = done
        newer.leadingText = "3 files ready"
        #expect(ActivityHold.select([newer], now: .now, fullscreen: false, displayed: done, holding: true)?.leadingText == "3 files ready")
    }

    // MARK: Hint

    @Test func theHintMentionsDraggingWhenThereAreFiles() {
        #expect(HoverHint.text(hasFiles: true) == "Drag out, or click to expand")
        #expect(HoverHint.text(hasFiles: false) == "Click to expand Notcher")
        #expect(HoverHint.text == "Click to expand Notcher")
    }
}
