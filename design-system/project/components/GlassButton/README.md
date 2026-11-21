A capsule button in interactive Liquid Glass, for the one or two actions a card offers.

Source: `Sources/NotchCore/Design/Controls.swift` (`GlassButton`, `GlassButtonStyle`).

```swift
GlassButton("Convert", symbol: "photo", prominence: .accent) { convert() }
```

## You provide

- `title`: one or two words, sentence case.
- `symbol`: an optional SF Symbol name.
- `prominence`: `.standard` (plain glass) or `.accent` (glass tinted `accent-glass`).
- `action`.

## Rules

- 12 pt semibold `text-primary` label, 12 pt horizontal and 6 pt vertical padding, capsule shape.
- Presses scale to 0.95 on `Motion.press`.
- At most one accent button in the whole panel. Most cards need none: prefer a row that acts on click.
- A `text-primary` label on `accent-glass` measures about 4.3:1 over the dark panel; keep accent labels to short, semibold words.
