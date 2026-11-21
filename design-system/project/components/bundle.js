/* @ds-bundle: {"format": 4, "namespace": "Notcher", "components": [{"name": "NotchSurface"}, {"name": "LiveActivity"}, {"name": "GlassCard"}, {"name": "GlassButton"}, {"name": "GlassIconButton"}, {"name": "RowButton"}, {"name": "SectionHeader"}, {"name": "ResultRow"}, {"name": "EmptyState"}, {"name": "ProgressRing"}, {"name": "StatusDot"}, {"name": "EqualizerBars"}, {"name": "CountdownText"}]} */
/* Notcher: web rendition of the NotchCore design kit. Each component returns an HTML string styled by bundle.css. */
(function () {
  'use strict';
  var ICONS = {
    "grid": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.25\" y=\"2.25\" width=\"4.75\" height=\"4.75\" rx=\"1.25\"/><rect x=\"9\" y=\"2.25\" width=\"4.75\" height=\"4.75\" rx=\"1.25\"/><rect x=\"2.25\" y=\"9\" width=\"4.75\" height=\"4.75\" rx=\"1.25\"/><rect x=\"9\" y=\"9\" width=\"4.75\" height=\"4.75\" rx=\"1.25\"/></g>",
    "tray": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.25 9.5 4.1 4a1 1 0 0 1 .95-.7h5.9a1 1 0 0 1 .95.7l1.85 5.5v2.2a1 1 0 0 1-1 1h-9.5a1 1 0 0 1-1-1z\"/><path d=\"M2.4 9.5h3.1c.2 1.2 1.2 2 2.5 2s2.3-.8 2.5-2h3.1\"/></g>",
    "clipboard": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"3.25\" y=\"3\" width=\"9.5\" height=\"11\" rx=\"1.75\"/><rect x=\"5.9\" y=\"1.75\" width=\"4.2\" height=\"2.5\" rx=\".9\" fill=\"currentColor\"/></g>",
    "sliders": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 4.75h5M12 4.75h1.5M2.5 11.25h1.5M8.5 11.25h5\"/><circle cx=\"9.75\" cy=\"4.75\" r=\"1.75\"/><circle cx=\"6.25\" cy=\"11.25\" r=\"1.75\"/></g>",
    "photo": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"2\"/><circle cx=\"5.7\" cy=\"6.4\" r=\"1\" fill=\"currentColor\"/><path d=\"m2.4 11.2 3.2-2.7a.9.9 0 0 1 1.2 0L9 10.4l1.5-1.3a.9.9 0 0 1 1.2 0l1.9 1.8\"/></g>",
    "doc": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4.5 1.9h4.3l3.2 3.2v8a1 1 0 0 1-1 1H4.5a1 1 0 0 1-1-1V2.9a1 1 0 0 1 1-1z\"/><path d=\"M8.7 2.1v3.1h3.1\"/></g>",
    "calendar": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.25\" y=\"3\" width=\"11.5\" height=\"10.75\" rx=\"2\"/><path d=\"M2.25 6.5h11.5M5.25 1.75v2.2M10.75 1.75v2.2\"/></g>",
    "terminal": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"2.75\" width=\"12\" height=\"10.5\" rx=\"2\"/><path d=\"M4.75 6.25 7 8 4.75 9.75M8.5 10h2.75\"/></g>",
    "note": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M6 12V3.9a.6.6 0 0 1 .45-.58l5.3-1.4a.6.6 0 0 1 .75.58V9.9\"/><circle cx=\"4.4\" cy=\"12\" r=\"1.6\" fill=\"currentColor\"/><circle cx=\"10.9\" cy=\"9.9\" r=\"1.6\" fill=\"currentColor\"/></g>",
    "play": "<path d=\"M5.2 3.6 12.4 8l-7.2 4.4z\" fill=\"currentColor\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linejoin=\"round\"/>",
    "pause": "<g fill=\"currentColor\"><rect x=\"3.4\" y=\"2.8\" width=\"3.2\" height=\"10.4\" rx=\"1\"/><rect x=\"9.4\" y=\"2.8\" width=\"3.2\" height=\"10.4\" rx=\"1\"/></g>",
    "next": "<path d=\"M2.2 4.4 7.4 8l-5.2 3.6zM8.6 4.4 13.8 8l-5.2 3.6z\" fill=\"currentColor\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linejoin=\"round\"/>",
    "prev": "<path d=\"M2.2 4.4 7.4 8l-5.2 3.6zM8.6 4.4 13.8 8l-5.2 3.6z\" transform=\"matrix(-1 0 0 1 16 0)\" fill=\"currentColor\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linejoin=\"round\"/>",
    "link": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M5 11 11 5M6 4.75h5.25V10\"/></g>",
    "text": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 4.25h10M3 8h10M3 11.75h6\"/></g>",
    "check": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3.5 8.5 6.6 11.5l6-7\"/></g>",
    "arrowdown": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2.5v7.75M4.75 7.25 8 10.5l3.25-3.25M3.25 13.5h9.5\"/></g>",
    "drop": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2.2c2.4 2.8 3.9 4.7 3.9 6.9a3.9 3.9 0 0 1-7.8 0c0-2.2 1.5-4.1 3.9-6.9z\"/></g>",
    "video": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"1.75\" y=\"4.25\" width=\"8.5\" height=\"7.5\" rx=\"1.75\"/><path d=\"M10.25 7.3 14 5.3v5.4l-3.75-2z\"/></g>",
    "trash": "<g fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 4.5h10M6.2 4.5V3.2a.7.7 0 0 1 .7-.7h2.2a.7.7 0 0 1 .7.7v1.3M4.3 4.5l.6 8.1a1 1 0 0 0 1 .9h4.2a1 1 0 0 0 1-.9l.6-8.1\"/></g>"
  };
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function tintClass(t) { return t ? ' nx-tint-' + t : ''; }

  /** An SF Symbol stand-in as inline SVG. */
  function icon(name, size, cls) {
    size = size || 12;
    return '<svg class="nx-ic' + (cls ? ' ' + cls : '') + '" width="' + size + '" height="' + size +
      '" viewBox="0 0 16 16" aria-hidden="true">' + (ICONS[name] || '') + '</svg>';
  }

  /** Format.swift: shared text formatting so every module writes figures the same way. */
  var Format = {
    bytes: function (count) {
      var c = Math.max(0, Math.floor(count));
      if (c < 1000) return c + ' B';
      var kb = c / 1000;
      if (kb < 999.5) return Math.round(kb) + ' KB';
      var mb = kb / 1000;
      if (mb < 99.95) return mb.toFixed(1) + ' MB';
      if (mb < 999.5) return Math.round(mb) + ' MB';
      return (mb / 1000).toFixed(1) + ' GB';
    },
    saving: function (savedFraction) {
      var pct = Math.round(Math.abs(savedFraction) * 100);
      if (pct === 0) return '0%';
      return savedFraction > 0 ? '\u2212' + pct + '%' : '+' + pct + '%';
    },
    countdown: function (seconds) {
      var s = Math.ceil(seconds);
      if (s <= 0) return 'now';
      if (s < 60) return s + 's';
      var m = Math.ceil(s / 60);
      if (m < 60) return m + 'm';
      var h = Math.floor(m / 60), rem = m % 60;
      return rem === 0 ? h + 'h' : h + 'h ' + rem + 'm';
    }
  };

  function EqualizerBars(p) {
    p = p || {};
    return '<span class="nx-eq' + (p.playing ? ' is-playing' : '') + tintClass(p.tint) + '" aria-hidden="true"><i></i><i></i><i></i></span>';
  }

  function ProgressRing(p) {
    p = p || {};
    var size = p.size || 16, r = (size - 2.5) / 2, pct = Math.round(Math.min(1, Math.max(0, p.progress || 0)) * 100);
    return '<svg class="nx-ring' + tintClass(p.tint) + '" width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + ' ' + size +
      '" style="--p:' + pct + '" role="img" aria-label="' + pct + ' percent">' +
      '<circle class="nx-ring-track" cx="' + size / 2 + '" cy="' + size / 2 + '" r="' + r + '"/>' +
      '<circle class="nx-ring-value" cx="' + size / 2 + '" cy="' + size / 2 + '" r="' + r + '" pathLength="100"/></svg>';
  }

  function StatusDot(p) {
    p = p || {};
    return '<span class="nx-dot' + tintClass(p.tint || 'primary') + (p.pulsing ? ' is-pulsing' : '') + '"></span>';
  }

  function CountdownText(p) {
    p = p || {};
    var seconds = p.to ? (new Date(p.to).getTime() - Date.now()) / 1000 : (p.seconds || 0);
    var style = p.style || 'numeric';
    return '<span class="' + style + ' nx-' + style + tintClass(p.tint) + '" data-countdown="' + Math.round(seconds) + '">' + Format.countdown(seconds) + '</span>';
  }
  /** Starts every countdown under `root`; each ticks once a second. */
  CountdownText.start = function (root) {
    (root || document).querySelectorAll('[data-countdown]').forEach(function (el) {
      if (el.dataset.wired) return;
      el.dataset.wired = '1';
      var end = Date.now() + Number(el.dataset.countdown) * 1000;
      function tick() { el.textContent = Format.countdown((end - Date.now()) / 1000); }
      tick(); setInterval(tick, 1000);
    });
  };

  function SectionHeader(p) {
    p = p || {};
    return '<header class="nx-header">' + (p.symbol ? icon(p.symbol, 10) : '') +
      '<span class="label nx-label nx-trunc">' + esc(p.title) + '</span><span class="nx-spacer"></span>' + (p.trailing || '') + '</header>';
  }

  function ResultRow(p) {
    p = p || {};
    var lead = p.leading ? '<span class="nx-row-thumb">' + p.leading + '</span>'
      : p.thumbnail ? '<span class="nx-row-thumb" style="background-image:url(&quot;' + esc(p.thumbnail) + '&quot;)"></span>'
      : '<span class="nx-row-thumb' + tintClass(p.symbolTint || 'secondary') + '">' + icon(p.symbol || 'doc', 12) + '</span>';
    var title = String(p.title == null ? '' : p.title);
    var head = title.length > 12 ? title.slice(0, -7) : title, tail = title.length > 12 ? title.slice(-7) : '';
    return '<div class="nx-row">' + lead + '<span class="nx-row-text"><span class="body nx-body nx-mid"><span>' + esc(head) + '</span><span>' + esc(tail) + '</span></span>' +
      (p.detail ? '<span class="caption nx-caption nx-trunc">' + esc(p.detail) + '</span>' : '') + '</span><span class="nx-spacer"></span>' +
      (p.trailing ? '<span class="numeric nx-numeric nx-row-trailing' + tintClass(p.trailingTint || 'secondary') + '">' + esc(p.trailing) + '</span>' : '') + '</div>';
  }

  function EmptyState(p) {
    p = p || {};
    return '<div class="nx-empty">' + icon(p.symbol, 18) + '<span class="caption nx-caption">' + esc(p.title) + '</span>' +
      (p.message ? '<span class="caption nx-caption nx-clamp">' + esc(p.message) + '</span>' : '') + '</div>';
  }

  function GlassCard(p) {
    p = p || {};
    return '<section class="nx-card' + (p.highlighted ? ' is-highlighted' : '') + (p.className ? ' ' + p.className : '') + '"' +
      (p.style ? ' style="' + esc(p.style) + '"' : '') + '>' + (p.children || '') + '</section>';
  }

  function GlassButton(p) {
    p = p || {};
    return '<button type="button" class="nx-btn' + (p.prominence === 'accent' ? ' nx-btn--accent' : '') + '">' +
      (p.symbol ? icon(p.symbol, 12) : '') + esc(p.title) + '</button>';
  }

  function GlassIconButton(p) {
    p = p || {};
    var kind = p.kind === 'plain' ? 'plain' : 'glass', size = p.size || (kind === 'glass' ? 28 : 24);
    var glyph = Math.round(size * (kind === 'glass' ? 0.44 : 0.5));
    return '<button type="button" class="nx-icon-btn nx-icon-btn--' + kind + tintClass(p.tint) + '" style="--size:' + size + 'px" aria-label="' +
      esc(p.label) + '" title="' + esc(p.label) + '">' + icon(p.symbol, glyph) + '</button>';
  }

  function RowButton(p) {
    p = p || {};
    return '<button type="button" class="nx-row-btn">' + (p.children || '') + '</button>';
  }

  function LiveActivity(p) {
    p = p || {};
    return '<div class="nx-wing nx-wing--leading" data-show="activity">' + (p.leading || '') + '</div>' +
      '<div class="nx-wing nx-wing--trailing" data-show="activity">' + (p.trailing || '') + '</div>';
  }

  function NotchSurface(p) {
    p = p || {};
    return '<div class="nx-notch" data-state="' + esc(p.state || 'closed') + '" data-page="' + esc(p.page || 'home') + '">' +
      '<i class="nx-notch-shadow"></i><div class="nx-notch-surface"></div>' + (p.children || '') + '</div>';
  }
  NotchSurface.states = ['closed', 'hover', 'activity', 'drop', 'expanded'];
  /** Moves a rendered notch to another state; the CSS springs do the rest. */
  NotchSurface.setState = function (el, state) {
    if (NotchSurface.states.indexOf(state) >= 0) el.dataset.state = state;
  };

  window.Notcher = {
    icon: icon, Format: Format,
    NotchSurface: NotchSurface, LiveActivity: LiveActivity, GlassCard: GlassCard,
    GlassButton: GlassButton, GlassIconButton: GlassIconButton, RowButton: RowButton,
    SectionHeader: SectionHeader, ResultRow: ResultRow, EmptyState: EmptyState,
    ProgressRing: ProgressRing, StatusDot: StatusDot, EqualizerBars: EqualizerBars, CountdownText: CountdownText
  };
})();
