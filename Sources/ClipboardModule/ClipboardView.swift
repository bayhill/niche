import NotchCore
import SwiftUI

/// The Clipboard page: a header and one row of clip cards, newest first. Four cards fit the page;
/// older clips scroll in from the right.
struct ClipboardPage: View {
    let module: ClipboardModule
    /// `false` lays the row out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    /// Four cards across the page.
    static let cardWidth = ((PanelLayout.pageSize.width - 3 * Tokens.Spacing.s) / 4).rounded(.down)

    var body: some View {
        let entries = module.entries
        let showsList = module.status == .monitoring && !entries.isEmpty
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader("Clipboard", symbol: "doc.on.clipboard") {
                if showsList {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text("\(entries.count) of \(module.capacity)")
                            .notchStyle(.caption)
                            .contentTransition(.numericText(value: Double(entries.count)))
                        GlassIconButton("trash", label: "Clear history", kind: .plain, size: 20) { module.clear() }
                    }
                    .transition(.opacity)
                }
            }

            ZStack {
                switch module.status {
                case .off:
                    StatusMessage(
                        symbol: "doc.on.clipboard", title: "Turn on clipboard history",
                        message: "Recent text and images stay in memory only. Passwords are skipped."
                    ) {
                        GlassButton("Turn on", symbol: "power", prominence: .accent) { module.turnOn() }
                    }
                    .transition(.opacity)
                case .paused:
                    StatusMessage(
                        symbol: "pause.circle", title: "Resume clipboard history",
                        message: "macOS asks before each read. Allowing Notcher in Privacy & Security skips this step."
                    ) {
                        GlassButton("Resume", symbol: "play.fill", prominence: .accent) { module.resume() }
                    }
                    .transition(.opacity)
                case .denied:
                    StatusMessage(
                        symbol: "hand.raised", title: "Allow clipboard access in System Settings",
                        message: "Privacy & Security lists Notcher under pasting from other apps."
                    ) {
                        HStack(spacing: Tokens.Spacing.s) {
                            GlassButton("Open Settings", symbol: "gear") { module.openSettings() }
                            GlassButton("Try again") { module.resume() }
                        }
                    }
                    .transition(.opacity)
                case .monitoring where entries.isEmpty:
                    EmptyState(symbol: "doc.on.clipboard", title: "Copy text or an image", message: "Recent copies collect here.")
                        .transition(.opacity)
                case .monitoring:
                    CardRow(scrolls: scrolls) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            ClipCard(entry: entry, module: module)
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

/// One row of cards that scrolls (and snaps to cards) when it overflows.
private struct CardRow<Content: View>: View {
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

/// One clip: kind, preview, source app and age. Click copies it again; hover offers removal.
struct ClipCard: View {
    let entry: ClipboardEntry
    let module: ClipboardModule
    @State private var hovering = false

    var body: some View {
        let confirmed = module.confirmedID == entry.id
        Button { module.copy(entry) } label: {
            GlassCard(highlighted: confirmed, hoverable: true) {
                SectionHeader(entry.kind.label, symbol: confirmed ? "checkmark" : entry.kind.symbol) {
                    // Space for the header actions, which sit outside the button.
                    Color.clear.frame(width: 1)
                }
                preview
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(entry.sourceApp ?? "").notchStyle(.caption).lineLimit(1)
                    Spacer(minLength: Tokens.Spacing.xs)
                    AgeText(date: entry.copiedAt)
                }
            }
        }
        .buttonStyle(CardPressStyle())
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if entry.isImage, module.canConvert {
                    GlassIconButton("wand.and.sparkles", label: "Convert to WebP", kind: .plain, size: 20) { module.convert(entry) }
                }
                if hovering {
                    GlassIconButton("xmark", label: "Remove from history", kind: .plain, size: 20) { module.remove(entry.id) }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(.top, Tokens.Spacing.m - 2)
            .padding(.trailing, Tokens.Spacing.s)
        }
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .help("Copy again")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var preview: some View {
        switch entry.kind {
        case .text:
            Text(entry.preview).notchStyle(.body).lineLimit(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .link(let display):
            Text(display).notchStyle(.body).lineLimit(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .colour(let colour):
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous)
                    .fill(Color(red: Double(colour.red) / 255, green: Double(colour.green) / 255, blue: Double(colour.blue) / 255))
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous)
                            .strokeBorder(Tokens.Colors.hairline, lineWidth: 1)
                    }
                Text(colour.hex).notchStyle(.numeric).lineLimit(1)
            }
        case .image:
            // The picture fills whatever room is left without ever widening the card.
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
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous)
                        .strokeBorder(Tokens.Colors.hairline, lineWidth: 1)
                }
                .help(dimensions ?? "Image")
        }
    }

    private var dimensions: String? {
        entry.pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" }
    }

    private var accessibilityText: String {
        let source = entry.sourceApp.map { ", from \($0)" } ?? ""
        switch entry.kind {
        case .text: return "Text\(source): \(entry.preview)"
        case .link(let display): return "Link\(source): \(display)"
        case .colour(let colour): return "Colour\(source): \(colour.hex)"
        case .image: return "Image\(source), \(dimensions ?? "unknown size")"
        }
    }
}

/// Press feedback for a whole card (the row scale from the design kit).
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
                        Text("\(size) clips, up to \(ClipboardLimits(historySize: size).maxImageEntries) images").tag(size)
                    }
                }
            } footer: {
                Text(
                    "History stays in memory and is never written to disk. Not recorded: copies marked private or "
                        + "transient (passwords), anything copied while 1Password, Bitwarden, Passwords or Keychain Access "
                        + "is in front, text over 100 KB and images over 20 MB."
                )
            }
            Section {
                Toggle("Add files copied in Finder to the Shelf", isOn: settings.binding(ClipboardModule.filesToShelfKey))
            } footer: {
                Text(
                    "When off, copied files are ignored. When on, each file copied in Finder is added to the Shelf as a "
                        + "reference; Shelf items are kept on disk, including after a restart, until removed from the Shelf."
                )
            }
            if module.status == .denied {
                Section {
                    LabeledContent("macOS blocks clipboard access") {
                        Button("Open System Settings") { module.openSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
