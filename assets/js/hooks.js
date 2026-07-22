// Colloq — LiveView Hooks
// EmojiPicker, PostImpression, AutoScroll, PushSubscription,
// VoiceRoom, TiptapEditor

let Hooks = {};

// Shared by the composer toolbar's blockquote button and the selection-quote
// pill in PostBody. Inner paths only — callers supply the <svg> wrapper.
const QUOTE_ICON =
  '<path d="M3 21c3 0 7-1 7-8V5c0-1.25-.75-2-2-2H4c-1.25 0-2 .75-2 2v6c0 1.25.75 2 2 2h1c0 1-1 2-2 2z"/>' +
  '<path d="M15 21c3 0 7-1 7-8V5c0-1.25-.75-2-2-2h-4c-1.25 0-2 .75-2 2v6c0 1.25.75 2 2 2h1c0 1-1 2-2 2z"/>';

// =========================================================================
// RowNav — makes a whole topic row clickable without wrapping it in an <a>
// (so tag/category links inside can be their own anchors). A click anywhere
// that isn't itself a link/button triggers the row's primary (title) link.
// =========================================================================
Hooks.RowNav = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      // Real links/buttons (title, tags, category) handle their own clicks.
      if (e.target.closest("a, button")) return;
      const primary = this.el.querySelector("[data-row-primary]");
      if (primary) primary.click();
    });
  }
};

// =========================================================================
// InfiniteScroll — pushes "load-more" when the sentinel nears the viewport.
// The server gates how many times this auto-fires (then swaps the sentinel
// for a button), so this hook just reports "I'm visible" — one in-flight
// request at a time via the reply callback.
// =========================================================================
Hooks.InfiniteScroll = {
  mounted() {
    this.loading = false;
    this.observer = new IntersectionObserver(
      (entries) => {
        if (this.loading) return;
        if (entries.some((e) => e.isIntersecting)) {
          this.loading = true;
          this.pushEvent("load-more", {}, () => {
            this.loading = false;
          });
        }
      },
      { rootMargin: "400px" }
    );
    this.observer.observe(this.el);
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
  }
};

// =========================================================================
// EMOJIS — shared list used by every emoji picker (title, chat, tiptap).
// To add more: just drop the emoji characters into this array. It's the
// single source of truth, so all pickers update at once.
// =========================================================================
const EMOJIS = [
  // Smileys & emotion
  "😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩","😘","😗","😚","😙",
  "😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🤨","😐","😑","😶","😏","😒","🙄","😬","🤥","😌",
  "😔","😪","🤤","😴","😷","🤒","🤕","🤢","🤮","🤧","🥵","🥶","🥴","😵","🤯","🤠","🥳","😎","🤓","🧐",
  "😕","😟","🙁","😮","😯","😲","😳","🥺","😦","😧","😨","😰","😥","😢","😭","😱","😖","😣","😞","😓",
  "😩","😫","🥱","😤","😡","😠","🤬","😈","👿","💀","💩","🤡","👻","👽","🤖",
  // Gestures & people
  "👍","👎","👊","✊","🤛","🤜","👏","🙌","👐","🤝","🙏","✌️","🤞","🤟","🤘","👌","🤏","👈","👉","👆",
  "👇","☝️","✋","🤚","🖐️","🖖","👋","🤙","💪","🦵","🦶","👀","👁️","🧠","👂","👃","👅","👄","💋","🫂",
  // Hearts & symbols
  "💙","🤍","🧡","💛","💚","💜","🖤","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝","💯","💢",
  "💥","💫","💦","💨","🕳️","💬","💭","🔥","⭐","🌟","✨","⚡","☀️","🌈","🎵","🎶",
  // Football & sports
  "⚽","🏀","🏈","⚾","🎾","🏐","🏉","🥅","🏆","🥇","🥈","🥉","🏅","🎖️","🎯","🏟️","👟","🧤","📣","🎽",
  // Argentina / Racing colours
  "🇦🇷","🔵","⚪","🔷","🤍","💙","🏁","🚩",
  // Celebration & objects
  "🎉","🎊","🥳","🎁","🎈","🍾","🥂","🍻","🍺","🍷","☕","🧉","🍕","🍔","🌭","🍿","📸","🎥","📺","📱",
  "💰","💵","📈","📉","⏰","⏳","✅","❌","❗","❓","💤","👑","🐐","🔝","🆗","🆒",
  // World Cup
  "🏆","🥇","⚽","🎽","📅","🗓️","🎫","🏟️","🌍","🌎","🌏",
  // Flags — CONMEBOL / South America
  "🇦🇷","🇧🇷","🇺🇾","🇨🇱","🇵🇾","🇧🇴","🇵🇪","🇪🇨","🇨🇴","🇻🇪","🇬🇾","🇸🇷",
  // Flags — CONCACAF / North & Central America
  "🇲🇽","🇺🇸","🇨🇦","🇨🇷","🇵🇦","🇭🇳","🇸🇻","🇬🇹","🇯🇲","🇨🇺","🇩🇴","🇭🇹","🇹🇹",
  // Flags — UEFA / Europe
  "🇪🇸","🇮🇹","🇫🇷","🇩🇪","🇬🇧","🏴󠁧󠁢󠁥󠁮󠁧󠁿","🏴󠁧󠁢󠁳󠁣󠁴󠁿","🏴󠁧󠁢󠁷󠁬󠁳󠁿","🇵🇹","🇳🇱","🇧🇪","🇭🇷","🇷🇸","🇨🇭","🇦🇹","🇵🇱","🇸🇪","🇩🇰","🇳🇴","🇮🇪",
  "🇬🇷","🇹🇷","🇺🇦","🇷🇺","🇨🇿","🇸🇰","🇭🇺","🇷🇴","🇧🇬","🇫🇮","🇮🇸","🇷🇸","🇧🇦","🇦🇱","🇲🇪","🇲🇰","🇸🇮","🇱🇺","🇲🇹","🇨🇾","🇻🇦",
  // Flags — CAF / Africa
  "🇲🇦","🇸🇳","🇹🇳","🇩🇿","🇪🇬","🇳🇬","🇬🇭","🇨🇲","🇨🇮","🇿🇦","🇰🇪","🇦🇴","🇲🇱","🇧🇫","🇨🇩","🇪🇹","🇺🇬","🇿🇲","🇿🇼","🇬🇦",
  // Flags — AFC / Asia & Oceania
  "🇯🇵","🇰🇷","🇸🇦","🇮🇷","🇦🇺","🇶🇦","🇦🇪","🇨🇳","🇮🇳","🇮🇩","🇹🇭","🇻🇳","🇵🇭","🇲🇾","🇸🇬","🇮🇶","🇺🇿","🇳🇿","🇰🇵",
  // Flags — other / symbolic
  "🏁","🚩","🏴‍☠️","🏳️","🏳️‍🌈","🇺🇳"
];

// =========================================================================
// LEAGUE_LOGOS — a built-in sticker pack of competition logos, inserted into
// the composer as inline images. Uses Sofascore's unique-tournament image
// endpoint (same source as the team crests already used across the app).
// =========================================================================
const leagueImg = (id) => `https://api.sofascore.com/api/v1/unique-tournament/${id}/image`;

const LEAGUE_LOGOS = {
  name: "⚽ Ligas",
  builtin: true,
  stickers: [
    { url: leagueImg(155), name: "Liga Profesional Argentina", size: 64 },
    { url: leagueImg(17), name: "Premier League", size: 64 },
    { url: leagueImg(8), name: "LaLiga", size: 64 },
    { url: leagueImg(23), name: "Serie A", size: 64 },
    { url: leagueImg(35), name: "Bundesliga", size: 64 },
    { url: leagueImg(34), name: "Ligue 1", size: 64 },
    { url: leagueImg(238), name: "Primeira Liga", size: 64 },
    { url: leagueImg(37), name: "Eredivisie", size: 64 },
    { url: leagueImg(325), name: "Brasileirão", size: 64 },
    { url: leagueImg(7), name: "Champions League", size: 64 },
    { url: leagueImg(679), name: "Europa League", size: 64 },
    { url: leagueImg(384), name: "Copa Libertadores", size: 64 },
    { url: leagueImg(480), name: "Copa Sudamericana", size: 64 },
    { url: leagueImg(16), name: "Copa del Mundo", size: 64 },
    { url: leagueImg(242), name: "MLS", size: 64 }
  ]
};

// =========================================================================
// Theme — swap the theme-* class on <html> (live, without a page reload)
// =========================================================================
function applyTheme(theme) {
  const t = theme || "dark";
  const el = document.documentElement;
  el.className = el.className.replace(/\btheme-\w+\b/g, "").trim();
  el.classList.add(`theme-${t}`);
}

// Persisted theme change from the server (after saving settings).
window.addEventListener("phx:set-theme", (e) => applyTheme(e.detail && e.detail.theme));

// Instant client-side preview when picking a theme in Settings.
Hooks.ThemePreview = {
  mounted() {
    // Reads the event target so this works whether the hook sits on a <select>
    // or on a wrapper around a group of radio inputs.
    this.el.addEventListener("change", (e) => {
      const value = e.target && e.target.value;
      if (value) applyTheme(value);
    });
  }
};

