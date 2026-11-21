import NotchCore
import Observation
import SwiftUI

/// What the SwiftUI hierarchy renders. Mutated only by `NotchController`, inside `Motion.animate`.
@MainActor
@Observable
final class NotchViewModel {
    var state: NotchState = .closed
    var page: ModuleID?
    var dropTargeted = false
    var activity: LiveActivity?
    var hint: DropHint = .fallback
    var layout: NotchLayout
    /// Enabled modules, in the order given to the controller.
    var modules: [any NotchModule] = []
    var fpsText: String?
    /// Briefly mounts the expanded panel and drop target invisibly at launch, so the first real open does not pay for
    /// building fonts, symbols and layers mid-animation.
    var warming = false

    @ObservationIgnored var onSelectPage: (ModuleID?) -> Void = { _ in }
    @ObservationIgnored var onOpenSettings: () -> Void = {}

    init(layout: NotchLayout) { self.layout = layout }
}

struct NotchRootView: View {
    let model: NotchViewModel
    @Namespace private var heroNamespace

    var body: some View {
        let layout = model.layout
        NotchChrome(
            width: layout.shapeRect.width, height: layout.shapeRect.height, topRadius: layout.topRadius,
            bottomRadius: layout.bottomRadius, glass: layout.glassAmount, capHeight: layout.bandHeight
        ) {
            NotchContentView(model: model)
        }
        .offset(x: layout.centerOffset)
        .frame(width: layout.windowFrame.width, height: layout.windowFrame.height, alignment: .top)
        .overlay(alignment: .bottom) {
            if let fps = model.fpsText {
                Text(fps)
                    .notchStyle(.numeric)
                    .padding(.horizontal, Tokens.Spacing.s)
                    .padding(.vertical, Tokens.Spacing.xs)
                    .background(Tokens.Colors.notchBlack.opacity(0.7), in: .capsule)
                    .padding(.bottom, Tokens.Spacing.xs)
            }
        }
        .environment(\.notchNamespace, heroNamespace)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

/// The notch surface and the clipped content, with size, radii and glass interpolated together frame by frame,
/// so the outline, the glass and the content mask never drift apart mid-spring.
private struct NotchChrome<Content: View>: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var glass: Double
    let capHeight: CGFloat
    let content: Content

    init(
        width: CGFloat, height: CGFloat, topRadius: CGFloat, bottomRadius: CGFloat, glass: Double, capHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width; self.height = height; self.topRadius = topRadius; self.bottomRadius = bottomRadius
        self.glass = glass; self.capHeight = capHeight; self.content = content()
    }

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, Double>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(AnimatablePair(topRadius, bottomRadius), glass)) }
        set {
            width = newValue.first.first; height = newValue.first.second
            topRadius = newValue.second.first.first; bottomRadius = newValue.second.first.second
            glass = newValue.second.second
        }
    }

    /// `NotchSurface` stacks the cap and a fixed 56 pt gradient, so it cannot be shorter than this without
    /// overflowing its frame. Shorter states draw it at this height and clip it to the real outline.
    private var surfaceMinHeight: CGFloat { capHeight + 57 }

    var body: some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        ZStack(alignment: .top) {
            NotchSurface(shape: shape, capHeight: capHeight, glassAmount: glass)
                .frame(width: width, height: max(height, surfaceMinHeight))
                .frame(width: width, height: height, alignment: .top)
                .clipShape(shape)

            content
                .frame(width: width, height: height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: width, height: height, alignment: .top)
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.opacity(active ? 0 : 1).blur(radius: active ? 6 : 0)
    }
}

extension AnyTransition {
    /// Content of a state arriving or leaving: fade and un-blur, settling down from the band.
    static func notchContent(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
            .combined(with: .scale(scale: 0.96, anchor: .top))
    }
}

/// Each state's content has a fixed size (independent of the animating outline), so mid-spring frames only move and
/// mask it instead of laying it out again, and content that is leaving never reflows into a shrinking frame.
private struct NotchContentView: View {
    let model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = model.layout
        let notch = layout.notchRect.size
        ZStack(alignment: .top) {
            if model.state == .activity || model.state == .hover, let activity = model.activity {
                WingsView(activity: activity, notchWidth: notch.width)
                    .frame(
                        width: NotchGeometry.bodyWidth(model.state, notch: notch, hasActivity: true),
                        height: layout.bandHeight
                    )
                    .id(activity.id)
                    .transition(.notchContent(reduceMotion: reduceMotion))
            }
            if model.state == .drop {
                DropTargetView(hint: model.hint, targeted: model.dropTargeted, bandHeight: layout.bandHeight)
                    .transition(.notchContent(reduceMotion: reduceMotion))
            }
            if model.warming && model.state != .expanded && model.state != .drop {
                Group {
                    ExpandedView(
                        model: model, notchWidth: notch.width,
                        bodyWidth: NotchGeometry.bodyWidth(.expanded, notch: notch, hasActivity: true), bandHeight: layout.bandHeight
                    )
                    DropTargetView(hint: model.hint, targeted: false, bandHeight: layout.bandHeight)
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .environment(\.notchNamespace, nil)
            }
            if model.state == .expanded {
                ExpandedView(
                    model: model, notchWidth: notch.width,
                    bodyWidth: NotchGeometry.bodyWidth(.expanded, notch: notch, hasActivity: true), bandHeight: layout.bandHeight
                )
                .transition(.notchContent(reduceMotion: reduceMotion))
            }
        }
    }
}

// MARK: - Wings

