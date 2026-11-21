#!/usr/bin/env python3
"""Rebuilds the generated parts of the Notcher design system.

Writes components/bundle.css, components/bundle.js, components/index.d.ts and every components/<Name>/preview.html
and README.md under ../project, plus a local preview harness under <repo>/.build/design-preview (git-ignored).
tokens.json, README.md, motion.md and notch-anatomy.md in ../project are edited by hand.

    python3 design-system/tools/gen.py
    python3 -m http.server 8765 --directory .build/design-preview   # then open http://localhost:8765/
"""
import json, math, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROJECT = os.path.join(ROOT, "project")
HARNESS = os.path.join(os.path.dirname(ROOT), ".build", "design-preview")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


# ---------- Motion.swift springs -> CSS linear() ----------
def spring(response, damping, n=28):
    w = 2 * math.pi / response
    def x(t):
        if damping >= 1:
            return 1 - math.exp(-w * t) * (1 + w * t)
        wd = w * math.sqrt(1 - damping * damping)
        return 1 - math.exp(-damping * w * t) * (math.cos(wd * t) + (damping * w / wd) * math.sin(wd * t))
    t = 0.05
    while t < 3:
        if all(abs(x(t + k * 0.01) - 1) < 0.002 for k in range(40)):
            break
        t += 0.01
    pts = ", ".join(("%.4f" % x(t * i / n)).rstrip("0").rstrip(".") for i in range(n + 1))
    return "linear(" + pts + ")", "%dms" % round(t * 1000)


SPRINGS = {"OPEN": (0.42, 0.80), "CLOSE": (0.45, 1.0), "MORPH": (0.38, 0.82), "PRESS": (0.22, 0.70), "APPEAR": (0.50, 0.86)}
css = open(os.path.join(HERE, "bundle.css")).read()
for key, (r, d) in SPRINGS.items():
    ease, dur = spring(r, d)
    css = css.replace("__%s_DUR__" % key, dur).replace("__%s__" % key, ease)
assert "__" not in css
write(os.path.join(PROJECT, "components", "bundle.css"), css)

# ---------- SF Symbol stand-ins (16 x 16, hand-drawn) ----------
S = 'fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"'
F = 'fill="currentColor" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"'
ICONS = {
    "grid": f'<g {S}><rect x="2.25" y="2.25" width="4.75" height="4.75" rx="1.25"/><rect x="9" y="2.25" width="4.75" height="4.75" rx="1.25"/><rect x="2.25" y="9" width="4.75" height="4.75" rx="1.25"/><rect x="9" y="9" width="4.75" height="4.75" rx="1.25"/></g>',
    "tray": f'<g {S}><path d="M2.25 9.5 4.1 4a1 1 0 0 1 .95-.7h5.9a1 1 0 0 1 .95.7l1.85 5.5v2.2a1 1 0 0 1-1 1h-9.5a1 1 0 0 1-1-1z"/><path d="M2.4 9.5h3.1c.2 1.2 1.2 2 2.5 2s2.3-.8 2.5-2h3.1"/></g>',
    "clipboard": f'<g {S}><rect x="3.25" y="3" width="9.5" height="11" rx="1.75"/><rect x="5.9" y="1.75" width="4.2" height="2.5" rx=".9" fill="currentColor"/></g>',
    "sliders": f'<g {S}><path d="M2.5 4.75h5M12 4.75h1.5M2.5 11.25h1.5M8.5 11.25h5"/><circle cx="9.75" cy="4.75" r="1.75"/><circle cx="6.25" cy="11.25" r="1.75"/></g>',
    "photo": f'<g {S}><rect x="2" y="3" width="12" height="10" rx="2"/><circle cx="5.7" cy="6.4" r="1" fill="currentColor"/><path d="m2.4 11.2 3.2-2.7a.9.9 0 0 1 1.2 0L9 10.4l1.5-1.3a.9.9 0 0 1 1.2 0l1.9 1.8"/></g>',
    "doc": f'<g {S}><path d="M4.5 1.9h4.3l3.2 3.2v8a1 1 0 0 1-1 1H4.5a1 1 0 0 1-1-1V2.9a1 1 0 0 1 1-1z"/><path d="M8.7 2.1v3.1h3.1"/></g>',
    "calendar": f'<g {S}><rect x="2.25" y="3" width="11.5" height="10.75" rx="2"/><path d="M2.25 6.5h11.5M5.25 1.75v2.2M10.75 1.75v2.2"/></g>',
    "terminal": f'<g {S}><rect x="2" y="2.75" width="12" height="10.5" rx="2"/><path d="M4.75 6.25 7 8 4.75 9.75M8.5 10h2.75"/></g>',
    "note": f'<g {S}><path d="M6 12V3.9a.6.6 0 0 1 .45-.58l5.3-1.4a.6.6 0 0 1 .75.58V9.9"/><circle cx="4.4" cy="12" r="1.6" fill="currentColor"/><circle cx="10.9" cy="9.9" r="1.6" fill="currentColor"/></g>',
    "play": f'<path d="M5.2 3.6 12.4 8l-7.2 4.4z" {F}/>',
    "pause": '<g fill="currentColor"><rect x="3.4" y="2.8" width="3.2" height="10.4" rx="1"/><rect x="9.4" y="2.8" width="3.2" height="10.4" rx="1"/></g>',
    "next": f'<path d="M2.2 4.4 7.4 8l-5.2 3.6zM8.6 4.4 13.8 8l-5.2 3.6z" {F}/>',
    "prev": f'<path d="M2.2 4.4 7.4 8l-5.2 3.6zM8.6 4.4 13.8 8l-5.2 3.6z" transform="matrix(-1 0 0 1 16 0)" {F}/>',
    "link": f'<g {S}><path d="M5 11 11 5M6 4.75h5.25V10"/></g>',
    "text": f'<g {S}><path d="M3 4.25h10M3 8h10M3 11.75h6"/></g>',
    "check": f'<g {S}><path d="M3.5 8.5 6.6 11.5l6-7"/></g>',
    "arrowdown": f'<g {S}><path d="M8 2.5v7.75M4.75 7.25 8 10.5l3.25-3.25M3.25 13.5h9.5"/></g>',
    "drop": f'<g {S}><path d="M8 2.2c2.4 2.8 3.9 4.7 3.9 6.9a3.9 3.9 0 0 1-7.8 0c0-2.2 1.5-4.1 3.9-6.9z"/></g>',
    "video": f'<g {S}><rect x="1.75" y="4.25" width="8.5" height="7.5" rx="1.75"/><path d="M10.25 7.3 14 5.3v5.4l-3.75-2z"/></g>',
    "trash": f'<g {S}><path d="M3 4.5h10M6.2 4.5V3.2a.7.7 0 0 1 .7-.7h2.2a.7.7 0 0 1 .7.7v1.3M4.3 4.5l.6 8.1a1 1 0 0 0 1 .9h4.2a1 1 0 0 0 1-.9l.6-8.1"/></g>',
}


