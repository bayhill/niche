import NotchCore
import SwiftUI

/// The centre dashboard card (210 × 184): header, artwork with track lines, live position, transport.
struct NowPlayingCard: View {
    let module: NowPlayingModule

    var body: some View {
        let state = module.state
        GlassCard(ambient: module.ambientArtwork ? state?.artwork : nil) {
            SectionHeader("Now Playing", symbol: "music.note") {
                EqualizerBars(playing: state?.isPlaying ?? false)
            }
            if let state {
                TrackView(state: state, send: module.send)
                    .transition(.opacity)
            } else {
                placeholder.transition(.opacity)
            }
        }
        .motion(Motion.morph, value: state == nil)
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

private struct TrackView: View {
    let state: NowPlayingState
    let send: (MediaCommand) -> Void

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

            Spacer(minLength: 0)

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
        .accessibilityElement(children: .contain)
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
