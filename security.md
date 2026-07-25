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

### 3. SSRF via link unfurling / validation

**Files:** `lib/colloq/workers/embed_worker.ex:217`, `lib/colloq/workers/link_validator_worker.ex:63`

- URLs extracted from user posts are fetched server-side with `Req.get(url, …)` / `Req.head`. No scheme/host allow-list, no private-IP filter.
- `http://169.254.169.254/latest/meta-data/…` (cloud metadata), `http://localhost:4000/admin/…`, `http://10.0.0.1/` are all reachable. Response content (title/description) is stored and shown, so it's **semi-blind** — internal responses can leak into embed cards.
- The embed worker also runs per post, so any poster triggers it.

**Fix:** Resolve the host, reject private/loopback/link-local ranges (RFC 1918, 169.254/16, 127/8, ::1, fc00::/7), and reject non-http(s) schemes.

### 4. Open redirect

**File:** `lib/colloq_web/controllers/link_controller.ex:8-13`

- `@allowed_domains` is `[]`, and the code treats empty as "allow all http/https" → `/go?url=https://attacker.com` is a clean redirector for phishing, and it's on your domain so it passes reputation checks.

**Fix:** Maintain an explicit allow-list, or drop the feature.

### 5. Weak CSP

**File:** `lib/colloq_web/router.ex:24`

- `script-src 'self' 'unsafe-inline' 'unsafe-eval'`. `unsafe-inline` + `unsafe-eval` defeats most XSS mitigations and pairs badly with the SVG vector above.

**Fix:** Use nonces (`csp_nonce_assign_key`) and drop both `unsafe-*`.

## Medium

### 6. Unauthenticated `/api/v1` endpoints

**File:** `lib/colloq_web/router.ex:139-145`

- The `:api` pipeline is `accepts + fetch_session` only — no `fetch_current_user`, no CSRF, no API key. `POST /api/v1/automations/:id/trigger` is reachable by anyone (currently a stub, but the docstring says "used by webhook integrations" — it'll get implemented without auth unless gated now).
- `POST /api/v1/push/subscribe` likewise.

**Fix:** Require a bearer/API token (and CSRF the session-bearing JSON routes, or exclude them from the cookie session).

### 7. Login rate limit is per-email only

**File:** `lib/colloq/accounts.ex:139-161`

- `Cachex` key is `login_attempts:<email>`. Attacker rotates email or targets many accounts per IP. Cache is in-memory and resets on restart, also letting a crashed node clear limits.

**Fix:** Add a per-IP bucket; use a persistent store (Oban/DB) for the lockout counter.

### 8. Chat attachment upload accepts any type up to 15 MB

**File:** `lib/colloq_web/controllers/upload_controller.ex:33-47`

- `attachment/2` validates only size. Combined with the extension-from-filename behaviour, a `evil.html`/`evil.svg` attachment stored locally is served same-origin and executable.

**Fix:** Same as #2 — magic-byte validation + sandbox origin/`Content-Disposition: attachment`.

## Low / hygiene

- **OAuth callback stores `user.id` (integer) directly** while `SessionController.create` stores `to_string(user_id)` (`auth_controller.ex:48` vs `session_controller.ex:54`). Both work today but the inconsistency is a future-bug trap.
- **OAuth account creation doesn't verify provider-verified email against existing local accounts** beyond `unique_constraint`. A pre-registered local account with the victim's email blocks the victim's OAuth login; or an attacker controlling a permissive OAuth provider can squat an email. Consider matching on `(provider, uid)` only (already done) and never auto-linking to password accounts.
- ~~**`dev.exs` loads `.env` via naive `String.split("=")` parser**~~ — **incorrect, retracted.** `config/dev.exs:17` is `String.split(line, "=", parts: 2)`; `parts: 2` keeps everything after the first `=`, so base64 keys and URLs with query strings survive intact. Nothing is truncated.
- **`erl_crash.dump` (7.6 MB) present in the repo root.** It's gitignored so not tracked, but crash dumps contain process memory — secrets included. Rotate any secrets that were live at crash time and delete the file.
- **Password policy** is min 8, no complexity / breach-list check (`user.ex:146-150`). Consider `HaveIBeenPwned` or zxcvbn.
- **`HtmlSanitizeEx.html5()` is applied in `render_body`** (good) but the post body is stored as rendered HTML, not sanitized at write time — any future renderer change or caching path that bypasses `render_body` re-exposes stored markup. Consider sanitizing on write as defense-in-depth.
- **`core_components.ex:599` / `:848`** use `Phoenix.HTML.raw(html)` — verify those `html` inputs are static/builder-generated, not user-controlled (the few skimmed looked fine).

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
2. **#4** — open redirect: two-line fix, or delete the `/go` feature.
3. **#2 / #3** — SVG XSS and SSRF (cheap to patch, high impact).
3. **#4 / #5** — open redirect and CSP.
4. **#6** — gate `/api/v1` before it grows real behaviour.
5. Everything else as hygiene.
