# Spam Detector — ONNX ML Classifier Plan

Plan for adding an ML spam classifier to the forum, using the HuggingFace model
[`onnx-community/tanaos-spam-detection-v1-ONNX`](https://huggingface.co/onnx-community/tanaos-spam-detection-v1-ONNX).
Written as a hand-off for a future session.

> **Status:** Elixir integration DONE + sidecar scaffolded; **shadow-mode ready**.
> Remaining: build/deploy the sidecar container, verify the model I/O signature
> (§2), turn on `spam_ml_enabled` in shadow mode, calibrate the threshold from
> real scores, then flip to `enforce`.
>
> **Done so far (Option A):**
> - Wired the enqueue: `Forum.create_post` and `create_topic` now enqueue
>   `SpamDetectorWorker` for TL0/TL1 authors (previously it was *never* enqueued —
>   see the correction in §1).
> - `Colloq.SpamClassifier` HTTP client (Req, fail-open).
> - `SpamDetectorWorker.classify/1` runs the ML step after the heuristics, with
>   `spam_ml_enabled` / `spam_ml_mode` (shadow|enforce) / `spam_ml_threshold`
>   site settings, shadow-mode logging, and fail-open on any error.
> - Sidecar scaffolded in `spam_classifier/` (FastAPI + onnxruntime + Dockerfile
>   that bakes in `model_int8.onnx`).
> - `SPAM_ML_URL` deploy env fallback in `config/runtime.exs`.

---

## 1. Context — what exists today

`lib/colloq/workers/spam_detector_worker.ex` runs on every post by a **TL0 or
TL1** user. (Correction to the original draft: the worker existed but was
**never enqueued** — the enqueue in `Forum.create_post`/`create_topic` was added
as part of this work.) Current heuristic pipeline in `classify/1`:

1. `too_many_urls?` — more than `@max_links` (3) URLs → spam
2. `duplicate_content?` — identical body in the last 10 posts → spam
3. `contains_blocked_words?` — blocked words from `SiteSettings`

On a hit → `handle_spam/2`: hides the post, flags it, notifies the author.
The moduledoc already mentions an intended "LLM classifier fallback for
borderline cases" — the ONNX model slots in exactly there.

- There are **no ML deps** in `mix.exs` yet (no Nx/Bumblebee/Ortex/tokenizers).
- The app already calls external HTTP classifiers/LLMs via `Req` (see
  `Colloq.Llm`), so an HTTP sidecar matches an existing pattern.
- This is a **background classifier**, not a chat "bot".

---

## 1b. Why a local model instead of an LLM API?

The core motivation: **don't burn scarce free-tier LLM quota (Groq / OpenRouter /
Cerebras) on a high-frequency binary decision.**

- Spam detection fires on **every TL0/TL1 post** — a boring, high-volume yes/no.
  Routing each one to an LLM would chew through free-tier **rate limits and token
  quota** fast.
- A ~134M DistilBERT **fine-tuned specifically for spam** is often *better* at
  binary spam/ham than a general LLM prompt — it's the right tool for a narrow
  task, not a downgrade. ("Poor man's" undersells it.)
- Local model = **$0 marginal cost, no rate limits, no network dependency,
  deterministic, ~15–60 ms**. Run it on every post without thinking about cost.
- It **frees the LLM budget for what genuinely needs generation**: topic
  summaries, persona bots, `/sofascore` answers. Spending tokens on "is this
  spam?" wastes a scarce resource.

**Mental model — a cost/quality ladder:** free heuristics → free local classifier
→ (optional, rare) paid LLM tie-breaker for borderline scores only. Reserve the
expensive rung for the expensive problems. Honest tradeoff: an LLM might catch
some novel/nuanced spam the classifier misses, but it should never be the default
path.

## 2. The model (verified facts)

- Architecture: **`DistilBertForSequenceClassification`** (multilingual
  DistilBERT). 6 layers, hidden 768, 12 heads, `max_position_embeddings` 512,
  `vocab_size` 119547 (multilingual — good for Spanish/rioplatense content).
- ~134M params.
- **Labels (`id2label`): `{0: "not_spam", 1: "spam"}`** → **index 1 = spam**.
- ONNX precision variants in the `onnx/` folder (file size ≈ in-RAM weights):

  | Variant | Size |
  |---|---|
  | `model.onnx` (fp32) | 541 MB |
  | `model_fp16.onnx` | 271 MB |
  | `model_int8` / `model_quantized` / `model_uint8` | **136 MB** ← use this |
  | `model_q4*` | 210–398 MB |

- **Use `model_int8.onnx` (136 MB)** — ~4× smaller than fp32, negligible
  accuracy loss for binary classification, fast on CPU. (Skip fp16 on CPU — it's
  often slower than int8.)

### Must verify before coding (15 min, saves hours)
- Open `onnx/model_int8.onnx` in [Netron](https://netron.app) (or
  `onnxruntime.InferenceSession(...).get_inputs()`): confirm the input **names**
  and **dtypes**. DistilBERT typically needs `input_ids` + `attention_mask`
  (int64) and usually **no** `token_type_ids` — but confirm.
