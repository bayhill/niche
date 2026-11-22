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
- **Claude Code sessions** — which sessions are running and which one is waiting. Read from Claude Code's own
  session files; alerts beside the notch are a separate opt-in.
- **Screenshots** — the last day's screenshots as they are taken: drag one out, convert it to WebP or put it on the
  shelf. Off until switched on; read from the folder macOS saves them in, never moved or deleted.
- **Colour** — pick any pixel on screen and copy it as hex, rgb, oklch or Display P3, with a contrast check between two picks.
- **Dev servers** — the local servers listening on this Mac: open one in the browser, copy its address or stop it.
  Off until switched on in Settings.
- **Builds** — the latest GitHub Actions run for chosen repositories, on the branch that is checked out, through the
  GitHub CLI that is already signed in. Off until switched on in Settings.

The panel opens on the tab that was used last; a setting in General makes it always open on Home.

## Requirements

- macOS 26 on a Mac with a notch. On a display without one, a virtual notch appears when there is something to
  show (an activity, a drag, the hotkey) and is invisible otherwise. Notcher lives on one display at a time.
- The Xcode 26 or later command-line toolchain (Swift 6.2+). There is no Xcode project; everything builds with SwiftPM.

## Build and install

    scripts/bundle.sh        # builds, signs and installs ~/Applications/Notcher.app
    scripts/run.sh           # (re)starts the installed app

`scripts/bundle.sh` quits a running Notcher and replaces the copy in `~/Applications`; `INSTALL=0 scripts/bundle.sh`
only builds `build/Notcher.app`.

`scripts/bundle.sh` signs with the identity named in `NOTCHER_SIGN_IDENTITY` (default `Notcher Local Signing`) and
falls back to ad-hoc signing when that identity is not in the keychain. Ad-hoc builds work, but macOS treats every
rebuild as a new app and asks again for Calendar, Automation and folder access. To avoid that, create a self-signed
code-signing certificate once: Keychain Access → Certificate Assistant → Create a Certificate, type "Code Signing",
with the name above. The app is signed with the hardened runtime either way.

## Using it

- **Open the panel** by clicking the notch or pressing ⌃⌥N. Hovering can open it too (Settings › General).
- **Drop images on the notch** to convert them. Hold ⌥ while dropping to put the files on the Shelf instead.
- **Settings** open from the menu bar icon, from the sliders icon in the panel, or by opening the app again.
- **Dev servers and Builds** are switched on under Settings › General › Modules. **Clipboard** and **Screenshots**
  have their own switch inside their tab. Any module can be switched off in the same list.
- **Launch at login** is off until it is switched on in Settings › General.

## What macOS asks for, and why

| Permission | Asked when | Used for |
|---|---|---|
| Calendar (full access) | Next meeting is connected | Reading the next event and its meeting link |
| Automation of Spotify or Music | Now Playing falls back to AppleScript | Asking the player what is playing |
| Desktop, Documents or Downloads folder | Screenshots is switched on, or a file there is converted | Listing recent screenshots; writing the WebP next to the original |
| Pasting from other apps | Clipboard is switched on | Reading what was copied |

None is needed for converting images dropped from a folder Notcher can already read.

For development:

    swift build
    swift test
    scripts/run.sh --fixtures --force-state expanded    # sample data, panel pinned open
    scripts/smoke.sh                                    # tests, bundle, a conversion, a capture of every state
    swift run -c release webpify -q 80 image.png        # the converter as a command-line tool (--help lists the flags)
    swift run NotchPlayground --force-state expanded    # the notch layer alone, with stand-in modules

The debug flags are documented in `Sources/NotchCore/DebugOptions.swift`; `--page` takes a module id such as `shelf`,
`colour` or `devServers`. `scripts/smoke.sh` needs an unlocked display and Screen Recording permission for the terminal.

## How it is put together

