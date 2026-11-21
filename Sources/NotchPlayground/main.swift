import AppKit
import NotchCore
import NotchCoreTesting
import NotchUI
import SwiftUI

// Runs the real NotchController with fake modules covering every placement and every live-activity glyph.
//
//   swift run NotchPlayground [DebugOptions flags] [--glyph symbol|progress|text|countdown|image|equalizer|nowplaying|nowplaying-short|nowplaying-long|files]
//                             [--no-activity] [--quit-after <seconds>] [--hover-opens]

private struct PlaygroundOptions {
    var glyph: String?
    var noActivity = false
    var quitAfter: Double?
    var hoverOpens = false

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--glyph": glyph = it.next()
            case "--no-activity": noActivity = true
            case "--quit-after": quitAfter = it.next().flatMap(Double.init)
            case "--hover-opens": hoverOpens = true
            default: break
            }
        }
    }
}

@MainActor
private enum Samples {
    static let art = SendableImage(gradient(width: 64, height: 64))

    static func gradient(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [CGColor(srgbRed: 0.98, green: 0.36, blue: 0.47, alpha: 1), CGColor(srgbRed: 0.42, green: 0.30, blue: 0.95, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return ctx.makeImage()!
    }

    static func activity(_ module: ModuleID, _ priority: LiveActivity.Priority, _ leading: ActivityGlyph, _ trailing: ActivityGlyph?, _ label: String) -> LiveActivity {
        LiveActivity(id: "\(module.rawValue).sample", module: module, priority: priority, leading: leading, trailing: trailing, accessibilityLabel: label)
    }
}

@MainActor
private func makeModules(_ options: PlaygroundOptions) -> [FakeModule] {
    let nowPlaying = FakeModule(.nowPlaying, title: "Now Playing", symbol: "music.note", placement: .dashboard(.leadingTop), view: AnyView(
        GlassCard(spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                Image(decorative: Samples.art.cgImage, scale: 2).resizable().frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))
                    .notchHero(.nowPlaying)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weightless").notchStyle(.title).lineLimit(1)
                    Text("Marconi Union").notchStyle(.caption).lineLimit(1)
                }
                Spacer(minLength: 0)
                EqualizerBars(playing: true)
            }
        }
    ))
    let calendar = FakeModule(.calendar, title: "Calendar", symbol: "calendar", placement: .dashboard(.leadingBottom), view: AnyView(
        GlassCard {
            SectionHeader("Next", symbol: "calendar") { CountdownText(to: .now.addingTimeInterval(725)).notchHero(.calendar) }
            Text("Design review").notchStyle(.title).lineLimit(1)
        }
    ))
    let convert = FakeModule(.convert, title: "Convert", symbol: "photo.on.rectangle", placement: .dashboard(.center), view: AnyView(
        GlassCard {
            SectionHeader("Convert", symbol: "photo") { ProgressRing(progress: 0.62).notchHero(.convert) }
            ResultRow(symbol: "photo", title: "hero-banner.webp", detail: "1.2 MB → 264 KB", trailing: Format.saving(0.78), trailingTint: .success)
            ResultRow(symbol: "photo", title: "team.webp", detail: "840 KB → 190 KB", trailing: Format.saving(0.77), trailingTint: .success)
            Spacer(minLength: 0)
        }
    ))
    convert.acceptance = { $0.isImage ? .accept(weight: DropWeight.preferred) : .reject }
    convert.hint = DropHint(title: "Convert to WebP", subtitle: "Quality 80 · saved next to the original", symbol: "photo.badge.arrow.down")

    let claude = FakeModule(.claudeAgents, title: "Claude", symbol: "sparkles", placement: .dashboard(.trailing), view: AnyView(
        GlassCard {
            SectionHeader("Claude", symbol: "sparkles") { StatusDot(.warning, pulsing: true).notchHero(.claudeAgents) }
            ResultRow(symbol: "terminal", symbolTint: .warning, title: "notcher", detail: "Needs permission", trailing: "2m", trailingTint: .warning)
            ResultRow(symbol: "terminal", title: "lanternfly", detail: "Working")
            Spacer(minLength: 0)
        }
    ))
    let shelf = FakeModule(.shelf, title: "Shelf", symbol: "tray.full", placement: .page(order: 0), view: AnyView(
        GlassCard {
            SectionHeader("Shelf", symbol: "tray.full") { Text("3 items").notchStyle(.caption) }
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(["report.pdf", "mockup.png", "notes.txt"], id: \.self) { name in
                    ResultRow(symbol: "doc", title: name, detail: "Dropped").frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
        }
    ))
    shelf.acceptance = { item in item.fileURL != nil ? .accept(weight: DropWeight.fallback) : .reject }
    shelf.hint = DropHint(title: "Add to Shelf", subtitle: "Keeps a reference, never moves the file", symbol: "tray.and.arrow.down")
    let clipboard = FakeModule(.clipboard, title: "Clipboard", symbol: "doc.on.clipboard", placement: .page(order: 1), view: AnyView(
        GlassCard { EmptyState(symbol: "doc.on.clipboard", title: "Clipboard history", message: "Copied items appear here.") }
    ))
    let hidden = FakeModule("hiddenSample", title: "Hidden", symbol: "eye.slash", placement: .hidden)

    let soon = Date.now.addingTimeInterval(725)
    let base: [(FakeModule, LiveActivity.Priority, ActivityGlyph, ActivityGlyph?, String)] = switch options.glyph {
    case "files": []
    case "symbol": [(claude, .attention, .symbol("sparkles", tint: .warning, pulse: true), .text("Allow?"), "Claude needs permission")]
    case "progress": [(convert, .progress, .progress(0.62), .text("3/12"), "Converting 3 of 12")]
    case "text": [(convert, .progress, .text("3/12"), .progress(0.25), "Converting 3 of 12")]
    case "countdown": [(calendar, .passive, .countdown(to: soon), .symbol("calendar", tint: .accent), "Design review soon")]
    case "image", "nowplaying", "nowplaying-short", "nowplaying-long": [(nowPlaying, .ambient, .image(Samples.art), .equalizer(playing: true), "Weightless playing")]
    case "equalizer": [(nowPlaying, .ambient, .equalizer(playing: true), .image(Samples.art), "Weightless playing")]
    default: [
        (nowPlaying, .ambient, .image(Samples.art), .equalizer(playing: true), "Weightless playing"),
        (convert, .progress, .progress(0.1), .text("1/12"), "Converting"),
    ]
    }
    if !options.noActivity {
        for (module, priority, leading, trailing, label) in base {
            module.liveActivity = Samples.activity(module.id, priority, leading, trailing, label)
        }
        // Wing text: `--glyph nowplaying` (long title), `nowplaying-short`, or `nowplaying-long` (both lines past the cap).
        let texts: (String, String)? = switch options.glyph {
        case "nowplaying": ("Weightless (Ambient Transmission, Part 1) – Remastered 2024", "Marconi Union")
        case "nowplaying-short": ("Weightless", "Marconi Union")
        case "nowplaying-long": (
            "Weightless (Ambient Transmission, Part 1) – Live at the Royal Albert Hall, Remastered 2024 Deluxe Edition",
            "Marconi Union, Jules Buckley, The Metropole Orkest and the BBC Concert Orchestra"
        )
        default: nil
        }
        if let texts, var activity = nowPlaying.liveActivity {
            activity.leadingText = texts.0
            activity.trailingText = texts.1
            nowPlaying.liveActivity = activity
        }
    }
    return [nowPlaying, calendar, convert, claude, shelf, clipboard, hidden]
}

