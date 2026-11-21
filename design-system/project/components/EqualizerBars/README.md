Three animated bars that say audio is playing.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
EqualizerBars(playing: player.isPlaying)
```

## You provide

- `playing`: the bars rest at 30% height when false.
- `tint` (default `.primary`).

## Rules

- 14 × 14 pt: three 2.5 pt capsules, 2 pt apart, centre-aligned.
- Use it as the trailing wing glyph of a Now Playing activity and as the trailing accessory of its SectionHeader.
- The bars stand still under Reduce Motion.
