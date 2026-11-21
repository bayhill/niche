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