// =========================================================================
// ECharts — dependency-free SVG charts (line / bar / pie) for the dashboard.
// Data attribute format: "label|value,label|value,..."
// =========================================================================
Hooks.ECharts = {
  mounted() { this.render(); },
  updated() { this.render(); },
  render() {
    const el = this.el;
    const type = el.dataset.chartType || "line";
    const data = (el.dataset.chartData || "")
      .split(",")
      .filter(Boolean)
      .map((s) => {
        const i = s.lastIndexOf("|");
        return { label: s.slice(0, i), value: parseFloat(s.slice(i + 1)) || 0 };
      });

    const css = getComputedStyle(document.documentElement);
    const accent = (css.getPropertyValue("--accent") || "#3b82f6").trim();
    const muted = (css.getPropertyValue("--text-muted") || "#6b7280").trim();
    const border = (css.getPropertyValue("--border") || "#1a2035").trim();
    const W = el.clientWidth || 480;
    const H = el.clientHeight || 240;

    if (!data.length) {
      el.innerHTML = `<div class="flex items-center justify-center h-full text-sm" style="color:${muted}">Sin datos todavía</div>`;
      return;
    }

    const svgEl = (name, attrs, children) => {
      const e = `<${name} ${Object.entries(attrs).map(([k, v]) => `${k}="${v}"`).join(" ")}>`;
      return children != null ? `${e}${children}</${name}>` : `<${name} ${Object.entries(attrs).map(([k, v]) => `${k}="${v}"`).join(" ")}/>`;
    };

    let inner = "";
    const pad = { l: 32, r: 12, t: 12, b: 22 };
    const iw = W - pad.l - pad.r;
    const ih = H - pad.t - pad.b;
    const max = Math.max(1, ...data.map((d) => d.value));

    if (type === "pie") {
      const total = data.reduce((a, d) => a + d.value, 0) || 1;
      const cx = W / 2, cy = H / 2, r = Math.min(W, H) / 2 - 20;
      const palette = [accent, "#22c55e", "#eab308", "#ef4444", "#a855f7", "#06b6d4", "#f97316", "#ec4899", "#84cc16", "#64748b"];
      let a0 = -Math.PI / 2;
      data.forEach((d, i) => {
        const frac = d.value / total;
        const a1 = a0 + frac * Math.PI * 2;
        const large = frac > 0.5 ? 1 : 0;
        const x0 = cx + r * Math.cos(a0), y0 = cy + r * Math.sin(a0);
        const x1 = cx + r * Math.cos(a1), y1 = cy + r * Math.sin(a1);
        const path = `M${cx},${cy} L${x0.toFixed(1)},${y0.toFixed(1)} A${r},${r} 0 ${large} 1 ${x1.toFixed(1)},${y1.toFixed(1)} Z`;
        inner += `<path d="${path}" fill="${palette[i % palette.length]}" opacity="0.9"><title>${d.label}: ${d.value}</title></path>`;
        const mid = (a0 + a1) / 2;
        if (frac > 0.06) {
          const lx = cx + (r * 0.62) * Math.cos(mid), ly = cy + (r * 0.62) * Math.sin(mid);
          inner += `<text x="${lx.toFixed(1)}" y="${ly.toFixed(1)}" font-size="12" fill="#fff" text-anchor="middle" dominant-baseline="middle">${d.label}</text>`;
        }
        a0 = a1;
      });
    } else if (type === "bar") {
      const n = data.length;
      const bw = iw / n * 0.7;
      const gap = iw / n;
      inner += `<line x1="${pad.l}" y1="${pad.t + ih}" x2="${pad.l + iw}" y2="${pad.t + ih}" stroke="${border}"/>`;
      data.forEach((d, i) => {
        const h = (d.value / max) * ih;
        const x = pad.l + gap * i + (gap - bw) / 2;
        const y = pad.t + ih - h;
        inner += `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${h.toFixed(1)}" rx="2" fill="${accent}"><title>${d.label}: ${d.value}</title></rect>`;
      });
      inner += this.axisLabels(data, pad, iw, ih, muted, "bar");
    } else if (type === "spark") {
      // Minimal sparkline for KPI tiles — no axis, no labels, fills the box.
      const n = data.length;
      const step = n > 1 ? W / (n - 1) : 0;
      const sMax = Math.max(1, ...data.map((d) => d.value));
      const sp = 2;
      const pts = data.map((d, i) => [step * i, sp + (H - 2 * sp) - (d.value / sMax) * (H - 2 * sp)]);
      const poly = pts.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
      if (n > 1) {
        inner += `<path d="M0,${H} L${poly.replace(/ /g, " L")} L${W},${H} Z" fill="${accent}" opacity="0.15"/>`;
        inner += `<polyline points="${poly}" fill="none" stroke="${accent}" stroke-width="1.5"/>`;
      } else if (n === 1) {
        inner += `<line x1="0" y1="${(H / 2).toFixed(1)}" x2="${W}" y2="${(H / 2).toFixed(1)}" stroke="${accent}" stroke-width="1.5"/>`;
      }
    } else if (type === "hbar") {
      // Horizontal bars — the right shape for ranked categories with text
      // labels: name on the left, bar growing right, value at the end. No
      // x-axis label crowding or truncation.
      const n = data.length;
      const rowH = ih / n;
      const barH = Math.min(rowH * 0.62, 20);
      const labelW = 96;
      const valW = 28;
      const bx = pad.l + labelW;
      const bwMax = Math.max(10, W - bx - valW);
      data.forEach((d, i) => {
        const cy = pad.t + rowH * i + rowH / 2;
        const w = (d.value / max) * bwMax;
        const name = d.label.length > 15 ? d.label.slice(0, 14) + "…" : d.label;
        inner += `<text x="${(pad.l - 20).toFixed(1)}" y="${cy.toFixed(1)}" font-size="11" fill="${muted}" dominant-baseline="middle"><title>${d.label}</title>${name}</text>`;
        inner += `<rect x="${bx.toFixed(1)}" y="${(cy - barH / 2).toFixed(1)}" width="${w.toFixed(1)}" height="${barH.toFixed(1)}" rx="2" fill="${accent}"><title>${d.label}: ${d.value}</title></rect>`;
        inner += `<text x="${(bx + w + 5).toFixed(1)}" y="${cy.toFixed(1)}" font-size="11" fill="${muted}" dominant-baseline="middle">${d.value}</text>`;
      });
    } else {
      // line
      const n = data.length;
      const step = n > 1 ? iw / (n - 1) : 0;
      inner += `<line x1="${pad.l}" y1="${pad.t + ih}" x2="${pad.l + iw}" y2="${pad.t + ih}" stroke="${border}"/>`;
      const pts = data.map((d, i) => {
        const x = pad.l + step * i;
        const y = pad.t + ih - (d.value / max) * ih;
        return [x, y];
      });
      const poly = pts.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
      const areaPath = `M${pad.l},${pad.t + ih} L${poly.replace(/ /g, " L")} L${pad.l + iw},${pad.t + ih} Z`;
      inner += `<path d="${areaPath}" fill="${accent}" opacity="0.12"/>`;
      inner += `<polyline points="${poly}" fill="none" stroke="${accent}" stroke-width="2"/>`;
      pts.forEach((p, i) => {
        inner += `<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="2.5" fill="${accent}"><title>${data[i].label}: ${data[i].value}</title></circle>`;
      });
      inner += this.axisLabels(data, pad, iw, ih, muted, "line");
    }

    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="100%" height="100%" style="overflow:visible">${inner}</svg>`;
  },
  axisLabels(data, pad, iw, ih, muted, type) {
    const n = data.length;
    // Bars carry their own label; for a dense line (30 days) thin to ~6.
    const every = type === "bar" ? 1 : Math.max(1, Math.ceil(n / 6));
    const isDate = (s) => /^\d{4}-\d{2}-\d{2}/.test(s);
    let out = "";
    data.forEach((d, i) => {
      if (i % every !== 0 && i !== n - 1) return;
      // Align under the bar centre for bars; along the polyline for lines.
      const x =
        type === "bar"
          ? pad.l + (iw / n) * i + iw / n / 2
          : n > 1
            ? pad.l + (iw / (n - 1)) * i
            : pad.l + iw / 2;
      // Dates → drop the year (MM-DD); other labels → truncate if long.
      let label = d.label;
      if (isDate(label)) label = label.slice(5);
      else if (label.length > 9) label = label.slice(0, 8) + "…";
      out += `<text x="${x.toFixed(1)}" y="${pad.t + ih + 15}" font-size="10" fill="${muted}" text-anchor="middle"><title>${d.label}</title>${label}</text>`;
    });
    return out;
  }
};

// =========================================================================
// TopicTimeline — Discourse-style scroll scrubber on the right of a topic
// =========================================================================
Hooks.TopicTimeline = {
  mounted() {
    const el = this.el;
    const total = () => Math.max(1, parseInt(el.dataset.total || "1", 10));
    const track = el.querySelector("[data-tl-track]");
    const progress = el.querySelector("[data-tl-progress]");
    const thumb = el.querySelector("[data-tl-thumb]");
    const current = el.querySelector("[data-tl-current]");
    const dateEl = el.querySelector("[data-tl-date]");
    const topBtn = el.querySelector("[data-tl-top]");
    const botBtn = el.querySelector("[data-tl-bottom]");

    // Interpolate the date at the current scroll position between the topic's
    // first and last post (Discourse-style "date at the thumb").
    const ES_MONTHS = ["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"];
    const startMs = Date.parse(el.dataset.tlStart || "") || null;
    const endMs = Date.parse(el.dataset.tlEnd || "") || startMs;

    // Format in the site's display timezone, not the viewer's. getDate() reads
    // local time, so a reader outside Argentina — or inside it, for a post made
    // late at night — saw a thumb date a day off from the labels above and
    // below it, which the server renders in the site zone.
    const tz = el.dataset.tlTz || "UTC";
    const dayFmt = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit"
    });
    const dateAt = (frac) => {
      if (!startMs) return "";
      const d = new Date(startMs + (endMs - startMs) * frac);
      // en-CA is stable YYYY-MM-DD, so this parse doesn't depend on the locale.
      const [, month, day] = dayFmt.format(d).split("-");
      return `${parseInt(day, 10)} ${ES_MONTHS[parseInt(month, 10) - 1]}`;
    };

    const docHeight = () => document.documentElement.scrollHeight - window.innerHeight;

    // Anchor the scrubber just to the right of the actual post column (which is
    // NOT viewport-centered because of the left sidebar). Hide it if there
    // isn't enough room so it never overlaps the posts.
    const positionX = () => {
      const content = document.getElementById("topic-content");
      if (!content) return;
      const right = content.getBoundingClientRect().right;
      const gap = 16;
      const elWidth = el.offsetWidth || 40;
      if (right + gap + elWidth > window.innerWidth) {
        el.style.visibility = "hidden";
      } else {
        el.style.left = `${Math.round(right + gap)}px`;
        el.style.visibility = "visible";
      }
    };

    const update = () => {
      const max = docHeight();
      const frac = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
      const pct = (frac * 100).toFixed(1);
      progress.style.height = `${pct}%`;
      thumb.style.top = `${pct}%`;
      const n = total();
      const pos = Math.max(1, Math.min(n, Math.round(frac * n) || 1));
      current.textContent = `${pos} / ${n}`;
      if (dateEl) dateEl.textContent = dateAt(frac);
    };

    this._onScroll = () => requestAnimationFrame(update);
    this._onResize = () => {
      positionX();
      update();
    };
    window.addEventListener("scroll", this._onScroll, { passive: true });
    window.addEventListener("resize", this._onResize);

    const scrollToFrac = (frac) => {
      window.scrollTo({ top: docHeight() * Math.min(1, Math.max(0, frac)) });
    };
    const fracFromY = (y) => {
      const r = track.getBoundingClientRect();
      return (y - r.top) / r.height;
    };

    const startDrag = (e) => {
      e.preventDefault();
      scrollToFrac(fracFromY(e.clientY));
      const move = (ev) => scrollToFrac(fracFromY(ev.clientY));
      const up = () => {
        document.removeEventListener("mousemove", move);
        document.removeEventListener("mouseup", up);
      };
      document.addEventListener("mousemove", move);
      document.addEventListener("mouseup", up);
    };
    track.addEventListener("mousedown", startDrag);
    thumb.addEventListener("mousedown", startDrag);

    topBtn.addEventListener("click", () => window.scrollTo({ top: 0, behavior: "smooth" }));
    botBtn.addEventListener("click", () =>
      window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "smooth" })
    );

    positionX();
    update();
  },
  updated() {
    // A new post may have changed the page height / count / layout width.
    if (this._onResize) this._onResize();
  },
  destroyed() {
    window.removeEventListener("scroll", this._onScroll);
    window.removeEventListener("resize", this._onResize);
  }
};

// =========================================================================
// ChatComposer — DM composer: Enter-to-send, emoji picker, file attachments
// =========================================================================
Hooks.ChatComposer = {
  mounted() {
    const form = this.el;
    const textarea = form.querySelector("#chat-input");
    const emojiBtn = form.querySelector("#chat-emoji-btn");
    const fileBtn = form.querySelector("#chat-file-btn");
    const fileInput = form.querySelector("#chat-file");

    // --- Enter to send (Shift+Enter = newline) ---
    textarea.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" && !ev.shiftKey) {
        ev.preventDefault();
        form.requestSubmit();
      }
    });

    // --- Insert text at the caret + notify LiveView (phx-change) ---
    const insertAtCaret = (text) => {
      // Focus first so the selection is valid even on the very first pick
      // (before this, the textarea may never have been focused).
      textarea.focus();
      const start = textarea.selectionStart ?? textarea.value.length;
      const end = textarea.selectionEnd ?? textarea.value.length;
      if (typeof textarea.setRangeText === "function") {
        textarea.setRangeText(text, start, end, "end");
      } else {
        textarea.value = textarea.value.slice(0, start) + text + textarea.value.slice(end);
        textarea.selectionStart = textarea.selectionEnd = start + text.length;
      }
      // Notify LiveView so @message_body stays in sync (survives re-renders).
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
    };

    // --- Emoji picker ---
    const emojis = EMOJIS;
    // The popup lives on <body> (not inside the form) so LiveView's morphdom
    // never reverts/wipes it when the form re-renders on phx-change.
    const pop = document.createElement("div");
    pop.className =
      "hidden fixed z-[80] p-2 rounded-lg bg-surface border border-border shadow-lg grid grid-cols-6 gap-1 w-64 max-h-64 overflow-y-auto";
    emojis.forEach((e) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = e;
      b.className = "text-2xl leading-none p-1 rounded hover:bg-surface-alt";
      // mousedown + preventDefault keeps focus/selection on the textarea, so
      // the very first pick inserts correctly instead of losing the caret.
      b.addEventListener("mousedown", (ev) => {
        ev.preventDefault();
        insertAtCaret(e);
        pop.classList.add("hidden");
      });
      pop.appendChild(b);
    });
    document.body.appendChild(pop);
    this._emojiPop = pop;

    const positionPop = () => {
      const r = emojiBtn.getBoundingClientRect();
      pop.style.left = `${Math.round(Math.min(r.left, window.innerWidth - 268))}px`;
      // Prefer showing above the button; the popup is ~256px tall (max-h-64).
      const top = r.top - 8 - Math.min(pop.offsetHeight || 256, 256);
      pop.style.top = `${Math.round(Math.max(8, top))}px`;
    };

    emojiBtn.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      const hidden = pop.classList.contains("hidden");
      pop.classList.remove("hidden");
      positionPop();
      if (!hidden) pop.classList.add("hidden");
    });
    document.addEventListener("click", (ev) => {
      if (ev.target !== emojiBtn && !emojiBtn.contains(ev.target) && !pop.contains(ev.target)) {
        pop.classList.add("hidden");
      }
    });

    // --- Sticker tray ---
    const stickerBtn = form.querySelector("#chat-sticker-btn");
    if (stickerBtn) {
      const hook = this;
      // Popup lives on <body> so LiveView morphdom never wipes it.
      const tray = document.createElement("div");
      tray.className =
        "hidden fixed z-[80] rounded-xl bg-surface border border-border shadow-lg w-72 max-h-80 flex flex-col overflow-hidden";
      const tabs = document.createElement("div");
      tabs.className = "flex gap-1 p-2 border-b border-border overflow-x-auto flex-shrink-0";
      const grid = document.createElement("div");
      grid.className = "p-2 grid grid-cols-4 gap-1 overflow-y-auto";
      tray.appendChild(tabs);
      tray.appendChild(grid);
      document.body.appendChild(tray);
      this._stickerTray = tray;

      let packs = null;

      const renderPack = (pack) => {
        grid.innerHTML = "";
        pack.stickers.forEach((st) => {
          const b = document.createElement("button");
          b.type = "button";
          b.className = "p-1 rounded-lg hover:bg-surface-alt flex items-center justify-center";
          const img = document.createElement("img");
          img.src = st.url;
          img.alt = "sticker";
          img.loading = "lazy";
          img.className = "w-14 h-14 object-contain";
          b.appendChild(img);
          b.addEventListener("mousedown", (ev) => {
            ev.preventDefault();
            hook.pushEvent("send-sticker", { url: st.url });
            tray.classList.add("hidden");
          });
          grid.appendChild(b);
        });
      };

      const renderTabs = () => {
        tabs.innerHTML = "";
        packs.forEach((pack, i) => {
          const t = document.createElement("button");
          t.type = "button";
          t.textContent = pack.name;
          t.className =
            "px-2.5 py-1 rounded-full text-xs font-medium whitespace-nowrap flex-shrink-0 text-muted hover:text-heading";
          t.addEventListener("mousedown", (ev) => {
            ev.preventDefault();
            tabs.querySelectorAll("button").forEach((x) =>
              x.classList.remove("bg-accent", "text-white")
            );
            t.classList.add("bg-accent", "text-white");
            renderPack(pack);
          });
          tabs.appendChild(t);
          if (i === 0) {
            t.classList.add("bg-accent", "text-white");
            renderPack(pack);
          }
        });
      };

      const positionTray = () => {
        const r = stickerBtn.getBoundingClientRect();
        tray.style.left = `${Math.round(Math.min(r.left, window.innerWidth - 300))}px`;
        const top = r.top - 8 - Math.min(tray.offsetHeight || 320, 320);
        tray.style.top = `${Math.round(Math.max(8, top))}px`;
      };

      const loadStickers = () => {
        if (packs) return Promise.resolve();
        return fetch("/api/stickers")
          .then((r) => r.json())
          .then((data) => {
            packs = (data && data.packs) || [];
            if (!packs.length) {
              grid.innerHTML =
                '<div class="col-span-4 text-center text-sm text-muted py-8">Todavía no hay stickers</div>';
            } else {
              renderTabs();
            }
          })
          .catch(() => {
            grid.innerHTML =
              '<div class="col-span-4 text-center text-sm text-muted py-8">No se pudieron cargar</div>';
          });
      };

      stickerBtn.addEventListener("mousedown", (ev) => {
        ev.preventDefault();
        const wasHidden = tray.classList.contains("hidden");
        if (wasHidden) {
          loadStickers().then(() => {
            tray.classList.remove("hidden");
            positionTray();
          });
        } else {
          tray.classList.add("hidden");
        }
      });
      document.addEventListener("click", (ev) => {
        if (ev.target !== stickerBtn && !stickerBtn.contains(ev.target) && !tray.contains(ev.target)) {
          tray.classList.add("hidden");
        }
      });
    }

    // --- File attachments ---
    fileBtn.addEventListener("click", () => fileInput.click());
    fileInput.addEventListener("change", async () => {
      const file = fileInput.files && fileInput.files[0];
      fileInput.value = "";
      if (!file) return;
      const fd = new FormData();
      fd.append("file", file);
      const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
      fileBtn.disabled = true;
      try {
        const res = await fetch("/api/chat/upload", {
          method: "POST",
          headers: { "x-csrf-token": csrf },
          body: fd
        });
        const data = await res.json();
        if (res.ok && data.url) {
          this.pushEvent("send-file", { url: data.url, name: data.name, type: data.type });
        } else {
          alert(data.error || "No se pudo subir el archivo");
        }
      } catch (e) {
        alert("Error al subir el archivo");
      } finally {
        fileBtn.disabled = false;
      }
    });
  },
  destroyed() {
    if (this._emojiPop) {
      this._emojiPop.remove();
      this._emojiPop = null;
    }
    if (this._stickerTray) {
      this._stickerTray.remove();
      this._stickerTray = null;
    }
  }
};

// =========================================================================
// TagInput — Discourse-style tag picker: chips + autocomplete, backed by a
// hidden comma-separated input so the existing form handler is unchanged.
// =========================================================================
Hooks.TagInput = {
  mounted() {
    const inputName = this.el.dataset.name || "tags";
    // When false, the user may only apply existing tags, not create new ones.
    const canCreate = this.el.dataset.canCreate !== "false";
    // Max tags allowed on the topic. Empty/absent = unlimited (staff, TL4);
    // otherwise a real cap, including 0 for levels that may not tag at all.
    // Don't collapse this to `parseInt(...) || Infinity` — 0 is falsy, so a
    // zero cap would silently become unlimited.
    const parsedMax = parseInt(this.el.dataset.maxTags ?? "", 10);
    const maxTags = Number.isNaN(parsedMax) ? Infinity : parsedMax;
    const initial = (this.el.dataset.initial || "")
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);

    this.tags = [];
    let activeIndex = -1;
    let suggestions = [];
    let seq = 0;

    // --- DOM scaffolding ---
    this.el.innerHTML = "";
    const hidden = document.createElement("input");
    hidden.type = "hidden";
    hidden.name = inputName;
    this.el.appendChild(hidden);

    const box = document.createElement("div");
    box.className =
      "flex flex-wrap items-center gap-1.5 rounded-lg border border-border bg-surface px-2 py-1.5 focus-within:ring-2 focus-within:ring-accent focus-within:border-accent";
    const field = document.createElement("input");
    field.type = "text";
    field.autocomplete = "off";
    field.placeholder = "Añadir etiqueta…";
    field.className = "flex-1 min-w-[120px] bg-transparent text-sm text-body py-1 focus:outline-none";

    const wrap = document.createElement("div");
    wrap.className = "relative";
    const dropdown = document.createElement("div");
    dropdown.className =
      "hidden absolute z-[70] left-0 right-0 mt-1 max-h-56 overflow-y-auto rounded-lg border border-border bg-surface shadow-lg py-1";
    wrap.appendChild(box);
    wrap.appendChild(dropdown);
    this.el.appendChild(wrap);

    const normalize = (t) => t.trim().replace(/,/g, "").slice(0, 40);

    const syncHidden = () => { hidden.value = this.tags.join(","); };

    const renderChips = () => {
      box.querySelectorAll("[data-chip]").forEach((c) => c.remove());
      this.tags.forEach((tag) => {
        const chip = document.createElement("span");
        chip.dataset.chip = tag;
        chip.className =
          "inline-flex items-center gap-1 rounded-full bg-accent-soft text-accent text-xs font-medium pl-2 pr-1 py-0.5";
        chip.innerHTML = `#${tag}`;
        const x = document.createElement("button");
        x.type = "button";
        x.className = "hover:text-heading";
        x.textContent = "✕";
        x.addEventListener("click", () => removeTag(tag));
        chip.appendChild(x);
        box.insertBefore(chip, field);
      });
      // At the cap: hide the input so no more can be typed. Removing a chip
      // brings it back.
      field.style.display = this.tags.length >= maxTags ? "none" : "";
    };

    const addTag = (raw, force = false) => {
      const tag = normalize(raw);
      if (!tag) return;
      // Enforce the per-topic tag cap (server also enforces it).
      if (!force && this.tags.length >= maxTags) {
        field.value = "";
        hideDropdown();
        return;
      }
      // Users below the create threshold can only add tags that already exist.
      // `force` bypasses this for prefilling a topic's current tags (which are
      // existing by definition).
      if (!force && !canCreate && !suggestions.some((s) => s.name.toLowerCase() === tag.toLowerCase())) {
        field.value = "";
        hideDropdown();
        return;
      }
      if (!this.tags.some((t) => t.toLowerCase() === tag.toLowerCase())) {
        this.tags.push(tag);
        renderChips();
        syncHidden();
      }
      field.value = "";
      hideDropdown();
    };

    const removeTag = (tag) => {
      this.tags = this.tags.filter((t) => t !== tag);
      renderChips();
      syncHidden();
    };

    const hideDropdown = () => {
      dropdown.classList.add("hidden");
      activeIndex = -1;
      suggestions = [];
    };

    const renderDropdown = () => {
      dropdown.innerHTML = "";
      const q = field.value.trim();
      const items = [];

      suggestions
        .filter((s) => !this.tags.some((t) => t.toLowerCase() === s.name.toLowerCase()))
        .forEach((s) => items.push({ name: s.name, count: s.count, isNew: false }));

      // Offer to create the typed tag if it isn't an exact existing match —
      // only for users allowed to create new tags.
      if (canCreate && q && !suggestions.some((s) => s.name.toLowerCase() === q.toLowerCase())) {
        items.push({ name: normalize(q), count: null, isNew: true });
      }

      if (!items.length) { hideDropdown(); return; }
      if (activeIndex >= items.length) activeIndex = items.length - 1;

      items.forEach((it, i) => {
        const b = document.createElement("button");
        b.type = "button";
        b.className =
          "flex items-center justify-between gap-2 w-full text-left px-3 py-1.5 text-sm " +
          (i === activeIndex ? "bg-surface-alt text-heading" : "text-body hover:bg-surface-alt");
        const label = it.isNew
          ? `<span class="text-muted">Crear</span> #${it.name}`
          : `#${it.name}`;
        const right = it.count != null ? `<span class="text-xs text-muted">${it.count}</span>` : "";
        b.innerHTML = `<span class="truncate">${label}</span>${right}`;
        b.addEventListener("mousedown", (ev) => {
          ev.preventDefault();
          addTag(it.name);
        });
        dropdown.appendChild(b);
      });
      this._items = items;
      dropdown.classList.remove("hidden");
    };

    const fetchSuggestions = () => {
      const q = field.value.trim();
      const mySeq = ++seq;
      fetch(`/api/tags/search?q=${encodeURIComponent(q)}`)
        .then((r) => r.json())
        .then((data) => {
          if (mySeq !== seq) return;
          suggestions = (data && data.tags) || [];
          activeIndex = -1;
          renderDropdown();
        })
        .catch(() => hideDropdown());
    };

    field.addEventListener("input", fetchSuggestions);
    field.addEventListener("focus", fetchSuggestions);
    field.addEventListener("blur", () => setTimeout(hideDropdown, 120));

    field.addEventListener("keydown", (ev) => {
      const open = !dropdown.classList.contains("hidden");
      const items = this._items || [];
      if (ev.key === "Enter" || ev.key === ",") {
        ev.preventDefault();
        if (open && activeIndex >= 0 && items[activeIndex]) addTag(items[activeIndex].name);
        else if (field.value.trim()) addTag(field.value);
      } else if (ev.key === "Backspace" && !field.value && this.tags.length) {
        removeTag(this.tags[this.tags.length - 1]);
      } else if (ev.key === "ArrowDown" && open) {
        ev.preventDefault();
        activeIndex = (activeIndex + 1) % items.length;
        renderDropdown();
      } else if (ev.key === "ArrowUp" && open) {
        ev.preventDefault();
        activeIndex = (activeIndex - 1 + items.length) % items.length;
        renderDropdown();
      } else if (ev.key === "Escape") {
        hideDropdown();
      }
    });

    box.addEventListener("click", () => field.focus());
    box.appendChild(field);

    // Prefill from initial value (force: existing tags always shown).
    initial.forEach((t) => addTag(t, true));
    syncHidden();
  }
};