def ic(name, size=12, cls=""):
    c = "nx-ic" + (" " + cls if cls else "")
    return f'<svg class="{c}" width="{size}" height="{size}" viewBox="0 0 16 16" aria-hidden="true">{ICONS[name]}</svg>'


# ---------- Kit snippets ----------
def eq(playing=True, tint=""):
    c = "nx-eq" + (" is-playing" if playing else "") + (" nx-tint-" + tint if tint else "")
    return f'<span class="{c}" aria-hidden="true"><i></i><i></i><i></i></span>'


def ring(p, size=16, tint=""):
    r = (size - 2.5) / 2
    c = "nx-ring" + (" nx-tint-" + tint if tint else "")
    return (f'<svg class="{c}" width="{size}" height="{size}" viewBox="0 0 {size} {size}" style="--p:{p}" role="img" aria-label="{p} percent">'
            f'<circle class="nx-ring-track" cx="{size/2}" cy="{size/2}" r="{r}"/>'
            f'<circle class="nx-ring-value" cx="{size/2}" cy="{size/2}" r="{r}" pathLength="100"/></svg>')


def dot(tint, pulsing=False):
    return f'<span class="nx-dot nx-tint-{tint}{" is-pulsing" if pulsing else ""}"></span>'


def header(title, symbol=None, trailing=""):
    sym = ic(symbol, 10) if symbol else ""
    return f'<header class="nx-header">{sym}<span class="label nx-label nx-trunc">{title}</span><span class="nx-spacer"></span>{trailing}</header>'


def row(title, detail=None, trailing=None, trailing_tint="secondary", symbol="doc", symbol_tint="secondary", thumb=None, lead=None):
    if lead:
        t = f'<span class="nx-row-thumb">{lead}</span>'
    elif thumb:
        t = f'<span class="nx-row-thumb nx-thumb--{thumb}"></span>'
    else:
        t = f'<span class="nx-row-thumb nx-tint-{symbol_tint}">{ic(symbol, 12)}</span>'
    d = f'<span class="caption nx-caption nx-trunc">{detail}</span>' if detail else ""
    tr = f'<span class="numeric nx-numeric nx-row-trailing nx-tint-{trailing_tint}">{trailing}</span>' if trailing else ""
    head, tail = (title[:-7], title[-7:]) if len(title) > 12 else (title, "")
    ti = f'<span class="body nx-body nx-mid"><span>{head}</span><span>{tail}</span></span>'
    return (f'<div class="nx-row">{t}<span class="nx-row-text">{ti}{d}</span>'
            f'<span class="nx-spacer"></span>{tr}</div>')


def empty(symbol, title, message=None):
    m = f'<span class="caption nx-caption nx-clamp">{message}</span>' if message else ""
    return f'<div class="nx-empty">{ic(symbol, 18)}<span class="caption nx-caption">{title}</span>{m}</div>'


def btn(title, symbol=None, accent=False, extra=""):
    c = "nx-btn" + (" nx-btn--accent" if accent else "") + (" " + extra if extra else "")
    return f'<button type="button" class="{c}">{ic(symbol, 12) if symbol else ""}{title}</button>'


def icon_btn(symbol, label, kind="glass", size=None, tint="", extra="", attrs=""):
    size = size or (28 if kind == "glass" else 24)
    glyph = round(size * (0.44 if kind == "glass" else 0.5))
    c = f"nx-icon-btn nx-icon-btn--{kind}" + (" nx-tint-" + tint if tint else "") + (" " + extra if extra else "")
    return f'<button type="button" class="{c}" style="--size:{size}px" aria-label="{label}" title="{label}" {attrs}>{ic(symbol, glyph)}</button>'


def card(inner, cls="", i=None, style=""):
    c = "nx-card" + (" " + cls if cls else "") + (" nx-appear" if i is not None else "")
    st = (f"--i:{i};" if i is not None else "") + style
    return f'<section class="{c}"{" style=" + chr(34) + st + chr(34) if st else ""}>{inner}</section>'


# ---------- Module compositions ----------
def calendar_card(i=None):
    return card(header("Next up", "calendar", '<span class="numeric nx-numeric nx-tint-accent" data-countdown="725">12m</span>')
                + '<div class="nx-np-meta"><span class="title nx-title nx-trunc">Design review</span>'
                  '<span class="caption nx-caption nx-trunc">10:30 – 11:00 · Video call</span></div>', i=i)


def claude_card(i=None):
    return card(header("Claude Code", "terminal", dot("warning", True))
                + row("notcher-design", "Waiting for permission", "2m", symbol="terminal", symbol_tint="warning"), i=i)


def nowplaying_card(i=None, ambient=False, playing=True):
    cls = "nx-np" + (" nx-card--ambient nx-ambient--ferry" if ambient else "")
    inner = (header("Now Playing", "note", eq(playing))
             + '<div class="nx-np-track"><div class="nx-art nx-art--ferry" role="img" aria-label="Album artwork"></div>'
               '<div class="nx-np-meta"><span class="title nx-title nx-trunc">Night Ferry</span>'
               '<span class="caption nx-caption nx-trunc">Halden</span>'
               '<span class="caption nx-caption nx-trunc">Low Tide</span></div></div>'
             + '<div class="nx-scrub-row"><span class="caption nx-caption nx-num">1:24</span>'
               '<span class="nx-scrub" role="progressbar" aria-label="Position" aria-valuenow="38" aria-valuemin="0" aria-valuemax="100"><i style="width:38%"></i></span>'
               '<span class="caption nx-caption nx-num">−2:17</span></div>'
             + '<div class="nx-np-controls">' + icon_btn("prev", "Previous", "plain", 28)
             + icon_btn("pause" if playing else "play", "Pause" if playing else "Play", "glass", 32, attrs="data-playpause")
             + icon_btn("next", "Next", "plain", 28) + "</div>")
    return card(inner, cls, i=i)


