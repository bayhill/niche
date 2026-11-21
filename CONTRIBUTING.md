# Working in this repository

Notcher is a SwiftPM-only macOS 26 app (Swift 6 language mode, no Xcode project). `scripts/bundle.sh` assembles,
signs and installs `Notcher.app`; `scripts/run.sh [flags]` restarts it.

## Ownership

| Paths | Owner |
|---|---|
| `Package.swift`, `scripts/`, `Resources/`, `Sources/NotchCore`, `Sources/NotchCoreTesting`, `Sources/NotcherApp`, `Tests/NotchCoreTests` | orchestrator (frozen contract `contracts-v1`) |
| `Sources/NotchUI`, `Sources/NotchPlayground`, `Tests/NotchUITests` | Agent A |
| `Sources/ImageEngine`, `Sources/ConvertModule`, `Sources/webpify`, their tests | Agent B |
| `Sources/ShelfModule`, `Sources/ClipboardModule`, their tests | Agent C |
| `Sources/NowPlayingModule`, `Sources/CalendarModule`, `Vendor/MediaRemoteAdapter`, their tests | Agent D |
| `Sources/ClaudeAgentsModule`, `Support/ClaudePlugin`, its tests | Agent E |

Edit only what you own. If the contract in `NotchCore` is wrong or missing something, say so in your report with the
exact change you need; do not edit it and do not work around it with a private copy.

## Rules

1. **Read `Sources/NotchCore` first.** It is the contract: `NotchModule`, `LiveActivity`, drop routing, services,
   `SettingsStore`, `AppDirectories`, and the design kit in `Sources/NotchCore/Design`.
2. **Design kit only.** Views are built from `GlassCard` (including `ambient:` for Now Playing), `GlassButton`,
   `GlassIconButton`, `RowButtonStyle`, `SectionHeader`, `ResultRow`, `EmptyState`, `ProgressRing`, `SpinnerRing`,
   `PositionBar`, `StatusDot`, `EqualizerBars`, `CountdownText`, `Text(...).notchStyle(_)`, `Format`, `Tokens`,
   `PanelLayout`, and `Motion`. `design-system/` describes the kit, the content rules (sentence case, no "you"/"we",
   no exclamation marks, empty states that name the next action) and the intended module layouts; the Swift kit is
   the source of truth where they differ. No literal colours, fonts, corner radii, materials or animation curves in module code.
   Animate with `.motion(Motion.x, value:)`, `Motion.animate`, `.motionAppear(index)`; SF Symbol effects and
   `contentTransition(.numericText())` are encouraged. Keep it simple: few controls, generous spacing.
3. **A dashboard card fills the frame it is given** (`PanelLayout.cardSize(for:)`); a page gets `PanelLayout.pageSize`.
   Never assume more room; truncate text instead of growing.
4. **Module shape.** Each module is a `@MainActor @Observable public final class` conforming to `NotchModule`, with:
   - `public static func live() -> Self`-style factory that works inside the app bundle, and
   - `public static func sample() -> Self`-style factory showing built-in sample data and touching nothing on the system
     (used by `--fixtures`, the playground and screenshots), plus
   - an initializer taking its dependencies (clock, file roots, process runner, data source protocols) for tests.
   `start` logs `context.log.notice("started")` when ready. `start` must not trigger a system permission prompt unless
   `context.mayPrompt` is true. Settings keys are `SettingsKey("<moduleID>.<name>", default:)`.
5. **Hero element.** Put `.notchHero(id)` on the one element your live-activity glyph should morph into.
6. **Swift 6 concurrency, explicit.** No default actor isolation is configured: annotate UI and module types
   `@MainActor`; keep parsing, reducers and engines `nonisolated` and `Sendable`. No `@unchecked Sendable` or
   `nonisolated(unsafe)` without a one-line comment saying why it is safe. Zero warnings.
7. **No SwiftPM resources** (`resources:` in the manifest, `Bundle.module`). Files the app needs at runtime live in
   `Resources/`, `Support/` or `Vendor/` and are copied into the bundle by `scripts/bundle.sh`; load them via
   `Bundle.main` with an injectable override for tests.
8. **Never touch the user's real data in tests or while developing**: no writes outside your worktree and temporary
   directories, no writes to the general pasteboard, nothing under `~/.claude`, no changes to system settings,
   no installs (Homebrew, npm, pip). Use `TestEnvironment` from `NotchCoreTesting` for roots and fakes.
9. **Tests use Swift Testing** (`import Testing`). Put the logic in pure types so it is testable without a GUI.
   To look at a view, render it off-screen with `ViewSnapshot` from `NotchCoreTesting` and open the PNG;
   only Agent A puts windows on the real display.
10. **Dependencies are frozen.** No new packages. Apple frameworks only, plus what `Package.swift` already declares.

## Commands

    swift build                      # everything
    swift test --filter <Target>Tests
    scripts/bundle.sh && scripts/run.sh --force-state expanded --fixtures
