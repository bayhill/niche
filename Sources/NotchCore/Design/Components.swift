import SwiftUI

/// Small heading at the top of a card: optional symbol, label text, optional trailing accessory.
public struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let symbol: String?
    private let trailing: Trailing

    public init(_ title: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.symbol = symbol; self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.Colors.textTertiary)
            }
            Text(title.uppercased()).notchStyle(.label).lineLimit(1)
            Spacer(minLength: Tokens.Spacing.xs)
            trailing
        }
        .frame(height: 16)
    }
}

public extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) { self.init(title, symbol: symbol) { EmptyView() } }
}

/// One line item: thumbnail or symbol, title, detail, trailing figure.
public struct ResultRow: View {
    private let thumbnail: SendableImage?
    private let symbol: String
    private let symbolTint: TintRole
    private let title: String
    private let detail: String?
    private let trailing: String?
    private let trailingTint: TintRole

    public init(
        thumbnail: SendableImage? = nil, symbol: String = "doc", symbolTint: TintRole = .secondary,
        title: String, detail: String? = nil, trailing: String? = nil, trailingTint: TintRole = .secondary
    ) {
        self.thumbnail = thumbnail; self.symbol = symbol; self.symbolTint = symbolTint; self.title = title
        self.detail = detail; self.trailing = trailing; self.trailingTint = trailingTint
    }

    public var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail.cgImage, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(symbolTint.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Tokens.Colors.cardFill)
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title).notchStyle(.body).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).notchStyle(.caption).lineLimit(1) }
            }
            Spacer(minLength: Tokens.Spacing.xs)
            if let trailing {
                Text(trailing).font(NotchTextStyle.numeric.font).foregroundStyle(trailingTint.color)
                    .contentTransition(.numericText()).lineLimit(1).fixedSize()
            }
        }
        .frame(height: 30)
    }
}

/// Centered placeholder for a card with nothing to show.
public struct EmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?

    public init(symbol: String, title: String, message: String? = nil) {
        self.symbol = symbol; self.title = title; self.message = message
    }

    public var body: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(Tokens.Colors.textTertiary)
            Text(title).notchStyle(.caption).multilineTextAlignment(.center)
            if let message {
                Text(message).font(NotchTextStyle.caption.font).foregroundStyle(Tokens.Colors.textTertiary)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Determinate progress ring.
public struct ProgressRing: View {
    private let progress: Double
    private let size: CGFloat
    private let lineWidth: CGFloat
    private let tint: TintRole

    public init(progress: Double, size: CGFloat = 16, lineWidth: CGFloat = 2.5, tint: TintRole = .accent) {
        self.progress = min(1, max(0, progress)); self.size = size; self.lineWidth = lineWidth; self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Tokens.Colors.cardStroke, lineWidth: lineWidth)
            Circle().trim(from: 0, to: progress)
                .stroke(tint.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .motion(Motion.morph, value: progress)
        .accessibilityElement()
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// Indeterminate ring for work whose progress is unknown (a single file converting). Rests under Reduce Motion.
public struct SpinnerRing: View {
    private let size: CGFloat
    private let lineWidth: CGFloat
    private let tint: TintRole
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 16, lineWidth: CGFloat = 2.5, tint: TintRole = .accent) {
        self.size = size; self.lineWidth = lineWidth; self.tint = tint
    }

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                Circle().stroke(Tokens.Colors.cardStroke, lineWidth: lineWidth)
                Circle().trim(from: 0, to: 0.7)
                    .stroke(tint.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90 + turn * 360))
            }
            .frame(width: size, height: size)
        }
        .accessibilityElement()
        .accessibilityLabel("In progress")
    }
}

/// Thin horizontal bar for a position in time (a track's playhead). Not a control.
public struct PositionBar: View {
    private let progress: Double

    public init(progress: Double) { self.progress = min(1, max(0, progress.isFinite ? progress : 0)) }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Colors.cardStroke)
                Capsule().fill(Tokens.Colors.textPrimary).frame(width: max(3, proxy.size.width * progress))
            }
        }
        .frame(height: 3)
        .motion(Motion.morph, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// Small coloured dot; pulses to ask for attention.
public struct StatusDot: View {
    private let tint: TintRole
    private let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ tint: TintRole, pulsing: Bool = false) { self.tint = tint; self.pulsing = pulsing }

    public var body: some View {
        Circle().fill(tint.color).frame(width: 7, height: 7)
            .phaseAnimator(pulsing && !reduceMotion ? [1.0, 0.35] : [1.0]) { view, phase in
                view.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.8) }
    }
}

/// Three animated bars for "audio is playing".
public struct EqualizerBars: View {
    private let playing: Bool
    private let tint: TintRole
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(playing: Bool, tint: TintRole = .primary) { self.playing = playing; self.tint = tint }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let level = playing && !reduceMotion ? 0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i))) : 0.3
                    Capsule().fill(tint.color).frame(width: 2.5, height: 12 * level)
                }
            }
            .frame(width: 14, height: 14)
        }
    }
}

/// Live countdown to a date: "1h 5m", "12m", "45s", "now".
public struct CountdownText: View {
    private let target: Date
    private let style: NotchTextStyle

    public init(to target: Date, style: NotchTextStyle = .numeric) { self.target = target; self.style = style }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Format.countdown(seconds: target.timeIntervalSince(context.date)))
                .notchStyle(style).contentTransition(.numericText(countsDown: true))
        }
    }
}

public extension View {
    /// Lets the view be dragged out of the notch as files (to Finder, a browser upload field, Slack...).
    @ViewBuilder func fileDragSource(_ urls: [URL]) -> some View {
        if let first = urls.first {
            onDrag { NSItemProvider(contentsOf: first) ?? NSItemProvider() }
        } else {
            self
        }
    }
}