def convert_card(i=None, state="done"):
    if state == "empty":
        inner = header("Convert", "photo") + empty("photo", "Drop images on the notch", "PNG, JPEG and HEIC become WebP")
    elif state == "working":
        inner = (header("Convert", "photo", '<span class="numeric nx-numeric nx-tint-secondary">2/5</span>')
                 + row("hero-banner.png", "1.2 MB → 264 KB", "−78%", "success", thumb="ferry")
                 + row("dunes-wide.jpeg", "Converting…", lead=ring(62), thumb=None)
                 + row("fjord-morning.heic", "Waiting", symbol="photo"))
    else:
        inner = (header("Convert", "photo", '<span class="caption nx-caption">WebP</span>')
                 + row("hero-banner.png", "1.2 MB → 264 KB", "−78%", "success", thumb="ferry")
                 + row("dunes-wide.jpeg", "3.4 MB → 912 KB", "−73%", "success", thumb="dune")
                 + row("settings-panel.png", "86 KB → 91 KB", "+6%", "secondary", thumb="ui"))
    return card(inner, i=i)


def clip(kind, symbol, body, source, when, i=None, cls=""):
    return card(header(kind, symbol) + body
                + f'<div class="nx-clip-foot"><span class="caption nx-caption nx-trunc">{source}</span><span class="nx-spacer"></span>'
                  f'<span class="caption nx-caption nx-num">{when}</span></div>', "nx-clip" + (" " + cls if cls else ""), i=i)


def clipboard_page(appear=True):
    n = (lambda k: k) if appear else (lambda k: None)
    clips = (
        clip("Text", "text", '<p class="body nx-body nx-clamp nx-clip-body" style="--lines:5">Keep the top cap pure black so the panel reads as part of the hardware, then let the glass take over.</p>', "Notes", "now", n(1), "is-highlighted")
        + clip("Link", "link", '<p class="body nx-body nx-clamp nx-clip-body" style="--lines:5">developer.apple.com/documentation/swiftui/glass</p>', "Safari", "4m", n(2))
        + clip("Image", "photo", '<div class="nx-clip-image nx-thumb--fjord" role="img" aria-label="Copied image"></div>', "Preview", "18m", n(3))
        + clip("Colour", "drop", '<div class="nx-clip-swatch" style="background:#409eff"></div><span class="numeric nx-numeric">#409EFF</span>', "Sketchbook", "1h", n(4))
    )
    return ('<div class="nx-page">'
            + header("Clipboard", "clipboard", '<span class="caption nx-caption">4 of 50</span>' + icon_btn("trash", "Clear history", "plain", 20))
            + f'<div class="nx-clips">{clips}</div></div>')


def home(appear=True):
    n = (lambda k: k) if appear else (lambda k: None)
    return f'<div class="nx-home">{calendar_card(n(0))}{claude_card(n(1))}{nowplaying_card(n(2))}{convert_card(n(3))}</div>'


def band():
    return ('<div class="nx-band" data-show="expanded"><span>'
            + icon_btn("grid", "Home", "plain", attrs='data-go="home" aria-pressed="true"')
            + icon_btn("tray", "Shelf", "plain", attrs='disabled')
            + icon_btn("clipboard", "Clipboard", "plain", attrs='data-go="clipboard" aria-pressed="false"')
            + "</span><span>" + icon_btn("sliders", "Settings", "plain") + "</span></div>")


def wings(leading, trailing=""):
    return (f'<div class="nx-wing nx-wing--leading" data-show="activity">{leading}</div>'
            f'<div class="nx-wing nx-wing--trailing" data-show="activity">{trailing}</div>')


WING_ART = '<span class="nx-wing-art nx-art--ferry nx-appear"></span>'
MENUBAR = ('<div class="nx-menubar" aria-hidden="true"><span><b>Desktop</b><span>File</span><span>Edit</span><span>View</span></span>'
           '<span><span>Sat 21 Nov</span><span>19:14</span></span></div>')

COUNTDOWN_JS = """
  // CountdownText: Format.countdown — "1h 5m", "12m", "45s", "now"
  function nxCountdown(s) {
    s = Math.ceil(s); if (s <= 0) return 'now'; if (s < 60) return s + 's';
    var m = Math.ceil(s / 60); if (m < 60) return m + 'm';
    var h = Math.floor(m / 60), r = m % 60; return r ? h + 'h ' + r + 'm' : h + 'h';
  }
  document.querySelectorAll('[data-countdown]').forEach(function (el) {
    var end = Date.now() + Number(el.dataset.countdown) * 1000;
    function tick() { el.textContent = nxCountdown((end - Date.now()) / 1000); }
    tick(); setInterval(tick, 1000);
  });
"""

PLAYPAUSE_JS = """
  var PLAY = %s, PAUSE = %s;
  document.querySelectorAll('[data-playpause]').forEach(function (b) {
    b.addEventListener('click', function () {
      var card = b.closest('.nx-card'), bars = card.querySelector('.nx-eq');
      var playing = bars.classList.toggle('is-playing');
      b.innerHTML = playing ? PAUSE : PLAY;
      b.setAttribute('aria-label', playing ? 'Pause' : 'Play'); b.title = playing ? 'Pause' : 'Play';
    });
  });
""" % (json.dumps(ic("play", 14)), json.dumps(ic("pause", 14)))


def doc(name, marker, body, style="", script="", body_class="nx-stage nx-stage--center"):
    st = f"<style>\n{style.strip()}\n</style>\n" if style.strip() else ""
    sc = f"<script>\n(function () {{\n{script.rstrip()}\n}})();\n</script>\n" if script.strip() else ""
    h = re.search(r"height=(\d+)", marker).group(1)
    return (f"<!-- @dsCard {marker} -->\n<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            f"<title>{name} — preview</title>\n{st}</head>\n<body>\n<div class=\"{body_class}\" style=\"height:{h}px\">\n{body.strip()}\n</div>\n{sc}</body>\n</html>\n")


PREVIEWS = {}
READMES = {}

SWITCH_CSS = """
.pv-switch { position: absolute; left: 50%; bottom: 16px; translate: -50% 0; display: flex; gap: 6px; padding: 5px; border-radius: 999px; }
.pv-switch .nx-btn { background: none; box-shadow: none; -webkit-backdrop-filter: none; backdrop-filter: none; color: var(--text-secondary); }
.pv-switch .nx-btn:hover { color: var(--text-primary); }
.pv-switch .nx-btn[aria-pressed="true"] { background: var(--glass-fill-hover); color: var(--text-primary); box-shadow: inset 0 1px 0 var(--glass-rim), inset 0 0 0 1px var(--glass-rim-soft); }
"""


def switch(items, attr):
    bs = "".join(f'<button type="button" class="nx-btn" {attr}="{k}" aria-pressed="{"true" if j == 0 else "false"}">{v}</button>' for j, (k, v) in enumerate(items))
    return f'<div class="nx-glass pv-switch" role="group" aria-label="Preview state">{bs}</div>'


