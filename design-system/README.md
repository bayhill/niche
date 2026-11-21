# Notcher design system

A reference copy of the Notcher design system: tokens, usage rules, web renditions of the design kit, and layout
explorations for the modules. It is also published as a browsable page at
(link removed) (private to its owner unless shared).

## What is authoritative

`Sources/NotchCore/Design` is the source of truth. This folder describes it and explores on top of it; it does not
override it. If the two disagree, the Swift code wins and this folder is out of date.

- **Mirrors the code** (read at commit `f6cf57c`): every value in `project/tokens.json` whose usage note names a
  `Tokens.…` or `PanelLayout.…` symbol, the motion table in `project/motion.md`, and the kit components.
- **Proposals, not in the code**: the Now Playing, Convert and Clipboard layouts, the ambient-artwork variant, the wing
  rendering, the top band of page icons, and the dashboard slot each module sits in. Treat these as a design to build
  toward, not as a contract.
- **Web-only stand-ins**: tokens whose usage note starts "Web stand-in" approximate what macOS draws natively
  (`.glassEffect`, shadows). Never copy them into Swift.

## Where to read

| For | Read |
|---|---|
| Principles, content rules, colour, type, layout, accessibility flags | `project/README.md` |
| Springs, stagger, Reduce Motion, haptics | `project/motion.md` |
| Notch states and sizes, live-activity priorities, drops | `project/notch-anatomy.md` |
| Exact values | `project/tokens.json` |
| How to use one component, and its rules | `project/components/<Name>/README.md` |
| A module's intended layout, as markup | `project/components/NowPlaying`, `Convert`, `Clipboard`, `NotchSurface` (`preview.html`) |

The rule in `CONTRIBUTING.md` still holds: module views are built from the NotchCore kit only, with no literal colours,
fonts, radii, materials or animation curves.

## Previewing and changing it

    python3 design-system/tools/gen.py
    python3 -m http.server 8765 --directory .build/design-preview

Then open http://localhost:8765/. `tools/gen.py` writes `project/components/**` from `tools/bundle.css`,
`tools/bundle_tail.js`, `tools/index.d.ts` and the markup in the script itself; edit those, not the generated files.
`project/tokens.json` and the three Markdown sections are edited by hand.

The published page is updated separately, by publishing the files under `project/` to the artifact above. The app icon
shown there is an upload exported from `Resources/AppIcon.icns` and is not duplicated here.
