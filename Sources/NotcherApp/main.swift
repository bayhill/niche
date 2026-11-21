import AppKit
import NotchCore
import SwiftUI

// Phase 0 stub: proves the hand-built bundle launches, sits on the notch, and shows the design kit.
// Replaced by the real composition root in Phase 2.

private struct KitGallery: View {
    let notch: CGSize
    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: Tokens.Radius.notchOpenBottom, bottomTrailingRadius: Tokens.Radius.notchOpenBottom, style: .continuous)
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: PanelLayout.gap) {
                VStack(spacing: PanelLayout.gap) {
                    GlassCard {
                        HStack(spacing: Tokens.Spacing.s) {
                            EqualizerBars(playing: true)
                            VStack(alignment: .leading) { Text("Weightless").notchStyle(.title); Text("Marconi Union").notchStyle(.caption) }
                            Spacer()
                            GlassIconButton("playpause.fill", label: "Play or pause") {}
                        }
                    }.motionAppear(0)
                    GlassCard {
                        SectionHeader("Next meeting", symbol: "calendar") { CountdownText(to: .now.addingTimeInterval(725)) }
                        Text("Design review").notchStyle(.title)
                    }.motionAppear(1)
                }
                GlassCard(highlighted: true) {
                    SectionHeader("Convert", symbol: "photo") { Text("WebP 80").notchStyle(.caption) }
                    ResultRow(symbol: "photo", title: "hero-banner.webp", detail: "1.2 MB → 264 KB", trailing: Format.saving(0.78), trailingTint: .success)
                    ResultRow(symbol: "photo", title: "team.webp", detail: "840 KB → 190 KB", trailing: Format.saving(0.77), trailingTint: .success)
                    Spacer(minLength: 0)
                    HStack { GlassButton("Options", symbol: "slider.horizontal.3") {}; GlassButton("Reveal", prominence: .accent) {} }
                }.motionAppear(2)
                GlassCard {
                    SectionHeader("Claude", symbol: "sparkles") { StatusDot(.warning, pulsing: true) }
                    ResultRow(symbol: "terminal", symbolTint: .warning, title: "notcher", detail: "Needs permission", trailing: "2m", trailingTint: .warning)
                    ResultRow(symbol: "terminal", title: "lanternfly", detail: "Working", trailing: nil)
                    Spacer(minLength: 0)
                    HStack { ProgressRing(progress: 0.62); Text("3/12").notchStyle(.numeric) }
                }.motionAppear(3)
            }
            .padding(PanelLayout.contentInsets)
        }
        .frame(width: PanelLayout.expandedSize.width, height: PanelLayout.expandedSize.height + notch.height)
        .background { NotchSurface(shape: shape, capHeight: notch.height, glassAmount: 1) }
    }
}

@MainActor
final class StubDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = DebugOptions.fromProcess
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let metrics = ScreenMetrics(screen: screen)
        let notch = metrics.effectiveNotchRect(simulated: options.simulateNotch)
        if options.dumpMetrics { print("metrics \(metrics)\nnotch \(notch)") }
        Log.logger("app").notice("stub started; notch \(notch.debugDescription, privacy: .public)")

        let expanded = options.forceState == "expanded"
        let size = expanded
            ? CGSize(width: PanelLayout.expandedSize.width, height: PanelLayout.expandedSize.height + notch.height)
            : notch.size
        let frame = CGRect(x: notch.midX - size.width / 2, y: metrics.frame.maxY - size.height, width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let closedShape = UnevenRoundedRectangle(bottomLeadingRadius: Tokens.Radius.notchClosedBottom, bottomTrailingRadius: Tokens.Radius.notchClosedBottom, style: .continuous)
        panel.contentView = expanded
            ? NSHostingView(rootView: KitGallery(notch: notch.size))
            : NSHostingView(rootView: NotchSurface(shape: closedShape, capHeight: notch.height, glassAmount: 0))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

setvbuf(stdout, nil, _IONBF, 0)
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = StubDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
