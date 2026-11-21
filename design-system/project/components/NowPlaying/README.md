The Now Playing dashboard card: artwork, title, artist and album, a thin position bar, and three transport controls.

An intentional addition: a composition of kit parts for `NowPlayingModule`, which is still a placeholder in the source. Nothing here is in the Swift code yet.

## Built from

- GlassCard in the `center` dashboard slot (210 × 184).
- SectionHeader "Now Playing" with EqualizerBars trailing.
- Artwork at 64 pt with `radius-control`, carrying `.notchHero(.nowPlaying)` so the wing thumbnail flies into it.
- Title in `title`, artist and album in `caption`, each on one truncated line.
- A 3 pt position bar: `card-stroke` track, `text-primary` fill, elapsed and remaining time in `caption` with monospaced digits.
- One glass GlassIconButton (32 pt play/pause) between two plain ones (28 pt).

## Ambient, an experiment

The artwork, blurred 30 pt and saturated, blooms through the card at 42% opacity. It is the only place content colour is allowed to tint a surface, and it would need a rule in the kit before modules use it. Text stays `text-primary` and `text-secondary`; check contrast against bright artwork before adopting it.

## Rules

- The live activity is `ambient`: artwork in the leading wing, EqualizerBars in the trailing wing. Never tint it.
- Paused: the bars rest and the button shows play. Do not dim the card.
