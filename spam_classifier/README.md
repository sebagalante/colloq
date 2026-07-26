# Spam-classifier sidecar

A tiny FastAPI + onnxruntime service that runs
[`onnx-community/tanaos-spam-detection-v1-ONNX`](https://huggingface.co/onnx-community/tanaos-spam-detection-v1-ONNX)
(multilingual DistilBERT fine-tuned for spam, int8 quantized, ~136 MB) and
classifies forum posts as spam / not-spam.

It's called by the Elixir app's `Colloq.SpamClassifier` from
`Colloq.Workers.SpamDetectorWorker`, for posts by not-yet-trusted (TL0/TL1)
users only. See `../spamdetector.md` for the full design rationale.

## API

- `POST /classify` — body `{"text": "..."}` → `{"label": "spam"|"not_spam", "score": 0.0..1.0}`
  where `score` is the softmax probability of the spam class.
- `GET /health` → `{"status": "ok", "inputs": [...]}` (lists the model's input names).

## Run

This host runs **podman** (rootless), not Docker — there is no `docker` binary,
so the `docker …` forms below will fail with "command not found". The CLIs are
argument-compatible, so it's a straight substitution.

```bash
# Build (bakes the model in — pin HF_REVISION to a commit SHA for prod):
podman build -t colloq-spam-classifier .

# Run:
podman run -d --name colloq-spam-classifier -p 8000:8000 colloq-spam-classifier

# Smoke test:
curl -s localhost:8000/health
curl -s localhost:8000/classify -H 'content-type: application/json' \
  -d '{"text":"CLICK HERE to win $$$ http://spam.example http://spam2.example"}'
```

Verified on podman 4.9.3: image builds (657 MB), `/health` returns
`{"status":"ok"}`, and the model scores Spanish correctly — a "GANA DINERO
RAPIDO!!!" post lands at 0.999, an ordinary question about the mediocampo at
0.02.

`podman ps` may print `"/" is not a shared mount` on rootless setups. It's a
warning about volume propagation; this sidecar mounts nothing, so it's noise.

### As a service

The other units in `systemd/` are system-level, but this one is a **rootless
user unit** — it needs no root and inherits the podman images of the user that
built them. `systemd/colloq-spam-classifier.container` is a Quadlet file:

```bash
mkdir -p ~/.config/containers/systemd
cp systemd/colloq-spam-classifier.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start colloq-spam-classifier

# Survive logout (otherwise the user's services stop when the session ends):
sudo loginctl enable-linger "$USER"
```

Quadlet generates the unit from that file at `daemon-reload`; there is no
`systemctl enable` step — `WantedBy=` inside the file handles it. On podman
older than 4.4 use `podman generate systemd --new --name colloq-spam-classifier`
instead.

## Wire it into the app

Point the app at the sidecar and start in **shadow mode** (log only, no action):

| Site setting (`/admin/settings`) | Value | Meaning |
|---|---|---|
| `spam_ml_url` | `http://localhost:8000` | Sidecar base URL |
| `spam_ml_enabled` | `true` | Turn the ML step on |
| `spam_ml_mode` | `shadow` | Log `{post_id, score, would_flag}`, take no action |
| `spam_ml_threshold` | `0.9` | Spam-probability cutoff |

`spam_ml_url` is `http://localhost:8000` because the Phoenix app runs **on the
host**, not in a container, and podman publishes the port there. A service name
like `http://spam-classifier:8000` only resolves between containers sharing a
network — from the host it fails DNS, and since everything fails open that shows
up as "the classifier silently never runs", not as an error.

Watch the logs (`[SpamDetector] ml post=… score=…`) for ~a week, pick a
threshold from the real score distribution, then flip `spam_ml_mode` to
`enforce`. Everything fails open: if the sidecar is down, posts are allowed —
confirmed against a stopped sidecar, which returns `{:error, :econnrefused}` and
the worker allows the post.

## Notes

- Model + tokenizer are loaded once at startup and **baked into the image** at
  build time — nothing is downloaded on boot.
- `ORT_THREADS=1` caps CPU so a burst of posts can't hog cores. Forum post rate
  is low, so sustained CPU ≈ 0.
- `app.py` introspects the ONNX graph's expected inputs and only feeds those, so
  it adapts whether or not the model wants `token_type_ids`.
