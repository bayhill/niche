import NotchCore
import SwiftUI

/// The Colour page: the pick button and format choice on the left, the picks in the middle, the contrast of two
/// picks on the right.
struct ColourPage: View {
    let module: ColourModule
    /// `false` lays the picks out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    static let controlsWidth: CGFloat = 124
    static let contrastWidth: CGFloat = 168

    var body: some View {
        let picks = module.picks
        HStack(alignment: .top, spacing: PanelLayout.gap) {
            Controls(module: module).frame(width: Self.controlsWidth)
            ZStack {
                if picks.isEmpty {
                    EmptyState(symbol: "eyedropper", title: "Pick a colour anywhere on screen", message: emptyMessage)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    HStack(alignment: .top, spacing: PanelLayout.gap) {
                        Swatches(module: module, scrolls: scrolls)
                        ContrastCard(module: module).frame(width: Self.contrastWidth)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyMessage: String {
        module.copiesOnPick ? "Each pick is copied as \(module.format.label) and kept here." : "Picks are kept here, newest first."
    }
}

/// "Pick a colour" and the format a click copies.
private struct Controls: View {
    let module: ColourModule

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            GlassButton("Pick a colour", symbol: "eyedropper", prominence: .accent) {
                Task { await module.pick() }
            }
            .fixedSize()
            .disabled(module.isPicking)
            .accessibilityHint("Shows a magnifier. Click any pixel on screen to pick its colour.")

            SectionHeader("Copy as")
            VStack(spacing: 0) {
                ForEach(ColourFormat.allCases) { format in
                    FormatRow(format: format, selected: module.format == format) { module.setFormat(format) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One choice in the format list: its name, and a check on the one in use.
private struct FormatRow: View {
    let format: ColourFormat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.xs) {
                Text(format.label).notchStyle(selected ? .body : .caption).lineLimit(1)
                Spacer(minLength: Tokens.Spacing.xs)
                if selected {
                    Image(systemName: "checkmark")
                        .font(NotchTextStyle.label.font)
                        .foregroundStyle(Tokens.Colors.accent)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .motion(Motion.quick, value: selected)
        .accessibilityLabel("Copy as \(format.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The picks, newest first, two to a row.
private struct Swatches: View {
    let module: ColourModule
    let scrolls: Bool

    var body: some View {
        let picks = module.picks
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(module.isComparing ? "Choose two to compare" : "Picks") {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text("\(picks.count) of \(module.capacity)")
                        .notchStyle(.caption)
                        .contentTransition(.numericText(value: Double(picks.count)))
                    GlassIconButton(
                        "circle.lefthalf.filled", label: module.isComparing ? "Done choosing" : "Choose two to compare",
                        kind: .plain, size: 20, tint: module.isComparing ? .accent : .secondary
                    ) { module.setComparing(!module.isComparing) }
                    GlassIconButton("trash", label: "Clear picks", kind: .plain, size: 20) { module.clear() }
                }
            }
            let grid = SwatchGrid(module: module, picks: picks)
            if scrolls {
                ScrollView(.vertical, showsIndicators: false) { grid }
                    .contentMargins(.vertical, 1, for: .scrollContent)
                    .scrollEdgeEffectStyle(.soft, for: .vertical)
            } else {
                Color.clear.overlay(alignment: .topLeading) { grid.fixedSize(horizontal: false, vertical: true) }.clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SwatchGrid: View {
    let module: ColourModule
    let picks: [ColourPick]

    var body: some View {
        Grid(horizontalSpacing: Tokens.Spacing.xs, verticalSpacing: Tokens.Spacing.xs) {
            ForEach(Array(stride(from: 0, to: picks.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + 2, picks.count), id: \.self) { index in
                        SwatchCard(pick: picks[index], module: module, isNewest: index == 0)
                            .motionAppear(min(index, 6))
                    }
                    if start + 1 >= picks.count { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
        .padding(.horizontal, 1)
    }
}

/// One pick: its colour and its value in the chosen format. Click copies (or chooses it for contrast).
private struct SwatchCard: View {
    let pick: ColourPick
    let module: ColourModule
    let isNewest: Bool

    var body: some View {
        let format = module.format
        let value = pick.colour.formatted(format)
        let copied = module.copiedID == pick.id
        let chosen = module.isComparing && module.selection.isChosen(pick.id)
        Button { module.activate(pick) } label: {
            GlassCard(padding: Tokens.Spacing.xs, spacing: 0, highlighted: copied || chosen, hoverable: true) {
                HStack(spacing: Tokens.Spacing.s) {
                    Swatch(colour: pick.colour)
                        .frame(width: 22, height: 22)
                        .modifier(HeroIf(active: isNewest))
                    VStack(alignment: .leading, spacing: 1) {
                        ViewThatFits(in: .horizontal) {
                            Text(value.text).notchStyle(.numeric).lineLimit(1).fixedSize()
                            Text(value.compact).notchStyle(.numeric).lineLimit(1)
                        }
                        detail(value: value, copied: copied, chosen: chosen)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(CardPressStyle())
        .help(value.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(value))
        .accessibilityHint(module.isComparing ? "Chooses it for the contrast check" : "Copies the value")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private func detail(value: FormattedColour, copied: Bool, chosen: Bool) -> some View {
        Group {
            if copied {
                Label("Copied", systemImage: "checkmark").labelStyle(.titleAndIcon)
            } else if chosen {
                Text("Chosen")
            } else if value.clamped {
                Text("Clamped to sRGB")
            } else if !pick.colour.isInSRGBGamut {
                Text("Outside sRGB")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Format.age(seconds: context.date.timeIntervalSince(pick.pickedAt)))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
        .notchStyle(.caption)
        .lineLimit(1)
        .contentTransition(.opacity)
    }

    private func accessibilityText(_ value: FormattedColour) -> String {
        if value.clamped { return "\(value.text), clamped to sRGB" }
        if !pick.colour.isInSRGBGamut { return "\(value.text), outside sRGB" }
        return value.text
    }
}

/// The picked colour itself, edged with a hairline so dark and light picks both keep an outline.
private struct Swatch: View {
    let colour: Colour

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous)
        shape.fill(colour.swatchColor)
            .overlay { shape.strokeBorder(Tokens.Colors.hairline, lineWidth: 1) }
    }
}

/// `.notchHero(.colour)` on the newest swatch only, so there is exactly one hero.
private struct HeroIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.notchHero(.colour) } else { content }
    }
}

/// Ratio, verdicts and an "Aa" preview each way for the pair being compared.
private struct ContrastCard: View {
    let module: ColourModule

    var body: some View {
        GlassCard {
            SectionHeader("Contrast", symbol: "circle.lefthalf.filled")
            if let (first, second) = module.contrastPair {
                let contrast = Contrast(first.colour, second.colour)
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(contrast.text)
                        .notchStyle(.display)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText())
                        .accessibilityLabel("Contrast ratio \(contrast.text.replacingOccurrences(of: ":1", with: " to 1"))")
                    Spacer(minLength: 0)
                    TextPreview(text: first.colour, fill: second.colour)
                    TextPreview(text: second.colour, fill: first.colour)
                }
                VerdictGrid(contrast: contrast)
                Text(contrast.involvesClamping ? "Measured on clamped hex" : "\(first.colour.hex) and \(second.colour.hex)")
                    .notchStyle(.caption)
                    .lineLimit(1)
            } else {
                EmptyState(symbol: "circle.lefthalf.filled", title: emptyTitle)
            }
        }
        .motion(Motion.morph, value: module.contrastPair.map { [$0.0.id, $0.1.id] })
    }

    private var emptyTitle: String {
        if module.isComparing {
            return module.selection.chosen.count == 1 ? "Choose one more swatch" : "Choose two swatches"
        }
        return module.picks.count == 1 ? "Pick one more colour to compare" : "Pick two colours to compare"
    }
}

/// "Aa" in one pick on a fill of the other.
private struct TextPreview: View {
    let text: Colour
    let fill: Colour

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.thumbnail, style: .continuous)
        Text("Aa")
            .font(NotchTextStyle.title.font)
            .foregroundStyle(text.swatchColor)
            .frame(width: 24, height: 24)
            .background(fill.swatchColor, in: shape)
            .overlay { shape.strokeBorder(Tokens.Colors.hairline, lineWidth: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview, \(text.hex) on \(fill.hex)")
    }
}

/// AA and AAA, for normal and large text.
private struct VerdictGrid: View {
    let contrast: Contrast

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.s, verticalSpacing: 2) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("Normal").notchStyle(.caption)
                Text("Large").notchStyle(.caption)
            }
            ForEach(Contrast.Level.allCases, id: \.self) { level in
                GridRow {
                    Text(level.rawValue).notchStyle(.body)
                    cell(level, .normal)
                    cell(level, .large)
                }
            }
        }
    }

    private func cell(_ level: Contrast.Level, _ size: Contrast.TextSize) -> some View {
        let passes = contrast.passes(level, size)
        return HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: passes ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(passes ? TintRole.success.color : TintRole.secondary.color)
            Text(passes ? "Pass" : "Fail").notchStyle(.caption)
        }
        .font(NotchTextStyle.caption.font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level.rawValue) \(size.rawValue) text: \(passes ? "passes" : "fails")")
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

/// Settings pane: the format and copy on pick.
struct ColourSettings: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Copy as", selection: settings.binding(ColourModule.formatKey)) {
                    ForEach(ColourFormat.allCases) { format in
                        Text("\(format.label): \(ColourSamples.settingsExample.formatted(format).text)").tag(format)
                    }
                }
                Toggle("Copy each pick straight away", isOn: settings.binding(ColourModule.copyOnPickKey))
            } footer: {
                Text(
                    "Hex and RGB clamp colours outside sRGB; OKLCH and Display P3 keep them. The last "
                        + "\(ColourHistory.defaultCapacity) picks are kept on this Mac until cleared."
                )
            }
        }
        .formStyle(.grouped)
    }
}
