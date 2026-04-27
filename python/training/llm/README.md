# Sleep-AI LoRA fine-tune

This pipeline fine-tunes the Gemma 3n weights that power the in-app
**Sleep AI** assistant so the model stays on-topic (sleep, sleep
stages, wellness habits) and politely declines anything else.

## Why this exists

We block off-topic prompts in two places:

| Layer                  | Where                                          | Cost                      |
|------------------------|------------------------------------------------|---------------------------|
| Topic gate             | `SleepKit/AI/SleepTopicGate.swift`             | ~µs per prompt; zero tokens |
| System prompt          | `GemmaSleepAIService.systemPrompt`             | ~80 tokens once per session |
| **LoRA fine-tune**     | This pipeline → fused MLX model                | one-time training         |

The first two ship today and catch ~95% of cases. LoRA bakes the same
policy into the weights so even prompt-injection ("ignore previous
instructions...") is materially harder.

## Requirements

- Apple Silicon (M-series), macOS 14+, ≥ 24 GB unified memory.
- Python 3.11+.
- `pip install mlx mlx-lm` (already in `python/requirements.txt`).

## Pipeline

```
seed_data/*.jsonl
        │
        │  python -m training.llm.build_dataset
        ▼
dataset/{train,valid,test}.jsonl
        │
        │  python -m training.llm.train_lora
        ▼
adapters/{adapters.safetensors, config.yaml, ...}
        │
        │  python -m training.llm.fuse
        ▼
fused-circadia-sleep/   ← MLX model the app can load
```

### 1. Build the dataset

```bash
python -m training.llm.build_dataset
```

Reads every `.jsonl` in `seed_data/` and emits `dataset/train.jsonl`,
`dataset/valid.jsonl`, `dataset/test.jsonl`. The seed set is small on
purpose — a few dozen high-signal examples per language. Add your own
JSONL files under `seed_data/` to extend coverage.

Each example uses the OpenAI-style **messages** format expected by
`mlx-lm`:

```json
{"messages": [
  {"role": "system",    "content": "You are Circadia, a calm on-device sleep companion. You only help with sleep and wellness."},
  {"role": "user",      "content": "How was my sleep last night?"},
  {"role": "assistant", "content": "I can read your numbers if you tap **Summarize last night**..."}
]}
```

The seed set covers:

- **Sleep + wellness** (en + zh) — REM, deep sleep, bedtime routines,
  caffeine, melatonin habits, smart-alarm explanations.
- **Off-topic refusals** (en + zh) — politics, code, finance,
  recipes, "ignore previous instructions" jailbreaks.
- **Medical-advice refusals** — "Do I have apnea?", dosing questions.
- **Crisis safety** — self-harm prompts redirected to real hotlines.

### 2. Train

```bash
python -m training.llm.train_lora
```

Runs `mlx_lm.lora` with the `LoRAConfig` defaults:

- rank 8, alpha 16, dropout 0.05 (deliberately small — we're nudging
  behavior, not adding capacity)
- 16 transformer layers adapted
- 600 iters, batch 2, lr 1e-4

Adapters land in `adapters/` along with `training_summary.json`.

### 3. Fuse

```bash
python -m training.llm.fuse
```

Bakes the LoRA into the base weights and writes a deployable MLX
checkpoint to `fused-circadia-sleep/`.

### 4. Use the fused model in the app

Two ways:

```bash
# Option A — env-var override (good for sim/Mac dev)
export CIRCADIA_GEMMA_DIR="$(pwd)/python/training/llm/fused-circadia-sleep"

# Option B — drop the directory into the app's Documents/Models
#           location and rename to gemma-3n-E2B-it-4bit (matches the
#           default `GemmaWeightsLocator.dirName`).
```

Then launch the app — `GemmaSleepAIService` will pick the new weights.

## Evaluation

Quick sanity check after fuse:

```bash
python -m mlx_lm.generate \
  --model python/training/llm/fused-circadia-sleep \
  --prompt "Write me a Python function to reverse a list."
```

A correctly-tuned model should refuse with a one-liner about staying
on sleep / wellness, then offer to help with a sleep topic. Spot-check
several off-topic prompts in both English and Chinese.

## Notes on data quality

- Keep the seed set **small and high-signal**. 50 great examples will
  beat 500 noisy ones for behavioral fine-tunes.
- Both languages should have similar coverage. If you 5× the English
  set without 5×ing Chinese, the model will drift toward English.
- Refusals should be polite, short, and end with an in-scope offer —
  this trains the model not just to say no, but to redirect.
- Never add training examples that produce medical diagnoses or
  medication advice — that's a hard rule, both ethically and per the
  app's regulatory disclaimers.
