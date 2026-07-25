#!/usr/bin/env python3
"""Convert google/embeddinggemma-300m to a Core ML .mlpackage + tokenizer files.

Output: Targets/Ember/Resources/Models/EmbeddingGemma.mlpackage
        Targets/Ember/Resources/Models/tokenizer/{tokenizer.json,tokenizer_config.json}
Ends with a parity check: CoreML output vs sentence-transformers output, cosine must be > 0.99.
VERIFY against the model card (https://ai.google.dev/gemma/docs/embeddinggemma) that the
prompt prefixes match GemmaEmbeddingFormat.swift before shipping.
"""
import numpy as np, torch, coremltools as ct
from pathlib import Path
from sentence_transformers import SentenceTransformer

MODEL_ID = "google/embeddinggemma-300m"
# Must match GemmaTextEmbedder.sequenceLength. Curated notes are short, but MemoryStore.index embeds
# FULL message text, so anything past this is silently truncated out of the vector. Raising it (or
# chunking long messages) is an open follow-up pending a measured latency/recall call.
SEQ_LEN = 256
# Anchored to the repo root via this file's location so the script works when invoked directly,
# not just through fetch_embeddinggemma.sh (which cd's to the root first).
OUT = Path(__file__).resolve().parent.parent / "Targets/Ember/Resources/Models"

st = SentenceTransformer(MODEL_ID)
st.eval()

class Pooled(torch.nn.Module):
    """input_ids/attention_mask -> mean-pooled, L2-normalized 768-dim sentence vector."""
    def __init__(self, st_model):
        super().__init__()
        self.st = st_model
    def forward(self, input_ids, attention_mask):
        out = self.st({"input_ids": input_ids, "attention_mask": attention_mask})
        return out["sentence_embedding"]

wrapper = Pooled(st)
ids = torch.zeros((1, SEQ_LEN), dtype=torch.int32)
mask = torch.zeros((1, SEQ_LEN), dtype=torch.int32)
traced = torch.jit.trace(wrapper, (ids, mask))

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.iOS18,
    compute_precision=ct.precision.FLOAT16,
)
OUT.mkdir(parents=True, exist_ok=True)
mlmodel.save(str(OUT / "EmbeddingGemma.mlpackage"))

tok_dir = OUT / "tokenizer"
tok_dir.mkdir(exist_ok=True)
st.tokenizer.save_pretrained(str(tok_dir))

# Parity check
text = "title: none | text: I'm planning a trip to Lisbon in September"
ref = st.encode([text], convert_to_numpy=True)[0]
enc = st.tokenizer(text, padding="max_length", max_length=SEQ_LEN, truncation=True, return_tensors="np")
pred = ct.models.MLModel(str(OUT / "EmbeddingGemma.mlpackage")).predict({
    "input_ids": enc["input_ids"].astype(np.int32),
    "attention_mask": enc["attention_mask"].astype(np.int32)})["embedding"][0]
cos = float(np.dot(ref, pred) / (np.linalg.norm(ref) * np.linalg.norm(pred)))
print(f"parity cosine = {cos:.4f}")
assert cos > 0.99, "Core ML output diverges from sentence-transformers — conversion is broken"
print("OK")
