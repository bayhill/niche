import NotchCore
import SwiftUI

/// The Shelf page: a header and one row of file cards, newest first. Four cards fit the page;
/// older items scroll in from the right. Same card language as the Clipboard page.
struct ShelfPage: View {
    let module: ShelfModule
    /// `false` lays the row out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    /// Four cards across the page.
    static let cardWidth = ((PanelLayout.pageSize.width - 3 * Tokens.Spacing.s) / 4).rounded(.down)

    var body: some View {
        let items = module.items
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader("Shelf", symbol: "tray.full") {
                if !items.isEmpty {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text("\(items.count) of \(module.capacity)")
                            .notchStyle(.caption)
                            .contentTransition(.numericText(value: Double(items.count)))
                            .notchHero(.shelf)
                        GlassIconButton("trash", label: "Clear shelf", kind: .plain, size: 20) { module.clear() }
                            .help("Clear shelf (files stay where they are)")
                    }
                    .transition(.opacity)
                }
            }

            ZStack {
                if items.isEmpty {
                    EmptyState(symbol: "tray", title: "Drop files on the notch", message: "Hold ⌥ to shelve images instead of converting them.")
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    CardRow(scrolls: scrolls) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ShelfCard(item: item, module: module)
                                .frame(width: Self.cardWidth)
                                .motionAppear(min(index, 6))
                                .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 0.6).combined(with: .opacity)))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await module.prune() }
    }
}

/// One row of cards that scrolls (and snaps to cards) when it overflows.
struct CardRow<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let row = HStack(alignment: .top, spacing: Tokens.Spacing.s) { content }
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { row.scrollTargetLayout() }
                // One point of room so the first and last cards' outlines are not cut by the scroll bounds.
                .contentMargins(.horizontal, 1, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollEdgeEffectStyle(.soft, for: .horizontal)
        } else {
            Color.clear.overlay(alignment: .topLeading) { row.fixedSize(horizontal: true, vertical: false) }.clipped()
        }
    }
}

/// One file: kind, picture, name, then size and age. Click reveals in Finder, drag takes the file out,
/// hover offers removal.
struct ShelfCard: View {
    let item: ShelfItem
    let module: ShelfModule
    @State private var hovering = false

    var body: some View {
        let kind = ShelfItemKind.of(item)
        Button { module.reveal(item) } label: {
            GlassCard(hoverable: true) {
                SectionHeader(kind.label, symbol: kind.symbol)
                picture(kind)
                Text(item.name).notchStyle(.body).lineLimit(1).truncationMode(.middle)
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(item.size.map(Format.bytes) ?? "").notchStyle(.caption).lineLimit(1)
                    Spacer(minLength: Tokens.Spacing.xs)
                    AgeText(date: item.addedAt)
                }
            }
        }
        .buttonStyle(CardPressStyle())
        .fileDragSource([item.url])  // exactly this card's file
        .overlay(alignment: .topTrailing) {
            if hovering {
                GlassIconButton("xmark", label: "Remove from shelf", kind: .plain, size: 20) { module.remove(item.id) }
                    .padding(.top, Tokens.Spacing.m - 2)
                    .padding(.trailing, Tokens.Spacing.s)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .task(id: item.path) { await module.loadThumbnail(for: item) }
        .help(item.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label), \(item.name)\(item.size.map { ", " + Format.bytes($0) } ?? "")")
        .accessibilityHint("Reveals the file in Finder. Drag to move it elsewhere.")
    }

    /// The thumbnail fills the space left in the card; pages and icons fit inside it, photos fill it.
    private func picture(_ kind: ShelfItemKind) -> some View {
        Tokens.Colors.cardFill
            .overlay {
                if let thumbnail = module.thumbnail(for: item) {
                    Image(decorative: thumbnail.cgImage, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: kind.fillsPreview ? .fill : .fit)
                        .padding(kind.fillsPreview ? 0 : Tokens.Spacing.xs)
                        .transition(.opacity)
                } else {
                    Image(systemName: kind.symbol)
                        .font(NotchTextStyle.display.font)
                        .foregroundStyle(Tokens.Colors.textTertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous)
                    .strokeBorder(Tokens.Colors.hairline, lineWidth: 1)
            }
    }
}

/// Press feedback for a whole card (the row scale from the design system).
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .motion(Motion.press, value: configuration.isPressed)
    }
}

/// "now", "4m", "1h", kept fresh.
private struct AgeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Format.age(seconds: context.date.timeIntervalSince(date)))
                .notchStyle(.caption)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        }
    }
}
