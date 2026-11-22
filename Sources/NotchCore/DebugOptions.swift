import CoreGraphics
import Foundation

/// Launch arguments for development and automated verification.
///
///     --simulate-notch 220x38   draw a virtual notch of this size (also on notched displays)
///     --force-state expanded    pin the notch state: closed | activity | hover | nudge | drop | expanded
///     --page shelf              with --force-state expanded: open this module's page
///     --dump-metrics            print screen metrics and the computed layout, then continue
///     --demo                    cycle through every state automatically
///     --fps                     show a frame-time overlay
///     --fixtures                modules show built-in sample data instead of live data
public struct DebugOptions: Sendable, Equatable {
    public var simulateNotch: CGSize?
    public var forceState: String?
    public var page: ModuleID?
    public var dumpMetrics = false
    public var demo = false
    public var fps = false
    public var fixtures = false

    public init() {}

    public init(arguments: [String]) {
        var it = arguments.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--simulate-notch":
                if let v = it.next() {
                    let parts = v.lowercased().split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2, parts[0] > 0, parts[1] > 0 { simulateNotch = CGSize(width: parts[0], height: parts[1]) }
                }
            case "--force-state": forceState = it.next()
            case "--page": page = it.next().map(ModuleID.init(_:))
            case "--dump-metrics": dumpMetrics = true
            case "--demo": demo = true
            case "--fps": fps = true
            case "--fixtures": fixtures = true
            default: break
            }
        }
    }

    public static var fromProcess: DebugOptions { DebugOptions(arguments: Array(CommandLine.arguments.dropFirst())) }
}
