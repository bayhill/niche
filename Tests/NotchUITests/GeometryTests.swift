import CoreGraphics
import NotchCore
import NotchCoreTesting
import Testing
@testable import NotchUI

private struct Fixture: CustomTestStringConvertible, Sendable {
    let name: String
    let metrics: ScreenMetrics
    let simulated: CGSize?
    let notch: CGRect
    /// A real notch (or a simulated one), as opposed to the default virtual pill on a notchless display.
    var claimsClosed: Bool { metrics.hasNotch || simulated != nil }
    var testDescription: String { name }
}

private let fixtures: [Fixture] = [
    Fixture(name: "mbp14MoreSpace", metrics: .mbp14MoreSpace, simulated: nil, notch: CGRect(x: 790, y: 1131, width: 220, height: 38)),
    Fixture(name: "mbp14Default", metrics: .mbp14Default, simulated: nil, notch: CGRect(x: 663.5, y: 950, width: 185, height: 32)),
    Fixture(name: "external1080p", metrics: .external1080p, simulated: nil, notch: CGRect(x: 1512 + 960 - 90, y: 1056, width: 180, height: 24)),
    Fixture(name: "externalHiddenMenuBar", metrics: .externalHiddenMenuBar, simulated: nil, notch: CGRect(x: 1190, y: 1416, width: 180, height: 24)),
    Fixture(name: "simulated 200x32 on mbp14MoreSpace", metrics: .mbp14MoreSpace, simulated: CGSize(width: 200, height: 32), notch: CGRect(x: 800, y: 1137, width: 200, height: 32)),
]

private func layout(_ f: Fixture, _ state: NotchState, activity: Bool = true) -> NotchLayout {
    NotchGeometry.layout(metrics: f.metrics, state: state, hasActivity: activity, simulatedNotch: f.simulated)
}

@Suite("Geometry")
struct GeometryTests {
    @Test(arguments: fixtures)
    fileprivate func notchRectAndClosedHitRectMatchTheNotch(_ f: Fixture) {
        let closed = layout(f, .closed, activity: false)
        #expect(closed.notchRect == f.notch)
        #expect(closed.visibleRect == f.notch)
        #expect(closed.shapeRect.size == f.notch.size)
        #expect(closed.glassAmount == 0)
        if f.claimsClosed {
            #expect(closed.hitRect == f.notch)
            #expect(closed.surfaceOpacity == 1)
        } else {
            // Notchless display: the closed virtual notch is not drawn and never takes the pointer or a click.
            #expect(closed.hitRect.isNull)
            #expect(closed.surfaceOpacity == 0)
            #expect(!closed.hits(CGPoint(x: f.notch.midX, y: f.notch.midY)))
            #expect(!closed.hits(CGPoint(x: f.notch.midX, y: f.notch.maxY)))
        }
    }

