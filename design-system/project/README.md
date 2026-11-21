Notcher lives in the MacBook notch. Closed, it is the hardware. Open, it is one sheet of dark Liquid Glass hanging from the top edge, holding a few quiet cards: Now Playing, Convert to WebP, clipboard history, a file shelf, the next meeting, Claude Code sessions.

Build every view from the kit in `Sources/NotchCore/Design` and nothing else. Module code contains no literal colours, fonts, corner radii, materials or animation curves.

## Principles

- **The notch is hardware.** Everything touching the top edge is `notch-black`. Glass, colour and content begin below the notch band and never reach it.
- **One sheet of glass, one layer of cards.** The panel is the only glass surface and the only elevation. Cards are a faint lift on it (`card-fill`, `card-stroke`), never glass on glass, never shadowed, never nested.
- **Few controls, generous spacing.** A card shows one thing and offers at most one or two actions. Prefer a row that acts on click to a button on every row.
- **One accent.** `accent` marks progress, the active drop target and time-relevant glyphs. Everything else is white at three strengths.
- **Truncate, never grow.** A card fills the frame it is given. Text shortens; layout does not move.

## Content

- **Sentence case** for titles, buttons and empty states: "Drop images on the notch", "Reveal", "Copy all". Section labels are written in normal case and set uppercase by `label`: "Now Playing" renders as NOW PLAYING.
- **Short names.** A module title is one or two words: "Shelf", "Convert", "Clipboard". Wing text is about six characters: "3/12", "12m".
- **Figures come from `Format`**, so every module writes them the same way:
  - Sizes in decimal units like Finder: "264 KB", "1.2 MB".
  - Savings as a signed percentage with a real minus sign (U+2212): "−78%" for smaller, "+6%" for larger, "0%" for none.
  - Durations as "1h 5m", "12m", "45s", then "now". Minutes round up.
  - Before and after with an arrow: "1.2 MB → 264 KB".
- **Say what to do, not what went wrong.** Empty states name the next action ("Drop images on the notch") and may add one line of detail ("PNG, JPEG and HEIC become WebP").
- **No emoji, no exclamation marks.** Status is a symbol, a dot or a figure.
- Address nobody: no "you", no "we". Labels are nouns, actions are verbs.

## Colour

The system is dark only: the notch is black on every desktop.

- Set titles, body text, numerics and display figures in `text-primary`.
- Set details and timestamps in `text-secondary`. Plain icon buttons rest in it.
- Set section labels and empty-state symbols in `text-tertiary`. It is a quiet signpost and never carries a fact on its own.
- Use `accent` for the ProgressRing, the highlighted GlassCard (`accent-wash` fill, 1.5 pt `accent` outline), accent wing glyphs and the one accent GlassButton (`accent-glass`).
- Use `success` for a real saving or finished work, and `warning` when the user has to act. Always pair them with a word, a figure or a symbol.
- Tint by role, not by value: `TintRole` is `primary`, `secondary`, `accent`, `success` or `warning`.
- Content brings its own colour: artwork, thumbnails, a copied colour swatch. Edge them with `hairline`.

## Glass

- The panel is drawn once, by `NotchSurface`: solid `notch-black` for the height of the notch, a melt over `cap-fade`, then Liquid Glass tinted `glass-tint` and held at `glass-floor` darkness.
- Closed, hover and live-activity states are solid black with no glass, rim or shadow. The drop target and the expanded panel are glass.
- Only GlassButton and GlassIconButton use interactive glass. Nothing else in a module does.
- On the web, `glass-blur`, `glass-saturate`, `glass-fill`, `glass-fill-hover`, `glass-rim`, `glass-rim-soft` and `glass-shadow` stand in for what macOS renders natively. They are approximations for these previews, not values to copy into Swift.

## Type

One family, the system font (SF Pro), in six styles. Apply them with `Text(...).notchStyle(_)`.

| Style | Use |
|---|---|
| `title` | Card titles, the main line of a row |
| `body` | Row titles, clip previews |
| `caption` | Details, timestamps |
| `label` | Section labels only, uppercase with 0.6 pt tracking |
| `numeric` | Sizes, percentages, countdowns; monospaced digits |
| `display` | One hero figure per card at most; SF Pro Rounded |

Every line is a single line unless a component says otherwise. File names truncate in the middle so the extension survives.

## Space, radius and layout

- Spacing has four steps: `space-xs`, `space-s`, `space-m`, `space-l`. Card padding is `space-m`; the gap between a card's children is `space-s`.
- Corners are continuous. Cards use `radius-card`, rectangular controls `radius-control`, thumbnails `radius-thumbnail`. Buttons are capsules and circles.
- The notch shape has its own radii: `radius-notch-closed-top` and `radius-notch-closed-bottom` when closed, `radius-notch-open-top` and `radius-notch-open-bottom` when open.
- The expanded panel is `expanded-width` × `expanded-height` below the notch band, inset by `inset-top`, `inset-side` and `inset-bottom`, with `panel-gap` between cards.
- The Home dashboard has three columns; the leading column is split in two. A module is a dashboard card, a full-width page with its own icon in the top band, or hidden.

## States and motion

- Hover fills with `card-fill-hover`. Presses scale down: 0.95 for a GlassButton, 0.90 for a glass icon button, 0.88 for a plain one, 0.98 for a row.
- Selection and active drop targets use the highlighted GlassCard and nothing else.
- Everything animates on the springs in the Motion section, and everything honours Reduce Motion.

## Iconography

- Icons are SF Symbols, named in code (`"photo"`, `"music.note"`, `"doc"`), drawn in a `TintRole`. Weights follow the kit: 10 pt semibold in a SectionHeader, 12 pt medium in a ResultRow, 18 pt regular in an EmptyState.
- SF Symbols cannot be redistributed, so the previews in this system use hand-drawn stand-ins of the same idea. They are not the real glyphs; use the SF Symbol in the app.
- The app icon is in the Logos group. There is no wordmark: set the name in the system font.

## Accessibility

- `text-tertiary` measures 3.4:1 on black, under the 4.5:1 floor for 10 pt labels. The source value is kept. Raising it to 0.50 opacity would reach 5.3:1.
- A `text-primary` label on `accent-glass` measures about 4.3:1 over the dark panel.
- `success` and `warning` are nearly equal in lightness, so a StatusDot never carries meaning alone.
- Web previews draw a 2 px `accent` focus ring, offset 2 px; the app uses the system focus ring.
- Every `ProgressRing` reports a percentage, every icon button has a label, every live activity has an `accessibilityLabel`.

## Intentional additions

These are not in the Swift source. They are compositions and stand-ins added to explore the design.

- **NowPlaying, Convert, Clipboard** (Modules group): layouts for modules that are still placeholders, built only from kit parts.
- **Ambient artwork** in NowPlaying: an experiment that lets artwork colour bloom through a card.
- **The wing rendering** in LiveActivity and the top band of page icons in NotchSurface: proposals for `NotchUI`, which is not built yet.
- **Web glass tokens**: the stand-ins listed under Glass.

## Not synced

Read from `Sources/NotchCore` at commit `f6cf57c`. Motion springs are documented in the Motion section because the token file has no motion family. No font files are included: SF Pro is the system font and is not redistributable. Components are hand-written web renditions of the SwiftUI views: `components/bundle.css` for the look, and `components/bundle.js` (`window.Notcher`) for small functions that return each component's markup plus the `Format` rules. Nothing was compiled from the Swift code. The Shelf, Calendar and Claude Code modules have no page of their own yet.
