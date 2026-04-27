"""Sleep-AI LoRA fine-tuning pipeline.

This package fine-tunes a small Gemma model with LoRA so the resulting
weights stay strictly on-topic (sleep, sleep stages, wellness habits)
and politely refuse anything else.

Why LoRA + system prompt + topic gate?
* The Swift `SleepTopicGate` and the `systemPrompt` already block ~95%
  of off-topic prompts. They cost nothing at inference time.
* LoRA bakes the same policy into the weights, so even prompt-injection
  attacks ("ignore previous instructions...") are degraded.
* LoRA adapters are tiny (a few MB) and can be fused back into the base
  model for redistribution as a single MLX checkpoint.

See `python/training/llm/README.md` for the full pipeline.
"""

__all__ = []