// =========================================================================
// FlashAutoHide — auto-dismiss toast flash messages after a delay
// =========================================================================
Hooks.FlashAutoHide = {
  mounted() {
    this.schedule();
  },
  updated() {
    // A new flash re-rendered into the same element: restart the timer.
    this.schedule();
  },
  schedule() {
    clearTimeout(this.timer);
    const ms = parseInt(this.el.dataset.autoHide || "10000", 10);
    this.timer = setTimeout(() => {
      this.el.style.transition = "opacity 300ms ease";
      this.el.style.opacity = "0";
      setTimeout(() => {
        // Trigger the flash's own dismiss (pushes lv:clear-flash to the server).
        const btn = this.el.querySelector("button");
        if (btn) btn.click();
        else this.el.style.display = "none";
      }, 300);
    }, ms);
  },
  destroyed() {
    clearTimeout(this.timer);
  }
};

// =========================================================================
// TwitterEmbed — renders X/Twitter blockquotes into full embeds
// =========================================================================
Hooks.TwitterEmbed = {
  mounted() {
    this.render();
  },
  render() {
    if (window.twttr && window.twttr.widgets) {
      window.twttr.widgets.load(this.el);
      return;
    }
    if (!document.getElementById("twitter-wjs")) {
      const s = document.createElement("script");
      s.id = "twitter-wjs";
      s.src = "https://platform.twitter.com/widgets.js";
      s.async = true;
      s.charset = "utf-8";
      s.onload = () => {
        if (window.twttr && window.twttr.widgets) window.twttr.widgets.load(this.el);
      };
      document.head.appendChild(s);
    } else {
      // Script is still loading — retry shortly.
      setTimeout(() => this.render(), 400);
    }
  }
};