private struct WingsView: View {
    let activity: LiveActivity
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ActivityGlyphView(glyph: activity.leading)
                .notchHero(activity.module)
                .frame(width: PanelLayout.wingWidth)
            Spacer(minLength: notchWidth)
            Group {
                if let trailing = activity.trailing { ActivityGlyphView(glyph: trailing) } else { Color.clear }
            }
            .frame(width: PanelLayout.wingWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.accessibilityLabel)
    }
}

/// Renders every `ActivityGlyph` at wing size (about 18 pt).
struct ActivityGlyphView: View {
    let glyph: ActivityGlyph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch glyph {
        case .symbol(let name, let tint, let pulse):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint.color)
                .symbolEffect(.pulse, options: .repeating, isActive: pulse && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 18)
        case .progress(let value):
            ProgressRing(progress: value, size: 16, lineWidth: 2.5)
        case .text(let text):
            Text(text)
                .notchStyle(.numeric)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .padding(.horizontal, 3)
        case .countdown(let date):
            CountdownText(to: date).lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 3)
        case .image(let image):
            Image(decorative: image.cgImage, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))
        case .equalizer(let playing):
            EqualizerBars(playing: playing)
        }
    }
}

// MARK: - Drop target

private struct DropTargetView: View {
    let hint: DropHint
    let targeted: Bool
    let bandHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: bandHeight)
            GlassCard(padding: Tokens.Spacing.m, highlighted: targeted) {
                HStack(spacing: Tokens.Spacing.m) {
                    Image(systemName: hint.symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(targeted ? Tokens.Colors.accent : Tokens.Colors.textPrimary)
                        .symbolEffect(.bounce, value: targeted)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hint.title).notchStyle(.title).lineLimit(1)
                        if let subtitle = hint.subtitle { Text(subtitle).notchStyle(.caption).lineLimit(1) }
                    }
                    .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(EdgeInsets(top: Tokens.Spacing.xs, leading: Tokens.Spacing.m, bottom: Tokens.Spacing.m, trailing: Tokens.Spacing.m))
            .motionAppear(0)
        }
        .frame(width: PanelLayout.dropSize.width, height: bandHeight + PanelLayout.dropSize.height)
    }
}

// MARK: - Expanded panel

private struct ExpandedView: View {
    let model: NotchViewModel
    let notchWidth: CGFloat
    let bodyWidth: CGFloat
    let bandHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            BandView(model: model, notchWidth: notchWidth, bodyWidth: bodyWidth)
                .frame(height: bandHeight)
            PageContainer(model: model)
                .frame(width: PanelLayout.pageSize.width, height: PanelLayout.pageSize.height)
                .padding(PanelLayout.contentInsets)
        }
        .frame(width: bodyWidth, height: bandHeight + PanelLayout.expandedSize.height, alignment: .top)
    }
}

private struct BandView: View {
    let model: NotchViewModel
    let notchWidth: CGFloat
    let bodyWidth: CGFloat
    @Namespace private var selection

    var body: some View {
        let side = max(0, (bodyWidth - notchWidth) / 2)
        let pages = PanelContent.pages(model.modules)
        HStack(spacing: 0) {
            HStack(spacing: Tokens.Spacing.xs) {
                BandButton(symbol: "square.grid.2x2", label: "Home", selected: model.page == nil, selection: selection) {
                    model.onSelectPage(nil)
                }
                .motionAppear(0)
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    BandButton(symbol: page.symbol, label: page.title, selected: model.page == page.id, selection: selection) {
                        model.onSelectPage(page.id)
                    }
                    .motionAppear(index + 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, PanelLayout.contentInsets.leading)
            .frame(width: side)

            Color.clear.frame(width: notchWidth)

            HStack(spacing: Tokens.Spacing.xs) {
                Spacer(minLength: 0)
                BandButton(symbol: "slider.horizontal.3", label: "Settings", selected: false, selection: selection) {
                    model.onOpenSettings()
                }
                .motionAppear(pages.count + 1)
            }
            .padding(.trailing, PanelLayout.contentInsets.trailing)
            .frame(width: side)
        }
    }
}

private struct BandButton: View {
    let symbol: String
    let label: String
    let selected: Bool
    let selection: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(label, systemImage: symbol) }
            .buttonStyle(PlainIconButtonStyle(size: 26, tint: selected ? .primary : .secondary))
            .background {
                if selected {
                    Circle().fill(Tokens.Colors.cardFill)
                        .overlay { Circle().strokeBorder(Tokens.Colors.cardStroke, lineWidth: 1) }
                        .matchedGeometryEffect(id: "band.selection", in: selection)
                }
            }
            .help(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PageContainer: View {
    let model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let module = PanelContent.pageModule(model.page, in: model.modules) {
                module.panelView()
                    .frame(width: PanelLayout.pageSize.width, height: PanelLayout.pageSize.height)
                    .motionAppear(1)
                    .id(module.id)
                    .transition(.notchContent(reduceMotion: reduceMotion))
            } else {
                HomeView(modules: model.modules)
                    .transition(.notchContent(reduceMotion: reduceMotion))
            }
        }
    }
}

private struct HomeView: View {
    let modules: [any NotchModule]

    var body: some View {
        let cards = PanelContent.dashboard(modules)
        let frames = DashboardLayout.frames(for: Set(cards.map(\.slot)))
        ZStack(alignment: .topLeading) {
            if cards.isEmpty {
                EmptyState(symbol: "square.grid.2x2", title: "Nothing on Home yet", message: "Enable a module in Settings.")
                    .motionAppear(1)
            }
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if let frame = frames[card.slot] {
                    card.module.panelView()
                        .frame(width: frame.width, height: frame.height)
                        .motionAppear(index + 1)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(width: PanelLayout.pageSize.width, height: PanelLayout.pageSize.height, alignment: .topLeading)
    }
}
