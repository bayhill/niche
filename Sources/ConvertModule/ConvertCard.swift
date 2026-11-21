import CoreGraphics
import ImageEngine
import NotchCore
import SwiftUI

/// The Home dashboard card (trailing slot): a header, then one row per file.
struct ConvertCard: View {
    let module: ConvertModule

    var body: some View {
        let running = module.batch?.isRunning == true
        GlassCard(spacing: Tokens.Spacing.s) {
            SectionHeader("Convert", symbol: "photo") {
                Group {
                    if module.showingOptions {
                        HeaderButton(title: "Done", help: "Close options") { toggleOptions() }
                    } else if running {
                        Text(module.headerTrailing)
                            .font(NotchTextStyle.numeric.font)
                            .foregroundStyle(Tokens.Colors.textSecondary)
                            .contentTransition(.numericText())
                            .accessibilityLabel("\(module.batch?.completed ?? 0) of \(module.batch?.total ?? 0) converted")
                    } else {
                        HeaderButton(title: module.headerTrailing, help: "Conversion options") { toggleOptions() }
                            .accessibilityLabel("Conversion options, \(ConvertSettings.summary(module.options))")
                    }
                }
                .transition(.opacity)
            }

            ZStack(alignment: .top) {
                if module.showingOptions {
                    OptionsPanel(module: module)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else if module.rows.isEmpty {
                    EmptyState(symbol: "photo", title: "Drop images on the notch", message: "PNG, JPEG and HEIC become WebP")
                        .transition(.opacity)
                } else {
                    RowList(module: module).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .motion(Motion.morph, value: module.showingOptions)
        .motion(Motion.morph, value: running)
        .motion(Motion.quick, value: module.options)
    }

    private func toggleOptions() { Motion.animate(Motion.morph) { module.showingOptions.toggle() } }
}

/// A quiet text control in the header: hover fill from `RowButtonStyle`, laid out as if it were plain text.
private struct HeaderButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).notchStyle(.caption).lineLimit(1).contentTransition(.numericText())
        }
        .buttonStyle(RowButtonStyle())
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
        .help(help)
    }
}

private struct RowList: View {
    let module: ConvertModule

    var body: some View {
        let visible = module.visibleRows
        let hero = module.heroRowID
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                FileRow(row: row, isHero: row.id == hero) { module.open(row) }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    .motionAppear(index)
            }
        }
        .motion(Motion.morph, value: visible.map(\.id))
    }
}

/// One file in any state. Always a `ResultRow` so state changes morph in place; while converting, a ring covers
/// the leading slot. Finished rows reveal the file on click and drag out as files.
private struct FileRow: View {
    let row: ConvertRow
    let isHero: Bool
    let action: () -> Void

    /// Lets the ring draw the leading slot itself (`ResultRow` has no slot for a custom view).
    private static let clearThumbnail: SendableImage? = {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage()
        else { return nil }
        return SendableImage(image)
    }()

    var body: some View {
        let converting: Double?? = if case .converting(let p) = row.state { .some(p) } else { .none }
        let failed = if case .failed = row.state { true } else { false }
        Button(action: action) {
            ResultRow(
                thumbnail: converting != nil ? Self.clearThumbnail : row.thumbnail,
                symbol: failed ? "exclamationmark.triangle" : "photo",
                symbolTint: failed ? .warning : .secondary,
                title: row.name, detail: row.detail,
                trailing: row.figure, trailingTint: row.figureTint
            )
            .overlay(alignment: .leading) {
                if let progress = converting {
                    ring(progress).transition(.opacity)
                }
            }
        }
        .buttonStyle(RowButtonStyle())
        .allowsHitTesting(row.output != nil)
        .fileDragSource(row.output.map { [$0] } ?? [])
        .padding(.horizontal, -6)
        .motion(Motion.morph, value: row.state)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func ring(_ progress: Double?) -> some View {
        let slot = ZStack {
            Tokens.Colors.cardFill
            if let progress {
                ProgressRing(progress: progress, size: 16, lineWidth: 2)
            } else {
                SpinnerRing(size: 16, lineWidth: 2)
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous))
        if isHero { slot.notchHero(.convert) } else { slot }
    }

    private var help: String {
        let lines = (row.output != nil ? ["Click to reveal in Finder, or drag out"] : []) + row.notes
        return lines.joined(separator: "\n")
    }
}

/// Inline options, so nothing requires leaving the card.
private struct OptionsPanel: View {
    let module: ConvertModule