    @Test(arguments: fixtures)
    fileprivate func everyStateHasTheSpecifiedSize(_ f: Fixture) {
        let n = f.notch.size
        let closedTop = Tokens.Radius.notchClosedTop, openTop = Tokens.Radius.notchOpenTop
        let activityWidth = n.width + 2 * PanelLayout.wingWidth + 2 * closedTop
        #expect(layout(f, .activity).shapeRect.size == CGSize(width: activityWidth, height: n.height))
        #expect(layout(f, .hover, activity: true).shapeRect.size
            == CGSize(width: activityWidth + PanelLayout.hoverGrowth.width, height: n.height + PanelLayout.hoverGrowth.height))
        #expect(layout(f, .hover, activity: false).shapeRect.size
            == CGSize(width: n.width + PanelLayout.hoverGrowth.width, height: n.height + PanelLayout.hoverGrowth.height))
        #expect(layout(f, .drop).shapeRect.size
            == CGSize(width: PanelLayout.dropSize.width + 2 * openTop, height: n.height + PanelLayout.dropSize.height))
        #expect(layout(f, .expanded).shapeRect.size
            == CGSize(width: PanelLayout.expandedSize.width + 2 * openTop, height: n.height + PanelLayout.expandedSize.height))
        #expect(layout(f, .expanded).bodyWidth == PanelLayout.expandedSize.width)
        #expect(layout(f, .drop).bodyWidth == PanelLayout.dropSize.width)
    }

    @Test(arguments: fixtures)
    fileprivate func wingsAreExactlyWingWidthBesideTheNotch(_ f: Fixture) {
        let a = layout(f, .activity)
        #expect((a.bodyWidth - f.notch.width) / 2 == PanelLayout.wingWidth)
        #expect(a.visibleRect.minX == f.notch.minX - PanelLayout.wingWidth - Tokens.Radius.notchClosedTop)
        #expect(a.visibleRect.maxX == f.notch.maxX + PanelLayout.wingWidth + Tokens.Radius.notchClosedTop)
        // The wings are visual only: just the notch takes the pointer, on every kind of display.
        #expect(a.hitRect == f.notch)
        #expect(a.surfaceOpacity == 1)
    }

    @Test(arguments: fixtures)
    fileprivate func radiiAndGlassPerState(_ f: Fixture) {
        for state in NotchState.allCases {
            let l = layout(f, state)
            #expect(l.topRadius == (state.isOpen ? Tokens.Radius.notchOpenTop : Tokens.Radius.notchClosedTop))
            #expect(l.bottomRadius == (state.isOpen ? Tokens.Radius.notchOpenBottom : Tokens.Radius.notchClosedBottom))
            #expect(l.glassAmount == (state.isOpen ? 1 : 0))
        }
    }

    @Test(arguments: fixtures)
    fileprivate func windowIsFixedFlushWithTheTopAndHoldsEveryStateWithMargin(_ f: Fixture) {
        let frames = Set(NotchState.allCases.map { layout(f, $0).windowFrame })
        #expect(frames.count == 1)
        let window = frames.first!
        #expect(window.maxY == f.metrics.frame.maxY)
        #expect(f.metrics.frame.contains(window))
        for state in NotchState.allCases {
            let l = layout(f, state)
            // Shape rect (window space) and visible rect (global) describe the same place.
            #expect(window.minX + l.shapeRect.minX == l.visibleRect.minX)
            #expect(window.maxY - l.shapeRect.minY == l.visibleRect.maxY)
            #expect(l.shapeRect.size == l.visibleRect.size)
            // Centred on the notch and hanging from the top of the screen.
            #expect(l.visibleRect.midX == f.notch.midX)
            #expect(l.visibleRect.maxY == f.metrics.frame.maxY)
            // Room for spring overshoot on every side but the top.
            let slack = window.insetBy(dx: NotchGeometry.windowMargin / 2, dy: 0)
            #expect(slack.minX <= l.visibleRect.minX && slack.maxX >= l.visibleRect.maxX)
            #expect(window.minY + NotchGeometry.windowMargin / 2 <= l.visibleRect.minY)
            // Whatever takes the pointer is inside what is drawn.
            if !l.hitRect.isNull { #expect(l.visibleRect.contains(l.hitRect)) }
        }
    }

    @Test(arguments: fixtures)
    fileprivate func everyStatesHitRectIsItsInteractivePartOnly(_ f: Fixture) {
        for state in NotchState.allCases {
            let l = layout(f, state)
            switch state {
            case .closed: #expect(l.hitRect == (f.claimsClosed ? f.notch : .null))
            case .activity: #expect(l.hitRect == f.notch)
            case .hover, .drop, .expanded: #expect(l.hitRect == l.visibleRect)
            }
            guard !l.hitRect.isNull else { continue }
            let r = l.hitRect
            #expect(l.hits(CGPoint(x: r.midX, y: r.midY)))
            // Pointer pinned against the top edge of the screen still hits.
            #expect(l.hits(CGPoint(x: r.midX, y: r.maxY)))
            // Just outside, on every side, passes through.
            #expect(!l.hits(CGPoint(x: r.minX - 0.5, y: r.midY)))
            #expect(!l.hits(CGPoint(x: r.maxX + 0.5, y: r.midY)))
            #expect(!l.hits(CGPoint(x: r.midX, y: r.minY - 0.5)))
            // Most of the window is click-through.
            #expect(!l.hits(CGPoint(x: l.windowFrame.minX + 1, y: l.windowFrame.minY + 1)))
        }
    }

    @Test func menuBarItemsBesideTheClosedNotchStayClickable() {
        let m = ScreenMetrics.mbp14MoreSpace
        let closed = NotchGeometry.layout(metrics: m, state: .closed)
        let activity = NotchGeometry.layout(metrics: m, state: .activity, hasActivity: true)
        let y = m.frame.maxY - 19
        // Status items right next to the notch.
        #expect(!closed.hits(CGPoint(x: m.auxLeft!.maxX - 1, y: y)))
        #expect(!closed.hits(CGPoint(x: m.auxRight!.minX + 1, y: y)))
        // With an activity showing, the wings are drawn over the menu bar but clicks there pass through.
        #expect(activity.visibleRect.contains(CGPoint(x: 790 - 30, y: y)))
        #expect(!activity.hits(CGPoint(x: 790 - 30, y: y)))
        #expect(!activity.hits(CGPoint(x: 1010 + 30, y: y)))
        #expect(!activity.hits(CGPoint(x: 790 - 0.5, y: y)))
        #expect(activity.hits(CGPoint(x: 900, y: y)))
        // App menus at the far left and right are never covered by any state.
        for state in NotchState.allCases {
            let l = NotchGeometry.layout(metrics: m, state: state, hasActivity: true)
            #expect(!l.hits(CGPoint(x: 300, y: y)))
            #expect(!l.hits(CGPoint(x: 1500, y: y)))
        }
    }

    @Test func aNotchlessMenuBarIsUntouchedUntilSomethingShows() {
        let m = ScreenMetrics.external1080p
        let notch = m.effectiveNotchRect()
        let centre = CGPoint(x: notch.midX, y: notch.midY)
        #expect(!NotchGeometry.layout(metrics: m, state: .closed).hits(centre))
        #expect(NotchGeometry.layout(metrics: m, state: .activity, hasActivity: true).hits(centre))
        #expect(NotchGeometry.layout(metrics: m, state: .expanded).hits(centre))
        #expect(NotchGeometry.layout(metrics: m, state: .drop).hits(centre))
        // A drag can still open the drop target there.
        #expect(NotchGeometry.isNearForDrop(CGPoint(x: centre.x, y: centre.y - 60), layout: NotchGeometry.layout(metrics: m, state: .closed)))
    }

    @Test func dumpForTheDevMachine() {
        let l = NotchGeometry.layout(metrics: .mbp14MoreSpace, state: .expanded, hasActivity: true)
        #expect(l.windowFrame == CGRect(x: 510, y: 891, width: 780, height: 278))
        #expect(l.hitRect == CGRect(x: 546, y: 927, width: 708, height: 242))
        #expect(l.visibleRect == l.hitRect)
        #expect(l.shapeRect == CGRect(x: 36, y: 0, width: 708, height: 242))
        #expect(l.centerOffset == 0)
    }

    @Test func windowIsClampedInsideANarrowScreen() {
        let narrow = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 600, height: 400), visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 375),
            safeTop: 0, auxLeft: nil, auxRight: nil
        )
        let l = NotchGeometry.layout(metrics: narrow, state: .expanded)
        #expect(l.windowFrame.minX >= 0 && l.windowFrame.maxX <= 600)
        #expect(l.hitRect.midX == 300)
    }

    @Test func dropProximity() {
        let m = ScreenMetrics.mbp14MoreSpace
        let closed = NotchGeometry.layout(metrics: m, state: .closed)
        let drop = NotchGeometry.layout(metrics: m, state: .drop)
        let notch = closed.notchRect
        #expect(NotchGeometry.isNearForDrop(CGPoint(x: notch.midX, y: notch.minY - 100), layout: closed))
        #expect(NotchGeometry.isNearForDrop(CGPoint(x: notch.maxX + 119, y: notch.midY), layout: closed))
        #expect(!NotchGeometry.isNearForDrop(CGPoint(x: notch.midX, y: notch.minY - 121), layout: closed))
        #expect(!NotchGeometry.isNearForDrop(CGPoint(x: notch.maxX + 100, y: notch.minY - 100), layout: closed))
        // Every point of the open drop target counts as near, so it cannot flicker shut under the pointer.
        let r = drop.visibleRect
        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY - 10)] {
            #expect(NotchGeometry.isNearForDrop(p, layout: drop))
        }
        #expect(NotchGeometry.distance(from: CGPoint(x: 0, y: 0), to: CGRect(x: 3, y: 4, width: 1, height: 1)) == 5)
        #expect(NotchGeometry.distance(from: CGPoint(x: 3.5, y: 4.5), to: CGRect(x: 3, y: 4, width: 1, height: 1)) == 0)
    }
}

