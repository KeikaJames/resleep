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
    "Circadia is a closed system: never suggest external cycle, fertility, "
    "wellness, or AI APIs. Health, sleep, cycle, and microphone-derived data "
    "stay on device. Microphone facts are local snore-event counts only; never "
    "claim raw audio was saved, uploaded, or replayed. "
    "For sleep summaries, cite score, exact duration, deep, REM, and awake "
    "from the context when present. For tiredness, cite score, exact "
    "duration, and awake before giving tips. For tag questions, cite taggedAvg and "
    "untaggedAvg and say correlation, not causation. Product facts: Sleep "
    "Plan sets bedtime, wake time, goal, and a smart wake window; automatic "
    "tracking starts in the planned window; Manual Start is only a fallback. "
    "If CIRCADIA_LOCAL_CONTEXT includes LOCAL_SLEEP_SKILL_RESULTS, treat them "
    "as already-called local tools. Use sleep_status, evidence, and "
    "advice_inputs instead of saying you cannot inspect sleep state. "
    "If advice_inputs includes latest_microphone_snore_events or "
    "latest_snore_events_per_hour, mention snore events as a local "
    "microphone-derived count, never as saved audio. "
    "For jet lag, learning, memory, exams, recovery, or bedtime routine plans: "
    "ask only missing route/timing/goal constraints when needed; when enough "
    "facts are present, give a followable plan under 90 words, include timed "
    "bright-light exposure or light avoidance for jet lag, and append a hidden "
    "<CIRCADIA_PLAN> block with autoTracking, bedtime, wake, goalMinutes, and "
    "smartWakeWindowMinutes. Do not explain that block. Do not use markdown "
    "headings or tables in Sleep Plan answers. "
    "If a jet-lag request already includes route, departure/arrival times, "
    "first must-be-awake time, and habitual sleep window, do not ask for "
    "confirmation; give the plan and append the save block. "
    "In Chinese, call Sleep Plan 睡眠计划, not the English product term. "
    "Do not claim unconditional background auto-start outside Sleep Plan. "
    "If the input contains no Chinese characters, answer only in English. "
    "If the user says you missed the point, apologize first in the user's "
    "language; Chinese complaints must begin with 抱歉 or 对不起. "
    "If the user did not complain, do not begin with an apology. "
    "Examples are illustrative. Never copy example numbers into a real answer "
    "unless those exact numbers appear in CIRCADIA_LOCAL_CONTEXT. Mention "
    "snore only when the current context includes snoreEvents, "
    "latest_microphone_snore_events, or latest_snore_events_per_hour. "
    "Example with local skills: if context says latest_score=64, "
    "latest_duration=6h05m, awake_minutes=40, and "
    "latest_microphone_snore_events=N, answer in Chinese with 64, 6h05, "
    "40m, and the local microphone snore-event count N; say no raw audio was saved. "
    "Example tag answer: if caffeine has taggedAvg=67 and untaggedAvg=79, "
    "cite both 67 and 79 and say association, not causation. "
    "Example missing jet-lag request: if the user only says they are going "
    "to New York, ask for departure city/time, arrival time, and the first "
    "must-be-awake time; do not append a plan block. "
    "Example complete jet-lag plan: include morning bright light or evening "
    "light avoidance, then append <CIRCADIA_PLAN> autoTracking=true "
    "bedtime=23:30 wake=07:30 goalMinutes=480 smartWakeWindowMinutes=25 "
    "</CIRCADIA_PLAN>."
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
    requires_plan_directive: bool = False
    forbids_plan_directive: bool = False


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


def _ctx_skill_snore() -> str:
    return (
        "CIRCADIA_LOCAL_CONTEXT\n"
        "Rules: use only these facts for personal claims; say data is limited when counts are small; do not diagnose.\n"
        "Latest: duration=6h05m; score=64; deep=42m; REM=58m; light=4h25m; awake=40m; dataQuality=moderate; confidence=68%; estimated=true; missingSignals=wakeSurvey.\n"
        "Recent nights newest-first:\n"
        "#1; score=64; duration=6h05m; deep=42m; REM=58m; awake=40m; snoreEvents=38; dataQuality=moderate; confidence=68%; estimated=true; missingSignals=wakeSurvey\n"
        "LOCAL_SLEEP_SKILL_RESULTS\n"
        "These are on-device MCP-style tool results. Use them for advice; do not claim raw audio or health data left the device.\n"
        "tool=sleep_status; confidence=68%\n"
        "facts=latest_duration=6h05m; latest_score=64; awake_minutes=40; deep_ratio=0.12; rem_ratio=0.16; data_quality=moderate; evidence_confidence=0.68; estimated_from_passive_sources=true\n"
        "findings=short_sleep_opportunity,high_wake_after_sleep_onset\n"
        "adviceInputs=short_sleep_opportunity,high_wake_after_sleep_onset\n"
        "tool=evidence; confidence=68%\n"
        "facts=healthkit=authorized; watch_paired=true; watch_reachable_now=false; watch_app_installed=true\n"
        "findings=night_estimated_from_healthkit_or_fallback,missing_signals=wakeSurvey\n"
        "adviceInputs=collect_or_confirm_wakeSurvey\n"
        "tool=advice_inputs; confidence=68%\n"
        "facts=latest_microphone_snore_events=38; latest_snore_events_per_hour=6.2\n"
        "findings=high_snore_density\n"
        "adviceInputs=discuss_sleep_position_nasal_congestion_alcohol_timing,track_snore_trend_without_saving_audio\n"
        "Current Sleep Plan: autoTracking=true; bedtime=23:30; wake=07:30; goal=480m; smartWakeWindow=25m."
    )


