The small heading at the top of a card: an optional symbol, the label, and an optional trailing accessory.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
SectionHeader("Now Playing", symbol: "music.note") { EqualizerBars(playing: isPlaying) }
```

## You provide

- `title`: one or two words in normal case. The header uppercases it.
- `symbol`: an optional SF Symbol, drawn 10 pt semibold in `text-tertiary`.
- `trailing`: one small accessory, such as EqualizerBars, a StatusDot, a count in `numeric` or a plain icon button.

## Rules

- 16 pt tall, set in `label`. One per card, first child.
- `text-tertiary` on the panel measures 3.4:1, so a header is a quiet signpost and never the only place a fact appears.
