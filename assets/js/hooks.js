// Colloq — LiveView Hooks
// EmojiPicker, PostImpression, AutoScroll, PushSubscription,
// VoiceRoom, TiptapEditor

let Hooks = {};

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
  "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝","💯","💢",
  "💥","💫","💦","💨","🕳️","💬","💭","🔥","⭐","🌟","✨","⚡","☀️","🌈","🎵","🎶",
  // Football & sports
  "⚽","🏀","🏈","⚾","🎾","🏐","🏉","🥅","🏆","🥇","🥈","🥉","🏅","🎖️","🎯","🏟️","👟","🧤","📣","🎽",
  // Argentina / Racing colours
  "🇦🇷","🔵","⚪","🔷","🤍","💙","🏁","🚩",
  // Celebration & objects
  "🎉","🎊","🥳","🎁","🎈","🍾","🥂","🍻","🍺","🍷","☕","🧉","🍕","🍔","🌭","🍿","📸","🎥","📺","📱",
  "💰","💵","📈","📉","⏰","⏳","✅","❌","❗","❓","💤","👑","🐐","🔝","🆗","🆒"
];

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
    this.el.addEventListener("change", () => applyTheme(this.el.value));
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
      inner += this.axisLabels(data, pad, iw, ih, muted);
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
      inner += this.axisLabels(data, pad, iw, ih, muted);
    }

    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="100%" height="100%" style="overflow:visible">${inner}</svg>`;
  },
  axisLabels(data, pad, iw, ih, muted) {
    // Show at most ~6 x-axis labels to avoid crowding.
    const n = data.length;
    const every = Math.max(1, Math.ceil(n / 6));
    let out = "";
    data.forEach((d, i) => {
      if (i % every !== 0 && i !== n - 1) return;
      const x = n > 1 ? pad.l + (iw / (n - 1)) * i : pad.l + iw / 2;
      const label = d.label.length > 6 ? d.label.slice(5) : d.label; // trim year from dates
      out += `<text x="${x.toFixed(1)}" y="${pad.t + ih + 15}" font-size="10" fill="${muted}" text-anchor="middle">${label}</text>`;
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
    const topBtn = el.querySelector("[data-tl-top]");
    const botBtn = el.querySelector("[data-tl-bottom]");

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
      "hidden fixed z-[80] p-2 rounded-lg bg-surface border border-border shadow-lg grid grid-cols-8 gap-0.5 w-64 max-h-56 overflow-y-auto";
    emojis.forEach((e) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = e;
      b.className = "text-lg leading-none p-1 rounded hover:bg-surface-alt";
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
      // Prefer showing above the button; the popup is ~230px tall.
      const top = r.top - 8 - Math.min(pop.offsetHeight || 224, 224);
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
  }
};

// =========================================================================
// TagInput — Discourse-style tag picker: chips + autocomplete, backed by a
// hidden comma-separated input so the existing form handler is unchanged.
// =========================================================================
Hooks.TagInput = {
  mounted() {
    const inputName = this.el.dataset.name || "tags";
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
    };

    const addTag = (raw) => {
      const tag = normalize(raw);
      if (!tag) return;
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

      // Offer to create the typed tag if it isn't an exact existing match.
      if (q && !suggestions.some((s) => s.name.toLowerCase() === q.toLowerCase())) {
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

    // Prefill from initial value.
    initial.forEach(addTag);
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
          { name: "Reacciones", emojis: ["👍", "❤️", "😂", "😮", "😢", "😡"] },
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
      "hidden fixed z-[80] p-2 rounded-lg bg-surface border border-border shadow-lg grid grid-cols-8 gap-0.5 w-64 max-h-56 overflow-y-auto";
    emojis.forEach((e) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = e;
      b.className = "text-lg leading-none p-1 rounded hover:bg-surface-alt";
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
      pop.style.top = `${Math.round(Math.min(below, window.innerHeight - 232))}px`;
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
    this.scrollToBottom();
    this.observer = new MutationObserver(() => this.scrollToBottom());
    this.observer.observe(this.el, { childList: true, subtree: true });
    this.handleScrollEvent = () => {
      const atBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 200;
      this.el.dataset.following = atBottom ? "true" : "false";
    };
    window.addEventListener("scroll", this.handleScrollEvent);
  },

  destroyed() {
    if (this.observer) this.observer.disconnect();
    window.removeEventListener("scroll", this.handleScrollEvent);
  },

  scrollToBottom() {
    if (this.el.dataset.following === "true") {
      window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" });
    }
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
  },

  async setupTiptap() {
    let Editor, StarterKit, Placeholder, LinkExtension, ImageExtension;
    let Table, TableRow, TableCell, TableHeader;
    try {
      Editor = (await import("@tiptap/core")).Editor;
      StarterKit = (await import("@tiptap/starter-kit")).default;
      Placeholder = (await import("@tiptap/extension-placeholder")).default;
      LinkExtension = (await import("@tiptap/extension-link")).default;
      ImageExtension = (await import("@tiptap/extension-image")).default;
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
        ImageExtension.configure({ inline: false, HTMLAttributes: { class: "rounded-lg max-w-full my-2" } }),
        Table.configure({ resizable: true, HTMLAttributes: { class: "tiptap-table" } }),
        TableRow,
        TableHeader,
        TableCell
      ],
      content: (input && input.value) || "",
      onUpdate: ({ editor }) => {
        if (input) input.value = editor.isEmpty ? "" : editor.getHTML();
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
      quote: '<path d="M3 21c3 0 7-1 7-8V5c0-1.25-.75-2-2-2H4c-1.25 0-2 .75-2 2v6c0 1.25.75 2 2 2h1c0 1-1 2-2 2z"/><path d="M15 21c3 0 7-1 7-8V5c0-1.25-.75-2-2-2h-4c-1.25 0-2 .75-2 2v6c0 1.25.75 2 2 2h1c0 1-1 2-2 2z"/>',
      code: '<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>',
      list: '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>',
      listOrdered: '<line x1="10" y1="6" x2="21" y2="6"/><line x1="10" y1="12" x2="21" y2="12"/><line x1="10" y1="18" x2="21" y2="18"/><path d="M4 6h1v4"/><path d="M4 10h2"/><path d="M6 18H4c0-1 2-2 2-3s-1-1.5-2-1"/>',
      image: '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>',
      smile: '<circle cx="12" cy="12" r="10"/><path d="M8 14s1.5 2 4 2 4-2 4-2"/><line x1="9" y1="9" x2="9.01" y2="9"/><line x1="15" y1="9" x2="15.01" y2="9"/>',
      table: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/><path d="M9 3v18"/><path d="M15 3v18"/>'
    };

    mkBtn(svg(I.bold), () => chain().toggleBold().run(), "Negrita (Ctrl+B)");
    mkBtn(svg(I.italic), () => chain().toggleItalic().run(), "Cursiva (Ctrl+I)");
    mkBtn(svg(I.strike), () => chain().toggleStrike().run(), "Tachado");
    mkBtn(svg(I.heading), () => chain().toggleHeading({ level: 2 }).run(), "Título");
    sep();
    mkBtn(svg(I.link), () => {
      const url = window.prompt("URL del enlace:");
      if (url) chain().setLink({ href: url }).run();
      else chain().unsetLink().run();
    }, "Enlace");
    mkBtn(svg(I.quote), () => chain().toggleBlockquote().run(), "Cita");
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
    pop.className = "hidden absolute z-50 top-full left-0 mt-1 p-2 rounded-lg bg-surface border border-border shadow-lg grid grid-cols-9 gap-0.5 w-72 max-h-64 overflow-y-auto";
    emojis.forEach((e) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = e;
      b.className = "text-lg leading-none p-1 rounded hover:bg-surface-alt";
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
// Export
// =========================================================================
export default Hooks;
