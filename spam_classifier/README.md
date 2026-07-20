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

```bash
# Build (bakes the model in — pin HF_REVISION to a commit SHA for prod):
docker build -t colloq-spam-classifier .

# Run:
docker run -p 8000:8000 colloq-spam-classifier

# Smoke test:
curl -s localhost:8000/health
curl -s localhost:8000/classify -H 'content-type: application/json' \
  -d '{"text":"CLICK HERE to win $$$ http://spam.example http://spam2.example"}'
```

## Wire it into the app

Point the app at the sidecar and start in **shadow mode** (log only, no action):

| Site setting (`/admin/settings`) | Value | Meaning |
|---|---|---|
| `spam_ml_url` | `http://spam-classifier:8000` | Sidecar base URL |
| `spam_ml_enabled` | `true` | Turn the ML step on |
| `spam_ml_mode` | `shadow` | Log `{post_id, score, would_flag}`, take no action |
| `spam_ml_threshold` | `0.9` | Spam-probability cutoff |

Watch the logs (`[SpamDetector] ml post=… score=…`) for ~a week, pick a
threshold from the real score distribution, then flip `spam_ml_mode` to
`enforce`. Everything fails open: if the sidecar is down, posts are allowed.

## Notes

- Model + tokenizer are loaded once at startup and **baked into the image** at
  build time — nothing is downloaded on boot.
- `ORT_THREADS=1` caps CPU so a burst of posts can't hog cores. Forum post rate
  is low, so sustained CPU ≈ 0.
- `app.py` introspects the ONNX graph's expected inputs and only feeds those, so
  it adapts whether or not the model wants `token_type_ids`.