- Confirm `tokenizer.json` is present (it is) and truncate posts to 512 tokens.
- Output is logits shape `[batch, 2]` → softmax → take index 1 (spam) score.

---

## 3. Runtime options + footprint (int8 model)

| Option | Idle RAM | CPU / post | Notes |
|---|---|---|---|
| **A. Python sidecar (HTTP)** | ~350–500 MB RSS (Python+onnxruntime ~150 MB + weights 136 MB + arenas ~100 MB) | ~15–60 ms, bursty | Separate process; **does not touch the BEAM's memory**. Idle CPU ≈ 0. |
| **B. Ortex (in BEAM)** | **+250–400 MB** added to the app node | ~15–60 ms (dirty NIF) | No 2nd service, but the BEAM node carries the model; ~doubles a small Phoenix node. Adds a Rust/onnxruntime build chain. |
| **C. Bumblebee (EXLA)** | 1.5–2.5 GB | first call compiles (s), then ~tens ms | XLA runtime huge; ignores the ONNX artifact. **Not worth it here.** |

fp32 instead of int8 adds ~+400 MB to A and B.

Forum post rate is low → **sustained CPU ≈ 0**; you only pay the burst per new
TL0/TL1 post. Cap threads (`intra_op_num_threads = 1`) so a burst can't hog
cores. Latency is irrelevant (async Oban worker; post is already stored).

### Decision
- **Recommended: A (Python sidecar) with `model_int8.onnx`.** Uses the exact
  ONNX, mirrors the existing HTTP-classifier pattern, keeps the BEAM lean,
  easiest to iterate/calibrate. Budget ~0.5 GB RAM + ~1 vCPU for the container.
- **B (Ortex)** only if a hard "no second service" rule applies and the app host
  has ~0.5 GB headroom.
- Final choice pending — user was still deciding (leaning A).

---

## 4. Implementation plan (Option A — sidecar)

### 4.1 Sidecar service
- Small **FastAPI + onnxruntime + tokenizers** app (~40 lines).
- Load `model_int8.onnx` + `tokenizer.json` **once at startup**.
- Endpoints:
  - `POST /classify {text}` → `{label, score}` (score = softmax prob of index 1 / spam).
  - `GET /health`.
- `intra_op_num_threads=1` (or 2) on the ONNX session.
- **Dockerfile bakes the model in at build time** (do NOT download on boot).
  Pin the HF **revision (commit SHA)** for reproducibility.
- Runs as a container next to the app / on the same network.

### 4.2 Elixir client — `Colloq.SpamClassifier`
- `Req.post(url, json: %{text: body}, receive_timeout: 800)`.
- Returns `{:ok, %{label, score}}` or `{:error, reason}`.
- **Fail-open**: any error/timeout → treat as not-spam (never lose a legit post
  because the model is down).

### 4.3 Worker hook — `SpamDetectorWorker.classify/1`
- Run the ML step **after** the cheap heuristics (obvious spam short-circuits for
  free), on all TL0/TL1 posts.
- On score ≥ threshold → `{:spam, "ml_classifier"}` → existing `handle_spam/2`
  (hide + flag + notify). **Store the score on the flag** for review/tuning.

### 4.4 Config (`SiteSettings`, tune without redeploys)
- `spam_ml_enabled` (bool)
- `spam_ml_mode` — `"shadow"` (log-only) | `"enforce"`
- `spam_ml_threshold` (float, e.g. `0.9`)
- `spam_ml_url` (sidecar base URL)

### 4.5 Rollout — SHADOW MODE FIRST (strongly recommended)
1. Ship in **shadow mode**: call the classifier, **log `{post_id, score,
   would_flag}`**, but take **no action**.
2. Collect ~a week of real posts; look at the score distribution and where real
   spam vs. ham lands.
3. Pick the threshold from the data, then flip `spam_ml_mode` to `"enforce"`.
   (Skipping this = false-positiving real users on day one.)

---

## 5. Option B notes (if chosen instead)
- Deps: `{:ortex}` (bundles ONNX Runtime via Rust), `{:tokenizers}`, `{:nx}`.
- Needs Rust toolchain + ONNX Runtime at **compile time**; prod needs a Docker
  build stage that compiles the NIFs.
- Load model once into an `Nx.Serving` / GenServer / `:persistent_term` at boot.
- Tokenize with `Tokenizers`, build int64 input tensors matching the verified
  signature, `Ortex.run`, `Nx.softmax`, take index 1.
- Everything else (worker hook, config, shadow mode, fail-open) is identical to A.

---

## 6. Cross-cutting principles
- **Fail-open** everywhere: model down = post allowed.
- **Heuristics first**, ML second (cost + short-circuit).
- **Store scores** for threshold calibration.
- **Shadow mode before enforcement.**
- Only runs for **TL0/TL1** (the existing risky cohort) — don't classify trusted users.

---

## 7. Next actions for the future session
1. Verify model I/O signature (Netron / onnxruntime) — §2.
2. Confirm runtime choice (A vs B) with the user.
3. If A: scaffold FastAPI service + Dockerfile (pinned int8 model), then
   `Colloq.SpamClassifier`, the worker hook, `SiteSettings` toggles, and
   shadow-mode logging.
4. Deploy in shadow mode; calibrate threshold; enable enforcement.