@Suite("Dashboard layout")
struct DashboardLayoutTests {
    let area = PanelLayout.pageSize

    @Test func allSlotsUseTheirCardSizesAndFitTheArea() {
        let frames = DashboardLayout.frames(for: Set(DashboardSlot.allCases))
        #expect(frames.count == 4)
        for slot in DashboardSlot.allCases {
            let f = frames[slot]!
            #expect(f.size == PanelLayout.cardSize(for: slot))
            #expect(CGRect(origin: .zero, size: area).contains(f))
        }
        let lt = frames[.leadingTop]!, lb = frames[.leadingBottom]!, c = frames[.center]!, t = frames[.trailing]!
        #expect(lt.minX == lb.minX && lt.minY == 0)
        #expect(lb.minY == lt.maxY + PanelLayout.gap)
        #expect(c.minX == lt.maxX + PanelLayout.gap)
        #expect(t.minX == c.maxX + PanelLayout.gap)
        #expect(c.minY == 0 && t.minY == 0)
    }

    @Test func missingColumnsAreRemovedAndTheRestCentred() {
        let frames = DashboardLayout.frames(for: [.center, .trailing])
        let c = frames[.center]!, t = frames[.trailing]!
        #expect(t.minX - c.maxX == PanelLayout.gap)
        let left = c.minX, right = area.width - t.maxX
        #expect(abs(left - right) <= 1)

        let single = DashboardLayout.frames(for: [.trailing])[.trailing]!
        #expect(abs(single.midX - area.width / 2) <= 1)
    }

