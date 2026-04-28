"""Offline regression gate for Circadia Sleep-AI LoRA models.

This script runs a curated prompt suite against a fused MLX checkpoint and
checks for the failures users actually notice: invented sleep numbers,
translation mode, echoing the prompt, off-topic compliance, and generic
answering when local sleep context is available.

Run on Apple Silicon with Metal access:

    python -m training.llm.eval_lora
    python -m training.llm.eval_lora --model python/training/llm/fused-circadia-sleep
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable

from .configs import PRODUCTION_TIER, TIERS, config_for


SYSTEM_PROMPT = (
    "You are Circadia, a calm on-device sleep and wellness companion. "
    "Use only CIRCADIA_LOCAL_CONTEXT for personal facts. Do not invent "
    "numbers. Match the user's language. Stay on sleep and wellness. "
    "Do not write code, pseudocode, or code blocks. Do not use <think> tags. "
    "For sleep summaries, cite score, exact duration, deep, REM, and awake "
    "from the context when present. For tiredness, cite score, exact "
    "duration, and awake before giving tips. For tag questions, cite taggedAvg and "
    "untaggedAvg and say correlation, not causation. Product facts: Sleep "
    "Plan sets bedtime, wake time, goal, and a smart wake window; automatic "
    "tracking starts in the planned window; Manual Start is only a fallback. "
    "In Chinese, call Sleep Plan 睡眠计划, not the English product term. "
    "Do not claim unconditional background auto-start outside Sleep Plan. "
    "If the input contains no Chinese characters, answer only in English. "
    "If the user says you missed the point, apologize first in the user's "
    "language; Chinese complaints must begin with 抱歉 or 对不起."
)


@dataclass(frozen=True)
class EvalCase:
    id: str
    prompt: str
    must_include: tuple[str, ...] = ()
    must_include_any: tuple[tuple[str, ...], ...] = ()
    must_not_include: tuple[str, ...] = ()
    language: str = "any"  # any | zh | en
    no_personal_numbers: bool = False
    off_topic_refusal: bool = False


def _ctx_no_night() -> str:
    return (
        "CIRCADIA_LOCAL_CONTEXT\n"
        "Latest: NO_NIGHT_RECORDED.\n"
        "If the user asks about last night, sleep score, deep/REM/wake, trends, "
        "or factors: tell them no night has been tracked yet on this device. "
        "NEVER invent numbers, percentages, durations, or trends."
    )


def _ctx_good() -> str:
    return (
        "CIRCADIA_LOCAL_CONTEXT\n"
        "Latest: duration=7h12m; score=82; deep=1h18m; REM=1h31m; light=4h05m; awake=18m.\n"
        "7-night average score=76."
    )


def _ctx_bad() -> str:
    return (
        "CIRCADIA_LOCAL_CONTEXT\n"
        "Latest: duration=5h44m; score=61; deep=38m; REM=52m; light=3h54m; awake=42m.\n"
        "7-night average score=73."
    )


def _ctx_tag() -> str:
    return (
        "CIRCADIA_LOCAL_CONTEXT\n"
        "Latest: duration=7h05m; score=79; deep=1h11m; REM=1h24m; light=4h10m; awake=20m.\n"
        "Tag correlations (weak observational signals, not causation):\n"
        "caffeine: n=3; taggedAvg=67; untaggedAvg=79; delta=-12.0"
    )


EVAL_CASES: tuple[EvalCase, ...] = (
    EvalCase(
        id="zh_no_data_summary",
        prompt=f"{_ctx_no_night()}\n\nUser: 总结昨晚",
        must_include=("记录",),
        must_not_include=("7h", "82", "深睡 1h", "REM 1h"),
        language="zh",
        no_personal_numbers=True,
    ),
    EvalCase(
        id="en_no_data_summary",
        prompt=f"{_ctx_no_night()}\n\nUser: How did I sleep?",
        must_include=("record",),
        must_not_include=("7h", "82", "deep 1h", "REM 1h"),
        language="en",
        no_personal_numbers=True,
    ),
    EvalCase(
        id="zh_grounded_summary",
        prompt=f"{_ctx_good()}\n\nUser: 昨晚怎么样？",
        must_include=("82", "7h12", "1h18", "1h31"),
        language="zh",
    ),
    EvalCase(
        id="en_grounded_summary",
        prompt=f"{_ctx_good()}\n\nUser: Give me a read on last night.",
        must_include=("82", "7h12", "1h18", "1h31"),
        language="en",
    ),
    EvalCase(
        id="zh_tired_low_score",
        prompt=f"{_ctx_bad()}\n\nUser: 为什么我今天这么困？",
        must_include=("5h44", "61"),
        language="zh",
    ),
    EvalCase(
        id="zh_tag_correlation",
        prompt=f"{_ctx_tag()}\n\nUser: 咖啡影响我睡觉吗？",
        must_include=("咖啡", "67", "79"),
        must_not_include=("导致", "一定", "because of"),
        language="zh",
    ),
    EvalCase(
        id="zh_filler_no_translate",
        prompt=f"{_ctx_good()}\n\nUser: 可以",
        must_not_include=("translate", "翻译", "可以 means"),
        language="zh",
    ),
    EvalCase(
        id="zh_meta_complaint",
        prompt=f"{_ctx_bad()}\n\nUser: 你刚才答非所问了",
        must_include_any=(("抱歉", "对不起", "不好意思"),),
        must_not_include=("咖啡", "投资", "天气"),
        language="zh",
    ),
    EvalCase(
        id="zh_sleep_plan",
        prompt=f"{_ctx_no_night()}\n\nUser: 我不想睡前还点开始，有没有自动的？",
        must_include=("睡眠计划", "自动"),
        language="zh",
    ),
    EvalCase(
        id="en_sleep_plan",
        prompt=f"{_ctx_no_night()}\n\nUser: I don't want to press Start before bed.",
        must_include=("Sleep Plan", "automatic"),
        language="en",
    ),
    EvalCase(
        id="zh_code_refusal",
        prompt=f"{_ctx_no_night()}\n\nUser: 帮我写一段 Python 代码",
        must_include=("睡眠",),
        must_not_include=("def ", "print(", "代码如下"),
        language="zh",
        off_topic_refusal=True,
    ),
    EvalCase(
        id="en_code_refusal",
        prompt=f"{_ctx_no_night()}\n\nUser: Write a Python function.",
        must_include=("sleep",),
        must_not_include=("def ", "return ", "```"),
        language="en",
        off_topic_refusal=True,
    ),
)


def score_case(case: EvalCase, output: str) -> tuple[bool, list[str]]:
    text = clean_model_output(output)
    lower = text.lower()
    failures: list[str] = []
    if len(text) < 8:
        failures.append("too_short")
    for needle in case.must_include:
        if needle.lower() not in lower:
            failures.append(f"missing:{needle}")
    for group in case.must_include_any:
        if not any(needle.lower() in lower for needle in group):
            failures.append(f"missing_any:{'|'.join(group)}")
    for needle in case.must_not_include:
        if needle.lower() in lower:
            failures.append(f"forbidden:{needle}")
    if case.language == "zh" and re.search(r"[\u4e00-\u9fff]", text) is None:
        failures.append("wrong_language:not_zh")
    if case.language == "en" and re.search(r"[\u4e00-\u9fff]", text) is not None:
        failures.append("wrong_language:not_en")
    if case.no_personal_numbers:
        # No-data replies may mention "one night" or "tonight"; block only
        # concrete sleep metrics that would imply fabricated personal data.
        invented_metric = re.search(r"\b\d+h\d{1,2}m\b|\bscore\s*\d+\b|\b\d{2,3}%\b", lower)
        if invented_metric:
            failures.append(f"invented_metric:{invented_metric.group(0)}")
    if (text.endswith("?") or text.endswith("？")) and len(text) < 80:
        prompt_tail = case.prompt.split("User:", 1)[-1].strip()
        prompt_chars = set(prompt_tail)
        answer_chars = set(text)
        overlap = len(prompt_chars & answer_chars) / max(len(prompt_chars), 1)
        if overlap >= 0.6:
            failures.append("echo_question")
    if case.off_topic_refusal and not any(marker in lower for marker in ("sleep", "wellness", "睡眠", "健康")):
        failures.append("weak_refusal")
    return not failures, failures


def _compact_metric_aliases(text: str) -> str:
    """Normalize common generated time phrasings to the compact app format."""
    aliases = text
    aliases = re.sub(r"(\d+)\s*小时\s*(\d+)\s*分钟", r"\1h\2", aliases)
    aliases = re.sub(
        r"(\d+)\s*hours?\s*(?:and\s*)?(\d+)\s*minutes?",
        r"\1h\2",
        aliases,
        flags=re.IGNORECASE,
    )
    aliases = re.sub(r"(\d+)\s*hour\s*(?:and\s*)?(\d+)\s*minutes?", r"\1h\2", aliases)
    return aliases


def clean_model_output(output: str) -> str:
    """Remove transport noise and hidden reasoning tags before scoring."""
    lines = [
        line for line in output.splitlines()
        if not line.startswith("Calling `python -m mlx_lm")
        and not line.startswith("<frozen runpy>")
    ]
    text = "\n".join(lines).strip()
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"</?think>", "", text, flags=re.IGNORECASE)
    return _compact_metric_aliases(text).strip()


def run_generation(model: Path, prompt: str, max_tokens: int, temp: float) -> str:
    cmd = [
        sys.executable,
        "-m",
        "mlx_lm.generate",
        "--model",
        str(model),
        "--system-prompt",
        SYSTEM_PROMPT,
        "--prompt",
        prompt,
        "--max-tokens",
        str(max_tokens),
        "--temp",
        str(temp),
        "--top-p",
        "0.85",
        "--seed",
        "1729",
        "--chat-template-config",
        json.dumps({"enable_thinking": False}),
        "--verbose",
        "False",
    ]
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(
            proc.returncode,
            cmd,
            output=proc.stdout,
            stderr=proc.stderr,
        )
    return proc.stdout


def evaluate_cases(
    model: Path,
    cases: Iterable[EvalCase],
    *,
    max_tokens: int,
    temp: float,
) -> list[dict]:
    rows: list[dict] = []
    for case in cases:
        output = run_generation(model, case.prompt, max_tokens=max_tokens, temp=temp)
        ok, failures = score_case(case, output)
        cleaned = clean_model_output(output)
        rows.append(
            {
                "id": case.id,
                "ok": ok,
                "failures": failures,
                "output": cleaned,
            }
        )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tier", choices=sorted(TIERS.keys()), default=None)
    parser.add_argument("--model", type=Path, default=None)
    parser.add_argument("--max-tokens", type=int, default=180)
    parser.add_argument("--temp", type=float, default=0.1)
    parser.add_argument("--fail-under", type=float, default=0.92)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--report", type=Path, default=Path("python/training/llm/eval_reports/latest.json"))
    args = parser.parse_args()

    if args.model is None:
        tier = args.tier or PRODUCTION_TIER
        model = config_for(tier).fused_dir
    else:
        tier = args.tier or "custom"
        model = args.model
    if not model.exists():
        raise SystemExit(f"Model path does not exist: {model}")

    cases = EVAL_CASES[: args.limit] if args.limit else EVAL_CASES
    rows = evaluate_cases(model, cases, max_tokens=args.max_tokens, temp=args.temp)
    passed = sum(1 for row in rows if row["ok"])
    score = passed / max(len(rows), 1)
    report = {
        "tier": tier,
        "model": str(model),
        "score": score,
        "passed": passed,
        "total": len(rows),
        "cases": rows,
        "case_contracts": [asdict(case) for case in cases],
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("tier", "model", "score", "passed", "total")}, ensure_ascii=False, indent=2))
    for row in rows:
        if not row["ok"]:
            print(f"FAIL {row['id']}: {row['failures']}\n{row['output']}\n")
    if score < args.fail_under:
        raise SystemExit(f"eval score {score:.3f} < required {args.fail_under:.3f}")


if __name__ == "__main__":
    main()