# ----- NotchSurface -----
drop_body = ('<div class="nx-content" data-show="drop">'
             + card('<span class="nx-icon-btn nx-icon-btn--glass nx-tint-accent" style="--size:32px">' + ic("arrowdown", 14) + "</span>"
                    '<span class="nx-drop-text"><span class="title nx-title nx-trunc">Convert to WebP</span>'
                    '<span class="caption nx-caption nx-trunc">3 images · hold ⌥ to keep them on the Shelf</span></span>',
                    "nx-drop is-highlighted", i=0) + "</div>")
notch_full = ('<div class="nx-notch" id="notch" data-state="expanded" data-page="home">'
              '<i class="nx-notch-shadow"></i><div class="nx-notch-surface"></div>'
              + wings(WING_ART, eq(True)) + band()
              + '<div class="nx-content" data-show="expanded"><div data-page-view="home" style="height:100%">' + home()
              + '</div><div data-page-view="clipboard" style="height:100%">' + clipboard_page() + "</div></div>"
              + drop_body + "</div>")
PREVIEWS["NotchSurface"] = doc(
    "NotchSurface", 'group="Notch" height=336 width=860 subtitle="Closed, hover, live activity, drop target and expanded"',
    '<div class="nx-screen">' + MENUBAR + notch_full
    + switch([("expanded", "Expanded"), ("drop", "Drop"), ("activity", "Activity"), ("hover", "Hover"), ("closed", "Closed")], "data-set") + "</div>",
    style=".nx-notch { cursor: default; }\n" + SWITCH_CSS,
    script="""
  var notch = document.getElementById('notch'), sets = document.querySelectorAll('[data-set]'), tabs = document.querySelectorAll('[data-go]');
  function set(state) {
    notch.dataset.state = state;
    sets.forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.set === state)); });
  }
  sets.forEach(function (b) { b.addEventListener('click', function () { set(b.dataset.set); }); });
  notch.addEventListener('mouseenter', function () { if (notch.dataset.state === 'closed') set('hover'); });
  notch.addEventListener('mouseleave', function () { if (notch.dataset.state === 'hover') set('closed'); });
  notch.addEventListener('click', function () {
    var s = notch.dataset.state; if (s === 'closed' || s === 'hover' || s === 'activity') set('expanded');
  });
  tabs.forEach(function (b) {
    b.addEventListener('click', function () {
      notch.dataset.page = b.dataset.go;
      tabs.forEach(function (t) { t.setAttribute('aria-pressed', String(t === b)); });
    });
  });
""" + COUNTDOWN_JS + PLAYPAUSE_JS, body_class="nx-stage")

READMES["NotchSurface"] = """The notch's one background: pure black where it meets the hardware, melting into dark Liquid Glass below. `NotchUI` draws exactly one behind everything; modules never use it.

Source: `Sources/NotchCore/Design/Surfaces.swift`. The preview is a web rendition: `backdrop-filter` stands in for `.glassEffect(.regular.tint(glassTint))`, and the hardware notch is assumed to be 185 × 32 pt.

```swift
NotchSurface(shape: notchShape, capHeight: metrics.safeTop, glassAmount: isExpanded ? 1 : 0)
```

## You provide

- `shape`: the animated notch outline (ears from `radius-notch-*-top`, corners from `radius-notch-*-bottom`).
- `capHeight`: the height of the solid black band, which is the hardware notch height.
- `glassAmount`: 0 for the closed notch (solid `notch-black` everywhere), 1 for the open panel (glass below the cap at `glass-floor`).

## States

| State | Size below or beside the notch | Glass | Spring |
|---|---|---|---|
| Closed | none | 0 | `Motion.close` |
| Hover | +12 × +6 (`hover-growth-*`) | 0 | `Motion.morph` |
| Live activity | a 40 pt wing each side (`wing-width`) | 0 | `Motion.morph` |
| Drop target | 420 × 92 (`drop-*`) | 1 | `Motion.open` |
| Expanded | 680 × 204 (`expanded-*`) | 1 | `Motion.open` |

## Rules

- The cap is always `notch-black` for the full notch height, then fades over `cap-fade` (56 pt). Never let glass or content colour reach the top edge.
- Content inside the open panel sits within `inset-top`, `inset-side`, `inset-bottom`.
- The closed notch casts no shadow and shows no rim. Glass, rim and shadow arrive together with `glassAmount`.
- Collapse with `Motion.close` (critically damped) so nothing bounces on the way back into the hardware.
"""

# ----- LiveActivity -----
ACTIVITIES = {
    "nowPlaying": (WING_ART, '<span class="nx-appear">' + eq(True) + "</span>"),
    "convert": ('<span class="nx-appear">' + ring(25, 18) + "</span>", '<span class="numeric nx-numeric nx-appear">3/12</span>'),
    "calendar": ('<span class="nx-tint-accent nx-appear">' + ic("calendar", 16) + "</span>", '<span class="numeric nx-numeric nx-appear" data-countdown="725">12m</span>'),
    "claudeAgents": ('<span class="nx-tint-warning nx-appear pv-pulse">' + ic("terminal", 16) + "</span>", '<span class="numeric nx-numeric nx-tint-warning nx-appear">Ask</span>'),
}
PREVIEWS["LiveActivity"] = doc(
    "LiveActivity", 'group="Notch" height=132 subtitle="One compact status in the wings beside the closed notch"',
    '<div class="nx-screen">' + MENUBAR
    + '<div class="nx-notch" id="notch" data-state="activity"><i class="nx-notch-shadow"></i><div class="nx-notch-surface"></div>'
    + wings(*ACTIVITIES["nowPlaying"]) + "</div>"
    + switch([("nowPlaying", "Ambient"), ("calendar", "Passive"), ("convert", "Progress"), ("claudeAgents", "Attention")], "data-activity") + "</div>",
    style="@keyframes pv-pulse { to { opacity: .35; } }\n.pv-pulse { animation: nx-appear var(--motion-appear-dur) var(--motion-appear) both, pv-pulse .8s ease-in-out .5s infinite alternate; }\n@media (prefers-reduced-motion: reduce) { .pv-pulse { animation: none; } }\n" + SWITCH_CSS,
    script="  var ACTIVITIES = " + json.dumps(ACTIVITIES) + """;
  var wings = document.querySelectorAll('.nx-wing'), buttons = document.querySelectorAll('[data-activity]');
""" + COUNTDOWN_JS.replace("document.querySelectorAll('[data-countdown]').forEach(function (el) {", "function nxWire() { document.querySelectorAll('[data-countdown]').forEach(function (el) { if (el.dataset.wired) return; el.dataset.wired = '1';").replace("    tick(); setInterval(tick, 1000);\n  });", "    tick(); setInterval(tick, 1000);\n  }); }\n  nxWire();") + """
  buttons.forEach(function (b) {
    b.addEventListener('click', function () {
      var a = ACTIVITIES[b.dataset.activity];
      wings[0].innerHTML = a[0]; wings[1].innerHTML = a[1]; nxWire();
      buttons.forEach(function (o) { o.setAttribute('aria-pressed', String(o === b)); });
    });
  });
""", body_class="nx-stage")

