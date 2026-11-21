import NotchCore
import SwiftUI

struct NowPlayingCard: View {
    let module: NowPlayingModule

    var body: some View {
        if let state = module.state {
            GlassCard(padding: Tokens.Spacing.s) { TrackView(state: state, send: module.send) }
        } else {
            GlassCard { placeholder }
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch module.phase {
        case .needsConnect:
            HStack(spacing: Tokens.Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now Playing").notchStyle(.title).lineLimit(1)
                    Text("Spotify and Music").notchStyle(.caption).lineLimit(1)
                }
                Spacer(minLength: 0)
                GlassButton("Connect", prominence: .accent) { module.connect() }
            }
            .frame(maxHeight: .infinity)
            .motionAppear()
        case .notAuthorized(let app):
            EmptyState(symbol: "lock", title: "Notcher can't see \(app)", message: "Allow it in Privacy › Automation")
        case .unavailable:
            EmptyState(symbol: "music.note", title: "Now Playing unavailable")
        case .idle, .active:
            EmptyState(symbol: "music.note", title: "Nothing playing").motionAppear()
        }
    }
}

private struct TrackView: View {
    let state: NowPlayingState
    let send: (MediaCommand) -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Artwork(image: state.artwork)
                .scaleEffect(state.isPlaying ? 1 : 0.9)
                .opacity(state.isPlaying ? 1 : 0.75)
                .motion(Motion.morph, value: state.isPlaying)
                .notchHero(.nowPlaying)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).notchStyle(.title).lineLimit(1)
                    if let artist = state.artist { Text(artist).notchStyle(.caption).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(state.trackKey)
                .transition(.blurReplace)
                .padding(.top, Tokens.Spacing.xs)

                Spacer(minLength: 0)

                HStack(spacing: Tokens.Spacing.xs) {
                    GlassIconButton("backward.fill", label: "Previous track", size: 24, tint: .secondary) { send(.previous) }
                    GlassIconButton(state.isPlaying ? "pause.fill" : "play.fill", label: state.isPlaying ? "Pause" : "Play") {
                        send(.togglePlayPause)
                    }
                    .contentTransition(.symbolEffect(.replace))
                    GlassIconButton("forward.fill", label: "Next track", size: 24, tint: .secondary) { send(.next) }
                }
            }
            .motion(Motion.morph, value: state.trackKey)
        }
        .accessibilityElement(children: .contain)
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
        .aspectRatio(1, contentMode: .fit)
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
                Text("macOS will ask once whether Notcher may control Spotify and Music.").font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private var checkLabel: String {
        if module.isChecking { return "Checking..." }
        guard let check = module.lastCheck else { return "Not checked" }
        return check.passed ? "Available" : "Unavailable"
    }

    private var sourceLabel: String {
        switch module.phase {
        case .active(let source): source.label
        case .idle: "Checking..."
        case .needsConnect: "Not connected"
        case .notAuthorized(let app): "\(app): Automation denied"
        case .unavailable: "Unavailable"
        }
    }
}