// =========================================================================
// EmojiPicker — Selector de emoji con sprites WebP estilo Noto
// =========================================================================
Hooks.EmojiPicker = {
  mounted() {
    this.pickerVisible = false;
    this.emojiCategories = this.el.dataset.emojiCategories
      ? JSON.parse(this.el.dataset.emojiCategories)
      : [
          { name: "Reacciones", emojis: ["👍", "💙", "😂", "😮", "😢", "😡"] },
          { name: "Fútbol", emojis: ["⚽", "🏆", "🔵", "⚪", "💙", "🤍"] },
          { name: "Gestos", emojis: ["👏", "🙌", "🔥", "💯", "🤝", "🎉"] }
        ];
    this.renderPicker();
    document.addEventListener("click", this.handleOutsideClick.bind(this));
  },

  destroyed() {
    document.removeEventListener("click", this.handleOutsideClick.bind(this));
    this.removePicker();
  },

  renderPicker() {
    let picker = document.createElement("div");
    picker.className = "emoji-picker-dropdown";
    picker.style.cssText = `
      position: absolute; z-index: 100; background: #1e293b;
      border: 1px solid #334155; border-radius: 12px;
      padding: 12px; box-shadow: 0 10px 40px rgba(0,0,0,0.5);
      min-width: 300px; display: none;
    `;

    this.emojiCategories.forEach((cat) => {
      let section = document.createElement("div");
      section.style.marginBottom = "8px";

      let label = document.createElement("div");
      label.textContent = cat.name;
      label.style.cssText = "font-size: 11px; color: #94a3b8; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.05em;";
      section.appendChild(label);

      let grid = document.createElement("div");
      grid.style.cssText = "display: grid; grid-template-columns: repeat(6, 1fr); gap: 4px;";

      cat.emojis.forEach((emoji) => {
        let btn = document.createElement("button");
        btn.textContent = emoji;
        btn.style.cssText = `
          font-size: 28px; background: transparent; border: none;
          cursor: pointer; padding: 4px; border-radius: 8px;
          transition: background 0.15s; line-height: 1;
        `;
        btn.onmouseenter = () => (btn.style.background = "#334155");
        btn.onmouseleave = () => (btn.style.background = "transparent");
        btn.onclick = (e) => {
          e.stopPropagation();
          this.pushEvent("emoji-selected", { emoji });
          this.hidePicker();
        };
        grid.appendChild(btn);
      });

      section.appendChild(grid);
      picker.appendChild(section);
    });

    this.el.appendChild(picker);
    this.pickerEl = picker;

    this.el.addEventListener("mouseenter", () => this.showPicker());
    this.el.addEventListener("mouseleave", (e) => {
      if (!this.pickerEl.contains(e.relatedTarget)) this.hidePicker();
    });
    this.pickerEl.addEventListener("mouseleave", (e) => {
      if (!this.el.contains(e.relatedTarget)) this.hidePicker();
    });
  },

  showPicker() {
    if (this.pickerEl) this.pickerEl.style.display = "block";
  },

  hidePicker() {
    if (this.pickerEl) this.pickerEl.style.display = "none";
  },

  handleOutsideClick(e) {
    if (this.pickerEl && !this.el.contains(e.target)) {
      this.hidePicker();
    }
  },

  removePicker() {
    if (this.pickerEl) this.pickerEl.remove();
  }
};

// =========================================================================
// EmojiInsert — emoji button that inserts into a target <input>/<textarea>
// at the caret, fully client-side. data-target = id of the field.
// =========================================================================
Hooks.EmojiInsert = {
  mounted() {
    const btn = this.el;
    const targetId = btn.dataset.target;

    const emojis = EMOJIS;

    const pop = document.createElement("div");
    pop.className =
      "hidden fixed z-[80] p-2 rounded-lg bg-surface border border-border shadow-lg grid grid-cols-6 gap-1 w-64 max-h-64 overflow-y-auto";
    emojis.forEach((e) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = e;
      b.className = "text-2xl leading-none p-1 rounded hover:bg-surface-alt";
      b.addEventListener("mousedown", (ev) => {
        ev.preventDefault();
        this.insert(targetId, e);
        pop.classList.add("hidden");
      });
      pop.appendChild(b);
    });
    document.body.appendChild(pop);
    this._pop = pop;

    const position = () => {
      const r = btn.getBoundingClientRect();
      pop.style.left = `${Math.round(Math.min(r.left, window.innerWidth - 268))}px`;
      const below = r.bottom + 6;
      pop.style.top = `${Math.round(Math.min(below, window.innerHeight - 264))}px`;
    };

    btn.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      const hidden = pop.classList.contains("hidden");
      pop.classList.remove("hidden");
      position();
      if (!hidden) pop.classList.add("hidden");
    });

    this._outside = (ev) => {
      if (ev.target !== btn && !btn.contains(ev.target) && !pop.contains(ev.target)) {
        pop.classList.add("hidden");
      }
    };
    document.addEventListener("click", this._outside);
  },

  insert(targetId, text) {
    const field = document.getElementById(targetId);
    if (!field) return;
    field.focus();
    const start = field.selectionStart ?? field.value.length;
    const end = field.selectionEnd ?? field.value.length;
    if (typeof field.setRangeText === "function") {
      field.setRangeText(text, start, end, "end");
    } else {
      field.value = field.value.slice(0, start) + text + field.value.slice(end);
      field.selectionStart = field.selectionEnd = start + text.length;
    }
    field.dispatchEvent(new Event("input", { bubbles: true }));
  },

  destroyed() {
    if (this._pop) this._pop.remove();
    document.removeEventListener("click", this._outside);
  }
};

// =========================================================================
// PostImpression — Contador de vistas por IntersectionObserver
// =========================================================================
Hooks.PostImpression = {
  mounted() {
    const postId = this.el.dataset.postId;
    if (!postId) return;

    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        this.pushEvent("view-post", { id: postId });
        observer.unobserve(this.el);
      }
    }, { threshold: 0.5 });

    observer.observe(this.el);
  }
};

// =========================================================================
// AutoScroll — Modo live de día de partido
// =========================================================================
Hooks.AutoScroll = {
  mounted() {
    // Scroll target: the element itself if it's a scroll pane (chat), else the
    // window (forum topic page, which scrolls the whole page).
    this.scroller = this.pickScroller();

    // A URL fragment is an explicit request for one specific post — a search
    // result, a shared permalink, a profile activity link. It outranks
    // "continue where you left off", which would otherwise bounce the reader to
    // the unread divider instead of the post they clicked. Decided here because
    // browsers never send the fragment to the server.
    //
    // _anchorTo (not a bare scrollIntoView) so the target stays put while
    // images and embeds above it finish loading and shift the page.
    const hashId = window.location.hash ? window.location.hash.slice(1) : "";
    const hashEl = hashId ? document.getElementById(hashId) : null;
    if (hashEl) {
      this.el.dataset.following = "false";
      this._anchorTo(hashEl);
      this._setupObservers();
      return;
    }

    // "Read from where I left off": if the server marked a first-unread post,
    // land on that divider so the reader continues into the new posts. Handled
    // before the top/bottom logic and takes priority over the title link.
    const anchorId = this.el.dataset.scrollAnchor;
    if (anchorId) {
      const target = document.getElementById(anchorId);
      if (target) {
        this.el.dataset.following = "false";
        this._anchorTo(target);
        this._setupObservers();
        return;
      }
    }

    // Open at the latest message unless told to stay at the top (a forum topic
    // opened via its title stays on the first post; opened via its activity
    // time jumps to the newest). Chat has no flag → defaults to the bottom.
    const stayTop = this.el.dataset.initial === "top";
    this.el.dataset.following = stayTop ? "false" : "true";
    this._setupObservers();
    if (!stayTop) this._settleToBottom();
  },

  // Hold the bottom while late layout settles.
  //
  // A single jump() at mount scrolls to the bottom *of the page as it is right
  // then* — before images, embeds and emoji have loaded. The page then grows,
  // and the scroll listener can't tell that growth apart from the reader
  // scrolling up: it sees a large distanceFromBottom, sets following="false",
  // and disables the very ResizeObserver that would have corrected it. The
  // reader ends up near the top, which is why "jump to latest" landed on the
  // first post and only worked on a second click, once the browser had
  // everything cached.
  //
  // Same approach _anchorTo already uses: keep re-jumping until real user
  // input (wheel/touch/key) says they want to browse, or layout settles.
  _settleToBottom() {
    this._settling = true;
    this.jump();

    this._settleResize = new ResizeObserver(() => {
      if (this._settling) this.jump();
    });
    this._settleResize.observe(this.el);

    this._endSettle = () => {
      if (!this._settling) return;
      this._settling = false;
      if (this._settleResize) {
        this._settleResize.disconnect();
        this._settleResize = null;
      }
      clearTimeout(this._settleTimer);
      window.removeEventListener("wheel", this._endSettle);
      window.removeEventListener("touchstart", this._endSettle);
      window.removeEventListener("keydown", this._endSettle);
    };

    window.addEventListener("wheel", this._endSettle, { passive: true });
    window.addEventListener("touchstart", this._endSettle, { passive: true });
    window.addEventListener("keydown", this._endSettle);
    this._settleTimer = setTimeout(this._endSettle, 2000);
  },

  _setupObservers() {
    // New content (posts/replies) arriving.
    this.observer = new MutationObserver(() => this.follow());
    this.observer.observe(this.el, { childList: true, subtree: true });

    // Height changes from late layout — images, embeds and avatars finish
    // loading AFTER a post is inserted, growing the page. Without watching for
    // that we'd scroll to the bottom-as-it-was and land a post or two short of
    // the real end. While pinned to the bottom, re-stick on every height change
    // so we always reach the true end. (Scrolling doesn't resize the element,
    // so this can't loop.)
    this.resizeObserver = new ResizeObserver(() => {
      if (this.el.dataset.following === "true") this.jump();
    });
    this.resizeObserver.observe(this.el);

    this.target = this.scroller === window ? window : this.scroller;
    this.handleScrollEvent = () => {
      // While settling, the scroll events are our own jumps reacting to the
      // page growing — reading them as reader intent is what broke the jump.
      if (this._settling) return;
      this.el.dataset.following = this.distanceFromBottom() < 200 ? "true" : "false";
    };
    this.target.addEventListener("scroll", this.handleScrollEvent, { passive: true });
  },

  // Land on `target` and keep it there while late layout (images/embeds/avatars
  // ABOVE it) loads and pushes it around — otherwise a one-shot scroll lands too
  // high, showing already-read posts. Re-anchors on every height change until
  // the reader takes over (wheel/touch/key) or a short settle window elapses.
  _anchorTo(target) {
    const toAnchor = () => target.scrollIntoView({ block: "start", behavior: "auto" });
    toAnchor();
    requestAnimationFrame(toAnchor);

    this._anchoring = true;
    this._anchorResize = new ResizeObserver(() => {
      if (this._anchoring) toAnchor();
    });
    this._anchorResize.observe(this.el);

    this._release = () => {
      if (!this._anchoring) return;
      this._anchoring = false;
      if (this._anchorResize) {
        this._anchorResize.disconnect();
        this._anchorResize = null;
      }
      if (this._anchorTimer) clearTimeout(this._anchorTimer);
      window.removeEventListener("wheel", this._release);
      window.removeEventListener("touchstart", this._release);
      window.removeEventListener("keydown", this._release);
    };
    // The reader scrolling/keying is intent to browse — stop fighting them.
    window.addEventListener("wheel", this._release, { passive: true });
    window.addEventListener("touchstart", this._release, { passive: true });
    window.addEventListener("keydown", this._release);
    // Safety net: release once layout has had time to settle.
    this._anchorTimer = setTimeout(this._release, 2000);
  },

  destroyed() {
    if (this._release) this._release();
    if (this._endSettle) this._endSettle();
    if (this.observer) this.observer.disconnect();
    if (this.resizeObserver) this.resizeObserver.disconnect();
    if (this.target) this.target.removeEventListener("scroll", this.handleScrollEvent);
  },

  // Nearest scrollable ancestor (auto/scroll overflow), or window.
  pickScroller() {
    let node = this.el;
    while (node && node !== document.body) {
      const oy = getComputedStyle(node).overflowY;
      if (oy === "auto" || oy === "scroll") return node;
      node = node.parentElement;
    }
    return window;
  },

  distanceFromBottom() {
    if (this.scroller === window) {
      return document.body.scrollHeight - (window.innerHeight + window.scrollY);
    }
    return this.scroller.scrollHeight - (this.scroller.clientHeight + this.scroller.scrollTop);
  },

  // Instant jump (initial open / re-anchor).
  jump() {
    if (this.scroller === window) window.scrollTo({ top: document.body.scrollHeight });
    else this.scroller.scrollTop = this.scroller.scrollHeight;
  },

  // Smooth follow, only while the reader is pinned to the bottom.
  follow() {
    if (this.el.dataset.following !== "true") return;
    if (this.scroller === window) {
      window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" });
    } else {
      this.scroller.scrollTo({ top: this.scroller.scrollHeight, behavior: "smooth" });
    }
  }
};