READMES["LiveActivity"] = """A compact status shown in the wings beside the closed notch: one glyph on the left, an optional glyph or about six characters on the right.

Source: `Sources/NotchCore/LiveActivity.swift`. Each module publishes at most one activity; `ActivityArbiter` picks the single one on screen, and `NotchUI` owns the rendering so every module looks the same. The wing rendering in this preview is a proposal: `NotchUI` is not built yet.

```swift
LiveActivity(id: "convert.batch", module: .convert, priority: .progress,
             leading: .progress(0.25), trailing: .text("3/12"),
             accessibilityLabel: "Converting 3 of 12 images")
```

## You provide

- `leading`: an `ActivityGlyph`, rendered at roughly 18 pt.
- `trailing`: optional. Keep text to about 6 characters.
- `priority`: `ambient` (music is playing), `passive` (meeting in 12 min), `progress` (converting 3/12) or `attention` (a session needs the user). Highest wins, then most recently updated. Over a fullscreen app only `attention` is shown.
- `accessibilityLabel`: the whole status as a sentence.

## Glyphs

| `ActivityGlyph` | Use for |
|---|---|
| `.symbol(name, tint:, pulse:)` | An SF Symbol; pulse only for `attention` |
| `.progress(0...1)` | A determinate ProgressRing |
| `.text(String)` | Short text in `numeric` |
| `.countdown(to:)` | A live CountdownText |
| `.image(SendableImage)` | Album art or an image preview, `radius-thumbnail` |
| `.equalizer(playing:)` | EqualizerBars |

## Rules

- Wings are `notch-black`, exactly as tall as the notch and `wing-width` (40 pt) wide. No glass, no cards.
- Colour carries meaning here: `accent` for time, `warning` for attention. Never tint ambient activities.
- Put `.notchHero(id)` on the one element in the module's card that the leading glyph should fly into when the notch expands.
"""

# ----- GlassCard -----
PREVIEWS["GlassCard"] = doc(
    "GlassCard", 'group="Surfaces" height=176 width=560 subtitle="Rest and highlighted"',
    '<div class="nx-glass nx-glass--row">'
    + card(header("Next up", "calendar") + '<div class="nx-np-meta"><span class="title nx-title nx-trunc">Design review</span><span class="caption nx-caption nx-trunc">10:30 – 11:00 · Video call</span></div>', style="width:210px;height:87px")
    + card(header("Convert", "photo") + '<div class="nx-np-meta"><span class="title nx-title nx-trunc">Drop to convert</span><span class="caption nx-caption nx-trunc">3 images</span></div>', "is-highlighted", style="width:210px;height:87px")
    + "</div>")
READMES["GlassCard"] = """The standard container for a module's content: a faint lifted layer on the panel's glass, laying its children out as a leading-aligned vertical stack.

Source: `Sources/NotchCore/Design/Surfaces.swift`.

```swift
GlassCard(highlighted: isDropTarget) {
    SectionHeader("Convert", symbol: "photo")
    ResultRow(title: "hero-banner.png", detail: "1.2 MB → 264 KB", trailing: "−78%", trailingTint: .success)
}
```

## You provide

- `content`: the children, stacked vertically. Start with a SectionHeader.
- `padding` (default `space-m`, 12) and `spacing` (default `space-s`, 8).
- `highlighted`: true for an active drop target or a selected item.

## Rules

- A card fills the frame it is given (`PanelLayout.cardSize(for:)`: 210 × 87 or 210 × 184 at the default size). Never assume more room; truncate text instead of growing.
- Rest: `card-fill` with a 1 pt `card-stroke` outline, `radius-card`.
- Highlighted: `accent-wash` with a 1.5 pt `accent` outline, scaled to 1.015 on `Motion.morph`.
- Do not nest cards, and do not add shadows: the panel's glass is the only elevation.
"""

# ----- GlassButton -----
PREVIEWS["GlassButton"] = doc(
    "GlassButton", 'group="Controls" height=104 width=520 subtitle="Standard, with symbol, accent, pressed"',
    '<div class="nx-glass nx-glass--row">' + btn("Reveal") + btn("Copy all", "clipboard") + btn("Convert", "photo", accent=True) + btn("Pressed", extra="is-pressed") + "</div>")
READMES["GlassButton"] = """A capsule button in interactive Liquid Glass, for the one or two actions a card offers.

Source: `Sources/NotchCore/Design/Controls.swift` (`GlassButton`, `GlassButtonStyle`).

```swift
GlassButton("Convert", symbol: "photo", prominence: .accent) { convert() }
```

## You provide

- `title`: one or two words, sentence case.
- `symbol`: an optional SF Symbol name.
- `prominence`: `.standard` (plain glass) or `.accent` (glass tinted `accent-glass`).
- `action`.

## Rules

- 12 pt semibold `text-primary` label, 12 pt horizontal and 6 pt vertical padding, capsule shape.
- Presses scale to 0.95 on `Motion.press`.
- At most one accent button in the whole panel. Most cards need none: prefer a row that acts on click.
- A `text-primary` label on `accent-glass` measures about 4.3:1 over the dark panel; keep accent labels to short, semibold words.
"""

# ----- GlassIconButton -----
PREVIEWS["GlassIconButton"] = doc(
    "GlassIconButton", 'group="Controls" height=104 width=520 subtitle="Glass and plain kinds"',
    '<div class="nx-glass nx-glass--row">' + icon_btn("prev", "Previous", "plain", 28) + icon_btn("pause", "Pause", "glass", 32) + icon_btn("next", "Next", "plain", 28)
    + '<span style="width:12px"></span>' + icon_btn("check", "Done", "glass", 28, tint="success") + icon_btn("grid", "Home", "plain", extra="is-hover") + icon_btn("clipboard", "Clipboard", "plain") + icon_btn("sliders", "Settings", "plain") + "</div>")
