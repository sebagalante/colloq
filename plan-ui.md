# Colloq — UI Completion Plan

Status assessment and prioritized work to make the UI usable. Written 2026-07-10
after getting the app to compile, boot, serve, and authenticate.

## TL;DR — why it feels "unusable"

The **backend and LiveView plumbing work**, but the app has almost no UI chrome:

- **No global navigation.** `app.html.heex` is a bare `<main>`; `root.html.heex` is
  just `<%= @inner_content %>`. There is no header, nav bar, logo, user menu, or
  login/logout link **anywhere** in the app. You cannot move between sections
  except by typing URLs.
- **No auth entry point.** The homepage has no "Sign in / Register" links, so
  there's no visible way to log in.
- **Sparse content.** Only categories/bots/players/admin are seeded — no topics —
  so the forum looks empty even when working.
- **Form bugs (partially fixed).** Several forms crashed on input due to a
  form-namespace mismatch (see P0.3). Login / forgot-password / reset-password are
  fixed; others still need auditing.
- **Missing assets.** `favicon.ico` and `/icons/icon-192.png` 404 (referenced by
  the layout/manifest). PWA service worker is currently a dev kill-switch.

Net effect: pages render and LiveView connects, but there is nothing to click that
navigates, and it looks broken. This plan fills in the missing UI layer.

---

## What already exists (reuse these)

**Layouts:** `lib/colloq_web/components/layouts/{root,app}.html.heex` (both nearly empty).

**Components** (`lib/colloq_web/components/core_components.ex`):
`badge`, `button`, `card`, `error`, `flash`, `flash_group`, `goal_alert`, `input`,
`match_score_pin`, `modal`, `reaction_bar`, `textarea`.
Icons: `lib/colloq_web/components/lucide.ex` — `<Lucide.icon name="..." />`.

**Design tokens already defined** in `assets/css/app.css` `:root` (dark) + light theme:
`--bg`, `--surface`, `--surface-alt`, `--text-heading`, `--text-muted`, `--accent`,
`--accent-hover/-muted/-soft/-border`, `--border`, `--border-hover`. Tailwind maps
these to classes (`bg-surface`, `text-heading`, `text-muted`, `bg-accent`, etc.) in
`assets/tailwind.config.js`. **Use these tokens — do not hardcode hex colors.**

**Pages that exist** (routes; all render, most lack chrome):
- Public: `/` forum index, `/c/:slug` category, `/t/:id[/:slug]` topic,
  `/register`, `/login`, `/2fa`, `/forgot-password`, `/reset-password`,
  `/comparar` player comparison, `/predicciones` predictions.
- Authed: `/messages`, `/messages/:id`, `/u/:username` profile, `/settings`,
  `/bookmarks`, `/forum/new`.
- Admin: `/admin` dashboard, `/admin/users`, `/admin/categories[/new|/:id/edit]`,
  `/admin/automations`, `/admin/bots`, `/admin/badges`, `/admin/settings[/llm|/x_feed]`.

---

## Design north star: Discourse

Colloq already mirrors Discourse's **data model** (trust levels 0–4, categories,
tags, badges, flags/moderation, reactions, bookmarks, PMs, bots) — so Discourse is
the natural UI reference. Adopt these patterns (modern Discourse + the 2025
"Horizon" direction), adapted to our dark-first tokens:

**App shell (Horizon-style):**
- **Left sidebar navigation** (sticky, ≥768px; collapsible to a hamburger on mobile;
  option to move right). Sections: **Categories** (with the colored category dots we
  already store in `category.color`), **Tags**, **Messages**, plus custom links
  (Predicciones, Comparar). This is now Discourse's primary nav — prefer it over a
  pure top navbar. Configurable default for logged-out visitors.
- **Top header:** logo (home) · **search exposed in the header** (not hidden behind an
  icon) · notifications bell with count · user avatar menu. Rounded corners, spacious.
- **User avatar menu:** Notifications, Replies, Mentions, Bookmarks, Messages,
  Preferences (`/settings`), Admin (gated), Log out.

**Topic list (simplified Horizon card/row):** show only the essentials —
**author avatar (OP), title, category badge (colored dot), tag chips, reply count,
last poster + relative time, and a "Hot" indicator** for active topics. Provide the
classic nav tabs above the list: **Latest / New / Unread / Top / Categories**.
Larger reading font, generous spacing.

**Category page:** category header (name, colored accent from `category.color`,
description, subcategory chips) above the filtered topic list. We already route
`/c/:slug`.

