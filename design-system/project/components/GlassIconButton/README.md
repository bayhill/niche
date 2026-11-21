A circular icon button: interactive glass for a card's primary control, or a borderless plain kind for dense rows and the panel's top band.

Source: `Sources/NotchCore/Design/Controls.swift` (`GlassIconButton`, `GlassIconButtonStyle`, `PlainIconButtonStyle`).

```swift
GlassIconButton("pause.fill", label: "Pause") { toggle() }
GlassIconButton("gearshape", label: "Settings", kind: .plain, size: 24, tint: .secondary) { openSettings() }
```

## You provide

- `symbol`: an SF Symbol name.
- `label`: the accessibility label and tooltip. Always required.
- `kind`: `.glass` (default) or `.plain`.
- `size`: 28 by default. The glyph is 44% of a glass button and 50% of a plain one.
- `tint`: a `TintRole`.

## Rules

- Glass presses scale to 0.90, plain to 0.88, on `Motion.press`.
- Plain buttons rest in their tint and turn `text-primary` on a `card-fill-hover` disc under the pointer, on `Motion.quick`.
- One glass icon button per card at most (play/pause). Everything around it is plain.