READMES["GlassIconButton"] = """A circular icon button: interactive glass for a card's primary control, or a borderless plain kind for dense rows and the panel's top band.

Source: `Sources/NotchCore/Design/Controls.swift` (`GlassIconButton`, `GlassIconButtonStyle`, `PlainIconButtonStyle`).

```swift
GlassIconButton("pause.fill", label: "Pause") { toggle() }
GlassIconButton("gearshape", label: "Settings", kind: .plain, size: 24, tint: .secondary) { openSettings() }
```

## You provide

- `symbol`: an SF Symbol name.
- `label`: the accessibility label and tooltip. Always required.
- `kind`: `.glass` (default) or `.plain`.
- `size`: 28 by default. The glyph is 44% of a glass button and 50% of a plain one.
- `tint`: a `TintRole`.

## Rules

- Glass presses scale to 0.90, plain to 0.88, on `Motion.press`.
- Plain buttons rest in their tint and turn `text-primary` on a `card-fill-hover` disc under the pointer, on `Motion.quick`.
- One glass icon button per card at most (play/pause). Everything around it is plain.
"""

# ----- RowButton -----
PREVIEWS["RowButton"] = doc(
    "RowButton", 'group="Controls" height=132 subtitle="A whole row that acts on click"',
    '<div class="nx-glass nx-glass--col" style="width:260px">'
    + '<button type="button" class="nx-row-btn is-hover">' + row("hero-banner.webp", "Click to reveal in Finder", "264 KB", thumb="ferry") + "</button>"
    + '<button type="button" class="nx-row-btn">' + row("dunes-wide.webp", "Click to reveal in Finder", "912 KB", thumb="dune") + "</button></div>")
READMES["RowButton"] = """Makes a whole row or card behave like a button, with a hover fill and a small press scale.

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
"""

# ----- SectionHeader -----
PREVIEWS["SectionHeader"] = doc(
    "SectionHeader", 'group="Content" height=140 subtitle="Label, optional symbol, optional trailing accessory"',
    '<div class="nx-glass nx-glass--col" style="width:240px;gap:12px">' + header("Clipboard") + header("Now Playing", "note", eq(True))
    + header("Convert", "photo", '<span class="numeric nx-numeric nx-tint-secondary">2/5</span>') + "</div>")
READMES["SectionHeader"] = """The small heading at the top of a card: an optional symbol, the label, and an optional trailing accessory.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
SectionHeader("Now Playing", symbol: "music.note") { EqualizerBars(playing: isPlaying) }
```

## You provide

- `title`: one or two words in normal case. The header uppercases it.
- `symbol`: an optional SF Symbol, drawn 10 pt semibold in `text-tertiary`.
- `trailing`: one small accessory, such as EqualizerBars, a StatusDot, a count in `numeric` or a plain icon button.

## Rules

- 16 pt tall, set in `label`. One per card, first child.
- `text-tertiary` on the panel measures 3.4:1, so a header is a quiet signpost and never the only place a fact appears.
"""

# ----- ResultRow -----
PREVIEWS["ResultRow"] = doc(
    "ResultRow", 'group="Content" height=176 subtitle="Thumbnail or symbol, title, detail, trailing figure"',
    '<div class="nx-glass nx-glass--col" style="width:260px">'
    + row("hero-banner.png", "1.2 MB → 264 KB", "−78%", "success", thumb="ferry")
    + row("a-very-long-file-name-for-the-quarterly-report.pdf", "Shelf · 2.4 MB", symbol="doc")
    + row("notcher-design", "Waiting for permission", "2m", "warning", symbol="terminal", symbol_tint="warning") + "</div>")
READMES["ResultRow"] = """One line item: a thumbnail or symbol, a title, an optional detail and an optional trailing figure.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
ResultRow(thumbnail: preview, title: "hero-banner.png", detail: "1.2 MB → 264 KB",
          trailing: Format.saving(0.78), trailingTint: .success)
```

## You provide

- `thumbnail` (a `SendableImage`) or `symbol` with `symbolTint`. The default symbol is `doc`.
- `title`: set in `body`, one line, truncated in the middle so file extensions survive.
- `detail`: set in `caption`, one line.
- `trailing`: a short figure in `numeric`, with `trailingTint`.

## Rules

- 30 pt tall with a 26 pt thumbnail at `radius-thumbnail`. A symbol sits on a `card-fill` square.
- Write figures with `Format`: `Format.bytes` ("264 KB"), `Format.saving` ("−78%", "+6%") and `Format.countdown` ("12m").
- Tint the trailing figure `success` only for a real saving; growth stays `text-secondary`.
"""

# ----- EmptyState -----
PREVIEWS["EmptyState"] = doc(
    "EmptyState", 'group="Content" height=260 width=560 subtitle="A card with nothing to show"',
    '<div class="nx-glass nx-glass--row">' + card(header("Convert", "photo") + empty("photo", "Drop images on the notch", "PNG, JPEG and HEIC become WebP"), style="width:210px;height:184px")
    + card(header("Clipboard", "clipboard") + empty("clipboard", "Nothing copied yet"), style="width:210px;height:184px") + "</div>")
READMES["EmptyState"] = """A centred placeholder for a card with nothing to show: a symbol, one line saying what is missing, and an optional hint.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
EmptyState(symbol: "photo", title: "Drop images on the notch", message: "PNG, JPEG and HEIC become WebP")
```

## You provide

- `symbol`: 18 pt, `text-tertiary`.
- `title`: `caption` in `text-secondary`. Say what to do, not what went wrong.
- `message`: optional, at most two lines, `caption` in `text-tertiary`.

## Rules

- Fills the space left in the card and centres itself. Keep the SectionHeader above it.
- No buttons and no illustrations: the notch itself is the call to action.
"""

# ----- ProgressRing -----
PREVIEWS["ProgressRing"] = doc(
    "ProgressRing", 'group="Content" height=104 subtitle="Determinate progress, 16 pt by default"',
    '<div class="nx-glass nx-glass--row" style="gap:20px">' + ring(8) + ring(38) + ring(72) + ring(100, tint="success") + ring(62, 28) + "</div>")
READMES["ProgressRing"] = """A small determinate progress ring for work the user started.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
ProgressRing(progress: Double(done) / Double(total))
```

## You provide

- `progress`: 0 to 1, clamped.
- `size` (default 16), `lineWidth` (default 2.5) and `tint` (default `.accent`).

## Rules

- The track is `card-stroke`; the value has round caps, starts at 12 o'clock and animates on `Motion.morph`.
- Use it as a ResultRow's leading element or as a wing glyph. Pair it with a count ("3/12") when there is more than one item.
- It reports its value to VoiceOver as a percentage.
"""

