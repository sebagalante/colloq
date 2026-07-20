// Colloq — hover "user card" popover
//
// Delegates over the whole document: hovering any `/u/:username` link fetches a
// small JSON payload and renders a floating card near the link (Discourse-style).
// One listener covers every username link in the app, so templates don't need to
// opt in. Cards are cached per username; the popover stays open while the pointer
// is over the link or the card itself.

const OPEN_DELAY = 350; // ms before a card appears on hover
const CLOSE_DELAY = 200; // ms grace period to move pointer into the card
const cache = new Map();

let popover = null;
let currentLink = null;
let openTimer = null;
let closeTimer = null;

function csrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
}

// Skip cards on coarse-pointer (touch) devices, where hover is unreliable.
const hoverCapable =
  window.matchMedia && window.matchMedia("(hover: hover) and (pointer: fine)").matches;

function usernameFromLink(a) {
  // Match /u/<username> exactly (not /u/<username>/card or deeper paths).
  const m = a.getAttribute("href")?.match(/^\/u\/([^/?#]+)\/?$/);
  return m ? decodeURIComponent(m[1]) : null;
}

async function fetchCard(username) {
  if (cache.has(username)) return cache.get(username);

  const res = await fetch(`/u/${encodeURIComponent(username)}/card`, {
    headers: { accept: "application/json", "x-csrf-token": csrfToken() },
    credentials: "same-origin",
  });
  if (!res.ok) throw new Error(`card ${res.status}`);
  const { user } = await res.json();
  cache.set(username, user);
  return user;
}

function relTime(iso) {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  const secs = Math.round((Date.now() - then) / 1000);
  const units = [
    ["a", 31536000],
    ["mes", 2592000],
    ["d", 86400],
    ["h", 3600],
    ["min", 60],
  ];
  for (const [label, size] of units) {
    const n = Math.floor(secs / size);
    if (n >= 1) return `hace ${n}${label}`;
  }
  return "ahora mismo";
}

function fmtNum(n) {
  return (n || 0).toLocaleString();
}

const esc = (s) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );

// min-w-0 lets the value truncate instead of forcing the grid column wider than
// its share; without it a long value ("hace 46min") pushed into its neighbour.
// The title attribute keeps the full text reachable when it does truncate.
function statCol(label, value) {
  return `<div class="flex flex-col min-w-0">
    <span class="text-[11px] uppercase tracking-wide text-muted truncate">${esc(label)}</span>
    <span class="text-sm font-semibold text-heading tabular-nums truncate" title="${esc(value)}">${esc(value)}</span>
  </div>`;
}

// Compact date: toLocaleDateString() renders a full four-digit year
// ("7/12/2026") which doesn't fit a stat column. Two-digit year keeps it short.
function shortDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (isNaN(d)) return "—";
  return d.toLocaleDateString(undefined, {
    day: "numeric",
    month: "numeric",
    year: "2-digit",
  });
}

function cardHTML(u) {
  const avatar = u.avatar_url
    ? `<img src="${esc(u.avatar_url)}" alt="" class="w-14 h-14 rounded-full object-cover" />`
    : `<div class="w-14 h-14 rounded-full bg-accent flex items-center justify-center text-xl font-bold text-white">${esc(
        u.initials
      )}</div>`;

  // No ring here: the glow is reserved for the profile page. The card still
  // states the status for screen readers.
  const online = u.online ? `<span class="sr-only">En línea</span>` : "";

  const location = u.location
    ? `<div class="flex items-center gap-1 text-xs text-muted mt-0.5">📍 ${esc(u.location)}</div>`
    : "";

  const bio = u.bio
    ? `<p class="text-xs text-body leading-relaxed mt-2 line-clamp-2">${esc(u.bio)}</p>`
    : "";

  const badges = (u.badges || [])
    .map(
      (b) =>
        `<span class="inline-flex items-center gap-1 text-[11px] px-1.5 py-0.5 rounded" style="background-color:${esc(
          b.color
        )}20;color:${esc(b.color)}">${esc(b.icon)} ${esc(b.name)}</span>`
    )
    .join("");

  const message = u.can_message
    ? `<a href="${esc(
        u.profile_path
      )}" class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-full bg-accent text-white hover:bg-accent-hover transition-colors">✉ Mensaje</a>`
    : "";

  return `
    <div class="flex items-start gap-3">
      <div class="relative flex-shrink-0">${avatar}${online}</div>
      <div class="min-w-0 flex-1">
        <a href="${esc(u.profile_path)}" class="block text-base font-bold text-heading hover:underline truncate">${esc(
    u.display_name
  )}</a>
        <div class="text-xs text-muted truncate">@${esc(u.username)}</div>
        ${location}
      </div>
      ${message}
    </div>
    ${bio}
    <div class="grid grid-cols-2 gap-x-4 gap-y-2 mt-3 pt-3 border-t border-border">
      ${statCol("Publicó", relTime(u.last_post_at))}
      ${statCol("Se unió", shortDate(u.joined_at))}
      ${statCol("Aplausos", fmtNum(u.cheers))}
      ${statCol("Posts", fmtNum(u.posts_count))}
    </div>
    ${badges ? `<div class="flex flex-wrap gap-1.5 mt-3">${badges}</div>` : ""}
  `;
}

function ensurePopover() {
  if (popover) return popover;
  popover = document.createElement("div");
  popover.className =
    "fixed z-[100] w-72 max-w-[calc(100vw-1rem)] rounded-xl bg-surface border border-border shadow-xl p-4 opacity-0 transition-opacity duration-150 pointer-events-auto";
  popover.style.top = "-9999px";
  popover.style.left = "-9999px";
  popover.addEventListener("mouseenter", () => clearTimeout(closeTimer));
  popover.addEventListener("mouseleave", scheduleClose);
  document.body.appendChild(popover);
  return popover;
}

function position(link) {
  const el = ensurePopover();
  const r = link.getBoundingClientRect();
  const w = el.offsetWidth;
  const h = el.offsetHeight;
  let top = r.bottom + 8;
  if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 8);
  let left = r.left;
  if (left + w > window.innerWidth - 8) left = window.innerWidth - w - 8;
  el.style.top = `${Math.max(8, top)}px`;
  el.style.left = `${Math.max(8, left)}px`;
}

