# Colloq — Development Plan & Findings

## Status: WIP (alpha)

This document tracks known issues plus Elixir development best practices to
follow going forward. The original full-file audit (48 numbered items) has been
worked through — those are now under "Resolved" at the bottom. The sections
below list only what is still open.

> Last reviewed: 2026-07-04. Reviewed statically only — this environment has no
> Elixir toolchain, no `deps/`, no `_build/`, and no `mix.lock`, so a clean
> `mix compile` has **not** been confirmed. Verify locally with
> `mix deps.get && mix compile` before relying on this.

---

## Open — Correctness

### A. `predictions_live.ex` — `get_match_title/1` looks up by the wrong key
- **File:** `lib/colloq_web/live/predictions_live.ex` (~line 171)
- **Issue:** `get_match_title(fixture_id)` calls
  `Colloq.Forum.get_topic!(fixture_id)`, passing the external Sofascore
  fixture id (a string, stored on `Topic.match_id`) where a Topic **primary
  key** is expected. It never matches a real topic; the surrounding `rescue`
  silently swallows the failure and always renders the fallback
  `"Match #<id>"` instead of the real match title.
- **Fix:** Look the topic up by its external id, e.g.
  `Repo.get_by(Topic, match_id: fixture_id)` (non-bang), and handle `nil`
  explicitly instead of relying on `rescue`.

### B. `predictions_live.ex` — dead `nil ->` branch on a bang call
- **File:** `lib/colloq_web/live/predictions_live.ex` (~line 172)
- **Issue:** `case Colloq.Forum.get_topic!(...) do nil -> ... ; topic -> ... end`
  — `get_topic!/1` raises on a miss rather than returning `nil`, so the
  `nil ->` clause is unreachable; only the outer `rescue` ever catches a
  missing topic. Confusing and hides intent.
- **Fix:** Once (A) is fixed to use a non-bang lookup, the `nil ->` branch
  becomes meaningful. Otherwise drop the dead clause.

---

## Open — Gaps (not in original audit)

### C. No `mix.lock` committed
- **Issue:** Dependency versions are unpinned. `mix.exs` uses `~>` ranges only;
  without a lockfile, `mix deps.get` can resolve different transitive versions
  on different machines / CI.
- **Fix:** Run `mix deps.get` and commit the generated `mix.lock`.

### D. Thin test coverage
- **Issue:** Only 5 test files (`forum`, `pagination`, `reactions`,
  `sofascore`, `trust`) cover 22 context modules. Untested contexts include
  `accounts`, `messaging`, `moderation`, `notifications`, `predictions`,
  `badges`, `bookmarks`, `bots`, `automations`, `permissions`,
  `push_subscriptions`, `tags`, `site_settings`. This contradicts best-practice
  #31 below.
- **Fix:** Add at least a happy-path + one error-path test per context, using
  the `ExMachina` factory. Prioritise auth (`accounts`), `predictions`
  (scoring), and `moderation`.

### E. No README
- **Issue:** No top-level README. Onboarding relies entirely on `.env.example`
  and the `mix setup` alias. The app has non-obvious moving parts (env-driven
  media adapter, OAuth for 5 providers, VAPID/web-push, Oban queues, systemd
  units under `systemd/`).
- **Fix:** Add a README covering local setup, required env vars, and how to run
  the workers/assets.

---

## Resolved

The full original audit (items 1–35) has been addressed and verified in the
source on 2026-07-04:

**Critical / compile:**
- [x] #1 `predictions_live.ex` renamed to `ColloqWeb.PredictionsLive`
- [x] #2 predictions uses `fixture_id` consistently (no `match_date`/`match_data`)
- [x] #3 push worker uses `if vapid_public && vapid_private` (no `and`-hack)
- [x] #4 `sw.js` cache callbacks are proper `async` functions
- [x] #5 `Colloq.Webhooks.Webhook` schema created; worker uses it
- [x] #6 `000031_create_post_drafts` migration added
- [x] #22 orphaned migrations now have schemas (`embeds`, `webhooks`,
      `chat_messages`, `bot_personas`, `voice_rooms`)