# ----- StatusDot -----
PREVIEWS["StatusDot"] = doc(
    "StatusDot", 'group="Content" height=104 subtitle="A 7 pt dot that can pulse for attention"',
    '<div class="nx-glass nx-glass--row" style="gap:18px">'
    + "".join(f'<span style="display:flex;align-items:center;gap:6px">{dot(t, p)}<span class="caption nx-caption">{l}</span></span>'
              for t, p, l in [("secondary", False, "Idle"), ("accent", False, "Running"), ("success", False, "Done"), ("warning", True, "Needs you")]) + "</div>")
READMES["StatusDot"] = """A small coloured dot that states a status and can pulse to ask for attention.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
StatusDot(.warning, pulsing: session.needsPermission)
```

## You provide

- A `TintRole`: `primary`, `secondary`, `accent`, `success` or `warning`.
- `pulsing`: true only when the user has to act.

## Rules

- 7 pt. The pulse fades between 1 and 0.35 over 0.8 s and stops under Reduce Motion.
- `success` and `warning` are close in lightness, so a dot never stands alone: put the state in words beside it or in the row's detail.
- One pulsing dot in the panel at a time.
"""

# ----- EqualizerBars -----
PREVIEWS["EqualizerBars"] = doc(
    "EqualizerBars", 'group="Content" height=104 subtitle="Playing and paused"',
    '<div class="nx-glass nx-glass--row" style="gap:18px">'
    + f'<span style="display:flex;align-items:center;gap:6px">{eq(True)}<span class="caption nx-caption">Playing</span></span>'
    + f'<span style="display:flex;align-items:center;gap:6px">{eq(False)}<span class="caption nx-caption">Paused</span></span>'
    + f'<span style="display:flex;align-items:center;gap:6px">{eq(True, "accent")}<span class="caption nx-caption">Accent</span></span></div>')
READMES["EqualizerBars"] = """Three animated bars that say audio is playing.

Source: `Sources/NotchCore/Design/Components.swift`.

```swift
EqualizerBars(playing: player.isPlaying)
```

## You provide

- `playing`: the bars rest at 30% height when false.
- `tint` (default `.primary`).

## Rules

- 14 × 14 pt: three 2.5 pt capsules, 2 pt apart, centre-aligned.
- Use it as the trailing wing glyph of a Now Playing activity and as the trailing accessory of its SectionHeader.
- The bars stand still under Reduce Motion.
"""

# ----- CountdownText -----
PREVIEWS["CountdownText"] = doc(
    "CountdownText", 'group="Content" height=104 subtitle="A live countdown to a date"',
    '<div class="nx-glass nx-glass--row" style="gap:22px">'
    + '<span class="numeric nx-numeric" data-countdown="3900">1h 5m</span><span class="numeric nx-numeric nx-tint-accent" data-countdown="725">12m</span>'
    + '<span class="numeric nx-numeric nx-tint-warning" data-countdown="45">45s</span><span class="display nx-display" data-countdown="8">8s</span></div>',
    script=COUNTDOWN_JS)
READMES["CountdownText"] = """A live countdown to a date, written the way every module writes durations: "1h 5m", "12m", "45s", then "now".

Source: `Sources/NotchCore/Design/Components.swift`, `Sources/NotchCore/Format.swift`.

```swift
CountdownText(to: meeting.start)
```

## You provide

- `target`: the date to count down to.
- `style`: a `NotchTextStyle`, `numeric` by default.

## Rules

- Updates once a second with a numeric content transition; digits are monospaced so the text does not shift.
- Minutes round up: 12 min 5 s reads "13m". Past dates read "now".
- Use it in a SectionHeader's trailing slot, a ResultRow's trailing figure or a wing.
"""

# ----- Modules (intentional additions) -----
def labelled(c, label):
    return f'<div class="pv-col">{c}<span class="label nx-label">{label}</span></div>'

PV_COL = ".pv-col { display: flex; flex-direction: column; align-items: center; gap: 8px; }\n.pv-col > .nx-card { width: 210px; height: 184px; }\n"

PREVIEWS["NowPlaying"] = doc(
    "NowPlaying", 'group="Modules" height=284 width=760 subtitle="The centre dashboard card, and an ambient-artwork experiment"',
    '<div class="nx-glass nx-glass--row">' + labelled(nowplaying_card(), "Standard") + labelled(nowplaying_card(ambient=True), "Ambient · experiment")
    + labelled(nowplaying_card(playing=False), "Paused") + "</div>",
    style=PV_COL, script=PLAYPAUSE_JS)
READMES["NowPlaying"] = """The Now Playing dashboard card: artwork, title, artist and album, a thin position bar, and three transport controls.

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
"""

PREVIEWS["Convert"] = doc(
    "Convert", 'group="Modules" height=284 width=760 subtitle="Convert to WebP: empty, converting and done"',
    '<div class="nx-glass nx-glass--row">' + labelled(convert_card(state="empty"), "Empty") + labelled(convert_card(state="working"), "Converting")
    + labelled(convert_card(state="done"), "Done") + "</div>", style=PV_COL)
READMES["Convert"] = """The Convert to WebP dashboard card: drop images on the notch, watch each one finish, read the saving.

An intentional addition: a composition of kit parts for `ConvertModule`, which is still a placeholder in the source.

## Built from

- GlassCard in the `trailing` dashboard slot (210 × 184).
- SectionHeader "Convert"; trailing is the output format at rest and a count ("2/5") while working.
- EmptyState when there is no history.
- ResultRow per file: thumbnail, file name, "1.2 MB → 264 KB" from `Format.bytes`, and the saving from `Format.saving`.
- ProgressRing in the row's leading slot while a file converts.

## Rules

- A saving is `success` and uses a real minus sign ("−78%"). A file that grew reads "+6%" in `text-secondary`: it is information, not an error.
- While dragging near the notch, the drop target (see NotchSurface) names the action: "Convert to WebP", the item count, and the ⌥ modifier that sends files to the Shelf instead.
- The live activity is `progress`: a ProgressRing leading, "3/12" trailing. Finish with `Haptics.success()`.
- Wrap finished rows in a RowButton that reveals the file; rows drag out of the notch as files.
"""

PREVIEWS["Clipboard"] = doc(
    "Clipboard", 'group="Modules" height=252 width=760 subtitle="Clipboard history as a full-width page"',
    '<div class="nx-glass" style="width:680px;height:212px">' + clipboard_page(appear=False) + "</div>")
READMES["Clipboard"] = """Clipboard history as a full-width page: the most recent clips as cards, newest first, each saying what it is, where it came from and when.

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
"""

# ----- Cover -----
bars = []
heights = [40, 72, 104, 64, 112, 88, 48, 96, 112, 56, 80, 104, 64, 40]
for k, h in enumerate(heights):
    x = 500 - 480 + k * 16
    cls = "pill ok" if k == 4 else ("pill warn" if k == 9 else "pill")
    bars.append(f'<rect class="{cls}" x="{x}" y="{200 - h / 2:g}" width="8" height="{h}" rx="4"/>')