    var body: some View {
        let o = module.options
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Spacing.xs) {
                Text("Quality").notchStyle(.body)
                Spacer(minLength: Tokens.Spacing.xs)
                GlassIconButton("minus", label: "Lower quality", kind: .plain, size: 20) { change { module.stepQuality(by: -1) } }
                    .disabled(o.lossless || o.quality <= 0)
                Text("\(o.quality)")
                    .notchStyle(.numeric)
                    .contentTransition(.numericText(value: Double(o.quality)))
                    .frame(minWidth: 22)
                GlassIconButton("plus", label: "Higher quality", kind: .plain, size: 20) { change { module.stepQuality(by: 1) } }
                    .disabled(o.lossless || o.quality >= 100)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .opacity(o.lossless ? 0.4 : 1)

            OptionButton(label: "Lossless", value: o.lossless ? "On" : "Off", active: o.lossless) { change { module.toggleLossless() } }
            OptionButton(label: "Max size", value: ConvertSettings.edgeLabel(o.maxPixelEdge), active: o.maxPixelEdge != nil) {
                change { module.cycleMaxEdge() }
            }
            OptionButton(label: "Metadata", value: o.stripMetadata ? "Strip" : "Keep", active: !o.stripMetadata) {
                change { module.toggleStripMetadata() }
            }
        }
        .padding(.horizontal, -6)
    }

    private func change(_ body: () -> Void) { Motion.animate(Motion.quick, body) }
}

private struct OptionButton: View {
    let label: String
    let value: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.xs) {
                Text(label).notchStyle(.body)
                Spacer(minLength: Tokens.Spacing.xs)
                Text(value)
                    .font(NotchTextStyle.numeric.font)
                    .foregroundStyle(active ? Tokens.Colors.accent : Tokens.Colors.textSecondary)
                    .contentTransition(.numericText())
                Image(systemName: "chevron.up.chevron.down")
                    .font(NotchTextStyle.label.font)
                    .foregroundStyle(Tokens.Colors.textTertiary)
            }
            .frame(height: 20)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Settings window pane.
struct ConvertSettingsForm: View {
    let settings: SettingsStore

    var body: some View {
        let lossless = settings.get(ConvertSettings.lossless)
        let quality = Binding<Double>(
            get: { Double(settings.get(ConvertSettings.quality)) },
            set: { settings.set(ConvertSettings.quality, Int($0.rounded())) }
        )
        let keepMetadata = Binding<Bool>(
            get: { !settings.get(ConvertSettings.stripMetadata) },
            set: { settings.set(ConvertSettings.stripMetadata, !$0) }
        )
        Form {
            Section {
                Toggle("Lossless", isOn: settings.binding(ConvertSettings.lossless))
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: quality, in: 0...100, step: Double(ConvertSettings.qualityStep))
                        Text("\(settings.get(ConvertSettings.quality))").monospacedDigit().frame(minWidth: 28, alignment: .trailing)
                    }
                }
                .disabled(lossless)
                Picker("Maximum size", selection: settings.binding(ConvertSettings.maxPixelEdge)) {
                    ForEach(ConvertSettings.maxEdgeChoices, id: \.self) { edge in
                        Text(edge.map { "\($0) px longest edge" } ?? "Original size").tag(edge)
                    }
                }
                Toggle("Keep metadata", isOn: keepMetadata)
            } header: {
                Text("WebP output")
            } footer: {
                Text("Images dropped on the notch are converted with these settings. The WebP is saved next to the original; if that folder can\u{2019}t be written, or the image has no file, it goes to Downloads. Keeping metadata embeds the colour profile and the camera\u{2019}s EXIF data, including location.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
