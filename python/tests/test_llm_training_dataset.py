"""Commercial guardrails for the Sleep-AI LoRA training pipeline."""

from __future__ import annotations

import json
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
PY_ROOT = HERE.parent
if str(PY_ROOT) not in sys.path:
    sys.path.insert(0, str(PY_ROOT))


def test_commercial_synthetic_dataset_has_real_coverage() -> None:
    from training.llm.build_dataset import commercial_synthetic_conversations, dedupe

    convs = dedupe(commercial_synthetic_conversations())
    assert len(convs) >= 220

    users = "\n".join(c.user for c in convs)
    assistants = "\n".join(c.assistant for c in convs)
    assert "Latest: NO_NIGHT_RECORDED" in users
    assert "duration=7h12m" in users or "duration=7h42m" in users
    assert "Tag correlations" in users
    assert "睡眠计划" in users
    assert "Sleep Plan" in users
    assert "答非所问" in users
    assert "Apple Watch" in users
    assert "30%" in assistants
    assert "sleep apnea" in users
    assert "不会编造" in assistants or "cannot invent" in assistants


def test_seed_plus_synthetic_dataset_ratio_is_not_refusal_heavy() -> None:
    from training.llm.build_dataset import (
        commercial_synthetic_conversations,
        dedupe,
        load_seed_file,
    )

    seed_dir = PY_ROOT / "training" / "llm" / "seed_data"
    convs = []
    for path in sorted(seed_dir.glob("*.jsonl")):
        convs.extend(load_seed_file(path))
    convs.extend(commercial_synthetic_conversations())
    convs = dedupe(convs)

    assert len(convs) >= 300
    refusal_markers = (
        "outside my scope",
        "out of my scope",
        "不在我的范围",
        "我只负责睡眠",
        "I do not write code",
        "I don't write code",
    )
    refusals = [
        c for c in convs
        if any(marker.lower() in c.assistant.lower() for marker in refusal_markers)
    ]
    assert len(refusals) / len(convs) < 0.35


def test_eval_contract_catches_known_bad_outputs() -> None:
    from training.llm.eval_lora import EVAL_CASES, score_case

    no_data = next(c for c in EVAL_CASES if c.id == "zh_no_data_summary")
    ok, failures = score_case(no_data, "昨晚睡了 7h12m，得分 82，深睡 1h18m。")
    assert not ok
    assert any(f.startswith("forbidden") or f.startswith("invented_metric") for f in failures)

    filler = next(c for c in EVAL_CASES if c.id == "zh_filler_no_translate")
    ok, failures = score_case(filler, 'I can translate "可以" to English as "can".')
    assert not ok
    assert any(f.startswith("forbidden") or f.startswith("wrong_language") for f in failures)


def test_train_config_masks_prompt_loss() -> None:
    from training.llm.configs import config_for
    from training.llm.train_lora import _write_yaml_config

    cfg = config_for("qwen-instant")
    out = PY_ROOT / ".pytest_cache" / "llm_config_test.json"
    path = _write_yaml_config(cfg, out)
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["fine_tune_type"] == "lora"
    assert payload["mask_prompt"] is True
    assert payload["grad_accumulation_steps"] >= 2
    assert payload["max_seq_length"] >= 2048
    assert payload["val_batches"] == -1
    assert payload["test_batches"] == -1


def test_release_default_tier_is_formal_model() -> None:
    from training.llm.configs import PRODUCTION_TIER, config_for
    from training.llm.train_lora import _write_yaml_config

    assert PRODUCTION_TIER == "production"
    cfg = config_for(PRODUCTION_TIER)
    assert "Qwen3-4B" in cfg.base_model
    assert cfg.fused_dir.name == "fused-circadia-sleep-qwen-4b"

    out = PY_ROOT / ".pytest_cache" / "llm_formal_config_test.json"
    path = _write_yaml_config(cfg, out)
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["model"] == cfg.base_model
    assert payload["fine_tune_type"] == "lora"


def test_full_finetune_config_unfreezes_all_layers_without_lora_parameters() -> None:
    from training.llm.configs import config_for
    from training.llm.train_lora import _write_yaml_config

    cfg = config_for("qwen-instant-full")
    out = PY_ROOT / ".pytest_cache" / "llm_full_config_test.json"
    path = _write_yaml_config(cfg, out)
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["fine_tune_type"] == "full"
    assert payload["num_layers"] == -1
    assert payload["batch_size"] == 1
    assert payload["learning_rate"] <= 2e-6
    assert payload["grad_accumulation_steps"] >= 4
    assert "lora_parameters" not in payload
