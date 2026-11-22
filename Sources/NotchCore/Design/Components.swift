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
/// The leading 26 pt slot shows a thumbnail, else a symbol, or any custom view (a `ProgressRing` while working).
public struct ResultRow<Leading: View>: View {
    private let leading: Leading?
    private let thumbnail: SendableImage?
    private let symbol: String
    private let symbolTint: TintRole
    private let title: String
    private let detail: String?
    private let trailing: String?
    private let trailingTint: TintRole

    /// A row whose leading slot holds a custom view, centred in the 26 pt square.
    public init(
        title: String, detail: String? = nil, trailing: String? = nil, trailingTint: TintRole = .secondary,
        @ViewBuilder leading: () -> Leading
    ) {
        self.leading = leading(); self.thumbnail = nil; self.symbol = "doc"; self.symbolTint = .secondary
        self.title = title; self.detail = detail; self.trailing = trailing; self.trailingTint = trailingTint
    }

    public var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Group {
                if let leading {
                    leading.frame(maxWidth: .infinity, maxHeight: .infinity).background(Tokens.Colors.cardFill)
                } else if let thumbnail {
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

public extension ResultRow where Leading == EmptyView {
    /// A row whose leading slot shows `thumbnail`, or `symbol` when there is none.
    init(
        thumbnail: SendableImage? = nil, symbol: String = "doc", symbolTint: TintRole = .secondary,
        title: String, detail: String? = nil, trailing: String? = nil, trailingTint: TintRole = .secondary
    ) {
        self.leading = nil; self.thumbnail = thumbnail; self.symbol = symbol; self.symbolTint = symbolTint
        self.title = title; self.detail = detail; self.trailing = trailing; self.trailingTint = trailingTint
    }
}

/// Centered placeholder for a card with nothing to show.
public struct EmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let compact: Bool

    /// - Parameter compact: one line (symbol beside the title, no message), for half-height cards.
    public init(symbol: String, title: String, message: String? = nil, compact: Bool = false) {
        self.symbol = symbol; self.title = title; self.message = message; self.compact = compact
    }

    public var body: some View {
        if compact {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(Tokens.Colors.textTertiary)
                Text(title).notchStyle(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            regular
        }
    }

    private var regular: some View {
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
    private let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ tint: TintRole, pulsing: Bool = false, size: CGFloat = 7) {
        self.tint = tint; self.pulsing = pulsing; self.size = size
    }

    public var body: some View {
        Circle().fill(tint.color).frame(width: size, height: size)
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
    /// Lets the view be dragged out of the notch as a file (to Finder, a browser upload field, Slack...).
    /// One view drags one file: only the first URL is offered.
    @ViewBuilder func fileDragSource(_ urls: [URL]) -> some View {
        if let first = urls.first {
            onDrag { FileDrag.provider(for: first) }
        } else {
            self
        }
    }
}

public enum FileDrag {
    /// The item provider for dragging a file out. The receiver gets a copy of the file's contents, so the original
    /// is never moved. `NSItemProvider(contentsOf:)` leaves `suggestedName` empty, and Finder then names the copy
    /// after its type ("PNG image.png"); carrying the file's own name keeps it.
    public static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.suggestedName = suggestedName(for: url)
        return provider
    }

    /// The name to offer for `url`: its own name without the extension. The receiver appends the extension of the
    /// file's type itself, so offering "report.pdf" lands as "report.pdf.pdf". A name with no extension is offered
    /// whole, since nothing is appended to it.
    public static func suggestedName(for url: URL) -> String {
        url.pathExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}
