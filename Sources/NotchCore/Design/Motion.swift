import AppKit
import SwiftUI

/// The only animation curves in the app. Everything is a spring so any transition can be interrupted
/// and reversed mid-flight without a visible jump.
public enum Motion {
    /// Notch expanding.
    public static let open = Animation.spring(response: 0.42, dampingFraction: 0.80)
    /// Notch collapsing (critically damped: no bounce on the way back into the hardware).
    public static let close = Animation.spring(response: 0.45, dampingFraction: 1.0)
    /// Elements changing size/position or morphing between states.
    public static let morph = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Press feedback on controls.
    public static let press = Animation.spring(response: 0.22, dampingFraction: 0.70)
    /// Content arriving.
    public static let appear = Animation.spring(response: 0.50, dampingFraction: 0.86)
    /// Small state changes (hover fills, tint changes).
    public static let quick = Animation.easeOut(duration: 0.16)
    /// Used instead of every spring when Reduce Motion is on.
    public static let reduced = Animation.easeInOut(duration: 0.20)

    /// Delay between consecutive items arriving.
    public static let staggerStep = 0.035

    public static func stagger(_ index: Int) -> Animation {
        appear.delay(0.06 + Double(max(0, index)) * staggerStep)
    }

    public static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    @MainActor public static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `withAnimation` that honours Reduce Motion. Use for state changes made outside a view body.
    @MainActor public static func animate(_ animation: Animation, _ changes: () -> Void) {
        withAnimation(resolve(animation, reduceMotion: systemReduceMotion), changes)
    }
}

private struct MotionAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 5)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
            .offset(y: shown || reduceMotion ? 0 : 4)
            .onAppear {
                withAnimation(reduceMotion ? Motion.reduced : Motion.stagger(index)) { shown = true }
            }
    }
}

private struct ValueMotion<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(Motion.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}

public extension View {
    /// Fade, un-blur and settle into place when the view appears. Pass the item's position for a stagger.
    func motionAppear(_ index: Int = 0) -> some View { modifier(MotionAppear(index: index)) }

    /// `.animation(_:value:)` that honours Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ValueMotion(animation: animation, value: value))
    }
}

/// Trackpad haptics. No-ops on hardware without a Force Touch trackpad.
@MainActor
public enum Haptics {
    /// A light tick: drag entered the target, item snapped.
    public static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    /// A firmer tap: work finished.
    public static func success() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}
