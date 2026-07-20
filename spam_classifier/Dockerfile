# Spam-classifier sidecar. The model is BAKED IN at build time (never
# downloaded on boot) for reproducibility and fast, network-free startup.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# --- Bake the model into the image -----------------------------------------
# Pin a commit SHA (not a branch) so the image is reproducible. Find the latest
# on https://huggingface.co/onnx-community/tanaos-spam-detection-v1-ONNX/commits/main
ARG HF_REPO=onnx-community/tanaos-spam-detection-v1-ONNX
ARG HF_REVISION=main
ENV MODEL_DIR=/models

RUN python -c "\
from huggingface_hub import hf_hub_download; \
import os; \
os.makedirs('/models', exist_ok=True); \
[hf_hub_download(repo_id='${HF_REPO}', revision='${HF_REVISION}', filename=f, local_dir='/models') \
 for f in ['onnx/model_int8.onnx', 'tokenizer.json']]"

# hf_hub_download preserves the 'onnx/' subdir; flatten so app.py finds it.
RUN mv /models/onnx/model_int8.onnx /models/model_int8.onnx

ENV ORT_THREADS=1
COPY app.py .

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