**High:**
- [x] #7 login creates a session via `UserAuth.log_in_user` + `SessionController`
- [x] #8 trust thresholds updated to 10/1 and 50/7
- [x] #9/#10 `ColloqWeb.UserSocket` created and channels wired
- [x] #11 `000029_alter_prediction_column_types` migration aligns types
- [x] #12/#16 leaderboard preload / scorer pattern-match fixed
- [x] #13 `away_score` stores the parsed integer
- [x] #14 fixture digest cache key handling fixed
- [x] #15 `profile.ex` captures the reassigned socket
- [x] #17 player comparison searches `SofascorePlayer`
- [x] #18 `Phoenix.Flash.get/2` replaces deprecated `live_flash`
- [x] #19 `notification_worker` guards `text_body/1` against `nil`
- [x] #20 `llm_responder_worker` no longer assumes a matching user
- [x] #21 `link_controller` validates scheme + domain allowlist

**Medium / low:**
- [x] #23 push worker accepts `team_id` (no hardcoded Racing)
- [x] #24 `runtime.exs` no longer uses `String.to_existing_atom`
- [x] #25 redundant `Colloq.PubSub` config removed
- [x] #26 flash uses a dedicated `attr :on_click, JS` + `phx-click`
- [x] #27 fixture digest stats (`gf`/`gc`/`gd`) now used in output
- [x] #28 `reset_password` uses signed, 1h-expiry `Phoenix.Token`
- [x] #29 `forgot_password` enqueues `PasswordResetWorker` with a signed token
- [x] #30 seeds read `ADMIN_PASSWORD` env and print the generated password
- [x] #31 `admin_live/bots` LLM test is async (`send(self(), ...)` + `handle_info`)
- [x] #32 deprecated `longpoll` removed from endpoint

**Earlier sessions:**
- [x] `phoenix_html_helpers` dep; `config :phoenix, :json_library, Jason`
- [x] `Colloq.Pagination`; `Colloq.Application` at `lib/colloq/application.ex`
- [x] `ColloqWeb.Telemetry` in the supervision tree
- [x] Nested replies; reactions; asset pipeline; multi-team Sofascore
- [x] Trust levels redesigned; VpnOnly IPv6; env-configurable signing salt

**Deferred style nits (optional):**
- #33 mixed Spanish/English moduledocs — standardise on Spanish.
- #34 `lib/colloq.ex` is a near-empty shell — keep or remove.
- #35 document all valid `Post.system_type` values in the schema moduledoc.

---

## Elixir development best practices

### Project structure

1. **One module per file.** File paths mirror module names:
   `Colloq.Forum.Post` → `lib/colloq/forum/post.ex`.
2. **Context modules** (`lib/colloq/forum.ex`) are the public API. Schemas
   (`lib/colloq/forum/post.ex`) are internal. Controllers/LiveViews should
   never call schema functions directly — always go through the context.
3. **Keep `lib/colloq.ex`** as the domain boundary or remove it entirely.
   Don't leave empty shell modules.
4. **Workers** belong in `lib/colloq/workers/`. Each worker should have a
   clear `@moduledoc` explaining its queue, cron schedule, and max_attempts.

### Schemas and migrations

5. **Migration field types must match schema field types.** Audit before
   running `ecto.migrate`. A mismatch will cause runtime crashes on insert
   or query.
6. **Never use `:integer` for IDs that come from external APIs as strings.**
   Use `:string`. API-Football and Sofascore both use string/numeric IDs.
7. **Every `belongs_to` should have a matching `references` in the migration.**
   Every `has_many` should have a matching index on the foreign key.
8. **Add `on_delete` to every `references`.** `:delete_all` for children that
   don't make sense without a parent; `:nilify_all` for optional associations.