// =========================================================================
// JumpToUnread — "N new replies" pill: taps down to the "New replies" divider.
// Nothing scrolls on load; the reader chooses when to jump. The pill only
// shows while the divider is below the fold, and hides once it's reached.
// =========================================================================
Hooks.JumpToUnread = {
  mounted() {
    this.target = document.getElementById(this.el.dataset.target);
    if (!this.target) return;

    this.onClick = () => this.target.scrollIntoView({ block: "start", behavior: "smooth" });
    this.el.addEventListener("click", this.onClick);

    // Reveal the pill only when the divider isn't already on screen, and drop it
    // the moment the reader reaches the new posts (whether via the pill or by
    // scrolling there themselves).
    this.observer = new IntersectionObserver(
      ([entry]) => this.toggle(!entry.isIntersecting),
      { threshold: 0 }
    );
    this.observer.observe(this.target);
  },

  toggle(show) {
    this.el.classList.toggle("hidden", !show);
    this.el.classList.toggle("flex", show);
  },

  destroyed() {
    if (this.observer) this.observer.disconnect();
    if (this.onClick) this.el.removeEventListener("click", this.onClick);
  }
};

// =========================================================================
// PushSubscription — Registro de notificaciones push web
// =========================================================================
Hooks.PushSubscription = {
  mounted() {
    if (!("Notification" in window) || !("serviceWorker" in navigator)) return;

    const vapidKey = this.el.dataset.vapidPublicKey;
    if (!vapidKey) return;

    Notification.requestPermission().then((permission) => {
      if (permission !== "granted") return;

      navigator.serviceWorker.ready.then((registration) => {
        return registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(vapidKey)
        });
      }).then((subscription) => {
        if (!subscription) return;

        this.pushEvent("push-subscribe", {
          endpoint: subscription.endpoint,
          keys: {
            p256dh: btoa(String.fromCharCode(...new Uint8Array(subscription.getKey("p256dh")))),
            auth: btoa(String.fromCharCode(...new Uint8Array(subscription.getKey("auth"))))
          }
        });
      }).catch((err) => console.error("[Colloq] Error suscripción push:", err));
    });
  }
};

// =========================================================================
// VoiceRoom — WebRTC + VAD para sala de voz
// Signaling relayed through LiveView (server broadcasts via PubSub)
// =========================================================================
Hooks.VoiceRoom = {
  mounted() {
    this.peerConnections = {};
    this.localStream = null;
    this.audioContext = null;
    this.isSpeaking = false;
    this.roomId = this.el.dataset.roomId;
    this.userId = this.el.dataset.userId;
    this.username = this.el.dataset.username;

    // Build ICE server config from data attributes
    this.rtcConfig = this.buildRtcConfig();

    // Handle server-pushed events (from LiveView via push_event)
    this.handleEvent("voice-peer-joined", (payload) => this.onPeerJoined(payload));
    this.handleEvent("voice-peer-left", (payload) => this.onPeerLeft(payload));
    this.handleEvent("voice-signal", (payload) => this.onSignal(payload));

    // Handle local button clicks (join/leave are phx-click, but we need mic access)
    this.el.addEventListener("voice-join", () => this.joinRoom());
    this.el.addEventListener("voice-leave", () => this.leaveRoom());
  },

  destroyed() {
    this.leaveRoom();
  },

  buildRtcConfig() {
    const stunUrl = this.el.dataset.stunUrl || "stun:stun.l.google.com:19302";
    const turnUrl = this.el.dataset.turnUrl;
    const turnUsername = this.el.dataset.turnUsername;
    const turnCredential = this.el.dataset.turnCredential;

    const iceServers = [{ urls: stunUrl }];

    if (turnUrl && turnUsername && turnCredential) {
      iceServers.push({
        urls: turnUrl,
        username: turnUsername,
        credential: turnCredential,
      });
    }

    return { iceServers };
  },

  async joinRoom() {
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      this.setupVAD(this.localStream);
      this.pushEvent("voice-ready", { room_id: this.roomId });
    } catch (err) {
      console.error("[VoiceRoom] Microphone access denied:", err);
    }
  },

  leaveRoom() {
    // Close all peer connections
    Object.values(this.peerConnections).forEach((pc) => pc.close());
    this.peerConnections = {};

    // Stop local stream
    if (this.localStream) {
      this.localStream.getTracks().forEach((t) => t.stop());
      this.localStream = null;
    }

    // Stop VAD
    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }

    this.pushEvent("voice-leave", { room_id: this.roomId });
  },

  // A new peer joined — create offer to them
  async onPeerJoined({ user_id, username }) {
    if (user_id == this.userId) return; // Ignore self

    const pc = this.createPeerConnection(user_id);

    // Add local tracks
    if (this.localStream) {
      this.localStream.getTracks().forEach((t) => pc.addTrack(t, this.localStream));
    }

    // Create and send offer
    try {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      this.pushEvent("voice-signal", { to: user_id, signal: pc.localDescription });
    } catch (err) {
      console.error("[VoiceRoom] Error creating offer:", err);
    }
  },

  // A peer left — clean up their connection
  onPeerLeft({ user_id }) {
    const pc = this.peerConnections[user_id];
    if (pc) {
      pc.close();
      delete this.peerConnections[user_id];
    }

    // Remove their audio element
    const audioEl = document.getElementById(`voice-audio-${user_id}`);
    if (audioEl) audioEl.remove();
  },

  // Received a signal (offer/answer/ICE) from another peer
  async onSignal({ from, signal }) {
    if (from == this.userId) return; // Ignore self-signals

    let pc = this.peerConnections[from];

    if (!pc) {
      pc = this.createPeerConnection(from);

      // Add local tracks
      if (this.localStream) {
        this.localStream.getTracks().forEach((t) => pc.addTrack(t, this.localStream));
      }
    }

    try {
      if (signal.type === "offer") {
        await pc.setRemoteDescription(new RTCSessionDescription(signal));
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        this.pushEvent("voice-signal", { to: from, signal: pc.localDescription });
      } else if (signal.type === "answer") {
        await pc.setRemoteDescription(new RTCSessionDescription(signal));
      } else if (signal.candidate) {
        await pc.addIceCandidate(new RTCIceCandidate(signal));
      }
    } catch (err) {
      console.error("[VoiceRoom] Signal error:", err);
    }
  },

  createPeerConnection(peerId) {
    const pc = new RTCPeerConnection(this.rtcConfig);
    this.peerConnections[peerId] = pc;

    pc.onicecandidate = (e) => {
      if (e.candidate) {
        this.pushEvent("voice-signal", { to: peerId, signal: e.candidate });
      }
    };

    pc.ontrack = (e) => {
      // Create or reuse audio element for this peer
      let audio = document.getElementById(`voice-audio-${peerId}`);
      if (!audio) {
        audio = document.createElement("audio");
        audio.id = `voice-audio-${peerId}`;
        audio.autoplay = true;
        document.getElementById("voice-audio-container")?.appendChild(audio);
      }
      audio.srcObject = e.streams[0];
    };

    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "disconnected" || pc.connectionState === "failed") {
        this.onPeerLeft({ user_id: peerId });
      }
    };

    return pc;
  },

  setupVAD(stream) {
    this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
    const source = this.audioContext.createMediaStreamSource(stream);
    const analyser = this.audioContext.createAnalyser();
    analyser.fftSize = 256;
    source.connect(analyser);

    const bufferLength = analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    const checkSpeaking = () => {
      if (!this.audioContext) return;
      analyser.getByteFrequencyData(dataArray);
      const avg = dataArray.reduce((a, b) => a + b, 0) / bufferLength;
      const speaking = avg > 30;

      if (speaking !== this.isSpeaking) {
        this.isSpeaking = speaking;
        this.pushEvent("voice-speaking", { speaking });
      }

      requestAnimationFrame(checkSpeaking);
    };

    checkSpeaking();
  },
};