PREVIEWS["Cover"] = """<!-- @dsCard height=288 -->
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Notcher</title>
<style>
  html, body { margin: 0; height: 100%; }
  body { background: var(--notch-black); color: var(--text-primary); font-family: var(--font-sans); overflow: hidden; }
  .cover { position: relative; width: 960px; height: 288px; overflow: hidden; background: var(--notch-black); }
  .art { position: absolute; top: 0; left: 480px; width: 480px; height: 288px; }
  .art svg { display: block; }
  .closed { fill: var(--text-primary); rx: var(--radius-notch-closed-bottom); }
  .glass { fill: var(--glass-fill-hover); rx: var(--radius-notch-open-bottom); }
  .accent { fill: var(--accent); rx: var(--radius-notch-open-bottom); }
  .pill { fill: var(--text-tertiary); rx: var(--space-xs); }
  .pill.ok { fill: var(--success); }
  .pill.warn { fill: var(--warning); }
  .words { position: absolute; left: 24px; bottom: 24px; max-width: 440px; }
  .name { margin: 0; font-size: 96px; line-height: .95; font-weight: 600; letter-spacing: -.03em; color: var(--text-primary); }
  .tag { margin: var(--space-s) 0 0 4px; font-size: 13px; line-height: 18px; color: var(--text-secondary); }
</style>
</head>
<body>
<div class="cover">
<div class="art" aria-hidden="true">
<svg viewBox="0 0 480 288" width="480" height="288">
<!--
  blocks      accent 216 wide × 236 tall (notch band + expanded-height) · glass-fill-hover 120 × 124 (notch band + drop-height) · text-primary 80 × 32 (two wing-widths × the notch band) — the notch's three sizes, hung from the top edge
  arrangement a strip of unequal slabs bleeding off the top edge, growing left to right, space-l gutters: closed, drop target, expanded
  pattern     pills, from the kit's EqualizerBars and "capsule" controls: 14 space-s-wide pills on a space-l pitch, centre-aligned like the bars, under the two shorter notches; one success, one warning
  scales      heights from the layout family; gutters and pitch space-l; pill width space-s, rx space-xs; corners radius-notch-closed-bottom and radius-notch-open-bottom
-->
<rect class="closed" x="16" y="-28" width="80" height="60" rx="13"/>
<rect class="glass" x="112" y="-28" width="120" height="152" rx="28"/>
<rect class="accent" x="248" y="-28" width="216" height="264" rx="28"/>
""" + "\n".join(bars) + """
</svg>
</div>
<div class="words">
<h1 class="name">Notcher</h1>
<p class="tag">A calm sheet of Liquid Glass under the MacBook notch.</p>
</div>
</div>
</body>
</html>
"""

# ---------- The bundle: a small classic script of render helpers ----------
ORDER = ["NotchSurface", "LiveActivity", "GlassCard", "GlassButton", "GlassIconButton", "RowButton", "SectionHeader",
         "ResultRow", "EmptyState", "ProgressRing", "StatusDot", "EqualizerBars", "CountdownText"]
bundle_js = ("/* @ds-bundle: " + json.dumps({"format": 4, "namespace": "Notcher", "components": [{"name": n} for n in ORDER]}) + " */\n"
             "/* Notcher: web rendition of the NotchCore design kit. Each component returns an HTML string styled by bundle.css. */\n"
             "(function () {\n  'use strict';\n  var ICONS = " + json.dumps(ICONS, indent=2).replace("\n", "\n  ") + ";\n"
             + open(os.path.join(HERE, "bundle_tail.js")).read())
assert "</script" not in bundle_js and "<!--" not in bundle_js
write(os.path.join(PROJECT, "components", "bundle.js"), bundle_js)
write(os.path.join(PROJECT, "components", "index.d.ts"), open(os.path.join(HERE, "index.d.ts")).read())

# ---------- Write the project files ----------
for name, html in PREVIEWS.items():
    write(os.path.join(PROJECT, "components", name, "preview.html"), html)
for name, md in READMES.items():
    write(os.path.join(PROJECT, "components", name, "README.md"), md)

# ---------- Local harness: what the page's preview frame would preload ----------
tok = json.load(open(os.path.join(PROJECT, "tokens.json")))
lines = [":root, [data-theme=\"dark\"] {"]
for t in tok["color"]["tokens"]:
    v = t["value"] if isinstance(t["value"], str) else t["value"]["dark"]
    lines.append(f"  --{t['name']}: {v};")
for t in tok["shadow"]["tokens"]:
    lines.append(f"  --{t['name']}: {t['value']};")
lines.append("}\n:root {")
for fam in ("spacing", "radius", "layout", "glass"):
    for t in tok[fam]["tokens"]:
        lines.append(f"  --{t['name']}: {t['value']};")
for k, v in tok["type"]["families"].items():
    lines.append(f"  --font-{k}: {v};")
lines.append("}")
for g in tok["type"]["groups"]:
    for s in g["styles"]:
        fam = s.get("family", g["family"])
        ls = f" letter-spacing: {s['letterSpacing']};" if "letterSpacing" in s else ""
        lines.append(f".{s['name']} {{ font-family: var(--font-{fam}); font-size: {s['fontSize']}; line-height: {s['lineHeight']}; font-weight: {s['fontWeight']};{ls} }}")
tokens_css = "\n".join(lines)
index = ["<!doctype html><meta charset=utf-8><title>harness</title><body style='margin:0;background:#888;font:12px system-ui'>"]
for name, html in PREVIEWS.items():
    page = html.replace("<head>", "<head>\n<style>\n" + tokens_css + "\n" + css + "\n</style>\n<script src='bundle.js'></script>", 1).replace('<html lang="en">', '<html lang="en" data-theme="dark">', 1)
    write(os.path.join(HARNESS, name + ".html"), page)
    m = re.search(r"height=(\d+)", html)
    w = re.search(r"width=(\d+)", html)
    index.append(f"<p style='margin:8px'>{name}</p><iframe src='{name}.html' style='border:0;display:block;width:{w.group(1) if w else 860}px;height:{m.group(1)}px'></iframe>")
write(os.path.join(HARNESS, "index.html"), "\n".join(index))
write(os.path.join(HARNESS, "bundle.js"), bundle_js)
print("wrote", len(PREVIEWS), "previews,", len(READMES), "readmes")
for key, (r, d) in SPRINGS.items():
    print(key, spring(r, d)[1])
