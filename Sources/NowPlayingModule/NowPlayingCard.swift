import NotchCore
import SwiftUI

/// The centre dashboard card (210 × 184): header, artwork with track lines, live position, transport.
struct NowPlayingCard: View {
    let module: NowPlayingModule

    var body: some View {
        let state = module.state
        let app = state == nil ? nil : module.sourceApp
        // Zero card padding: the click area and the transport row carry the padding themselves, so together they
        // cover the whole card, margins included.
        GlassCard(padding: 0, spacing: 0, ambient: module.ambientArtwork ? state?.artwork : nil, hoverable: app != nil) {
            if let state {
                SourceAppClickArea(app: app, open: module.openSourceApp) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        header(playing: state.isPlaying)
                        TrackInfo(state: state)
                        Spacer(minLength: 0)
                    }
                    .padding([.top, .horizontal], Tokens.Spacing.m)
                }
                TransportRow(state: state, send: module.send)
                    .padding([.horizontal, .bottom], Tokens.Spacing.m)
                    .padding(.top, Tokens.Spacing.s)
                    .background {
                        // Behind the buttons: a click between or beside them opens the app; a click on one never does.
                        if app != nil {
                            Color.clear.contentShape(Rectangle()).onTapGesture { module.openSourceApp() }.accessibilityHidden(true)
                        }
                    }
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    header(playing: false)
                    placeholder.transition(.opacity)
                }
                .padding(Tokens.Spacing.m)
            }
        }
        .motion(Motion.morph, value: state == nil)
    }

    private func header(playing: Bool) -> some View {
        SectionHeader("Now Playing", symbol: "music.note") { EqualizerBars(playing: playing) }
    }

    @ViewBuilder private var placeholder: some View {
        switch module.phase {
        case .needsConnect:
            Prompt(symbol: "music.note", title: "Connect Spotify and Music", message: "Track and controls appear here") {
                GlassButton("Connect", prominence: .accent) { module.connect() }
            }
        case .notAuthorized(let app):
            Prompt(symbol: "lock", title: "Allow Notcher to control \(app)", message: "Privacy & Security › Automation") {
                GlassButton("Open System Settings") { module.openAutomationSettings() }
            }
        case .unavailable:
            Prompt(symbol: "music.note", title: "Now Playing unavailable", message: "Check again in Settings") { EmptyView() }
        case .active(.appleScript):
            Prompt(symbol: "music.note", title: "Play something in Spotify or Music", message: nil) { EmptyView() }
        case .idle, .active:
            Prompt(symbol: "music.note", title: "Play something in any app", message: nil) { EmptyView() }
        }
    }
}

private struct Prompt<Action: View>: View {
    let symbol: String
    let title: String
    let message: String?
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            EmptyState(symbol: symbol, title: title, message: message).fixedSize(horizontal: false, vertical: true)
            action.fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motionAppear()
    }
}

/// Header, artwork, track lines and position: one button that opens the source app, when there is one.
private struct SourceAppClickArea<Label: View>: View {
    let app: SourceApp?
    let open: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        if let app {
            Button(action: open) {
                label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle())
            .help(app.openLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(app.openLabel)
            .accessibilityAddTraits(.isButton)
        } else {
            label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The row's press feedback (0.98 on `Motion.press`) without its padding and fill: the card already hovers.
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .motion(Motion.press, value: configuration.isPressed)
    }
}

private struct TrackInfo: View {
    let state: NowPlayingState

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                Artwork(image: state.artwork).notchHero(.nowPlaying)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).notchStyle(.title).lineLimit(1)
                    if let artist = state.artist { Text(artist).notchStyle(.caption).lineLimit(1) }
                    if let album = state.album { Text(album).notchStyle(.caption).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(state.trackKey)
                .transition(.blurReplace)
            }
            .motion(Motion.morph, value: state.trackKey)

            if state.position(at: state.timestamp ?? .now) != nil {
                PositionRow(state: state).transition(.opacity)
            }
        }
    }
}

private struct TransportRow: View {
    let state: NowPlayingState
    let send: (MediaCommand) -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            GlassIconButton("backward.fill", label: "Previous track", kind: .plain, size: 28, tint: .secondary) { send(.previous) }
            GlassIconButton(state.isPlaying ? "pause.fill" : "play.fill", label: state.isPlaying ? "Pause" : "Play", size: 32) {
                send(.togglePlayPause)
            }
            .contentTransition(.symbolEffect(.replace))
            GlassIconButton("forward.fill", label: "Next track", kind: .plain, size: 28, tint: .secondary) { send(.next) }
        }
        .frame(maxWidth: .infinity)
        .motion(Motion.quick, value: state.isPlaying)
    }
}

/// Elapsed, bar, remaining. Ticks about once a second while playing, frozen while paused.
private struct PositionRow: View {
    let state: NowPlayingState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !state.isPlaying)) { context in
            let position = state.position(at: context.date) ?? 0
            let duration = state.duration ?? 0
            HStack(spacing: Tokens.Spacing.s) {
                time(Format.playback(seconds: position))
                PositionBar(progress: duration > 0 ? position / duration : 0)
                time(Format.playback(seconds: duration - position, remaining: true))
            }
        }
    }

    private func time(_ text: String) -> some View {
        Text(text)
            .font(NotchTextStyle.caption.font.monospacedDigit())
            .foregroundStyle(NotchTextStyle.caption.color)
            .contentTransition(.numericText())
            .lineLimit(1)
            .fixedSize()
    }
}

private struct Artwork: View {
    let image: SendableImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
        ZStack {
            if let image {
                Image(decorative: image.cgImage, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image.cgImage))
                    .transition(.opacity.combined(with: .scale(0.92)))
            } else {
                Image(systemName: "music.note").font(NotchTextStyle.display.font).foregroundStyle(Tokens.Colors.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Tokens.Colors.cardFill)
                    .transition(.opacity)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Tokens.Colors.hairline, lineWidth: 1) }
        .motion(Motion.morph, value: image.map { ObjectIdentifier($0.cgImage) })
    }
}

struct NowPlayingSettings: View {
    let module: NowPlayingModule

    var body: some View {
        Form {
            LabeledContent("Source", value: sourceLabel)
            LabeledContent("System Now Playing") {
                HStack {
                    Text(checkLabel).foregroundStyle(.secondary)
                    Button("Check again") { module.checkAgain() }.disabled(module.isChecking)
                }
            }
            if module.phase == .needsConnect {
                LabeledContent("Spotify and Music") {
                    Button("Connect") { module.connect() }
                }
                Text("macOS asks once whether Notcher may control Spotify and Music.").font(.caption)
            }
            if let settings = module.settingsStore {
                Toggle("Show title and artist beside the notch", isOn: settings.binding(NowPlayingModule.showTitleInNotch))
                Toggle(isOn: settings.binding(NowPlayingModule.ambientArtwork)) {
                    Text("Ambient artwork")
                    Text("Artwork colour blooms through the card")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var checkLabel: String {
        if module.isChecking { return "Checking…" }
        guard let check = module.lastCheck else { return "Not checked" }
        return check.passed ? "Available" : "Unavailable"
    }

    private var sourceLabel: String {
        switch module.phase {
        case .active(let source): source.label
        case .idle: "Checking…"
        case .needsConnect: "Not connected"
        case .notAuthorized(let app): "\(app): automation denied"
        case .unavailable: "Unavailable"
        }
    }
}
