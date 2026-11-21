One line item: a thumbnail or symbol, a title, an optional detail and an optional trailing figure.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
ResultRow(thumbnail: preview, title: "hero-banner.png", detail: "1.2 MB → 264 KB",
          trailing: Format.saving(0.78), trailingTint: .success)
```

## You provide

- `thumbnail` (a `SendableImage`) or `symbol` with `symbolTint`. The default symbol is `doc`.
- `title`: set in `body`, one line, truncated in the middle so file extensions survive.
- `detail`: set in `caption`, one line.
- `trailing`: a short figure in `numeric`, with `trailingTint`.

## Rules

- 30 pt tall with a 26 pt thumbnail at `radius-thumbnail`. A symbol sits on a `card-fill` square.
- Write figures with `Format`: `Format.bytes` ("264 KB"), `Format.saving` ("−78%", "+6%") and `Format.countdown` ("12m").
- Tint the trailing figure `success` only for a real saving; growth stays `text-secondary`.
