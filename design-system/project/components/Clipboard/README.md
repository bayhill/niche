Clipboard history as a full-width page: the most recent clips as cards, newest first, each saying what it is, where it came from and when.

An intentional addition: a composition of kit parts for `ClipboardModule`, which is still a placeholder in the source.

## Built from

- A `.page` module (652 × 184) with its own icon in the top band.
- SectionHeader "Clipboard" with a count and a plain icon button to clear history.
- Four GlassCards, each with a SectionHeader naming the kind (Text, Link, Image, Colour), a preview, and a footer in `caption`: source app on the left, age on the right.
- Text and links in `body`, clamped to five lines. Images fill the card at `radius-thumbnail`. A colour shows its swatch and its hex in `numeric`.

## Rules

- Clicking a card copies it again and highlights it (`accent-wash`, `accent` outline) with `Haptics.tick()`.
- Ages use `Format.countdown` wording without a sign: "now", "4m", "1h".
- Never show the contents of a clip marked concealed or transient by its source app.
- Keep it to one row. More history belongs behind search, not a scrolling grid.
