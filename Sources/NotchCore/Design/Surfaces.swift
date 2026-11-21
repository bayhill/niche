import SwiftUI

/// The notch's background: pure black where it meets the hardware, melting into dark Liquid Glass below.
/// NotchUI draws exactly one of these behind everything; modules never use it.
public struct NotchSurface<S: Shape>: View {
    private let shape: S
    private let capHeight: CGFloat
    private let glassAmount: Double
    /// Distance over which the black cap fades into glass.
    public static var fadeHeight: CGFloat { 56 }

    /// - Parameters:
    ///   - shape: the animated notch outline.
    ///   - capHeight: height of the solid black band at the top (the notch height).
    ///   - glassAmount: 0 = solid black everywhere (closed notch), 1 = full glass below the cap (expanded).
    public init(shape: S, capHeight: CGFloat, glassAmount: Double) {
        self.shape = shape; self.capHeight = capHeight; self.glassAmount = min(1, max(0, glassAmount))
    }

    public var body: some View {
        let floor = 1 - glassAmount * (1 - Tokens.Colors.glassFloor)
        ZStack(alignment: .top) {
            Color.clear
                .glassEffect(.regular.tint(Tokens.Colors.glassTint), in: shape)
                .opacity(glassAmount > 0 ? 1 : 0)
            // One gradient with stops placed in points, so the surface can be any height (down to the bare notch).
            GeometryReader { proxy in
                let height = max(proxy.size.height, 1)
                let capStop = min(1, capHeight / height)
                let fadeStop = min(1, (capHeight + Self.fadeHeight) / height)
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: capStop),
                        .init(color: .black.opacity(floor), location: fadeStop),
                        .init(color: .black.opacity(floor), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(shape)
        }
    }
}

/// The standard container for a module's content: a faint lifted layer on the panel's glass.
/// Lays its children out as a leading-aligned `VStack`.
public struct GlassCard<Content: View>: View {
    private let padding: CGFloat
    private let spacing: CGFloat
    private let highlighted: Bool
    private let content: Content

    /// Children are stacked vertically, leading-aligned, and the card fills the frame it is given.
    /// - Parameters:
    ///   - spacing: vertical gap between children.
    ///   - highlighted: draws the accent outline (active drop target, selected item).
    public init(
        padding: CGFloat = Tokens.Spacing.m, spacing: CGFloat = Tokens.Spacing.s, highlighted: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding; self.spacing = spacing; self.highlighted = highlighted; self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(highlighted ? Tokens.Colors.accent.opacity(0.14) : Tokens.Colors.cardFill, in: shape)
            .overlay {
                shape.strokeBorder(highlighted ? Tokens.Colors.accent : Tokens.Colors.cardStroke, lineWidth: highlighted ? 1.5 : 1)
            }
            .scaleEffect(highlighted ? 1.015 : 1)
            .motion(Motion.morph, value: highlighted)
            .contentShape(shape)
    }
}

// MARK: - Shared element ("hero") transitions between a wing glyph and a module's card

public extension EnvironmentValues {
    /// Set by NotchUI on the whole notch hierarchy. `nil` outside it (previews, Settings).
    @Entry var notchNamespace: Namespace.ID? = nil
}

private struct NotchHero: ViewModifier {
    let module: ModuleID
    @Environment(\.notchNamespace) private var namespace
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "hero.\(module.rawValue)", in: namespace)
        } else {
            content
        }
    }
}

public extension View {
    /// Marks the one element in a module's panel view (album art, progress ring, status badge) that its live-activity
    /// glyph should fly into when the notch expands. NotchUI applies the same id to the wing's leading glyph.
    func notchHero(_ module: ModuleID) -> some View { modifier(NotchHero(module: module)) }
}