// =========================================================================
// TiptapEditor — Integración Tiptap v2
// =========================================================================
Hooks.TiptapEditor = {
  mounted() {
    this.editor = null;
    this.setupTiptap();
    // Server clears the editor after a successful post.
    this.handleEvent("tiptap:clear", () => {
      if (this.editor) this.editor.commands.clearContent(true);
    });
    // Quote-a-comment: insert a blockquote into the targeted composer.
    this.handleEvent("tiptap:quote", ({ target, html }) => {
      if (target !== this.el.id || !this.editor) return;
      this.editor.chain().focus().insertContent(html).run();
      this.el.scrollIntoView({ behavior: "smooth", block: "center" });
    });
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy();
      this.editor = null;
    }
    if (this._mentionBox) {
      this._mentionBox.remove();
      this._mentionBox = null;
    }
    if (this._slashBox) {
      this._slashBox.remove();
      this._slashBox = null;
    }
  },

  async setupTiptap() {
    let Editor, StarterKit, Placeholder, LinkExtension, ImageExtension, Spoiler;
    let Table, TableRow, TableCell, TableHeader;
    try {
      Editor = (await import("@tiptap/core")).Editor;
      StarterKit = (await import("@tiptap/starter-kit")).default;
      Placeholder = (await import("@tiptap/extension-placeholder")).default;
      LinkExtension = (await import("@tiptap/extension-link")).default;
      ImageExtension = (await import("@tiptap/extension-image")).default;
      Spoiler = (await import("./extensions/spoiler.js")).default;
      Table = (await import("@tiptap/extension-table")).default;
      TableRow = (await import("@tiptap/extension-table-row")).default;
      TableCell = (await import("@tiptap/extension-table-cell")).default;
      TableHeader = (await import("@tiptap/extension-table-header")).default;
    } catch (err) {
      console.error("[TiptapEditor] load failed, falling back to textarea:", err);
      const inp = document.getElementById(this.el.dataset.targetInput);
      const ta = document.createElement("textarea");
      ta.className = "w-full min-h-[120px] px-3 py-2 text-sm bg-surface text-body focus:outline-none";
      ta.placeholder = this.el.dataset.placeholder || "";
      ta.value = (inp && inp.value) || "";
      ta.addEventListener("input", () => { if (inp) inp.value = ta.value; });
      this.el.innerHTML = "";
      this.el.appendChild(ta);
      return;
    }

    const input = document.getElementById(this.el.dataset.targetInput);

    // Build toolbar + editor mount inside the hook element.
    this.el.innerHTML = "";
    const toolbar = document.createElement("div");
    toolbar.className =
      "flex flex-wrap items-center gap-0.5 border-b border-border px-2 py-1.5 bg-surface-alt rounded-t-lg";
    const mount = document.createElement("div");
    mount.className = "tiptap-content";
    this.el.appendChild(toolbar);
    this.el.appendChild(mount);

    this.editor = new Editor({
      element: mount,
      extensions: [
        StarterKit,
        Placeholder.configure({ placeholder: this.el.dataset.placeholder || "Escribí..." }),
        LinkExtension.configure({ openOnClick: false }),
        Spoiler,
        ImageExtension.extend({
          // Persist width/height so stickers keep a fixed small size. These
          // attributes survive the server-side HTML sanitizer (class does not).
          addAttributes() {
            return {
              ...this.parent?.(),
              width: {
                default: null,
                parseHTML: (el) => el.getAttribute("width"),
                renderHTML: (attrs) => (attrs.width ? { width: attrs.width } : {})
              },
              height: {
                default: null,
                parseHTML: (el) => el.getAttribute("height"),
                renderHTML: (attrs) => (attrs.height ? { height: attrs.height } : {})
              },
              // Flag an image as sensitive/NSFW. Rendered as data-sensitive so
              // the post view can blur it behind a warning until clicked (see
              // the PostBody hook). Survives the html5 sanitizer.
              sensitive: {
                default: null,
                parseHTML: (el) => (el.getAttribute("data-sensitive") ? "true" : null),
                renderHTML: (attrs) =>
                  attrs.sensitive ? { "data-sensitive": "true" } : {}
              }
            };
          }
        }).configure({ inline: false, HTMLAttributes: { class: "rounded-lg max-w-full my-2" } }),
        Table.configure({ resizable: true, HTMLAttributes: { class: "tiptap-table" } }),
        TableRow,
        TableHeader,
        TableCell
      ],
      content: (input && input.value) || "",
      onUpdate: ({ editor }) => {
        if (input) input.value = editor.isEmpty ? "" : editor.getHTML();
      },
      editorProps: {
        // Paste a bare image/GIF URL → embed it inline (a live preview right in
        // the composer) instead of leaving it as a link. Keyless: the browser
        // renders the CDN image directly, and <img src> survives the server-side
        // sanitizer. Only fires for a paste that is *just* a direct media URL,
        // so pasting a paragraph that happens to contain a link is untouched.
        handlePaste: (view, event) => {
          const text = (event.clipboardData || window.clipboardData)
            ?.getData("text/plain")
            ?.trim();

          // Whole clipboard must be a single http(s) URL ending in a raster/GIF
          // extension (optionally with a query string). Share pages like
          // giphy.com/gifs/… aren't direct media and are intentionally skipped.
          const IMAGE_URL = /^https?:\/\/\S+\.(gif|webp|png|jpe?g|avif)(\?\S*)?$/i;
          if (!text || /\s/.test(text) || !IMAGE_URL.test(text)) return false;

          this.editor.chain().focus().setImage({ src: text }).run();
          return true;
        }
      }
    });

    const chain = () => this.editor.chain().focus();
    const svg = (paths) =>
      `<svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;

    const mkBtn = (icon, run, title) => {
      const b = document.createElement("button");
      b.type = "button";
      b.title = title;
      b.innerHTML = icon;
      b.className =
        "flex items-center justify-center w-8 h-8 rounded text-muted hover:text-heading hover:bg-border transition-colors";
      b.addEventListener("click", (e) => {
        e.preventDefault();
        run();
      });
      toolbar.appendChild(b);
    };
    const sep = () => {
      const s = document.createElement("span");
      s.className = "w-px h-5 bg-border mx-1";
      toolbar.appendChild(s);
    };

    const I = {
      bold: '<path d="M6 12h9a4 4 0 0 1 0 8H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h7a4 4 0 0 1 0 8"/>',
      italic: '<line x1="19" y1="4" x2="10" y2="4"/><line x1="14" y1="20" x2="5" y2="20"/><line x1="15" y1="4" x2="9" y2="20"/>',
      strike: '<path d="M16 4H9a3 3 0 0 0-2.83 4"/><path d="M14 12a4 4 0 0 1 0 8H6"/><line x1="4" y1="12" x2="20" y2="12"/>',
      heading: '<path d="M6 12h12"/><path d="M6 20V4"/><path d="M18 20V4"/>',
      link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
      quote: QUOTE_ICON,
      code: '<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>',
      list: '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>',
      listOrdered: '<line x1="10" y1="6" x2="21" y2="6"/><line x1="10" y1="12" x2="21" y2="12"/><line x1="10" y1="18" x2="21" y2="18"/><path d="M4 6h1v4"/><path d="M4 10h2"/><path d="M6 18H4c0-1 2-2 2-3s-1-1.5-2-1"/>',
      image: '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>',
      smile: '<circle cx="12" cy="12" r="10"/><path d="M8 14s1.5 2 4 2 4-2 4-2"/><line x1="9" y1="9" x2="9.01" y2="9"/><line x1="15" y1="9" x2="15.01" y2="9"/>',
      table: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/><path d="M9 3v18"/><path d="M15 3v18"/>',
      sticker: '<path d="M15.5 3H5a2 2 0 0 0-2 2v14c0 1.1.9 2 2 2h14a2 2 0 0 0 2-2V8.5L15.5 3Z"/><path d="M15 3v6h6"/><path d="M10 14a3.5 3.5 0 0 0 4 0"/><path d="M9 12h.01"/><path d="M15 12h.01"/>',
      spoiler: '<path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/><path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/><path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/><line x1="2" y1="2" x2="22" y2="22"/>',
      sensitive: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>'
    };

    mkBtn(svg(I.bold), () => chain().toggleBold().run(), "Negrita (Ctrl+B)");
    mkBtn(svg(I.italic), () => chain().toggleItalic().run(), "Cursiva (Ctrl+I)");
    mkBtn(svg(I.strike), () => chain().toggleStrike().run(), "Tachado");
    mkBtn(svg(I.spoiler), () => chain().toggleSpoiler().run(), "Spoiler (ocultar hasta hacer clic)");
    mkBtn(svg(I.heading), () => chain().toggleHeading({ level: 2 }).run(), "Título");
    sep();
    mkBtn(svg(I.link), () => {
      const url = window.prompt("URL del enlace:");
      if (url) chain().setLink({ href: url }).run();
      else chain().unsetLink().run();
    }, "Enlace");
    mkBtn(svg(I.quote), () => chain().toggleBlockquote().run(), "Cita en bloque");
    mkBtn(svg(I.code), () => chain().toggleCodeBlock().run(), "Código");
    sep();
    mkBtn(svg(I.list), () => chain().toggleBulletList().run(), "Lista");
    mkBtn(svg(I.listOrdered), () => chain().toggleOrderedList().run(), "Lista numerada");
    mkBtn(svg(I.table), () => chain().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run(), "Insertar tabla");
    sep();

    // --- Image upload ---
    const fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.accept = "image/png,image/jpeg,image/gif,image/webp";
    fileInput.style.display = "none";
    fileInput.addEventListener("change", async () => {
      const file = fileInput.files && fileInput.files[0];
      fileInput.value = "";
      if (!file) return;
      const fd = new FormData();
      fd.append("file", file);
      const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
      try {
        const res = await fetch("/api/upload", {
          method: "POST",
          headers: { "x-csrf-token": csrf },
          body: fd
        });
        const data = await res.json();
        if (res.ok && data.url) chain().setImage({ src: data.url }).run();
        else alert(data.error || "No se pudo subir la imagen");
      } catch (e) {
        alert("Error al subir la imagen");
      }
    });
    this.el.appendChild(fileInput);
    mkBtn(svg(I.image), () => fileInput.click(), "Subir imagen");

    // Toggle "sensitive/NSFW" on an image. Rather than relying on the image
    // being the active selection (fragile: clicking the toolbar can drop the
    // node selection), we locate the target image node by position — the
    // selected one, else the image nearest the cursor, else the only image —
    // and flip its attribute with setNodeMarkup. In the post it renders
    // blurred behind a warning until the reader clicks (PostBody hook).
    mkBtn(svg(I.sensitive), () => {
      const { state } = this.editor;
      const sel = state.selection;
      let pos = null;

      if (sel.node && sel.node.type.name === "image") {
        pos = sel.from;
      } else {
        const imgs = [];
        state.doc.descendants((node, p) => {
          if (node.type.name === "image") imgs.push(p);
        });
        if (imgs.length === 1) {
          pos = imgs[0];
        } else if (imgs.length > 1) {
          const c = sel.from;
          pos = imgs.reduce(
            (best, p) => (Math.abs(p - c) < Math.abs(best - c) ? p : best),
            imgs[0]
          );
        }
      }

      if (pos === null) {
        alert("Insertá o seleccioná una imagen para marcarla como sensible.");
        return;
      }

      const node = state.doc.nodeAt(pos);
      const makeSensitive = !node.attrs.sensitive;
      this.editor
        .chain()
        .focus()
        .command(({ tr }) => {
          tr.setNodeMarkup(pos, undefined, {
            ...node.attrs,
            sensitive: makeSensitive ? "true" : null
          });
          return true;
        })
        .run();
    }, "Marcar imagen como sensible");

    // --- Sticker picker ---
    const stWrap = document.createElement("div");
    stWrap.className = "relative inline-flex";
    const stBtn = document.createElement("button");
    stBtn.type = "button";
    stBtn.title = "Sticker";
    stBtn.innerHTML = svg(I.sticker);
    stBtn.className = "flex items-center justify-center w-8 h-8 rounded text-muted hover:text-heading hover:bg-border transition-colors";
    const stPop = document.createElement("div");
    stPop.className = "hidden absolute z-50 top-full left-0 mt-1 rounded-lg bg-surface border border-border shadow-lg w-72 max-w-[90vw] max-h-72 flex flex-col overflow-hidden";
    const stTabs = document.createElement("div");
    stTabs.className = "flex gap-1 p-2 border-b border-border overflow-x-auto flex-shrink-0";
    const stGrid = document.createElement("div");
    stGrid.className = "p-2 grid grid-cols-4 gap-1 overflow-y-auto";
    stPop.appendChild(stTabs);
    stPop.appendChild(stGrid);
    let stPacks = null;
    const stRenderPack = (pack) => {
      stGrid.innerHTML = "";
      pack.stickers.forEach((st) => {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "p-1 rounded-lg hover:bg-surface-alt flex items-center justify-center";
        const img = document.createElement("img");
        img.src = st.url;
        img.alt = "sticker";
        img.loading = "lazy";
        img.className = "w-14 h-14 object-contain";
        b.appendChild(img);
        b.addEventListener("click", (ev) => {
          ev.preventDefault();
          const sz = st.size || 128;
          chain().setImage({ src: st.url, width: sz, height: sz }).run();
          stPop.classList.add("hidden");
        });
        stGrid.appendChild(b);
      });
    };
    const stRenderTabs = () => {
      stTabs.innerHTML = "";
      stPacks.forEach((pack, i) => {
        const t = document.createElement("button");
        t.type = "button";
        t.textContent = pack.name;
        t.className = "px-2.5 py-1 rounded-full text-xs font-medium whitespace-nowrap flex-shrink-0 text-muted hover:text-heading";
        t.addEventListener("click", (ev) => {
          ev.preventDefault();
          stTabs.querySelectorAll("button").forEach((x) => x.classList.remove("bg-accent", "text-white"));
          t.classList.add("bg-accent", "text-white");
          stRenderPack(pack);
        });
        stTabs.appendChild(t);
        if (i === 0) { t.classList.add("bg-accent", "text-white"); stRenderPack(pack); }
      });
    };
    const stLoad = () => {
      if (stPacks) return Promise.resolve();
      // Built-in "Ligas" pack always comes first, then any admin sticker packs.
      return fetch("/api/stickers")
        .then((r) => r.json())
        .then((data) => {
          stPacks = [LEAGUE_LOGOS, ...((data && data.packs) || [])];
          stRenderTabs();
        })
        .catch(() => {
          stPacks = [LEAGUE_LOGOS];
          stRenderTabs();
        });
    };
    stBtn.addEventListener("click", (ev) => {
      ev.preventDefault();
      const hidden = stPop.classList.contains("hidden");
      if (hidden) stLoad().then(() => stPop.classList.remove("hidden"));
      else stPop.classList.add("hidden");
    });
    document.addEventListener("click", (ev) => { if (!stWrap.contains(ev.target)) stPop.classList.add("hidden"); });
    stWrap.appendChild(stBtn);
    stWrap.appendChild(stPop);
    toolbar.appendChild(stWrap);

    // --- Emoji picker (large, Discourse-like set) ---
    const emojis = EMOJIS;
    const wrap = document.createElement("div");
    wrap.className = "relative inline-flex";
    const emojiBtn = document.createElement("button");
    emojiBtn.type = "button";
    emojiBtn.title = "Emoji";
    emojiBtn.innerHTML = svg(I.smile);
    emojiBtn.className = "flex items-center justify-center w-8 h-8 rounded text-muted hover:text-heading hover:bg-border transition-colors";
    const pop = document.createElement("div");
    pop.className = "hidden absolute z-50 top-full left-0 mt-1 p-2 rounded-lg bg-surface border border-border shadow-lg grid grid-cols-7 gap-1 w-72 max-w-[90vw] max-h-64 overflow-y-auto";
    emojis.forEach((e) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = e;
      b.className = "text-2xl leading-none p-1 rounded hover:bg-surface-alt";
      b.addEventListener("click", (ev) => {
        ev.preventDefault();
        chain().insertContent(e).run();
        pop.classList.add("hidden");
      });
      pop.appendChild(b);
    });

    // Custom emoji (admin-uploaded) — inserted as :shortcode: text, which the
    // server renders as an inline image. Fetched once, lazily.
    fetch("/api/emojis")
      .then((r) => r.json())
      .then((data) => {
        const custom = (data && data.emojis) || [];
        if (!custom.length) return;
        const divider = document.createElement("div");
        divider.className = "col-span-9 border-t border-border my-1";
        pop.appendChild(divider);
        custom.forEach((ce) => {
          const b = document.createElement("button");
          b.type = "button";
          b.title = `:${ce.name}:`;
          b.className = "p-1 rounded hover:bg-surface-alt flex items-center justify-center";
          const img = document.createElement("img");
          img.src = ce.url;
          img.alt = `:${ce.name}:`;
          img.className = "w-5 h-5 object-contain";
          b.appendChild(img);
          b.addEventListener("click", (ev) => {
            ev.preventDefault();
            chain().insertContent(`:${ce.name}: `).run();
            pop.classList.add("hidden");
          });
          pop.appendChild(b);
        });
      })
      .catch(() => {});

    emojiBtn.addEventListener("click", (ev) => {
      ev.preventDefault();
      pop.classList.toggle("hidden");
    });
    document.addEventListener("click", (ev) => {
      if (!wrap.contains(ev.target)) pop.classList.add("hidden");
    });
    wrap.appendChild(emojiBtn);
    wrap.appendChild(pop);
    toolbar.appendChild(wrap);

    // --- @mention autocomplete -------------------------------------------
    const mentionBox = document.createElement("div");
    mentionBox.className =
      "hidden fixed z-[60] w-64 max-h-64 overflow-y-auto rounded-lg border border-border bg-surface shadow-lg py-1";
    document.body.appendChild(mentionBox);
    this._mentionBox = mentionBox;

    let mentionItems = [];
    let mentionIndex = 0;
    let mentionRange = null;
    let mentionSeq = 0;

    const hideMention = () => {
      mentionBox.classList.add("hidden");
      mentionItems = [];
      mentionRange = null;
    };

    const renderMention = () => {
      mentionBox.innerHTML = "";
      if (!mentionItems.length) { hideMention(); return; }
      mentionItems.forEach((u, i) => {
        const item = document.createElement("button");
        item.type = "button";
        item.className =
          "flex items-center gap-2 w-full text-left px-3 py-1.5 text-sm " +
          (i === mentionIndex ? "bg-surface-alt text-heading" : "text-body hover:bg-surface-alt");
        const label =
          u.display_name && u.display_name !== u.username
            ? `${u.display_name} <span class="text-muted">@${u.username}</span>`
            : `@${u.username}`;
        item.innerHTML = `<span class="truncate">${label}</span>`;
        item.addEventListener("mousedown", (ev) => {
          ev.preventDefault();
          selectMention(u);
        });
        mentionBox.appendChild(item);
      });
      if (mentionRange) {
        const coords = this.editor.view.coordsAtPos(mentionRange.from);
        mentionBox.style.left = `${Math.round(coords.left)}px`;
        mentionBox.style.top = `${Math.round(coords.bottom + 4)}px`;
      }
      mentionBox.classList.remove("hidden");
    };

    const selectMention = (u) => {
      if (!mentionRange || !u) return;
      this.editor
        .chain()
        .focus()
        .insertContentAt({ from: mentionRange.from, to: mentionRange.to }, `@${u.username} `)
        .run();
      hideMention();
    };

    const checkMention = () => {
      const sel = this.editor.state.selection;
      if (!sel.empty) { hideMention(); return; }
      const $from = sel.$from;
      const to = sel.from;
      const textBefore = $from.parent.textBetween(0, $from.parentOffset, "\n", "￼");
      const m = /(?:^|\s)@(\w{1,30})$/.exec(textBefore);
      if (!m) { hideMention(); return; }
      const query = m[1];
      mentionRange = { from: to - query.length - 1, to };
      const seq = ++mentionSeq;
      fetch(`/api/users/search?q=${encodeURIComponent(query)}`)
        .then((r) => r.json())
        .then((data) => {
          if (seq !== mentionSeq) return; // ignore stale responses
          mentionItems = (data && data.users) || [];
          mentionIndex = 0;
          renderMention();
        })
        .catch(() => hideMention());
    };

    this.editor.on("update", checkMention);
    this.editor.on("selectionUpdate", checkMention);

    // Intercept nav keys before ProseMirror when the suggestion list is open.
    this.editor.view.dom.addEventListener(
      "keydown",
      (ev) => {
        if (mentionBox.classList.contains("hidden") || !mentionItems.length) return;
        if (ev.key === "ArrowDown") {
          ev.preventDefault();
          mentionIndex = (mentionIndex + 1) % mentionItems.length;
          renderMention();
        } else if (ev.key === "ArrowUp") {
          ev.preventDefault();
          mentionIndex = (mentionIndex - 1 + mentionItems.length) % mentionItems.length;
          renderMention();
        } else if (ev.key === "Enter" || ev.key === "Tab") {
          ev.preventDefault();
          selectMention(mentionItems[mentionIndex]);
        } else if (ev.key === "Escape") {
          ev.preventDefault();
          hideMention();
        }
      },
      true
    );

    // --- /command autocomplete -------------------------------------------
    // Bot commands (/sofascore, /dolar) only fire when they're the first thing
    // in the post — the server checks the stripped body *starts with* them — so
    // we only suggest when "/" opens the first block. Static list, no API.
    const SLASH_COMMANDS = [
      { insert: "/sofascore partido ", label: "/sofascore partido", desc: "Racing: en vivo o próximo partido", key: "/sofascore partido" },
      { insert: "/sofascore partido anterior ", label: "/sofascore partido anterior", desc: "Último resultado de Racing", key: "/sofascore partido anterior" },
      { insert: "/sofascore liga ", label: "/sofascore liga [fecha]", desc: "Fixture de una fecha de la liga", key: "/sofascore liga" },
      { insert: "/sofascore tabla ", label: "/sofascore tabla", desc: "Tabla de posiciones del torneo", key: "/sofascore tabla" },
      { insert: "/sofascore tabla anual ", label: "/sofascore tabla anual", desc: "Tabla anual (acumulada del año)", key: "/sofascore tabla anual" },
      { insert: "/sofascore plantel ", label: "/sofascore plantel", desc: "Plantel de Racing", key: "/sofascore plantel" },
      { insert: "/sofascore ", label: "/sofascore <jugador>", desc: "Estadísticas de un jugador", key: "/sofascore" },
      { insert: "/dolar ", label: "/dolar", desc: "Cotización del dólar", key: "/dolar" },
    ];

    const slashBox = document.createElement("div");
    slashBox.className =
      "hidden fixed z-[60] w-72 max-h-64 overflow-y-auto rounded-lg border border-border bg-surface shadow-lg py-1";
    document.body.appendChild(slashBox);
    this._slashBox = slashBox;

    let slashItems = [];
    let slashIndex = 0;
    let slashRange = null;

    const hideSlash = () => {
      slashBox.classList.add("hidden");
      slashItems = [];
      slashRange = null;
    };

    const renderSlash = () => {
      slashBox.innerHTML = "";
      if (!slashItems.length) { hideSlash(); return; }
      slashItems.forEach((c, i) => {
        const item = document.createElement("button");
        item.type = "button";
        item.className =
          "flex flex-col items-start gap-0.5 w-full text-left px-3 py-1.5 text-sm " +
          (i === slashIndex ? "bg-surface-alt text-heading" : "text-body hover:bg-surface-alt");
        item.innerHTML =
          `<span class="font-medium">${c.label}</span>` +
          `<span class="text-xs text-muted">${c.desc}</span>`;
        item.addEventListener("mousedown", (ev) => {
          ev.preventDefault();
          selectSlash(c);
        });
        slashBox.appendChild(item);
      });
      if (slashRange) {
        const coords = this.editor.view.coordsAtPos(slashRange.from);
        slashBox.style.left = `${Math.round(coords.left)}px`;
        slashBox.style.top = `${Math.round(coords.bottom + 4)}px`;
      }
      slashBox.classList.remove("hidden");
    };

    const selectSlash = (c) => {
      if (!slashRange || !c) return;
      this.editor
        .chain()
        .focus()
        .insertContentAt({ from: slashRange.from, to: slashRange.to }, c.insert)
        .run();
      hideSlash();
    };

    const checkSlash = () => {
      const sel = this.editor.state.selection;
      if (!sel.empty) { hideSlash(); return; }
      const $from = sel.$from;
      const isFirstBlock = this.editor.state.doc.firstChild === $from.parent;
      const textBefore = $from.parent.textBetween(0, $from.parentOffset, "\n", "￼");
      // "/" then word chars / spaces (commands can have a subcommand word).
      if (!isFirstBlock || !/^\/[\w\s]*$/.test(textBefore)) { hideSlash(); return; }
      const typed = textBefore.toLowerCase();
      slashItems = SLASH_COMMANDS.filter((c) => {
        const k = c.key.toLowerCase();
        return k.startsWith(typed) || typed.startsWith(k + " ") || typed === k;
      });
      slashIndex = 0;
      slashRange = { from: sel.from - $from.parentOffset, to: sel.from };
      renderSlash();
    };

    this.editor.on("update", checkSlash);
    this.editor.on("selectionUpdate", checkSlash);

    this.editor.view.dom.addEventListener(
      "keydown",
      (ev) => {
        if (slashBox.classList.contains("hidden") || !slashItems.length) return;
        if (ev.key === "ArrowDown") {
          ev.preventDefault();
          slashIndex = (slashIndex + 1) % slashItems.length;
          renderSlash();
        } else if (ev.key === "ArrowUp") {
          ev.preventDefault();
          slashIndex = (slashIndex - 1 + slashItems.length) % slashItems.length;
          renderSlash();
        } else if (ev.key === "Enter" || ev.key === "Tab") {
          ev.preventDefault();
          selectSlash(slashItems[slashIndex]);
        } else if (ev.key === "Escape") {
          ev.preventDefault();
          hideSlash();
        }
      },
      true
    );
  }
};

// =========================================================================
// Utility: urlBase64ToUint8Array
// =========================================================================
function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding).replace(/\-/g, "+").replace(/_/g, "/");
  const rawData = atob(base64);
  return new Uint8Array([...rawData].map((char) => char.charCodeAt(0)));
}

// =========================================================================
// Copy to clipboard (push_event handler)
// =========================================================================
window.addEventListener("phx:copy-to-clipboard", (e) => {
  if (e.detail.text) {
    navigator.clipboard.writeText(e.detail.text).catch(() => {
      // Fallback for older browsers
      const textarea = document.createElement("textarea");
      textarea.value = e.detail.text;
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand("copy");
      document.body.removeChild(textarea);
    });
  }
});

// =========================================================================
// SettingImageUpload — upload a PNG/SVG for an image-type site setting.
// Uploads to /api/upload, then fills the URL input + preview. The form's
// "Save" button persists the URL like any other setting value.
// =========================================================================
Hooks.SettingImageUpload = {
  mounted() {
    const fileInput = this.el.querySelector("[data-file]");
    const urlInput = this.el.querySelector("[data-url]");
    const preview = this.el.querySelector("[data-preview]");
    const status = this.el.querySelector("[data-status]");
    if (!fileInput || !urlInput) return;

    fileInput.addEventListener("change", async () => {
      const file = fileInput.files && fileInput.files[0];
      fileInput.value = "";
      if (!file) return;

      if (status) status.textContent = "Subiendo…";
      const fd = new FormData();
      fd.append("file", file);
      const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
      try {
        const res = await fetch("/api/upload", {
          method: "POST",
          headers: { "x-csrf-token": csrf },
          body: fd
        });
        const data = await res.json();
        if (res.ok && data.url) {
          urlInput.value = data.url;
          urlInput.dispatchEvent(new Event("input", { bubbles: true }));
          if (preview) {
            preview.src = data.url;
            preview.classList.remove("hidden");
          }
          if (status) status.textContent = "Listo — tocá Guardar";
        } else {
          if (status) status.textContent = data.error || "No se pudo subir";
        }
      } catch (e) {
        if (status) status.textContent = "Error al subir";
      }
    });
  }
};

// =========================================================================
// Lottie / TGS animated stickers (Telegram-style)
// =========================================================================
// Vector stickers: tiny files, crisp at any size. Telegram ships `.tgs`, which
// is just gzipped Lottie JSON — so `.tgs` gets gunzipped first.
//
// NOTE: the dynamic import below defers *evaluation*, but esbuild is configured
// without `--splitting`, so lottie-web + pako (~386KB) are still inlined into
// app.js and shipped on every page. Enabling `--splitting --format=esm` (and a
// module script tag) would make this a real lazy load.
let lottiePromise = null;

function loadLottie() {
  if (!lottiePromise) {
    lottiePromise = import("lottie-web/build/player/lottie_light.min.js").then(
      (m) => m.default || m
    );
  }
  return lottiePromise;
}

async function fetchAnimationData(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`sticker fetch failed: ${res.status}`);

  // .tgs is gzipped Lottie JSON; plain .json is not.
  if (url.endsWith(".tgs")) {
    const { inflate } = await import("pako");
    const buf = new Uint8Array(await res.arrayBuffer());
    return JSON.parse(inflate(buf, { to: "string" }));
  }

  return res.json();
}

Hooks.LottieSticker = {
  async mounted() {
    this.render();
  },

  updated() {
    // Re-render only if the source actually changed.
    const src = this.el.dataset.src;
    if (src !== this._src) this.render();
  },

  destroyed() {
    if (this._anim) this._anim.destroy();
  },

  async render() {
    const src = this.el.dataset.src;
    this._src = src;
    if (!src) return;

    try {
      const [lottie, animationData] = await Promise.all([
        loadLottie(),
        fetchAnimationData(src),
      ]);

      if (this._anim) this._anim.destroy();

      this._anim = lottie.loadAnimation({
        container: this.el,
        renderer: "svg",
        loop: this.el.dataset.loop !== "false",
        autoplay: true,
        animationData,
      });
    } catch (err) {
      // Never break the chat over a sticker — leave the placeholder in place.
      console.error("[LottieSticker]", err);
    }
  },
};

// =========================================================================
// CategoryTree — expand/collapse subcategories in the sidebar
// =========================================================================
// The sidebar lives in the app layout, so it re-renders on every LiveView
// patch and every navigation. A plain JS.toggle() only flips a class in the
// DOM, which the next patch overwrites with the server's `hidden` — the list
// sprang back shut the moment you clicked a subcategory.
//
// So the open set lives here and is re-applied on updated(). It's persisted to
// localStorage as well, which means an expanded category also survives a full
// page load rather than resetting every time you navigate.
const CATEGORY_TREE_KEY = "colloq:open-categories";

Hooks.CategoryTree = {
  mounted() {
    // Delegated: one listener on the container survives children being
    // re-rendered underneath it.
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-cat-toggle]");
      if (!btn || !this.el.contains(btn)) return;
      e.preventDefault();

      const id = btn.dataset.catToggle;
      const open = this.readOpen();
      if (open.has(id)) open.delete(id);
      else open.add(id);
      this.writeOpen(open);
      this.applyOpen();
    });

    this.applyOpen();
  },

  updated() {
    this.applyOpen();
  },

  // localStorage can throw (private mode, storage disabled) — a sidebar that
  // won't expand is a much worse failure than one that forgets.
  readOpen() {
    try {
      return new Set(JSON.parse(window.localStorage.getItem(CATEGORY_TREE_KEY) || "[]"));
    } catch (_) {
      return new Set();
    }
  },

  writeOpen(set) {
    try {
      window.localStorage.setItem(CATEGORY_TREE_KEY, JSON.stringify([...set]));
    } catch (_) {
      /* not fatal — the tree still works for this page */
    }
  },

  applyOpen() {
    const open = this.readOpen();

    this.el.querySelectorAll("[data-cat-subs]").forEach((subs) => {
      const id = subs.dataset.catSubs;
      const isOpen = open.has(id);
      subs.classList.toggle("hidden", !isOpen);

      const btn = this.el.querySelector(`[data-cat-toggle="${id}"]`);
      if (!btn) return;
      btn.setAttribute("aria-expanded", isOpen ? "true" : "false");
      const chevron = btn.querySelector("svg");
      if (chevron) chevron.classList.toggle("rotate-90", isOpen);
    });
  },
};

// =========================================================================
// PostBody — click-to-reveal for spoilers and sensitive media
// =========================================================================
// Mounted on each rendered post body. Wires up two composer features that
// ship as inert markup in the stored HTML:
//   • <span data-spoiler>  → blurred inline text, click to reveal
//   • <img data-sensitive> → blurred image behind an NSFW warning overlay
// Both are idempotent so LiveView patches (updated()) don't double-wrap.
Hooks.PostBody = {
  mounted() {
    this.setup();
    this.setupQuoteSelection();
  },
  updated() {
    this.setup();
  },
  destroyed() {
    this.teardownQuoteSelection();
  },
  setup() {
    // Inline spoilers: reveal on click (once revealed, stay revealed).
    this.el.querySelectorAll("[data-spoiler]").forEach((el) => {
      if (el.dataset.spoilerWired) return;
      el.dataset.spoilerWired = "1";
      el.addEventListener("click", () => el.classList.add("is-revealed"));
    });

    // Sensitive images: blurred by CSS via [data-sensitive] (wrapper or not).
    // Clicking reveals — add `.revealed` to the image and `.is-revealed` to the
    // wrapper (to drop the veil). Idempotent via a dataset flag so LiveView
    // patches don't stack listeners.
    this.el.querySelectorAll("img[data-sensitive]").forEach((img) => {
      if (img.dataset.sensitiveWired) return;
      img.dataset.sensitiveWired = "1";
      const wrap = img.closest(".sensitive-media");
      const target = wrap || img;
      target.addEventListener("click", () => {
        img.classList.add("revealed");
        if (wrap) wrap.classList.add("is-revealed");
      });
    });
  },

  // Selecting text inside a post floats a "Quote" pill next to the selection;
  // clicking it quotes only what was selected, instead of the whole post.
  // Listeners live on this.el (not document) so N posts don't each pay for
  // every mouseup on the page — a selection that leaves this post also leaves
  // the containment check below, so there's nothing to catch out there.
  setupQuoteSelection() {
    const postId = this.el.dataset.postId;
    if (!postId || !this.el.dataset.quotable) return;

    this._quotePill = null;

    this._hideQuotePill = () => {
      if (this._quotePill) {
        this._quotePill.remove();
        this._quotePill = null;
      }
    };

    this._onSelect = () => {
      const sel = window.getSelection();
      if (!sel || sel.isCollapsed || sel.rangeCount === 0) return this._hideQuotePill();

      const range = sel.getRangeAt(0);
      // Only react to selections living entirely inside THIS post body.
      if (!this.el.contains(range.commonAncestorContainer)) return this._hideQuotePill();

      const text = sel.toString().trim();
      if (text.length < 2) return this._hideQuotePill();

      const rect = range.getBoundingClientRect();
      if (!rect.width && !rect.height) return this._hideQuotePill();

      this._showQuotePill(rect, postId, text);
    };

    // Deferred: the selection isn't final until after the mouseup/keyup fires.
    this._deferSelect = () => window.setTimeout(this._onSelect, 0);

    // A click anywhere else dismisses the pill (mousedown on the pill itself is
    // suppressed below so it survives long enough to be clicked).
    this._onDocMouseDown = (e) => {
      if (this._quotePill && !this._quotePill.contains(e.target)) this._hideQuotePill();
    };

    this.el.addEventListener("mouseup", this._deferSelect);
    this.el.addEventListener("keyup", this._deferSelect);
    document.addEventListener("mousedown", this._onDocMouseDown);
    window.addEventListener("scroll", this._hideQuotePill, true);
  },

  _showQuotePill(rect, postId, text) {
    this._hideQuotePill();

    const pill = document.createElement("button");
    pill.type = "button";
    pill.className = "quote-pill";
    pill.innerHTML =
      `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ` +
      `stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${QUOTE_ICON}</svg>`;
    pill.appendChild(document.createTextNode(this.el.dataset.quoteLabel || "Quote"));

    // Fixed positioning: the rect is already viewport-relative, and the pill
    // sits above the selection unless that would clip off the top.
    pill.style.top = `${Math.max(8, rect.top - 40)}px`;
    pill.style.left = `${rect.left + rect.width / 2}px`;

    // Keep the selection alive through the click.
    pill.addEventListener("mousedown", (e) => e.preventDefault());
    pill.addEventListener("click", () => {
      this.pushEvent("quote-post", { post_id: postId, text });
      window.getSelection()?.removeAllRanges();
      this._hideQuotePill();
    });

    document.body.appendChild(pill);
    this._quotePill = pill;
  },

  teardownQuoteSelection() {
    if (!this._hideQuotePill) return;
    this._hideQuotePill();
    this.el.removeEventListener("mouseup", this._deferSelect);
    this.el.removeEventListener("keyup", this._deferSelect);
    document.removeEventListener("mousedown", this._onDocMouseDown);
    window.removeEventListener("scroll", this._hideQuotePill, true);
  },
};

// =========================================================================
// ReactionPill — feedback the CSS alone can't give. The pill element is
// reused across patches (morphdom just swaps the number), so the mount-time
// `reaction-pop` never re-fires. This watches data-count / data-mine and
// replays a bump on every change, plus a one-off emoji burst when *you* are
// the one adding the reaction.
// =========================================================================
const BURST_COUNT = 6;

Hooks.ReactionPill = {
  mounted() {
    this.count = Number(this.el.dataset.count);

    // The server names the exact pill the viewer just reacted to, so bursting
    // needs no guesswork about whether this is an initial render. Fires on
    // add only; the server stays silent when a reaction is removed.
    this.handleEvent("reaction:burst", ({ post_id, emoji }) => {
      if (
        String(post_id) === this.el.dataset.postId &&
        emoji === this.el.dataset.emojiKey
      ) {
        this.burst();
      }
    });
  },

  updated() {
    const count = Number(this.el.dataset.count);
    if (count !== this.count) this.bump();
    this.count = count;
  },

  // Restart the animation by forcing a reflow between class toggles.
  bump() {
    const el = this.el.querySelector("[data-count-text]") || this.el;
    el.classList.remove("reaction-bump");
    void el.offsetWidth;
    el.classList.add("reaction-bump");
  },

  burst() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const source = this.el.querySelector("[data-emoji]");
    if (!source) return;

    for (let i = 0; i < BURST_COUNT; i++) {
      const particle = source.cloneNode(true);
      particle.removeAttribute("data-emoji");
      particle.className = "reaction-particle";

      // Fan out over a 120° arc centred on straight up.
      const angle = -Math.PI / 2 + (i / (BURST_COUNT - 1) - 0.5) * (Math.PI * 2) / 3;
      const distance = 26 + Math.random() * 18;
      particle.style.setProperty("--dx", `${Math.cos(angle) * distance}px`);
      particle.style.setProperty("--dy", `${Math.sin(angle) * distance}px`);
      particle.style.animationDelay = `${i * 20}ms`;

      particle.addEventListener("animationend", () => particle.remove());
      this.el.appendChild(particle);
    }
  },
};

// =========================================================================
// Export
// =========================================================================
export default Hooks;
