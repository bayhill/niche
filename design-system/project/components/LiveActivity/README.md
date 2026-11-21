A compact status shown in the wings beside the closed notch: one glyph on the left, an optional glyph or about six characters on the right.

Source: `Sources/NotchCore/LiveActivity.swift`. Each module publishes at most one activity; `ActivityArbiter` picks the single one on screen, and `NotchUI` owns the rendering so every module looks the same. The wing rendering in this preview is a proposal: `NotchUI` is not built yet.

```swift
LiveActivity(id: "convert.batch", module: .convert, priority: .progress,
             leading: .progress(0.25), trailing: .text("3/12"),
             accessibilityLabel: "Converting 3 of 12 images")
```

## You provide

- `leading`: an `ActivityGlyph`, rendered at roughly 18 pt.
- `trailing`: optional. Keep text to about 6 characters.
- `priority`: `ambient` (music is playing), `passive` (meeting in 12 min), `progress` (converting 3/12) or `attention` (a session needs the user). Highest wins, then most recently updated. Over a fullscreen app only `attention` is shown.
- `accessibilityLabel`: the whole status as a sentence.

## Glyphs

| `ActivityGlyph` | Use for |
|---|---|
| `.symbol(name, tint:, pulse:)` | An SF Symbol; pulse only for `attention` |
| `.progress(0...1)` | A determinate ProgressRing |
| `.text(String)` | Short text in `numeric` |
| `.countdown(to:)` | A live CountdownText |
| `.image(SendableImage)` | Album art or an image preview, `radius-thumbnail` |
| `.equalizer(playing:)` | EqualizerBars |

## Rules

- Wings are `notch-black`, exactly as tall as the notch and `wing-width` (40 pt) wide. No glass, no cards.
- Colour carries meaning here: `accent` for time, `warning` for attention. Never tint ambient activities.
- Put `.notchHero(id)` on the one element in the module's card that the leading glyph should fly into when the notch expands.
