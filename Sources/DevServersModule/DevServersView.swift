import NotchCore
import SwiftUI

/// The Dev servers page: a header, then the servers by port, two to a row. Six fit the page; more scroll.
struct DevServersPage: View {
    let module: DevServersModule
    /// `false` lays the rows out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    var body: some View {
        let servers = module.servers
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader("Dev servers", symbol: "server.rack") {
                if module.phase == .listed, !servers.isEmpty {
                    Text(servers.count == 1 ? "1 listening" : "\(servers.count) listening")
                        .notchStyle(.caption)
                        .contentTransition(.numericText(value: Double(servers.count)))
                        .transition(.opacity)
                }
            }

            ZStack {
                switch module.phase {
                case .waiting:
                    Color.clear
                case .failed where servers.isEmpty:
                    StatusMessage(
                        symbol: "exclamationmark.triangle", title: "Listening processes could not be read",
                        message: "Another try follows in a few seconds while this page is open."
                    ) {
                        GlassButton("Try again", symbol: "arrow.clockwise") { Task { await module.refresh() } }
                    }
                    .transition(.opacity)
                case .listed where servers.isEmpty:
                    EmptyState(symbol: "server.rack", title: "Start a dev server in a project folder", message: emptyMessage)
                        .transition(.opacity)
                case .listed, .failed:
                    ServerGrid(module: module, servers: servers, scrolls: scrolls)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { module.pageAppeared() }
        .onDisappear { module.pageDisappeared() }
    }

    private var emptyMessage: String {
        module.showsAll
            ? "Every process listening on a TCP port shows here."
            : "Servers started from a folder in the home folder show here, by port."
    }
}

/// Explanation plus an action, centred.
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

/// Two columns of rows that scroll when they overflow.
private struct ServerGrid: View {
    let module: DevServersModule
    let servers: [DevServer]
    let scrolls: Bool

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: Tokens.Spacing.s), GridItem(.flexible(), spacing: Tokens.Spacing.s)]
        let grid = LazyVGrid(columns: columns, alignment: .leading, spacing: Tokens.Spacing.s) {
            ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                ServerRow(server: server, module: module)
                    .motionAppear(min(index, 6))
                    .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 0.8).combined(with: .opacity)))
            }
        }
        .padding(.horizontal, 1)
        if scrolls {
            ScrollView(.vertical, showsIndicators: false) { grid }
                // One point of room so the first and last rows' outlines are not cut by the scroll bounds.
                .contentMargins(.vertical, 1, for: .scrollContent)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            Color.clear.overlay(alignment: .topLeading) { grid.fixedSize(horizontal: false, vertical: true) }.clipped()
        }
    }
}

/// One server: the port, the project and the process, a mark when other devices can reach it, and its actions.
/// A click on the row opens it in the browser.
struct ServerRow: View {
    let server: DevServer
    let module: DevServersModule

    static let actionSize: CGFloat = 22
    static let portWidth: CGFloat = 68

    var body: some View {
        let note = module.note?.server == server.id ? module.note?.kind : nil
        Button { module.open(server) } label: {
            GlassCard(padding: Tokens.Spacing.s, spacing: 0, highlighted: note == .copied, hoverable: true) {
                HStack(spacing: Tokens.Spacing.s) {
                    Text(server.portText)
                        .notchStyle(.display)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: Self.portWidth, alignment: .leading)
                        .contentTransition(.numericText(value: Double(server.port)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.projectName ?? server.processName)
                            .notchStyle(.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        detail(note)
                    }
                    Spacer(minLength: 0)
                    // Room for the actions, which sit outside the button.
                    Color.clear.frame(width: 3 * Self.actionSize, height: 1)
                }
            }
        }
        .buttonStyle(RowPressStyle())
        .overlay(alignment: .trailing) { actions(note).padding(.trailing, Tokens.Spacing.s - 2) }
        .motion(Motion.quick, value: note)
        .help("Open \(server.address)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens it in the browser")
    }

    @ViewBuilder private func detail(_ note: DevServersModule.RowNote?) -> some View {
        Group {
            switch note {
            case .copied:
                Label("Copied", systemImage: "checkmark").labelStyle(.titleAndIcon).notchStyle(.caption)
            case .confirmStop:
                Text("Click again to stop").font(NotchTextStyle.caption.font).foregroundStyle(TintRole.warning.color)
            case .stopping:
                Text("Stopping").notchStyle(.caption)
            case .stillRunning:
                Text("Still running").font(NotchTextStyle.caption.font).foregroundStyle(TintRole.warning.color)
            case .notStopped:
                Text("Not stopped").font(NotchTextStyle.caption.font).foregroundStyle(TintRole.warning.color)
            case nil:
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(server.projectName == nil ? "pid \(server.pid)" : server.processName).notchStyle(.caption)
                    if server.reach.isExposed { NetworkMark(server: server) }
                }
            }
        }
        .lineLimit(1)
        .transition(.opacity)
    }

    private func actions(_ note: DevServersModule.RowNote?) -> some View {
        HStack(spacing: 0) {
            GlassIconButton("arrow.up.right", label: "Open in browser", kind: .plain, size: Self.actionSize, tint: .secondary) {
                module.open(server)
            }
            GlassIconButton("doc.on.doc", label: "Copy \(server.address)", kind: .plain, size: Self.actionSize, tint: .secondary) {
                module.copy(server)
            }
            Group {
                if note == .stopping {
                    SpinnerRing(size: 12, lineWidth: 2, tint: .secondary).frame(width: Self.actionSize, height: Self.actionSize)
                } else {
                    let armed = note == .confirmStop
                    GlassIconButton(
                        armed ? "stop.circle.fill" : "stop.circle", label: armed ? "Click again to stop" : "Stop",
                        kind: .plain, size: Self.actionSize, tint: armed ? .warning : .secondary
                    ) { module.requestStop(server) }
                    .contentTransition(.symbolEffect(.replace))
                }
            }
            .transition(.opacity)
        }
    }

    private var accessibilityText: String {
        var parts = ["Port \(server.port)", server.projectName ?? server.processName]
        if server.projectName != nil { parts.append(server.processName) }
        if server.reach.isExposed { parts.append("open to the network") }
        return parts.joined(separator: ", ")
    }
}

/// "Network" in the warning tint: the port accepts connections from other devices, not just this Mac.
private struct NetworkMark: View {
    let server: DevServer

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "network").imageScale(.small)
            Text("Network")
        }
        .font(NotchTextStyle.caption.font)
        .foregroundStyle(TintRole.warning.color)
        .fixedSize()
        .help(explanation)
    }

    private var explanation: String {
        if server.reach == .allInterfaces { return "Listens on all interfaces: other devices on the network can reach it" }
        return "Listens on \(server.exposedHost ?? "a network address"): other devices on that network can reach it"
    }
}

/// Press feedback for a whole row (the row scale from the design kit).
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .motion(Motion.press, value: configuration.isPressed)
    }
}

/// Settings pane: which listening processes the page lists.
struct DevServersSettings: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("List every listening process", isOn: settings.binding(DevServersModule.showAllKey))
            } footer: {
                Text(
                    "Off: only servers started from a folder inside the home folder, leaving out apps and macOS "
                        + "services. On: every process of this user that listens on a TCP port. The list is read "
                        + "only while the page shows. Stop asks the process to quit and never forces it."
                )
            }
        }
        .formStyle(.grouped)
    }
}
