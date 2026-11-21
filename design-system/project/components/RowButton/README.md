Makes a whole row or card behave like a button, with a hover fill and a small press scale.

Source: `Sources/NotchCore/Design/Controls.swift` (`RowButtonStyle`).

```swift
Button { reveal(file) } label: {
    ResultRow(thumbnail: file.thumbnail, title: file.name, detail: "Click to reveal in Finder", trailing: Format.bytes(file.size))
}
.buttonStyle(RowButtonStyle())
```

## You provide

- The label, normally a ResultRow.
- The action: one obvious thing, such as reveal in Finder, copy again or open.

## Rules

- Adds 6 pt horizontal and 4 pt vertical padding, `radius-control`, a `card-fill-hover` fill on hover (`Motion.quick`) and a 0.98 press scale (`Motion.press`).
- Prefer this over adding a button to every row.
