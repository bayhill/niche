import NotchCore
import SwiftUI

/// The Screenshots page: a header and one row of tiles, newest first. Four tiles fit the page;
/// older screenshots scroll in from the right. Same card language as the Shelf and Clipboard pages.
struct ScreenshotsPage: View {
    let module: ScreenshotsModule
    /// `false` lays the row out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    /// Four tiles across the page.
    static let tileWidth = ((PanelLayout.pageSize.width - 3 * Tokens.Spacing.s) / 4).rounded(.down)

    var body: some View {
        let shots = module.screenshots
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader("Screenshots", symbol: "camera.viewfinder") {
                if module.status == .watching, !shots.isEmpty {
                    Group {
                        if module.needsAccess {
                            HStack(spacing: Tokens.Spacing.xs) {
                                Text("Allow folder access in Privacy & Security to show previews").notchStyle(.caption).lineLimit(1)
                                GlassIconButton("gear", label: "Open Privacy & Security", kind: .plain, size: 20) {
                                    module.openPrivacySettings()
                                }
                            }
                        } else {
                            Text("Last 24 hours").notchStyle(.caption).lineLimit(1)
                        }
                    }
                    .transition(.opacity)
                }
            }

            ZStack {
                switch module.status {
                case .off:
                    ShowPrompt { module.enable() }
                        .transition(.opacity)
                case .watching where shots.isEmpty && module.folderAccess == .denied:
                    StatusMessage(
                        symbol: "lock", title: "Allow access to the screenshot folder",
                        message: "Privacy & Security › Files and Folders lists Notcher."
                    ) {
                        HStack(spacing: Tokens.Spacing.s) {
                            GlassButton("Open Settings", symbol: "gear") { module.openPrivacySettings() }
                            GlassButton("Try again") { module.retry() }
                        }
                    }
                    .transition(.opacity)
                case .watching where shots.isEmpty:
                    EmptyState(
                        symbol: "camera.viewfinder", title: "Take a screenshot with ⇧⌘4",
                        message: "Screenshots from the last 24 hours collect here."
                    )
                    .transition(.opacity)
                case .watching:
                    TileRow(scrolls: scrolls) {
                        ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                            ScreenshotTile(shot: shot, module: module, isHero: index == 0)
                                .frame(width: Self.tileWidth)
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
        .task { await module.retryUnreadable() }
    }
}

/// The dormant page, in the manner of Calendar's "Connect calendar": one line, one button, one line of detail.
private struct ShowPrompt: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Text("Recent screenshots, ready to drag out, convert or shelve").notchStyle(.caption).lineLimit(1)
            GlassButton("Show screenshots", symbol: "camera.viewfinder", prominence: .accent, action: action).fixedSize()
            Text("macOS may ask for access to the folder they are saved in.")
                .font(NotchTextStyle.caption.font).foregroundStyle(Tokens.Colors.textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motionAppear()
    }
}

/// Explanation plus one or two actions, centred.
private struct StatusMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            EmptyState(symbol: symbol, title: title, message: message).fixedSize(horizontal: false, vertical: true)
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row of tiles that scrolls (and snaps to tiles) when it overflows.
private struct TileRow<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let row = HStack(alignment: .top, spacing: Tokens.Spacing.s) { content }
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { row.scrollTargetLayout() }
                // One point of room so the first and last tiles' outlines are not cut by the scroll bounds.
                .contentMargins(.horizontal, 1, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollEdgeEffectStyle(.soft, for: .horizontal)
        } else {
            Color.clear.overlay(alignment: .topLeading) { row.fixedSize(horizontal: true, vertical: false) }.clipped()
        }
    }
}

/// One screenshot: age and actions, the picture, then pixel and file size. Click reveals in Finder,
/// drag takes the file out.
struct ScreenshotTile: View {
    let shot: Screenshot
    let module: ScreenshotsModule
    /// The newest tile's picture is where the live activity's thumbnail lands.
    let isHero: Bool

    static let actionSize: CGFloat = 20

