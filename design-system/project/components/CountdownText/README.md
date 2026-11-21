A live countdown to a date, written the way every module writes durations: "1h 5m", "12m", "45s", then "now".

Source: `Sources/NotchCore/Design/Components.swift`, `Sources/NotchCore/Format.swift`.

```swift
CountdownText(to: meeting.start)
```

## You provide

- `target`: the date to count down to.
- `style`: a `NotchTextStyle`, `numeric` by default.

## Rules

- Updates once a second with a numeric content transition; digits are monospaced so the text does not shift.
- Minutes round up: 12 min 5 s reads "13m". Past dates read "now".
- Use it in a SectionHeader's trailing slot, a ResultRow's trailing figure or a wing.