**Topic page:** original post pinned at top, replies below; **right-side topic
timeline / progress scrubber** (jump-to-post, "X / N posts", last-activity date);
**docked composer** at the bottom (resizable, markdown + live side-by-side preview,
category/tag pickers) — we already have the TipTap `TiptapEditor` hook; reactions via
`reaction_bar`; per-post menu (reply, quote, bookmark, flag, share `#post-<id>`);
**"Suggested / related topics"** list at the bottom.

**Trust levels & badges in the UI:** show the user's trust level and badges on
`/u/:username` and next to usernames (flair). Gate actions by trust level (we already
seed TL0–4 with `can_*` limits) and surface locked actions with a hint.

**Notifications:** header bell → dropdown grouped list (replies, mentions, likes,
messages) with unread counts; a full `/notifications` page.

**Admin:** Discourse-style **admin left sidebar** grouping sections (see P2).

**Theming:** Discourse Horizon derives the whole palette from one base color via
`oklch()`. We already have a token system (`--accent`, `--surface`, …) — keep it, but
consider driving accents from a single seed color and add the light/dark toggle (P3).

Sources: [Using the Discourse sidebar](https://meta.discourse.org/t/using-the-discourse-sidebar/258478),
[Introducing admin sidebar navigation](https://meta.discourse.org/t/introducing-admin-sidebar-navigation/289281),
[How We Built Horizon](https://blog.discourse.org/2025/10/how-we-built-horizon-with-design-driven-development/).

---

## P0 — Critical (app is unusable without these)

### P0.1 Global navigation / app shell (Discourse-style) — ✅ DONE (v1)
Built `lib/colloq_web/components/navigation.ex` (`app_header/1` + `sidebar/1`),
imported into `ColloqWeb.Layouts`, and rebuilt `app.html.heex` as header + left
sidebar + main. Logout route `get "/logout"` → `SessionController.delete` added.
Verified: logged-out shows Log in / Sign up; logged-in shows avatar menu (Profile,
Messages, Bookmarks, Settings, Admin [permission-gated], Log out); sidebar lists
categories with colored dots. Remaining polish below.

- [x] `app_header` — logo, search box (placeholder → `/` for now), messages icon,
      user avatar menu (JS.toggle dropdown) / Log in + Sign up when logged out.
- [x] `sidebar` — Forum / Predictions / Compare / Messages / Bookmarks + Categories
      (colored dot from `category.color`). Collapsible via hamburger < 768px.
- [x] Logout route + `SessionController.delete` (drops session).
- [x] `app.html.heex` shell wired; relies on `on_mount` assigns (P0.2).
- [ ] Wire search to a real search results page (currently a placeholder link).
- [ ] Add a notifications **bell** with unread count (needs notifications UI).
- [ ] Polish mobile sidebar toggle (overlay/backdrop, close on navigate).

<details><summary>Original task breakdown</summary>

- [ ] Create `lib/colloq_web/components/navigation.ex`:
      - `<.app_header current_user={@current_user} />` — logo → `~p"/"`, a search
        input **exposed in the header**, notifications bell (count), and the user
        avatar menu (or "Iniciar sesión" / "Registrarse" when logged out).
      - `<.sidebar current_user={@current_user} categories={@categories} />` — sticky
        left nav: **Categories** (colored dot from `category.color` → `~p"/c/:slug"`),
        Tags, Messages (`/messages`), Guardados (`/bookmarks`), plus custom links
        (Predicciones, Comparar). Collapsible to a hamburger < 768px.
      - User avatar dropdown → Perfil (`/u/:username`), Mensajes, Guardados,
        Preferencias (`/settings`), Admin (only if
        `Colloq.Permissions.can?(@current_user, :view_dashboard)` or `:view_users`),
        "Cerrar sesión".
- [ ] Add a **logout** route + action: `delete "/session"` → `SessionController.delete`
      (`configure_session(conn, drop: true)` / `clear_session` + redirect `/`).
      There is currently no logout path at all.
- [ ] Update `app.html.heex` to the shell layout: header on top, sidebar left,
      `@inner_content` in the main column. Needs `@current_user`/`@categories` on
      connected mounts — see P0.2 (load `categories` in the shared `on_mount`).
- [ ] Mobile: hamburger toggles the sidebar (LiveView JS or a small hook).

</details>

### P0.2 Make `@current_user` reliably available to every LiveView — ✅ DONE
- [x] Wired `on_mount {ColloqWeb.UserAuth, :default}` globally via the `live_view`
      macro in `colloq_web.ex` (simpler than per-route `live_session`; auth is still
      enforced by the router pipelines). `on_mount/4` now uses the safe `get_user/1`,
      sets `@current_user`, `@locale`, `@theme`, and `assign_new(:categories, …)`.
- [x] Verified navbar renders on disconnected (curl) and connected (ws join) renders.
- [ ] TODO cleanup: remove now-redundant per-LiveView user loading in individual mounts.

### P0.3 Audit & fix form-namespace crashes (systemic) — ✅ DONE
Forms built with `to_form(%{...string map...})` **without `as:`** but whose
`handle_event` matches `%{"user" => ...}` (etc.) crash and lock the inputs.

- [x] `login`, `forgot_password`, `reset_password` — added `as: :user`.
- [x] `admin_live/categories.ex` — added `as: :category` to `assign_form`.
- [x] `admin_live/badges.ex` — added `as: :badge` to `assign_form`.
- [x] Audited the rest: `automations`/`bots` use explicit `name="automation[…]"` /
      `name="bot[…]"` inputs (match handlers); `settings`/`llm_settings`/`x_feed_settings`
      use top-level keys that match; `user_live/settings` matches `%{}`; `registration`
      uses `to_form(changeset)` (auto-namespaced). All correct.
- [ ] TODO: add regression tests submitting `validate`/`save` for each form.

### P0.4 Seed sample content so the app isn't empty — ✅ DONE
- [x] Extended `priv/repo/seeds.exs` with 6 sample topics across all categories, each
      with 1–2 replies (10 posts total), guarded by `Topic count == 0`.
- [x] Fixed two real bugs found while seeding:
      - `Forum.create_topic` never set `posts_count`/`last_post_id` (forum showed
        "0 comentarios"; replies collided on `post_number`) — now sets them.
      - `Topic` schema was missing the `bumped_at` field (column existed) — added it
        to the schema + changeset, so `create_post`'s bump no longer raises.
- [x] Also fixed the recurring `ColloqWeb.Telemetry.VM.run_queue_lengths` `:badarg`
      log spam (invalid `:total_run_queue_lengths_cpu/_io` stat keys).

---

## P1 — Core usability

### P1.1 Forum index — Discourse topic list (`live/forum_live/index.html.heex`)
> **Status:** Verified working — the template already renders Discourse-style rows
> (OP avatar, category badge, tags, reply count, relative time), category filter
> chips, empty state, pagination, and the new-topic modal. Now populated by the
> seeded topics (P0.4). Remaining below is polish (nav tabs, last-poster, Hot).
- [ ] Replace the current layout with a **Horizon-style topic row/card**: OP avatar,
      title, category badge (colored dot), tag chips, reply count, last poster +
      relative time, and a "Hot" indicator for active topics.
- [x] Added **Latest / Top** sort tabs (URL-driven `?order=top`). Backend:
      `Forum.list_topics` now takes `:order` (`:latest` = pinned+bumped_at,
      `:top` = pinned+views+bumped_at) and preloads `last_post: :user`.
- [x] Topic row enriched: **🔥 Hot** badge (posts_count ≥ 3), correct reply count
      (`posts_count - 1`), and **last poster** (shown when ≠ OP author).
- [x] Empty state + pagination already present.
- [ ] New/Unread tabs (need per-user read-state tracking — deferred).
- [ ] Larger reading font + spacing tuning (kept theme/CSS untouched per request).

### P1.2 Topic page — Discourse topic view (`live/forum_live/topic.html.heex`)
> **Status:** Fixed a crash that 500'd *every* topic page — the `reaction_bar`
> component read `@quick_emojis` as an assign when it's a module attribute; now
> assigned in the component. Topic pages render, and logged-in users see the reply
> form (verified). The template already has header, post list, reply composer, poll
> form, reactions, and topic-summary. Remaining below is polish.
- [ ] Layout: OP pinned at top, replies below, each with avatar, name + flair/trust,
      relative time, reactions (`reaction_bar`), and a per-post menu (reply, quote,
      bookmark, flag, share `#post-<id>`).
- [ ] **Right-side topic timeline / progress scrubber**: "X / N posts", jump to
      top/bottom, last-activity date (Discourse's signature interaction).
- [ ] **Docked composer** at the bottom for replies (TipTap `TiptapEditor` hook),
      with live preview; "Log in to join" gate when logged out (already present).
- [ ] **Suggested / related topics** list at the bottom.
- [ ] Confirm `#post-<id>` fragment anchoring works (see `bookmarks` link fix).

### P1.3 Auth pages consistency — ✅ mostly done
- [x] Cross-links already present: login → register + forgot; register/forgot/reset →
      login. All auth pages use inline `render/1` with a centered card. Verified 200.
- [ ] Polish: unify the exact card styling + shared logo header across all five.
- [ ] Wire OAuth buttons (`/auth/:provider`) into login/register when providers exist.
- [ ] Cleanup: each auth page has an unused `.html.heex` (render/1 wins) → "ignoring
      template" warnings. Delete the dead `.heex` files.

### P1.4 User-facing pages — ✅ render verified
- [x] All render 200 (logged-in): `/u/admin`, `/settings`, `/messages`, `/bookmarks`,
      `/predicciones`, `/comparar`, `/forum/new`. No crashes.
- [x] Full-route smoke test: **all 29 routes (public + authed + admin) return 200/302.**
- [ ] Polish (content/UX, not crashes): profile header (avatar, flair, trust, badges),
      messages thread UI, settings save confirmation, bookmarks empty state.

### P1.5 Missing assets (kills console noise + PWA) — ✅ DONE (v1)
- [x] Added `priv/static/favicon.svg` (◆ Colloq mark) + `icons/icon.svg`; repointed
      `root.html.heex` (`rel="icon"` + apple-touch) and `manifest.json` to the SVG.
      All 404s (favicon.ico, icon-192/512.png) gone. (SVG since no PNG tooling here;
      swap for PNGs if you want broader PWA install support.)
- [x] Added `favicon.svg` to `static_paths` so Plug.Static serves it.
- [ ] PWA story: `sw.js` is a dev kill-switch; original saved as `sw.js.pwa-backup`.
      Restore + keep the localhost guard for prod when ready.

---

## P2 — Admin UI — ✅ DONE (v1)

- [x] Admin nav: added a permission-gated **"Administration"** section to the sidebar
      (`navigation.ex`) linking Dashboard, Users, Categories, Badges, Bots, Automations,
      Settings — each `:if={Permissions.can?(...)}`, hidden for non-admins. Admin pages
      are now reachable without typing URLs.
- [x] Fixed crashes: `/admin/bots` + `/admin/automations` were 500'ing because the
      `textarea` component's `id`/`name`/`value` attrs had no defaults (KeyError on
      `@id`). Gave them defaults + FormField support; also let `input`/`textarea` pass
      `min/max/step/rows/placeholder` through `:rest`. All 8 admin pages now 200.
- [x] `/admin/categories`: CRUD reachable + `as: :category` fix (P0.3). **Original
      request delivered** — mods can manage categories.
- [ ] Polish: dedicated admin layout (vs. sidebar section), `/admin/users` search +
      moderation actions, empty/confirm states.

---

## P3 — Polish

- [ ] Component library gaps: `avatar`, `dropdown`/menu, `pagination`, `tabs`, `tooltip`,
      `table`, `empty_state`, `spinner`/skeleton loaders.
- [ ] Discourse-specific components: `topic_list_item` (Horizon row/card),
      `topic_timeline` (progress scrubber), `sidebar` + `sidebar_section`,
      `notification_menu`, `docked_composer`, `category_badge` (colored dot),
      `user_card` (hover preview), `trust_level_badge`.
- [ ] Loading & disconnected states (LiveView `phx-loading` styling; there's currently
      no `.phx-*` CSS in `app.css`).
- [ ] Light/dark theme toggle in the navbar (tokens already support both; wire the
      `data-theme` switch + persist to `user.theme`).
- [ ] Responsive/mobile pass (hamburger menu for the navbar).
- [ ] Accessibility: focus states, aria labels, keyboard nav for dropdowns/modals.
- [ ] i18n: many strings are hardcoded Spanish; route them through `gettext`.

---

## Suggested execution order

1. **P0.2** (on_mount wiring) → **P0.1** (navbar + logout) — unblocks navigation & auth.
2. **P0.3** (form audit) — makes every form actually usable.
3. **P0.4** (seed content) — makes the app demonstrable.
4. **P1.5** (assets) — quick, removes console errors.
5. **P1.3** (auth pages) → **P1.1/P1.2** (forum) → **P1.4** (user pages).
6. **P2** (admin shell) → **P3** (polish).

## Notes / conventions

- Reuse existing components and the CSS token classes; match the dark-first theme.
- Gate admin/mod UI with `Colloq.Permissions.can?/2` — do not hardcode roles.
- After each form change, drive it end-to-end (join + `validate`/`save`) — the
  form-namespace bug is invisible to compile and only shows at runtime.
- Keep the service worker disabled on localhost (`assets/js/app.js`) to avoid the
  stale-cache trap during development.
