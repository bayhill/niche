A small determinate progress ring for work the user started.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
ProgressRing(progress: Double(done) / Double(total))
```

## You provide

- `progress`: 0 to 1, clamped.
- `size` (default 16), `lineWidth` (default 2.5) and `tint` (default `.accent`).

## Rules

- The track is `card-stroke`; the value has round caps, starts at 12 o'clock and animates on `Motion.morph`.
- Use it as a ResultRow's leading element or as a wing glyph. Pair it with a count ("3/12") when there is more than one item.
- It reports its value to VoiceOver as a percentage.
