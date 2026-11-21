import SwiftUI

public enum GlassProminence: Sendable { case standard, accent }

/// Capsule button in interactive Liquid Glass.
public struct GlassButtonStyle: ButtonStyle {
    private let prominence: GlassProminence
    public init(prominence: GlassProminence = .standard) { self.prominence = prominence }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tokens.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(glass, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .motion(Motion.press, value: configuration.isPressed)
            .contentShape(.capsule)
    }

    private var glass: Glass {
        switch prominence {
        case .standard: .regular.interactive()
        case .accent: .regular.tint(Tokens.Colors.accent.opacity(0.75)).interactive()
        }
    }
}

/// Circular icon button in interactive Liquid Glass.
public struct GlassIconButtonStyle: ButtonStyle {
    private let size: CGFloat
    private let tint: TintRole
    public init(size: CGFloat = 28, tint: TintRole = .primary) { self.size = size; self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint.color)
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .circle)
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .motion(Motion.press, value: configuration.isPressed)
            .contentShape(.circle)
    }
}

/// Borderless icon button with a hover fill, for dense rows and the panel's top band.
public struct PlainIconButtonStyle: ButtonStyle {
    private let size: CGFloat
    private let tint: TintRole
    public init(size: CGFloat = 24, tint: TintRole = .secondary) { self.size = size; self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View { PlainIconLabel(configuration: configuration, size: size, tint: tint) }

    private struct PlainIconLabel: View {
        let configuration: Configuration
        let size: CGFloat
        let tint: TintRole
        @State private var hovering = false
        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(hovering ? Tokens.Colors.textPrimary : tint.color)
                .frame(width: size, height: size)
                .background(hovering ? Tokens.Colors.cardFillHover : .clear, in: .circle)
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .motion(Motion.press, value: configuration.isPressed)
                .motion(Motion.quick, value: hovering)
                .onHover { hovering = $0 }
                .contentShape(.circle)
        }
    }
}

public struct GlassButton: View {
    private let title: String
    private let symbol: String?
    private let prominence: GlassProminence
    private let action: () -> Void

    public init(_ title: String, symbol: String? = nil, prominence: GlassProminence = .standard, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.prominence = prominence; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .buttonStyle(GlassButtonStyle(prominence: prominence))
    }
}

public struct GlassIconButton: View {
    public enum Kind: Sendable { case glass, plain }
    private let symbol: String
    private let label: String
    private let kind: Kind
    private let size: CGFloat
    private let tint: TintRole
    private let action: () -> Void

    /// - Parameter label: accessibility label and tooltip.
    public init(
        _ symbol: String, label: String, kind: Kind = .glass, size: CGFloat = 28, tint: TintRole = .primary,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol; self.label = label; self.kind = kind; self.size = size; self.tint = tint; self.action = action
    }

    public var body: some View {
        let button = Button(action: action) { Label(label, systemImage: symbol) }
        Group {
            switch kind {
            case .glass: button.buttonStyle(GlassIconButtonStyle(size: size, tint: tint))
            case .plain: button.buttonStyle(PlainIconButtonStyle(size: size, tint: tint))
            }
        }
        .help(label)
    }
}

/// Makes a whole row/card behave like a button: hover fill and press scale. For "click to reveal in Finder" rows.
public struct RowButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { RowLabel(configuration: configuration) }

    private struct RowLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(hovering ? Tokens.Colors.cardFillHover : .clear, in: shape)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .motion(Motion.press, value: configuration.isPressed)
                .motion(Motion.quick, value: hovering)
                .onHover { hovering = $0 }
                .contentShape(shape)
        }
    }
}
