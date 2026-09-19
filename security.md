# Security Review — Colloq

Findings from a review of the Colloq codebase (Elixir/Phoenix forum application).

## Critical

### 1. Predictable fallback secrets → session/token forgery — ✅ FIXED 2026-07-23

**Files:** `config/runtime.exs:9`, `lib/colloq_web/endpoint.ex:8`, `config/config.exs:42`

- `secret_key_base` falls back to a hardcoded string if env var unset, even in prod (the `System.get_env("DEV_SECRET_KEY_BASE", "dev-dev-…")` chain only errors when you call `fetch_env!`, which isn't used here).
- `PHX_SESSION_SIGNING_SALT` defaults to `"colloq2024"`.
- LiveView `signing_salt` defaults to `"todo-change-me"`.

If any of these are unset in prod, an attacker can forge `Phoenix.Token`s — and the entire login flow is `Phoenix.Token.verify("login", token)` (`session_controller.ex:49`). Forge a login token for `user_id: 1` and you're super admin.

**This was worse than originally written.** Two of the three could not be set in
prod at all:

- `endpoint.ex:8` read the env var inside a **module attribute** — evaluated at compile time.
- `config.exs:42` did the same, and `config.exs` is compile-time config; only `runtime.exs` is read at boot.

So in a release both salts were whatever the *build* environment had, and
exporting them on the prod host did nothing — the defaults `"colloq2024"` and
`"todo-change-me"` shipped inside the artifact. `fetch_env!` alone would not
have fixed this; the reads had to move.

**Fix applied:**

- All three secrets are now read in `runtime.exs` only, and raise in `:prod` when unset (dev/test keep their fallbacks). `SECRET_KEY_BASE` is additionally rejected below 64 bytes.
- `endpoint.ex` exposes `session_options/0`, which fetches the salt from app env per request; `plug :session` inits `Plug.Session` at runtime instead of freezing options at compile time.
- The LiveView socket's `connect_info` takes the `{Endpoint, :session_options, []}` MFA form, which `Phoenix.Socket.Transport` resolves at connect time.

**Deploy note:** there is no prod environment yet, so nothing was exposed and
there is nothing to rotate. This fix is preventive: it closes the trap *before*
the first deploy, when exporting the salts on the host would have silently done
nothing and the git-public defaults would have shipped inside the release.

When prod is stood up, all three (`SECRET_KEY_BASE`,
`PHX_SESSION_SIGNING_SALT`, `PHX_LIVE_SIGNING_SALT`) must be present or the app
refuses to boot — see `.env.example`. Generate each with `mix phx.gen.secret`.
If the salts are ever rotated after launch, existing session cookies are
invalidated and every user is logged out once.

### 2. Stored XSS via SVG / content-type–extension mismatch

**File:** `lib/colloq_web/controllers/upload_controller.ex:53-59`

- `@allowed` includes `image/svg+xml`. SVG can carry `<script>` and `onload`.
- `validate/1` trusts the client-supplied `content_type`, but `store/1` keeps the original **filename extension**. Upload `evil.svg` with `Content-Type: image/png` → passes validation, stored as `…svg`, served by Plug.Static (same-origin, see `static_paths` → `uploads`) as `image/svg+xml` → executes JS in the forum origin.
- `html_sanitize_ex` sanitizes *post bodies*, not uploaded asset content.

**Fix:** Drop `image/svg+xml` from the allow-list, validate magic bytes (e.g. `ExMagick`/`file`), or serve uploads from a sandbox origin with `Content-Disposition: attachment`.

## High

### 3. SSRF via link unfurling / validation — ✅ FIXED 2026-09-19

**Files:** `lib/colloq/workers/embed_worker.ex:217`, `lib/colloq/workers/link_validator_worker.ex:63`

- URLs extracted from user posts are fetched server-side with `Req.get(url, …)` / `Req.head`. No scheme/host allow-list, no private-IP filter.
- `http://169.254.169.254/latest/meta-data/…` (cloud metadata), `http://localhost:4000/admin/…`, `http://10.0.0.1/` are all reachable. Response content (title/description) is stored and shown, so it's **semi-blind** — internal responses can leak into embed cards.
- The embed worker also runs per post, so any poster triggers it.

**Fix applied:** new `Colloq.HttpGuard` (`lib/colloq/http_guard.ex`) — rejects non-http(s) schemes, blocked hostnames (localhost/.local/.internal), and any host that resolves to a private/loopback/link-local/CGNAT/multicast/reserved address (IPv4 and IPv6, including IPv4-mapped). DNS is resolved up front so hostnames pointing at internal IPs are caught. Wired into `EmbedWorker.fetch_og/1` (unsafe URL → no preview card) and `LinkValidatorWorker.validate_url/1` (unsafe URL → reported dead, never fetched). Known residual risk (documented in the module): redirects followed by `Req` are not re-checked.

### 4. Open redirect — ✅ FIXED 2026-09-19

**File:** `lib/colloq_web/controllers/link_controller.ex:8-13`

- `@allowed_domains` is `[]`, and the code treats empty as "allow all http/https" → `/go?url=https://attacker.com` is a clean redirector for phishing, and it's on your domain so it passes reputation checks.

**Fix applied:** fail-closed — an empty effective allow-list disables `/go` entirely (`host in []` is always false; the old `Enum.empty?` special case is gone). The allow-list is now read per request from the `allowed_redirect_domains` site setting (comma-separated, exact host match, replaces the module default) so admins can re-enable the feature deliberately.

### 5. Weak CSP — ✅ FIXED 2026-09-19

**File:** `lib/colloq_web/router.ex:24`

- `script-src 'self' 'unsafe-inline' 'unsafe-eval'`. `unsafe-inline` + `unsafe-eval` defeats most XSS mitigations and pairs badly with the SVG vector above.

**Fix applied:** `ColloqWeb.Plugs.SecureHeaders` (`lib/colloq_web/plugs/secure_headers.ex`) now sets browser security headers with a **per-request nonce** in prod: `script-src 'self' 'nonce-…' <twitter hosts>` — both `unsafe-*` dropped. The nonce reaches LiveView via `csp_nonce_assign_key: {:conn, :csp_nonce}` on the `/live` socket (endpoint.ex) and the root layout script tag gets `nonce={@csp_nonce}`. Dev/test keep the previous permissive policy (live-reload injects unsigned inline scripts). Deploy note: any new inline script in prod needs the nonce attribute or the browser blocks it (fails loudly in console).

## Medium

### 6. Unauthenticated `/api/v1` endpoints — ✅ FIXED 2026-09-19

**File:** `lib/colloq_web/router.ex:139-145`

- The `:api` pipeline is `accepts + fetch_session` only — no `fetch_current_user`, no CSRF, no API key. `POST /api/v1/automations/:id/trigger` is reachable by anyone (currently a stub, but the docstring says "used by webhook integrations" — it'll get implemented without auth unless gated now).
- `POST /api/v1/push/subscribe` likewise.

**Fix applied:** the `:api` pipeline now requires `Authorization: Bearer <API_V1_TOKEN>` via `ColloqWeb.Plugs.RequireApiToken` (constant-time compare, fail-closed when the token env var is unset). The session was removed from that pipeline on purpose — cookie-session JSON routes without CSRF are CSRF-able; nothing in the frontend calls these routes (push subscribe goes through the LiveView `push-subscribe` event, which no LiveView handles — dead code). Token documented in `.env.example`.

### 7. Login rate limit is per-email only — ✅ FIXED 2026-09-19

**File:** `lib/colloq/accounts.ex:139-161`

- `Cachex` key is `login_attempts:<email>`. Attacker rotates email or targets many accounts per IP. Cache is in-memory and resets on restart, also letting a crashed node clear limits.

**Fix applied:** `authenticate_user/3` (new optional `ip` argument, passed by the login LiveView, resolved through the same trusted-proxy chain as registration) now keeps a second bucket — max 20 failed attempts per IP per 15 minutes alongside the existing 5 per email. Both buckets bump on every failure; a successful login clears only the email bucket, so an attacker's IP budget isn't reset by one lucky guess. The in-memory persistence caveat stands (see below).

### 8. Chat attachment upload accepts any type up to 15 MB — ✅ FIXED 2026-09-19 (with #2)

**File:** `lib/colloq_web/controllers/upload_controller.ex:33-47`

- `attachment/2` validates only size. Combined with the extension-from-filename behaviour, a `evil.html`/`evil.svg` attachment stored locally is served same-origin and executable.

**Fix:** Same as #2 — magic-byte validation + sandbox origin/`Content-Disposition: attachment`.

**Fixed together with #2:** the chat attachment path no longer exists; `UploadController` validates by magic bytes (`Colloq.Media.Sniff`) and uploads get sandbox CSP + `nosniff` + `Content-Disposition: attachment` (`ColloqWeb.Plugs.UploadHeaders`). See #2.

## Low / hygiene

- **OAuth callback stores `user.id` (integer) directly** while `SessionController.create` stores `to_string(user_id)` (`auth_controller.ex:48` vs `session_controller.ex:54`). Both work today but the inconsistency is a future-bug trap.
- **OAuth account creation doesn't verify provider-verified email against existing local accounts** beyond `unique_constraint`. A pre-registered local account with the victim's email blocks the victim's OAuth login; or an attacker controlling a permissive OAuth provider can squat an email. Consider matching on `(provider, uid)` only (already done) and never auto-linking to password accounts.
- ~~**`dev.exs` loads `.env` via naive `String.split("=")` parser**~~ — **incorrect, retracted.** `config/dev.exs:17` is `String.split(line, "=", parts: 2)`; `parts: 2` keeps everything after the first `=`, so base64 keys and URLs with query strings survive intact. Nothing is truncated.
- **`erl_crash.dump` (7.6 MB) present in the repo root.** It's gitignored so not tracked, but crash dumps contain process memory — secrets included. Rotate any secrets that were live at crash time and delete the file.
- **Password policy** is min 8, no complexity / breach-list check (`user.ex:146-150`). Consider `HaveIBeenPwned` or zxcvbn.
- **`HtmlSanitizeEx.html5()` is applied in `render_body`** (good) but the post body is stored as rendered HTML, not sanitized at write time — any future renderer change or caching path that bypasses `render_body` re-exposes stored markup. Consider sanitizing on write as defense-in-depth.
- **`core_components.ex:599` / `:848`** use `Phoenix.HTML.raw(html)` — verify those `html` inputs are static/builder-generated, not user-controlled (the few skimmed looked fine; the `emoji_display` path at `:659` uses admin-validated emoji URLs).
- **Session cookie lacked `Secure`/`HttpOnly`** — ✅ FIXED 2026-09-19. `Endpoint.session_options/0` now adds `secure: true` and `http_only: true` in prod (dev keeps defaults for plain http://localhost); the stale comment claiming runtime.exs set them is gone.
- **AI topic summary scrubbed with `basic_html`** — ✅ FIXED 2026-09-19. `topic.html.heex:777` now uses the same `html5` scrubber as post bodies; the summary is LLM output distilled from user posts, so it's attacker-influenceable and gets the strict allowlist.
- **Link validator attributed moderation flags to user id 1 when no "sistema" account exists** — ✅ FIXED 2026-09-19. `find_system_user_id/0` returns nil and the flag is skipped with a warning instead of pinning spam reports on an arbitrary account.
- **Login/2FA tokens ride in GET query strings** (`/session?token=…`). Mitigated by the 120s `max_age`; converting to POST would be the cleaner shape. Not changed.

## Not actually exploitable

- All `fragment(...)` uses parameterize with `^` bind variables — no SQL injection.
- No `System.cmd` / `:os.cmd` / `Code.eval_string` on user input.
- `assign_role/3` correctly enforces rank ordering via `can_assign_role?/3` — no privilege escalation via admin role assignment.
- 2FA is enforced on the `:admin_base` pipeline via `require_2fa_verified`.

## Missed by this review (found separately)

- **Password reset links were valid ~41 days, not 1 hour** — ✅ fixed 2026-07-23. `reset_password.ex:7` passed `:timer.hours(1)` (3_600_000 **milliseconds**) to `Phoenix.Token.verify`'s `max_age`, which is in **seconds**. Now `3600`. Other call sites (`user_socket.ex:52`, `session_controller.ex:49/69/88`) already used plain integers and were unaffected.
- **#6 is more urgent than "a stub."** `AutomationController.trigger/2` is unauthenticated and, once implemented against `Automations.run_automation/1`, would let anyone execute automation scripts (`create_post`, `llm_respond`, `close_topic`). Gate the route before the stub is filled in.

## Suggested fix order

1. ~~**#1** — force-fail on missing prod secrets~~ ✅ done (see above).
2. ~~**#4** — open redirect~~ ✅ done (fail-closed; site setting `allowed_redirect_domains` re-enables).
3. ~~**#2 / #3** — SVG XSS and SSRF~~ ✅ done (Sniff + UploadHeaders; HttpGuard).
4. ~~**#5** — CSP nonces~~ ✅ done (prod only — see deploy note).
5. ~~**#6** — gate `/api/v1`~~ ✅ done (bearer token, fail-closed).
6. ~~**#7** — per-IP login bucket~~ ✅ done (in-memory caveat stands — move to a persistent store for multi-node).
7. Remaining hygiene as listed above.

Remaining known gaps (accepted/documented): SSRF redirect-following residual risk; rate-limit counters not persistent across node restarts; login tokens in GET query strings.
