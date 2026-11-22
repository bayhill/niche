# Notcher

A native macOS app that lives in the MacBook notch. Drop images on the notch and they are converted to WebP next to
the originals, using the last-used settings. Around that it keeps a few glanceable tools in one sheet of dark Liquid
Glass.

- **Convert** — PNG, JPEG, HEIC and more to WebP (libwebp), with quality, lossless, max-edge and metadata options.
  Originals are never modified and existing files are never overwritten.
- **Shelf** — hold file references in the notch and drag them out later.
- **Clipboard** — recent text, links, images and colours. Off until switched on; kept in memory only.
- **Now Playing** — title, artist, artwork and transport, also beside the closed notch.
- **Next meeting** — from the calendars macOS knows about, with a Join button for Teams, Meet, Zoom and Webex links.
  Five minutes before a meeting the notch grows and says so, until it is answered (the lead time is a setting, as is off).
  Calls nudge two minutes before. Join opens the Teams or Zoom app directly when it is installed, and pauses what is playing.
- **Claude Code sessions** — which sessions are running and which one is waiting.

## Requirements

- macOS 26 on a Mac with a notch (a virtual notch is drawn on other displays).
- The Xcode 26 or later command-line toolchain (Swift 6.2+). There is no Xcode project; everything builds with SwiftPM.

## Build and install

    scripts/bundle.sh        # builds, signs and installs ~/Applications/Notcher.app
    scripts/run.sh           # (re)starts the installed app

`scripts/bundle.sh` signs with the identity named in `NOTCHER_SIGN_IDENTITY` (default `Notcher Local Signing`) and
falls back to ad-hoc signing when that identity is not in the keychain. Ad-hoc builds work, but macOS treats every
rebuild as a new app and asks again for Calendar and Automation access. To avoid that, create a self-signed
code-signing certificate once: Keychain Access → Certificate Assistant → Create a Certificate, type "Code Signing",
with the name above.

For development:

    swift build
    swift test
    scripts/run.sh --fixtures --force-state expanded    # sample data, panel pinned open
    scripts/smoke.sh                                    # tests, bundle, a conversion, a capture of every state
    swift run -c release webpify -q 80 image.png        # the converter as a command-line tool

The debug flags are documented in `Sources/NotchCore/DebugOptions.swift`.

## How it is put together

| Path | What |
|---|---|
| `Sources/NotchCore` | The contract every module implements, and the design kit (tokens, motion, components) |
| `Sources/NotchUI` | The notch window: shape, states, hover, drag and drop, the expanded panel |
| `Sources/ImageEngine`, `Sources/webpify` | Decode, normalise and encode to WebP; the command-line tool |
| `Sources/*Module` | One target per module; each depends on `NotchCore` only |
| `Sources/NotcherApp` | The app: wires modules together, Settings, launch at login |
| `Support/ClaudePlugin` | The optional Claude Code plugin that reports session events |
| `Vendor/MediaRemoteAdapter` | Vendored helper for Now Playing |
| `design-system/` | A description of the kit and the intended layouts; the Swift kit is the source of truth |

`CONTRIBUTING.md` has the rules the code follows.

## Privacy

Notcher has no telemetry and no accounts. It makes one kind of network request: when Now Playing falls back to
AppleScript for Spotify, it downloads the album artwork from the address Spotify reports. Settings are stored in
macOS preferences and everything else under `~/Library/Application Support/Notcher`.

- Clipboard history is off by default, skips anything marked concealed or transient and anything copied from a
  password manager, and is never written to disk.
- Claude Code alerts are off by default. Enabling them in Settings installs a small plugin through the `claude` CLI,
  which adds two entries to `~/.claude/settings.json`; the plugin passes only a few short fields per event (never
  prompts or tool output), and the app deletes each event after reading it.

## Caveats

- Now Playing reads the system's media state through Apple's private MediaRemote framework, by way of
  [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter). It can stop working with a macOS update, and
  it rules out the Mac App Store. Spotify and Music have an AppleScript fallback.
- The app is not sandboxed and not notarised. It is built to be compiled and run on your own Mac.

## Licence

MIT; see `LICENSE`. Third-party software and its licences are listed in `THIRD_PARTY_NOTICES.md`.