function scheduleClose() {
  clearTimeout(closeTimer);
  closeTimer = setTimeout(close, CLOSE_DELAY);
}

function close() {
  clearTimeout(openTimer);
  currentLink = null;
  if (popover) {
    popover.style.opacity = "0";
    popover.style.top = "-9999px";
    popover.style.left = "-9999px";
  }
}

async function open(link, username) {
  currentLink = link;
  try {
    const user = await fetchCard(username);
    if (currentLink !== link) return; // pointer moved away while loading
    const el = ensurePopover();
    el.innerHTML = cardHTML(user);
    position(link);
    requestAnimationFrame(() => (el.style.opacity = "1"));
  } catch {
    close();
  }
}

function onOver(e) {
  const link = e.target.closest?.('a[href^="/u/"]');
  if (!link) return;
  const username = usernameFromLink(link);
  if (!username || link === currentLink) return;
  clearTimeout(closeTimer);
  clearTimeout(openTimer);
  openTimer = setTimeout(() => open(link, username), OPEN_DELAY);
}

function onOut(e) {
  const link = e.target.closest?.('a[href^="/u/"]');
  if (!link) return;
  // Ignore moves that stay within the same link.
  if (link.contains(e.relatedTarget)) return;
  clearTimeout(openTimer);
  scheduleClose();
}

export function initUserCard() {
  if (!hoverCapable) return;
  document.addEventListener("mouseover", onOver);
  document.addEventListener("mouseout", onOut);
  // Close on scroll/navigation so the card never lingers detached from its link.
  window.addEventListener("scroll", close, { passive: true });
  window.addEventListener("phx:page-loading-start", close);
}
