import ImageEngine
import NotchCore
import SwiftUI

/// The Home dashboard card (centre slot).
struct ConvertCard: View {
    let module: ConvertModule

    var body: some View {
        let options = module.options
        GlassCard(spacing: Tokens.Spacing.s) {
            SectionHeader("WebP", symbol: "photo") {
                if !module.showingOptions {
                    Text(ConvertSettings.shortSummary(options)).notchStyle(.caption).lineLimit(1)
                        .contentTransition(.numericText()).transition(.opacity)
                }
                GlassIconButton(
                    module.showingOptions ? "checkmark" : "slider.horizontal.3",
                    label: module.showingOptions ? "Done" : "Conversion options", kind: .plain, size: 20
                ) {
                    Motion.animate(Motion.morph) { module.showingOptions.toggle() }
                }
                .contentTransition(.symbolEffect(.replace))
            }

            ZStack(alignment: .top) {
                if module.showingOptions {
                    OptionsPanel(module: module)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else if module.recent.isEmpty && module.batch == nil {
                    DropInvite().transition(.opacity)
                } else {
                    ResultsList(module: module).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .motion(Motion.morph, value: module.showingOptions)
        .motion(Motion.quick, value: options)
    }
}

/// Inviting empty state before the first conversion.
private struct DropInvite: View {
    var body: some View {
        EmptyState(symbol: "photo.badge.arrow.down", title: "Drop images on the notch", message: "WebP lands next to the original")
            .padding(Tokens.Spacing.s)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Colors.cardStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .motionAppear()
    }
}

private struct ResultsList: View {
    let module: ConvertModule

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let batch = module.batch {
                BatchStrip(batch: batch)
                    .padding(.bottom, Tokens.Spacing.xs)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ForEach(Array(module.recent.prefix(ConvertModule.recentLimit).enumerated()), id: \.element.id) { index, item in
                ResultButton(item: item) { module.open(item) }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    .motionAppear(index)
            }
        }
        .motion(Motion.morph, value: module.recent.map(\.id))
        .motion(Motion.morph, value: module.batch == nil)
    }
}

/// "Converting… 3/12" while running; the total saving once done. Its glyph is the hero for the wing.
private struct BatchStrip: View {
    let batch: BatchProgress

    var body: some View {
        let saved = batch.savedFraction
        let warn = batch.failed > 0 || (saved ?? 0) < 0 || saved == nil
        let tint: TintRole = batch.isRunning ? .accent : (warn ? .warning : .success)
        HStack(spacing: Tokens.Spacing.s) {
            ZStack {
                if batch.isRunning {
                    ProgressRing(progress: batch.fraction, size: 14, lineWidth: 2)
                } else {
                    Image(systemName: warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(NotchTextStyle.title.font)
                        .foregroundStyle(tint.color)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .notchHero(.convert)

            Text(caption).notchStyle(.caption).lineLimit(1).contentTransition(.numericText())
            Spacer(minLength: Tokens.Spacing.xs)
            Text(figure)
                .font(NotchTextStyle.numeric.font)
                .foregroundStyle(batch.isRunning ? Tokens.Colors.textPrimary : tint.color)
                .contentTransition(.numericText())
                .lineLimit(1).fixedSize()
        }
        .frame(height: 18)
        .motion(Motion.morph, value: batch)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        if batch.isRunning { return "Converting\u{2026}" }
        if batch.succeeded == 0 { return batch.total == 1 ? "Failed" : "All failed" }
        if batch.failed > 0 { return "\(batch.failed) failed" }
        return batch.total == 1 ? "Done" : "\(batch.succeeded) converted"
    }

    private var figure: String {
        if batch.isRunning { return "\(batch.completed)/\(batch.total)" }
        return batch.savedFraction.map(Format.saving) ?? "\(batch.failed)/\(batch.total)"
    }
}

/// A result row: click reveals in Finder, drag carries the file out.
private struct ResultButton: View {
    let item: ConvertedItem
    let action: () -> Void

    var body: some View {
        let failed = item.failure != nil
        Button(action: action) {
            ResultRow(
                thumbnail: item.thumbnail, symbol: failed ? "exclamationmark.triangle" : "photo",
                symbolTint: failed ? .warning : .secondary, title: item.name, detail: item.detail,
                trailing: failed ? nil : Format.saving(item.savedFraction),
                trailingTint: item.savedFraction < 0 ? .warning : .success
            )
        }
        .buttonStyle(RowButtonStyle())
        .disabled(failed)
        .fileDragSource(item.output.map { [$0] } ?? [])
        .padding(.horizontal, -6)
        .help(help)
    }

    private var help: String {
        let lines = (item.failure == nil ? ["Click to show in Finder, or drag it out"] : []) + item.notes
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
