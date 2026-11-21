The notch's one background: pure black where it meets the hardware, melting into dark Liquid Glass below. `NotchUI` draws exactly one behind everything; modules never use it.

Source: `Sources/NotchCore/Design/Surfaces.swift`. The preview is a web rendition: `backdrop-filter` stands in for `.glassEffect(.regular.tint(glassTint))`, and the hardware notch is assumed to be 185 × 32 pt.

```swift
NotchSurface(shape: notchShape, capHeight: metrics.safeTop, glassAmount: isExpanded ? 1 : 0)
```

## You provide

- `shape`: the animated notch outline (ears from `radius-notch-*-top`, corners from `radius-notch-*-bottom`).
- `capHeight`: the height of the solid black band, which is the hardware notch height.
- `glassAmount`: 0 for the closed notch (solid `notch-black` everywhere), 1 for the open panel (glass below the cap at `glass-floor`).

## States

| State | Size below or beside the notch | Glass | Spring |
|---|---|---|---|
| Closed | none | 0 | `Motion.close` |
| Hover | +12 × +6 (`hover-growth-*`) | 0 | `Motion.morph` |
| Live activity | a 40 pt wing each side (`wing-width`) | 0 | `Motion.morph` |
| Drop target | 420 × 92 (`drop-*`) | 1 | `Motion.open` |
| Expanded | 680 × 204 (`expanded-*`) | 1 | `Motion.open` |

## Rules

- The cap is always `notch-black` for the full notch height, then fades over `cap-fade` (56 pt). Never let glass or content colour reach the top edge.
- Content inside the open panel sits within `inset-top`, `inset-side`, `inset-bottom`.
- The closed notch casts no shadow and shows no rim. Glass, rim and shadow arrive together with `glassAmount`.
- Collapse with `Motion.close` (critically damped) so nothing bounces on the way back into the hardware.
