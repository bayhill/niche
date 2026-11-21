A small coloured dot that states a status and can pulse to ask for attention.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
StatusDot(.warning, pulsing: session.needsPermission)
```

## You provide

- A `TintRole`: `primary`, `secondary`, `accent`, `success` or `warning`.
- `pulsing`: true only when the user has to act.

## Rules

- 7 pt. The pulse fades between 1 and 0.35 over 0.8 s and stops under Reduce Motion.
- `success` and `warning` are close in lightness, so a dot never stands alone: put the state in words beside it or in the row's detail.
- One pulsing dot in the panel at a time.
