#!/usr/bin/env bash
# Dev-only: converts google/embeddinggemma-300m to Core ML + tokenizer files for local runs.
#
# This script does NOT log you in. The download happens inside SentenceTransformer, which requires
# that you have ALREADY run `huggingface-cli login` and accepted the Gemma license for your account
# on https://huggingface.co/google/embeddinggemma-300m — otherwise the fetch fails with a 401/403.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found on PATH." >&2
    exit 1
fi

if ! python3 -c "import torch, coremltools, sentence_transformers" 2>/dev/null; then
    echo "error: missing Python packages. Install them with:" >&2
    echo "    python3 -m pip install torch coremltools sentence-transformers numpy" >&2
    exit 1
fi

if ! command -v huggingface-cli >/dev/null 2>&1; then
    echo "warning: huggingface-cli not found — cannot verify you are logged in." >&2
    echo "         If the download fails with 401/403, run 'huggingface-cli login' and accept" >&2
    echo "         the Gemma license at https://huggingface.co/google/embeddinggemma-300m" >&2
fi

python3 scripts/convert_embeddinggemma.py
echo "Model + tokenizer in Targets/Ember/Resources/Models/ (gitignored — never commit)"