    var body: some View {
        let result = module.thumbnail(for: shot)
        let actions = actionCount
        Button { module.reveal(shot) } label: {
            GlassCard(hoverable: true) {
                HStack(spacing: Tokens.Spacing.xs) {
                    AgeText(date: shot.createdAt)
                    Spacer(minLength: Tokens.Spacing.xs)
                    // Room for the actions, which sit outside the button.
                    Color.clear.frame(width: CGFloat(actions) * Self.actionSize, height: 1)
                }
                .frame(height: Self.actionSize)
                picture(result)
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(shot.pixelSize?.text ?? "").notchStyle(.caption).lineLimit(1)
                    Spacer(minLength: Tokens.Spacing.xs)
                    Text(shot.bytes.map(Format.bytes) ?? "").notchStyle(.caption).lineLimit(1).fixedSize()
                }
            }
        }
        .buttonStyle(TilePressStyle())
        .fileDragSource([shot.url])  // exactly this tile's file
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if module.canConvert {
                    GlassIconButton("wand.and.sparkles", label: "Convert to WebP", kind: .plain, size: Self.actionSize) { module.convert(shot) }
                }
                if module.canShelve {
                    GlassIconButton("tray.and.arrow.down", label: "Add to shelf", kind: .plain, size: Self.actionSize) { module.addToShelf(shot) }
                }
                GlassIconButton("folder", label: "Reveal in Finder", kind: .plain, size: Self.actionSize) { module.reveal(shot) }
            }
            .padding(.top, Tokens.Spacing.m)
            .padding(.trailing, Tokens.Spacing.s)
        }
        .task(id: LoadID(path: shot.dedupeKey, modified: shot.modifiedAt)) { await module.loadThumbnail(for: shot) }
        .help(result == .unreadable ? "No access to this folder" : "Reveal in Finder")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText(result))
        .accessibilityHint("Reveals the file in Finder. Drag to take it elsewhere.")
    }

    private var actionCount: Int { 1 + (module.canConvert ? 1 : 0) + (module.canShelve ? 1 : 0) }

    /// One load per file and modification date.
    private struct LoadID: Hashable {
        let path: String
        let modified: Date?
    }

    /// The picture fills whatever room is left without ever widening the tile.
    private func picture(_ result: ThumbnailResult?) -> some View {
        Tokens.Colors.cardFill
            .overlay {
                if let image = result?.image {
                    Image(decorative: image.cgImage, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    Image(systemName: result == .unreadable ? "lock" : "photo")
                        .font(NotchTextStyle.display.font)
                        .foregroundStyle(Tokens.Colors.textTertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous)
                    .strokeBorder(Tokens.Colors.hairline, lineWidth: 1)
            }
            .hero(isHero)
    }

    private func accessibilityText(_ result: ThumbnailResult?) -> String {
        var parts = ["Screenshot", shot.name]
        if let size = shot.pixelSize { parts.append(size.text.replacingOccurrences(of: "\u{00D7}", with: "by")) }
        if result == .unreadable { parts.append("no access to its folder") }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    @ViewBuilder func hero(_ on: Bool) -> some View {
        if on { notchHero(.screenshots) } else { self }
    }
}

/// Press feedback for a whole tile (the row scale from the design kit).
private struct TilePressStyle: ButtonStyle {
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

/// Settings pane: on/off, and the note beside the notch.
struct ScreenshotsSettings: View {
    let module: ScreenshotsModule
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Show recent screenshots", isOn: Binding(
                    get: { settings.get(ScreenshotsModule.enabledKey) },
                    set: { $0 ? module.enable() : module.disable() }
                ))
            } footer: {
                Text(
                    "Screenshots from the last 24 hours, read from the folder macOS saves them in. Files are never "
                        + "moved, renamed or deleted, and nothing is kept after quitting. macOS may ask for access to "
                        + "the folder screenshots are saved in."
                )
            }
            Section {
                Toggle("Show new screenshots beside the notch", isOn: settings.binding(ScreenshotsModule.showBesideNotchKey))
            } footer: {
                Text("For a few seconds after each screenshot, ready to drag straight out of the menu bar.")
            }
        }
        .formStyle(.grouped)
    }
}