9. **Timestamps:** use `:utc_datetime_usec` consistently (already set via
   `config :colloq, generators: [timestamp_type: :utc_datetime_usec]`).
10. **Never hardcode data in schemas or contexts.** Use seeds or API fetching.
    (We removed the hardcoded Racing squad for this reason.)

### Contexts

11. **Contexts return tagged tuples:** `{:ok, result}`, `{:error, reason}`.
    Never return bare values or `nil` from public context functions.
12. **Validate cross-references in the context, not the schema.**
    `Forum.create_reply/4` checks `parent_post.topic_id == topic.id` — this
    belongs in the context, not the changeset, because it requires loading
    another record.
13. **Don't preload in every function.** Provide a `!` variant or an explicit
    `preload:` option. `get_topic!/1` preloads posts because it's always
    used in the UI; `get_post!/1` preloads `:user` and `:topic` for the same
    reason. Other functions should be lean.
14. **Use `Repo.transaction` for multi-step operations.** If a function
    inserts a topic + a post + updates a counter, wrap it in a transaction
    so a failure rolls everything back.

### LiveView

15. **Always capture the result of `if`/`case` blocks that reassign `socket`.**
    The bug pattern:
    ```elixir
    # BAD — socket is reassigned inside if but not captured
    if connected?(socket) do
      socket = load_data(socket)
    end
    {:ok, socket}  # ← original socket, data not loaded

    # GOOD
    socket =
      if connected?(socket) do
        load_data(socket)
      else
        socket
      end
    {:ok, socket}
    ```
16. **Load current_user via `on_mount` callback, not manually in every
    LiveView.** Define `on_mount(:default, ...)` in `UserAuth` and use it
    in the router:
    ```elixir
    live "/t/:id", ForumLive.Topic, :show
      # on_mount handled by pipeline, not per-LiveView
    ```
17. **Reload data after mutations, don't append to lists.** When a new post
    is created, call `Forum.get_topic!/1` again rather than
    `socket.assigns.posts ++ [post]`. This ensures associations are preloaded
    and nested structures are correct.
18. **Function components with `attr` belong in component modules, not
    LiveView modules.** If a component is used only in one LiveView, it's OK
    there, but if it's recursive or complex, move it to
    `ColloqWeb.CoreComponents` or a dedicated component module.
19. **Don't call context functions synchronously in `handle_event` if they
    make HTTP calls.** Use `send(self(), {:result, ...})` + `handle_info`,
    or enqueue an Oban job and subscribe to PubSub.
20. **Always pass all required assigns to function components.** If a
    component uses `@reaction_data`, it must be in the `attr` list and
    passed by the caller.

### Workers (Oban)

21. **Workers must handle all expected arg shapes.** Use pattern matching
    in `perform/1` with multiple clauses. Add a fallback clause that
    returns `{:error, "unknown action"}`.
22. **Use `{:snooze, seconds}` for rate-limited APIs**, not `{:error, ...}`.
    Snooze retries without consuming an attempt.
23. **`max_attempts` should reflect the cost of the job.** Idempotent
    notifications: 3 attempts. Destructive operations: 1 attempt. External
    API calls with backoff: 5 attempts.
24. **Never hardcode team IDs in workers.** Use `Colloq.Sofascore.teams/0`
    or accept `team_id` in job args.
25. **Workers should not reference modules that don't exist.** If a worker
    needs a schema, create the schema first. `Colloq.Webhook` is referenced
    but doesn't exist.

### Security

26. **Never accept arbitrary external URLs for redirect.** Validate against
    an allowlist or only allow relative paths. (`link_controller.ex`)
27. **Password reset tokens must be signed and time-limited.** Use
    `Phoenix.Token.sign(Endpoint, secret, data)` and
    `Phoenix.Token.verify(Endpoint, secret, token, max_age: :timer.hours(1))`.
28. **Sanitize all user-generated HTML on write AND on render.**
    `HtmlSanitizeEx.basic_html/1` is used in both `Post.changeset` and
    `render_body/1` — keep both as defense in depth.