    @Test func aLoneLeadingCardKeepsItsSizeAndRow() {
        let top = DashboardLayout.frames(for: [.leadingTop, .center])[.leadingTop]!
        #expect(top.minY == 0 && top.size == PanelLayout.cardSize(for: .leadingTop))
        let bottom = DashboardLayout.frames(for: [.leadingBottom, .center])[.leadingBottom]!
        #expect(bottom.maxY == area.height && bottom.size == PanelLayout.cardSize(for: .leadingBottom))
    }

    @Test func nothingToLayOut() {
        #expect(DashboardLayout.frames(for: []).isEmpty)
    }
}

@Suite("Fullscreen detection")
struct FullscreenTests {
    let me: pid_t = 1
    let app: pid_t = 42
    let windowServer: pid_t = 99

    func menuBar(width: CGFloat, height: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> WindowSnapshot {
        WindowSnapshot(ownerPID: windowServer, layer: FullscreenDetector.menuBarLayer, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    func decide(_ windows: [WindowSnapshot], _ screen: ScreenMetrics, primaryHeight: CGFloat) -> Bool {
        FullscreenDetector.isFullscreen(windows: windows, screen: screen, primaryHeight: primaryHeight, ownPID: me)
    }

    @Test func normalDesktopIsNotFullscreen() {
        let browser = WindowSnapshot(ownerPID: app, layer: 0, bounds: CGRect(x: 200, y: 120, width: 1100, height: 800))
        #expect(!decide([menuBar(width: 1800, height: 39), browser], .mbp14MoreSpace, primaryHeight: 1169))
    }

    @Test func aZoomedWindowOnANotchedDisplayIsNotFullscreen() {
        // Same bounds a fullscreen window gets below the camera housing, but the menu bar is there.
        let zoomed = WindowSnapshot(ownerPID: app, layer: 0, bounds: CGRect(x: 0, y: 38, width: 1800, height: 1131))
        #expect(!decide([menuBar(width: 1800, height: 39), zoomed], .mbp14MoreSpace, primaryHeight: 1169))
    }

    @Test func realFullscreenOnANotchedDisplay() {
        let full = WindowSnapshot(ownerPID: app, layer: 0, bounds: CGRect(x: 0, y: 38, width: 1800, height: 1131))
        #expect(decide([full], .mbp14MoreSpace, primaryHeight: 1169))
        // Our own window never counts, nor do overlays at other layers.
        let ours = WindowSnapshot(ownerPID: me, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1800, height: 1169))
        let overlay = WindowSnapshot(ownerPID: app, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1800, height: 1169))
        #expect(!decide([ours, overlay], .mbp14MoreSpace, primaryHeight: 1169))
    }

    @Test func fullscreenOnANotchlessDisplay() {
        let ext = ScreenMetrics.external1080p
        // Secondary display to the right of a 982 pt tall primary: CG y = 982 - 1080.
        let full = WindowSnapshot(ownerPID: app, layer: 0, bounds: CGRect(x: 1512, y: -98, width: 1920, height: 1080))
        #expect(decide([full], ext, primaryHeight: 982))
        // The primary's menu bar does not count for this screen.
        #expect(decide([menuBar(width: 1512, height: 32), full], ext, primaryHeight: 982))
        // Its own menu bar does.
        #expect(!decide([menuBar(width: 1920, height: 25, x: 1512, y: -98), full], ext, primaryHeight: 982))
        // A window that leaves the menu-bar strip uncovered is not fullscreen even with the menu bar hidden.
        let zoomed = WindowSnapshot(ownerPID: app, layer: 0, bounds: CGRect(x: 1512, y: -73, width: 1920, height: 1055))
        #expect(!decide([zoomed], ext, primaryHeight: 982))
    }
}

@Suite("Frame stats")
struct FrameStatsTests {
    @Test func steadyFramesDropNothing() {
        var stats = FrameStats()
        for i in 0..<120 { stats.record(timestamp: Double(i) / 120, frameInterval: 1.0 / 120) }
        #expect(stats.frames == 120 && stats.dropped == 0)
        #expect(abs(stats.worst - 1.0 / 120) < 1e-9)
    }

    @Test func aLongGapCountsTheMissedVsyncs() {
        var stats = FrameStats()
        stats.record(timestamp: 0, frameInterval: 1.0 / 120)
        stats.record(timestamp: 3.0 / 120, frameInterval: 1.0 / 120)
        #expect(stats.dropped == 2)
        stats.resetWorst()
        #expect(stats.worst == 0)
    }
}