def _ctx_plan_only() -> str:
    return (
        "CIRCADIA_LOCAL_CONTEXT\n"
        "Latest: NO_NIGHT_RECORDED.\n"
        "Current Sleep Plan: autoTracking=true; bedtime=23:30; wake=07:30; goal=480m; smartWakeWindow=25m."
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
        must_include_any=(("record", "tracked"),),
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
        must_not_include=("导致", "一定", "because of", "38", "打鼾", "snore"),
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
    EvalCase(
        id="zh_local_skills_snore_advice",
        prompt=f"{_ctx_skill_snore()}\n\nUser: 我为什么睡醒还是累？给我具体建议",
        must_include=("64", "6h05", "40"),
        must_include_any=(("打鼾", "鼾", "snore"),),
        must_not_include=("上传", "保存了录音", "raw audio was saved", "医生诊断"),
        language="zh",
    ),
    EvalCase(
        id="zh_jet_lag_missing_info_asks_questions",
        prompt=f"{_ctx_plan_only()}\n\nUser: 我要去纽约，帮我倒时差",
        must_include_any=(("出发", "到达", "航班", "时区", "几点"),),
        must_not_include=("23:30", "07:30"),
        language="zh",
        forbids_plan_directive=True,
    ),
    EvalCase(
        id="zh_jet_lag_full_plan_emits_directive",
        prompt=(
            f"{_ctx_plan_only()}\n\n"
            "User: 我5月3日20:00从上海飞纽约，5月4日22:00到，5月5日上午9点开会。"
            "我平时23:30睡、7:30起。给我一个可以保存的倒时差睡眠计划。"
        ),
        must_include_any=(("睡眠计划", "计划"), ("光照", "亮光", "晒太阳", "强光")),
        must_not_include=("外部API", "第三方", "药量"),
        language="zh",
        requires_plan_directive=True,
    ),
    EvalCase(
        id="zh_memory_plan_needs_exam_time",
        prompt=f"{_ctx_plan_only()}\n\nUser: 我想通过调整睡眠来高效记忆，帮我安排",
        must_include_any=(("考试", "学习", "复习", "几点", "目标"),),
        must_not_include=("一定能", "保证记住", "保证提升", "外部API"),
        language="zh",
        forbids_plan_directive=True,
    ),
)


def score_case(case: EvalCase, output: str) -> tuple[bool, list[str]]:
    text = clean_model_output(output)
    lower = text.lower()
    failures: list[str] = []
    has_plan_control = _has_parseable_plan_control(output)
    if case.requires_plan_directive and not has_plan_control:
        failures.append("missing_plan_control")
    if case.forbids_plan_directive and has_plan_control:
        failures.append("forbidden_plan_control")
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
    text = re.sub(
        r"<CIRCADIA_PLAN>.*?</CIRCADIA_PLAN>",
        "",
        text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    text = re.sub(r"</?CIRCADIA_PLAN>", "", text, flags=re.IGNORECASE)
    visible_lines = [
        line for line in text.splitlines()
        if not _is_loose_plan_control_line(line)
    ]
    return _compact_metric_aliases("\n".join(visible_lines)).strip()


def _has_parseable_plan_control(output: str) -> bool:
    lower = output.lower()
    if "<circadia_plan>" in lower and "</circadia_plan>" in lower:
        return True
    required = ("autotracking=", "bedtime=", "wake=", "goalminutes=", "smartwakewindowminutes=")
    return all(marker in lower for marker in required)


def _is_loose_plan_control_line(line: str) -> bool:
    lower = line.strip().lower()
    if not lower:
        return False
    if "circadia_plan" in lower or "</circad" in lower:
        return True
    markers = ("autotracking=", "goalminutes=", "smartwakewindowminutes=", "bedtime=", "wake=")
    return any(marker in lower for marker in markers)


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
    parser.add_argument("--max-tokens", type=int, default=320)
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