29. **Session signing salts must come from env vars, not be hardcoded.**
    (Fixed: `PHX_SESSION_SIGNING_SALT`.)
30. **Don't commit passwords in seeds.** Generate or read from env.

### Testing

31. **Every context function should have at least one test.** Cover the
    happy path and one error path (e.g., validation failure, not found).
32. **Use `ExMachina` factories for test data.** Don't construct structs
    manually in tests. (Factory exists at `test/support/factory.ex`.)
33. **Mock external APIs with `Mox`.** Define a behaviour, set
    `Mox.expect/4` in tests, and configure the app to use the mock in
    `test.exs`. Sofascore and LLM API calls should be mockable.
34. **Test the tree builder, not just CRUD.** `Forum.get_topic!/1` builds a
    nested reply tree — test that deeply nested replies appear in the right
    structure.
35. **Use `async: true` for tests that don't touch shared state.** Tests
    that only use the DB sandbox can be async. Tests that use Cachex or
    PubSub should be `async: false`.

### Code style

36. **Pick one language for docs and stick to it.** This project uses
    Spanish for UI and moduledocs — keep it consistent.
37. **Use `~w()` sigils for string lists** instead of `["a", "b", "c"]`.
    Already used in several places — keep it consistent.
38. **Don't use Ruby/JS syntax in Elixir.** `return`, `unless` without
    `do:` blocks, string interpolation with `#{}` inside non-string contexts.
    (We fixed `return` in `fixture_digest_worker.ex`.)
39. **Pipe everywhere.** `foo |> bar() |> baz()` is preferred over
    `baz(bar(foo))`. The only exception is when the first argument is
    short and the function takes a callback.
40. **Use `require Logger` at the top of any module that logs.** Don't
    rely on transitive requires.

### Asset pipeline

41. **`config :esbuild` and `config :tailwind` must define profiles with
    `version`, `args`, `cd`, and `env`.** (Fixed in a previous session.)
42. **`assets/package.json` is for npm-only deps (Tiptap).** Phoenix and
    `phoenix_live_view` resolve from `deps/` via `NODE_PATH`.
43. **`mix setup` should install deps, migrate, seed, and install assets
    in one command.** (Fixed: `setup` alias now includes `assets.setup`.)

### Configuration

44. **Compile-time config in `config/config.exs`** — no secrets, only
    structure (repo, endpoint, Oban queues, asset profiles).
45. **Runtime config in `config/runtime.exs`** — all env vars, secrets,
    per-environment adapter selection.
46. **Env-specific config (`dev.exs`, `test.exs`, `prod.exs`)** should be
    tiny shells. Everything substantial goes in `runtime.exs`.
47. **Don't use `String.to_existing_atom/1` on env vars.** Use a mapping
    function or `String.to_atom/1` for controlled, bounded values.
48. **`config :phoenix, :json_library, Jason` is required** for
    `Phoenix.json_library()` to work in the endpoint parser.

---

## Prioritized fix order

1. **`predictions_live.ex`** — module name + schema fields (#1, #2)
2. **`push_notification_worker.ex`** — `and` with non-boolean (#3)
3. **`sw.js`** — async/await (#4)
4. **Login session** (#7)
5. **`trust_promotion_worker.ex` thresholds** (#8)
6. **`prediction.ex` migration types** (#11)
7. **UserSocket + channels** (#9, #10)
8. **`webhook_dispatch_worker.ex`** — create `Webhook` schema (#5)
9. **`prune_drafts_worker.ex`** — create table or remove (#6)
10. **`profile.ex` socket capture** (#15)
11. **`predictions.ex` preload on maps** (#12)
12. **`link_controller.ex` open redirect** (#21)
13. **`reset_password.ex` signed tokens** (#28)
14. **`forgot_password.ex` send email** (#29)
15. **Orphaned migrations** (#22)
16. **Remaining medium/low items**