/// Ticks the convert progress activity so live updates can be seen animating in place.
@MainActor
private func tickConvert(_ module: FakeModule) {
    Task {
        var done = 1
        while true {
            try? await Task.sleep(for: .seconds(0.8))
            guard var activity = module.liveActivity, case .progress = activity.leading else { return }
            done = done % 12 + 1
            activity.leading = .progress(Double(done) / 12)
            activity.trailing = .text("\(done)/12")
            activity.updatedAt = .now
            module.liveActivity = activity
        }
    }
}

setvbuf(stdout, nil, _IONBF, 0)
MainActor.assumeIsolated {
    let args = Array(CommandLine.arguments.dropFirst())
    let options = PlaygroundOptions(args)
    let debug = DebugOptions(arguments: args)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let root = FileManager.default.temporaryDirectory.appending(path: "notcher-playground", directoryHint: .isDirectory)
    let directories = AppDirectories.rooted(at: root)
    let settings = SettingsStore.ephemeral()
    settings.set(NotchSettings.openOnHover, options.hoverOpens)
    let services = AppServices()
    services.openSettings = { id in print("openSettings(\(id?.rawValue ?? "nil"))") }

    let modules = makeModules(options)
    if let convert = modules.first(where: { $0.id == .convert }), options.glyph == nil { tickConvert(convert) }
    // `--glyph files`: a finished conversion whose two outputs can be dragged straight out of the bar.
    if options.glyph == "files", let convert = modules.first(where: { $0.id == .convert }) {
        let folder = root.appending(path: "Converted", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [("hero-banner.png", 0.25), ("team.png", 0.85)].compactMap { name, hue -> URL? in
            let image = TestImage.solid(width: 64, height: 64, red: hue, green: 0.5, blue: 1 - hue)
            return try? TestImage.write(image, to: folder.appending(path: name))
        }
        convert.liveActivity = LiveActivity(
            id: "convert.done", module: .convert, priority: .progress,
            leading: .symbol("checkmark.circle.fill", tint: .success), trailing: .text(Format.saving(0.78), tint: .success),
            leadingText: "2 files ready", files: files, expiresAt: .now.addingTimeInterval(6), accessibilityLabel: "Converted 2 files"
        )
    }
    let controller = NotchController(modules: modules, services: services, settings: settings, directories: directories, debug: debug)
    controller.start()

    if let seconds = options.quitAfter {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            controller.stop()
            exit(0)
        }
    }
    app.run()
}
