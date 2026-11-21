# Contributing to Notcher

Notcher is a SwiftPM-only macOS 26 app (Swift 6 language mode, no Xcode project). `scripts/bundle.sh` assembles,
signs and installs `Notcher.app`; `scripts/run.sh [flags]` restarts it.

## Layout

`Sources/NotchCore` is the contract and the design kit. `Sources/NotchUI` is the notch window. Each `Sources/*Module`
target is one feature and depends on `NotchCore` only; modules never import each other and talk through the service
protocols in `NotchCore`. `Sources/NotcherApp` wires everything together. The README has the full table.

A change to one module should stay inside that module's target and its tests. If the contract in `NotchCore` is
wrong or missing something, change it there, deliberately, rather than working around it with a private copy.

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
5. **Hero element.** Put `.notchHero(id)` on the one element the module's live-activity glyph should morph into.
6. **Swift 6 concurrency, explicit.** No default actor isolation is configured: annotate UI and module types
   `@MainActor`; keep parsing, reducers and engines `nonisolated` and `Sendable`. No `@unchecked Sendable` or
   `nonisolated(unsafe)` without a one-line comment saying why it is safe. Zero warnings.
7. **No SwiftPM resources** (`resources:` in the manifest, `Bundle.module`). Files the app needs at runtime live in
   `Resources/`, `Support/` or `Vendor/` and are copied into the bundle by `scripts/bundle.sh`; load them via
   `Bundle.main` with an injectable override for tests.
8. **Never touch the user's real data in tests or while developing**: no writes outside the checkout and temporary
   directories, no writes to the general pasteboard, nothing under `~/.claude`, no changes to system settings,
   no installs (Homebrew, npm, pip). Use `TestEnvironment` from `NotchCoreTesting` for roots and fakes.
9. **Tests use Swift Testing** (`import Testing`). Put the logic in pure types so it is testable without a GUI.
   To look at a view, render it off-screen with `ViewSnapshot` from `NotchCoreTesting` and open the PNG, or run
   the app or `NotchPlayground` with `--fixtures --force-state …`.
10. **Few dependencies.** Apple frameworks, plus what `Package.swift` already declares. A new package needs a reason
    that survives the question "could this be fifty lines of our own code?", and an entry in `THIRD_PARTY_NOTICES.md`.

## Commands

    swift build                      # everything
    swift test --filter <Target>Tests
    scripts/bundle.sh && scripts/run.sh --force-state expanded --fixtures
