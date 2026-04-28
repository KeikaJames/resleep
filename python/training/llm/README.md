# Sleep-AI fine-tune

This pipeline builds and validates the on-device Circadia Sleep AI model.
Release policy is intentionally simple: the app ships one formal model
(Qwen3-4B 4-bit + Circadia LoRA), because it is the only candidate that
currently passes the offline behavior gate.

The smaller 1.7B LoRA and full fine-tune configs remain as experiments
only. In the latest run, the 1.7B LoRA scored 7/12, and the 1.7B full
fine-tune scored 5/12. Do not ship either as the formal assistant without
improving data and passing `eval_lora.py`.

## What The Gate Checks

- No hallucinated sleep metrics when no night is recorded.
- Summaries cite local duration, score, deep, REM, and awake values.
- Tag answers cite local tagged/untagged averages and avoid causal claims.
- Sleep Plan answers describe automatic tracking only inside the planned window.
- Filler like `可以` does not become translation.
- Code and off-topic prompts are refused.
- Chinese prompts stay Chinese; English prompts stay English.

## Pipeline

```bash
PYTHONPATH=python python3 -m training.llm.build_dataset
PYTHONPATH=python python3 -m training.llm.train_lora
PYTHONPATH=python python3 -m training.llm.fuse
PYTHONPATH=python python3 -m training.llm.eval_lora --fail-under 0.92 --temp 0
```

The generated `dataset/`, `adapters-*`, `fused-*`, and `eval_reports/`
directories are intentionally ignored by Git. They are large and
regenerable from the versioned seed data and scripts.

## Production Bundle

The iOS build phase embeds only:

```text
python/training/llm/fused-circadia-sleep-qwen-4b
→ circadia-sleep-qwen-4b-4bit
```

There are no release build flags for old smaller-model candidates. To run an experiment,
train and evaluate it locally, but keep the release bundle on the formal model
until the candidate passes the same offline gate and the total
uncompressed app size remains below Apple limits.

## Full Fine-Tune Notes

Full fine-tune cannot run on 4-bit MLX weights:

```text
RuntimeError: [QuantizedMatmul::vjp] no gradient wrt the quantized weights.
```

Use a BF16 base for full SFT experiments. The current 1.7B full-fine-tune
config uses `mlx-community/Qwen3-1.7B-bf16`, but the result did not pass
the behavior gate and should not be shipped.
