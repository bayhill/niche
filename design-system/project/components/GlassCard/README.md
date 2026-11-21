The standard container for a module's content: a faint lifted layer on the panel's glass, laying its children out as a leading-aligned vertical stack.

Source: `Sources/NotchCore/Design/Surfaces.swift`.

```swift
GlassCard(highlighted: isDropTarget) {
    SectionHeader("Convert", symbol: "photo")
    ResultRow(title: "hero-banner.png", detail: "1.2 MB → 264 KB", trailing: "−78%", trailingTint: .success)
}
```

## You provide

- `content`: the children, stacked vertically. Start with a SectionHeader.
- `padding` (default `space-m`, 12) and `spacing` (default `space-s`, 8).
- `highlighted`: true for an active drop target or a selected item.

## Rules

- A card fills the frame it is given (`PanelLayout.cardSize(for:)`: 210 × 87 or 210 × 184 at the default size). Never assume more room; truncate text instead of growing.
- Rest: `card-fill` with a 1 pt `card-stroke` outline, `radius-card`.
- Highlighted: `accent-wash` with a 1.5 pt `accent` outline, scaled to 1.015 on `Motion.morph`.
- Do not nest cards, and do not add shadows: the panel's glass is the only elevation.
