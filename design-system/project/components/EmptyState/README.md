A centred placeholder for a card with nothing to show: a symbol, one line saying what is missing, and an optional hint.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
EmptyState(symbol: "photo", title: "Drop images on the notch", message: "PNG, JPEG and HEIC become WebP")
```

## You provide

- `symbol`: 18 pt, `text-tertiary`.
- `title`: `caption` in `text-secondary`. Say what to do, not what went wrong.
- `message`: optional, at most two lines, `caption` in `text-tertiary`.

## Rules

- Fills the space left in the card and centres itself. Keep the SectionHeader above it.
- No buttons and no illustrations: the notch itself is the call to action.
