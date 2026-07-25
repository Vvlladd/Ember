#!/usr/bin/env bash
# Dev-only: accepts the Gemma license on HF once (huggingface-cli login), then converts.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/convert_embeddinggemma.py
echo "Model + tokenizer in Targets/Ember/Resources/Models/ (gitignored — never commit)"