| Path | What |
|---|---|
| `Sources/NotchCore` | The contract every module implements, and the design kit (tokens, motion, components) |
| `Sources/NotchUI` | The notch window: shape, states, hover, drag and drop, the expanded panel |
| `Sources/ImageEngine`, `Sources/webpify` | Decode, normalise and encode to WebP; the command-line tool |
| `Sources/*Module` | One target per module; each depends on `NotchCore` only (`ConvertModule` also on `ImageEngine`) |
| `Sources/NotcherApp` | The app: wires modules together, Settings, launch at login |
| `Sources/NotchCoreTesting`, `Sources/NotchPlayground` | Fakes and off-screen rendering for tests; the notch layer as a stand-alone program |
| `Tests` | One test target per source target (Swift Testing) |
| `Resources`, `scripts` | `Info.plist`, entitlements and icon; build, run and smoke-test scripts |
| `Support/ClaudePlugin` | The optional Claude Code plugin that reports session events |
| `Vendor/MediaRemoteAdapter` | Vendored helper for Now Playing |

`CONTRIBUTING.md` has the rules the code follows.

## Privacy

Notcher has no telemetry and no accounts. It makes two kinds of network request, both optional: when Now Playing
falls back to AppleScript for Spotify, it downloads the album artwork from the address Spotify reports (over https,
without keeping a copy on disk); and when
Builds is switched on, it runs the GitHub CLI (`gh run list`) for the repositories added in Settings.

What it reads:

- **Clipboard** is off by default, skips anything marked concealed or transient and anything copied from a
  password manager, and is never written to disk.
- **Claude Code sessions** reads the session files under `~/.claude/sessions` to list what is running. The module is
  on by default; switch it off under Settings › General › Modules.
- **Claude Code alerts** are off by default. Enabling them in Settings installs a small plugin through the `claude`
  CLI, which adds two entries to `~/.claude/settings.json`. The plugin passes a few short fields per event (never
  tool input or tool output; a session title, which Claude Code may derive from the prompt, is one of them), and the
  app deletes each event after reading it.
- **Builds** never sees a token: it uses the `gh` that is installed and signed in, and does nothing without it.
  Enterprise tokens and `GH_HOST` in the environment are not passed on to `gh`, and a repository whose remote is on a
  host other than github.com is added only after that host is confirmed in Settings.
- **Dev servers** reads the list of listening processes with `lsof` and only stops a process when its Stop button is
  clicked twice.

What it changes on the Mac:

- Settings in macOS preferences (`dev.bayhill.notcher`).
- `~/Library/Application Support/Notcher`: the Shelf's list of file references, colour picks, and, with Claude Code
  alerts on, the plugin copy, an event folder and up to three backups of `~/.claude/settings.json`.
- `~/Library/Caches/Notcher`: reserved for things that can be rebuilt; empty today.
- Converted images, next to the originals. A file dragged from an app that only promises it (Mail, Photos, a
  browser) is saved to `~/Downloads` first and converted there.
- With launch at login on: a login item, or `~/Library/LaunchAgents/dev.bayhill.notcher.login.plist` when macOS
  refuses a login item for a locally signed app.
- A global hotkey, ⌃⌥N, which can be switched off in Settings › General.

## Uninstalling

1. Switch off Claude Code alerts in Settings if they were on (this removes the plugin from Claude Code), and launch
   at login.
2. Quit Notcher and delete `~/Applications/Notcher.app`.
3. Delete `~/Library/Application Support/Notcher`, `~/Library/Caches/Notcher` and, if it exists,
   `~/Library/LaunchAgents/dev.bayhill.notcher.login.plist`.
4. `defaults delete dev.bayhill.notcher` removes the settings, and `tccutil reset All dev.bayhill.notcher` the
   permissions.

## Caveats

- Now Playing reads the system's media state through Apple's private MediaRemote framework, by way of
  [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter). It can stop working with a macOS update, and
  it rules out the Mac App Store. Spotify and Music have an AppleScript fallback.
- The app is not sandboxed and not notarised. It is built to be compiled and run on your own Mac.
- Notcher is an independent project. It is not affiliated with or endorsed by Apple, Anthropic, GitHub, Microsoft,
  Zoom, Google, Cisco or Spotify, whose products it works alongside.

## Licence

MIT; see `LICENSE`. Third-party software and its licences are listed in `THIRD_PARTY_NOTICES.md`.
