import NotchCore
import SwiftUI
import UniformTypeIdentifiers

/// The Shelf page: a header and one horizontally scrolling row of file tiles.
struct ShelfPage: View {
    let module: ShelfModule
    /// `false` lays the row out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    var body: some View {
        let items = module.items
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader("Shelf", symbol: "tray.full") {
                if !items.isEmpty {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(items.count == 1 ? "1 item" : "\(items.count) items")
                            .notchStyle(.caption)
                            .contentTransition(.numericText(value: Double(items.count)))
                            .notchHero(.shelf)
                        Button { module.clear() } label: { Text("Clear").notchStyle(.caption) }
                            .buttonStyle(RowButtonStyle())
                            .help("Forget every item (the files stay where they are)")
                    }
                    .transition(.opacity)
                }
            }

            ZStack {
                if items.isEmpty {
                    EmptyState(
                        symbol: "tray",
                        title: "Your shelf is empty",
                        message: "Drop files on the notch to keep them handy. Hold ⌥ to shelve images too."
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    TileRow(scrolls: scrolls) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ShelfTile(item: item, module: module)
                                .motionAppear(min(index, 8))
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

/// A horizontal row of tiles that scrolls (and snaps to tiles) when it overflows.
struct TileRow<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let row = HStack(alignment: .top, spacing: Tokens.Spacing.xs) { content }
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { row.scrollTargetLayout() }
                .scrollTargetBehavior(.viewAligned)
                .scrollEdgeEffectStyle(.soft, for: .horizontal)
        } else {
            Color.clear.overlay(alignment: .topLeading) { row.fixedSize() }.clipped()
        }
    }
}

/// One file: picture, name, size. Click reveals in Finder, drag takes the file out, hover offers removal.
struct ShelfTile: View {
    let item: ShelfItem
    let module: ShelfModule
    @State private var hovering = false

    static let width: CGFloat = 104
    static let pictureHeight: CGFloat = 96

    var body: some View {
        Button { module.reveal(item) } label: {
            VStack(spacing: Tokens.Spacing.s) {
                picture
                    .frame(width: Self.width - Tokens.Spacing.m, height: Self.pictureHeight)
                VStack(spacing: 1) {
                    Text(item.name).notchStyle(.body).lineLimit(1).truncationMode(.middle)
                    Text(detail).notchStyle(.caption).lineLimit(1)
                }
                .frame(width: Self.width - Tokens.Spacing.m)
            }
            .padding(.vertical, Tokens.Spacing.xs)
        }
        .buttonStyle(RowButtonStyle())
        .fileDragSource([item.url])
        .overlay(alignment: .topTrailing) {
            if hovering {
                GlassIconButton("xmark", label: "Remove from Shelf", size: 20) { module.remove(item.id) }
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .task(id: item.path) { await module.loadThumbnail(for: item) }
        .help(item.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(detail)")
        .accessibilityHint("Reveals the file in Finder. Drag to move it somewhere else.")
    }

    private var detail: String {
        guard let size = item.size else { return "Folder" }
        return Format.bytes(size)
    }

    @ViewBuilder private var picture: some View {
        if let thumbnail = module.thumbnail(for: item) {
            Image(decorative: thumbnail.cgImage, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))
                .shadow(radius: 3, y: 1)
                .overlay(alignment: .bottomLeading) { badge }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else {
            Image(systemName: fallbackSymbol)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(width: Self.pictureHeight - Tokens.Spacing.l, height: Self.pictureHeight - Tokens.Spacing.l)
                .background(Tokens.Colors.cardFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                .overlay(alignment: .bottomLeading) { badge }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var badge: some View {
        if item.origin == .converted { ConvertedBadge().offset(x: -Tokens.Spacing.xs, y: Tokens.Spacing.xs) }
    }

    private var fallbackSymbol: String {
        if item.size == nil { return "folder.fill" }
        guard let type = UTType(filenameExtension: item.url.pathExtension.lowercased()) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .json) || type.conforms(to: .sourceCode) { return "curlybraces" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// Marks a file Notcher made: a small accent sparkle.
private struct ConvertedBadge: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(NotchTextStyle.label.font)
            .foregroundStyle(TintRole.primary.color)
            .padding(Tokens.Spacing.xs)
            .background(Tokens.Colors.accent, in: .circle)
            .shadow(radius: 2, y: 1)
            .help("Converted by Notcher")
            .accessibilityLabel("Converted")
    }
}
