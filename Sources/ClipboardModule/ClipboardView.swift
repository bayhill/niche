import NotchCore
import SwiftUI

/// The Clipboard page: a header and a horizontally scrolling row of recent copies, newest first.
struct ClipboardPage: View {
    let module: ClipboardModule
    /// `false` lays the row out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    var body: some View {
        let entries = module.entries
        let showsList = module.status == .monitoring && !entries.isEmpty
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader("Clipboard", symbol: "doc.on.clipboard") {
                if showsList {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(entries.count == 1 ? "1 copy" : "\(entries.count) copies")
                            .notchStyle(.caption)
                            .contentTransition(.numericText(value: Double(entries.count)))
                        Button { module.clear() } label: { Text("Clear").notchStyle(.caption) }
                            .buttonStyle(RowButtonStyle())
                            .help("Forget every copy")
                    }
                    .transition(.opacity)
                }
            }

            ZStack {
                switch module.status {
                case .off:
                    StatusMessage(
                        symbol: "doc.on.clipboard", title: "Clipboard history is off",
                        message: "Keep the last things you copy at hand. Stays in memory; passwords are skipped."
                    ) {
                        GlassButton("Turn on", symbol: "power", prominence: .accent) { module.turnOn() }
                    }
                    .transition(.opacity)
                case .paused:
                    StatusMessage(
                        symbol: "pause.circle", title: "Clipboard history is paused",
                        message: "macOS asks before Notcher reads what you copy. Allow it in Privacy & Security to skip this."
                    ) {
                        GlassButton("Resume", symbol: "play.fill", prominence: .accent) { module.resume() }
                    }
                    .transition(.opacity)
                case .denied:
                    StatusMessage(
                        symbol: "hand.raised", title: "macOS is blocking clipboard access",
                        message: "Allow Notcher to paste from other apps in System Settings › Privacy & Security."
                    ) {
                        HStack(spacing: Tokens.Spacing.s) {
                            GlassButton("Open Settings", symbol: "gear") { module.openSettings() }
                            GlassButton("Try Again") { module.resume() }
                        }
                    }
                    .transition(.opacity)
                case .monitoring where entries.isEmpty:
                    EmptyState(symbol: "doc.on.clipboard", title: "Nothing copied yet", message: "Copy some text or an image and it appears here.")
                        .transition(.opacity)
                case .monitoring:
                    ClipTileRow(scrolls: scrolls) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            ClipboardTile(entry: entry, module: module)
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

/// A horizontal row of tiles that scrolls (and snaps to tiles) when it overflows.
private struct ClipTileRow<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let row = HStack(alignment: .top, spacing: Tokens.Spacing.s) { content }
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { row.scrollTargetLayout() }
                .scrollTargetBehavior(.viewAligned)
                .scrollEdgeEffectStyle(.soft, for: .horizontal)
        } else {
            Color.clear.overlay(alignment: .topLeading) { row.fixedSize(horizontal: true, vertical: false) }.clipped()
        }
    }
}

/// One copy. Click puts it back on the clipboard; images also offer conversion to WebP.
struct ClipboardTile: View {
    let entry: ClipboardEntry
    let module: ClipboardModule
    @State private var hovering = false

    static let width: CGFloat = 150

    var body: some View {
        let confirmed = module.confirmedID == entry.id
        Button { module.copy(entry) } label: {
            GlassCard(padding: Tokens.Spacing.s + Tokens.Spacing.xs / 2, spacing: Tokens.Spacing.s, highlighted: confirmed) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: kind.symbol).font(NotchTextStyle.label.font).foregroundStyle(Tokens.Colors.textTertiary)
                    Text(kind.label).notchStyle(.label)
                    Spacer(minLength: Tokens.Spacing.xs)
                    AgeText(date: entry.copiedAt)
                }
                content
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(hovering && !confirmed ? Tokens.Colors.hairline : .clear)
                    .allowsHitTesting(false)
            }
            .frame(width: Self.width)
        }
        .buttonStyle(TilePressStyle())
        .overlay(alignment: .bottomTrailing) {
            if entry.isImage, module.canConvert {
                GlassIconButton("wand.and.sparkles", label: "Convert to WebP", size: 26) { module.convert(entry) }
                    .padding(Tokens.Spacing.s + Tokens.Spacing.xs)
                    .opacity(hovering ? 1 : 0.85)
            }
        }
        .overlay {
            if confirmed {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(NotchTextStyle.title.font)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .symbolEffect(.bounce, value: confirmed)
                    .padding(.horizontal, Tokens.Spacing.m)
                    .padding(.vertical, Tokens.Spacing.s)
                    .background(Tokens.Colors.accent, in: .capsule)
                    .shadow(radius: 6, y: 2)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .help(entry.isImage ? "Click to copy this image again" : "Click to copy this text again")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.isImage ? "Image, \(dimensions ?? "unknown size")" : entry.preview)
    }

    @ViewBuilder private var content: some View {
        switch entry.content {
        case .text:
            Text(entry.preview)
                .notchStyle(.body)
                .lineLimit(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                // The picture fills whatever room is left without ever widening the tile.
                Tokens.Colors.cardFill
                    .overlay {
                        if let thumbnail = module.thumbnail(for: entry.id) {
                            Image(decorative: thumbnail.cgImage, scale: 2)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        } else {
                            Image(systemName: "photo").foregroundStyle(Tokens.Colors.textTertiary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))
                if let dimensions { Text(dimensions).font(NotchTextStyle.numeric.font).foregroundStyle(Tokens.Colors.textSecondary).lineLimit(1) }
            }
        }
    }

    private var dimensions: String? {
        entry.pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" }
    }

    private var kind: (symbol: String, label: String) {
        switch entry.content {
        case .image: ("photo", "Image")
        case .text(let text): ClipboardPolicy.looksLikeLink(text) ? ("link", "Link") : ("text.alignleft", "Text")
        }
    }
}

/// Press feedback for a whole tile.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .motion(Motion.press, value: configuration.isPressed)
    }
}

/// "now", "4m", "2h", "3d", kept fresh.
private struct AgeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.age(from: date, to: context.date))
                .notchStyle(.caption)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
    }

    static func age(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// Settings pane: on/off, history size, and what is never recorded.
struct ClipboardSettings: View {
    let module: ClipboardModule
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Keep a history of copied text and images", isOn: Binding(
                    get: { settings.get(ClipboardModule.enabledKey) },
                    set: { $0 ? module.turnOn() : module.turnOff() }
                ))
                Picker("History size", selection: Binding(
                    get: { settings.get(ClipboardModule.historySizeKey) },
                    set: { module.setHistorySize($0) }
                )) {
                    ForEach(ClipboardModule.historySizes, id: \.self) { size in
                        let limits = ClipboardLimits(historySize: size)
                        Text("\(limits.maxTextEntries) texts, \(limits.maxImageEntries) images").tag(size)
                    }
                }
            } footer: {
                Text(
                    "History stays in memory and is never written to disk. Not recorded: copies marked private or transient "
                        + "(passwords), anything copied while 1Password, Bitwarden, Passwords or Keychain Access is in front, "
                        + "files, text over 100 KB and images over 20 MB."
                )
            }
            if module.status == .denied {
                Section {
                    LabeledContent("macOS is blocking clipboard access") {
                        Button("Open System Settings") { module.openSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
