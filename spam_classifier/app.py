"""
Spam-classifier sidecar.

Serves the ONNX model `onnx-community/tanaos-spam-detection-v1-ONNX`
(multilingual DistilBERT fine-tuned for spam) behind a tiny HTTP API. The
Elixir app (`Colloq.SpamClassifier`) calls POST /classify on every not-yet-
trusted post.

Design notes:
  * Model + tokenizer are loaded ONCE at startup (baked into the image, never
    downloaded on boot — see the Dockerfile).
  * We introspect the ONNX session's expected inputs and feed only those, so we
    don't hard-code whether the model wants token_type_ids.
  * intra_op_num_threads is capped so a burst of posts can't hog CPU.
  * Labels: id2label = {0: "not_spam", 1: "spam"} → index 1 is the spam prob.
"""
import os

import numpy as np
import onnxruntime as ort
from fastapi import FastAPI
from pydantic import BaseModel
from tokenizers import Tokenizer

MODEL_DIR = os.environ.get("MODEL_DIR", "/models")
MODEL_PATH = os.path.join(MODEL_DIR, "model_int8.onnx")
TOKENIZER_PATH = os.path.join(MODEL_DIR, "tokenizer.json")
MAX_TOKENS = 512
SPAM_INDEX = 1

# --- Load once at startup --------------------------------------------------
_so = ort.SessionOptions()
_so.intra_op_num_threads = int(os.environ.get("ORT_THREADS", "1"))
_so.inter_op_num_threads = 1

session = ort.InferenceSession(MODEL_PATH, sess_options=_so, providers=["CPUExecutionProvider"])
# Names the graph actually expects, e.g. {"input_ids", "attention_mask"}.
EXPECTED_INPUTS = {i.name for i in session.get_inputs()}

tokenizer = Tokenizer.from_file(TOKENIZER_PATH)
tokenizer.enable_truncation(max_length=MAX_TOKENS)

app = FastAPI(title="spam-classifier", version="1.0")


class ClassifyIn(BaseModel):
    text: str


class ClassifyOut(BaseModel):
    label: str
    score: float  # P(spam) in [0, 1]


def _softmax(logits: np.ndarray) -> np.ndarray:
    z = logits - np.max(logits)
    e = np.exp(z)
    return e / np.sum(e)


def _build_feed(text: str) -> dict:
    enc = tokenizer.encode(text)
    ids = np.array([enc.ids], dtype=np.int64)
    mask = np.array([enc.attention_mask], dtype=np.int64)

    feed = {}
    if "input_ids" in EXPECTED_INPUTS:
        feed["input_ids"] = ids
    if "attention_mask" in EXPECTED_INPUTS:
        feed["attention_mask"] = mask
    if "token_type_ids" in EXPECTED_INPUTS:
        feed["token_type_ids"] = np.zeros_like(ids)
    return feed


@app.get("/health")
def health():
    return {"status": "ok", "inputs": sorted(EXPECTED_INPUTS)}


@app.post("/classify", response_model=ClassifyOut)
def classify(body: ClassifyIn):
    text = (body.text or "").strip()
    if not text:
        return ClassifyOut(label="not_spam", score=0.0)

    logits = session.run(None, _build_feed(text))[0][0]
    probs = _softmax(np.asarray(logits, dtype=np.float64))
    score = float(probs[SPAM_INDEX])
    label = "spam" if score >= 0.5 else "not_spam"
    return ClassifyOut(label=label, score=score)
