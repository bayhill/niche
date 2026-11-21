# Notch anatomy

The notch has five states. Sizes are in points and sit beside or below the notch band, whose height is the hardware notch (`Sources/NotchCore/Design/Tokens.swift`, `PanelLayout`).

| State | Shape | Surface | When |
|---|---|---|---|
| Closed | The hardware notch; ears `radius-notch-closed-top`, corners `radius-notch-closed-bottom` | `notch-black` | Nothing to show |
| Hover | Grows by `hover-growth-width` × `hover-growth-height` | `notch-black` | The pointer is over the notch |
| Live activity | A `wing-width` wing on each side | `notch-black` | A module has a status worth showing |
| Drop target | `drop-width` × `drop-height`; ears `radius-notch-open-top`, corners `radius-notch-open-bottom` | Glass | A drag is near the notch |
| Expanded | `expanded-width` × `expanded-height` | Glass | Clicked or opened |

On a display without a notch, a virtual one is drawn 180 × 24 pt at the top centre.

## The expanded panel

- **The band** is the top strip, as tall as the notch and always `notch-black`. The hardware sits in its centre; page icons and settings sit either side as plain icon buttons.
- **The content** starts `inset-top` below the band and keeps `inset-side` and `inset-bottom` clear.
- **Home** is a dashboard of three columns with `panel-gap` between them. The leading column holds two half-height cards (210 × 87); the centre and trailing columns hold one full-height card each (210 × 184).
- **A page** replaces the dashboard with one module at 652 × 184.

## Live activities

Each module publishes at most one activity. The highest priority wins, then the most recently updated.

| Priority | Meaning | Example |
|---|---|---|
| `ambient` | Always-on background info | Music is playing |
| `passive` | Time-relevant, not urgent | Meeting in 12 min |
| `progress` | Work in flight that the user started | Converting 3/12 |
| `attention` | Needs the user now | A Claude Code session is waiting for permission |

Over a fullscreen app only `attention` is shown.

## Drops

- While a drag is near the notch, the drop target names what will happen: a symbol, a title and an optional subtitle from the winning module's `DropHint`.
- Images go to Convert; anything goes to the Shelf. Holding ⌥ at drop time skips conversion and sends files to the Shelf.
- Dropping on a module's card inside the expanded panel targets that module directly and highlights its GlassCard.
