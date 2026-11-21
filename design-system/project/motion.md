# Motion

Everything is a spring, so any transition can be interrupted and reversed mid-flight without a visible jump. These are the only curves in the app (`Sources/NotchCore/Design/Motion.swift`).

| Name | Spring (response, damping) | Use |
|---|---|---|
| `Motion.open` | 0.42, 0.80 | The notch expanding to the drop target or the panel |
| `Motion.close` | 0.45, 1.00 | The notch collapsing. Critically damped: no bounce on the way back into the hardware |
| `Motion.morph` | 0.38, 0.82 | Elements changing size or position, a card highlighting, a ring filling |
| `Motion.press` | 0.22, 0.70 | Press feedback on controls |
| `Motion.appear` | 0.50, 0.86 | Content arriving |
| `Motion.quick` | ease-out, 0.16 s | Small state changes: hover fills, tint changes |
| `Motion.reduced` | ease-in-out, 0.20 s | Replaces every spring when Reduce Motion is on |

## Rules

- Animate with `.motion(Motion.x, value:)`, `Motion.animate { }` and `.motionAppear(index)`. Never write a curve or a duration in module code.
- Open with `Motion.open`, close with `Motion.close`. Do not reuse one for the other.
- Content arrives with `motionAppear`: it fades in, un-blurs from 5 pt, scales from 0.96 and rises 4 pt. Pass the item's position for a stagger of 0.06 s plus 0.035 s per item.
- Mark one element per module with `.notchHero(id)`. The live-activity glyph in the wing flies into it when the notch expands.
- Numbers change with `contentTransition(.numericText())`. SF Symbol effects are welcome.
- Under Reduce Motion nothing blurs, scales, slides or pulses: springs become `Motion.reduced`, the equalizer rests and the status dot stops pulsing.

## Haptics

- `Haptics.tick()`: a drag entered the target, an item snapped, a clip was copied.
- `Haptics.success()`: work finished.

## On the web

The previews sample each spring into a CSS `linear()` easing with its settle time (`--motion-open`, `--motion-open-dur` and so on in `components/bundle.css`), and switch to a 200 ms ease-in-out under `prefers-reduced-motion`.
