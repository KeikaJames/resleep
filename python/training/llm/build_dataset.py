"""Build a Sleep-AI fine-tuning dataset from seed JSONL files.

Reads `seed_data/*.jsonl`, validates each record, optionally generates
synthetic paraphrases, and emits the `train.jsonl` / `valid.jsonl`
splits that `mlx_lm.lora` expects.

Format produced:

    {"messages": [{"role": "system", "content": "..."},
                  {"role": "user",   "content": "..."},
                  {"role": "assistant", "content": "..."}]}

Run:

    python -m training.llm.build_dataset \
        --seed-dir python/training/llm/seed_data \
        --out-dir  python/training/llm/dataset

This is intentionally simple — the goal is a high-quality, *small*
seed set that locks the model on-topic. Scaling the dataset up
(via real user feedback) is a separate concern.
"""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List


@dataclass(frozen=True)
class Conversation:
    """One supervised training example: a (system, user, assistant) trio."""
    system: str
    user: str
    assistant: str

    def to_messages(self) -> dict:
        # Gemma's chat template does not support a `system` role, so we
        # prepend the system instruction to the first user turn. This keeps
        # the behavioral conditioning in-context while remaining compatible
        # with mlx-lm's tokenizer.apply_chat_template path.
        merged_user = f"{self.system}\n\n{self.user}" if self.system else self.user
        return {
            "messages": [
                {"role": "user", "content": merged_user},
                {"role": "assistant", "content": self.assistant},
            ]
        }


def load_seed_file(path: Path) -> List[Conversation]:
    """Read a JSONL seed file and return validated conversations.

    Skips and reports any malformed lines instead of failing the whole
    build — a single typo shouldn't kill the pipeline.
    """
    convs: List[Conversation] = []
    with path.open("r", encoding="utf-8") as fh:
        for i, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                msgs = obj["messages"]
                roles = [m["role"] for m in msgs]
                assert roles == ["system", "user", "assistant"], roles
                convs.append(
                    Conversation(
                        system=msgs[0]["content"],
                        user=msgs[1]["content"],
                        assistant=msgs[2]["content"],
                    )
                )
            except (json.JSONDecodeError, AssertionError, KeyError) as exc:
                print(f"  ! {path.name}:{i} skipped — {exc}")
    return convs


def split(
    convs: List[Conversation],
    val_fraction: float,
    seed: int,
) -> tuple[List[Conversation], List[Conversation]]:
    rng = random.Random(seed)
    items = list(convs)
    rng.shuffle(items)
    n_val = max(1, int(len(items) * val_fraction))
    return items[n_val:], items[:n_val]


def write_jsonl(path: Path, convs: Iterable[Conversation]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with path.open("w", encoding="utf-8") as fh:
        for c in convs:
            fh.write(json.dumps(c.to_messages(), ensure_ascii=False) + "\n")
            n += 1
    return n


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed-dir", type=Path,
                        default=Path("python/training/llm/seed_data"))
    parser.add_argument("--out-dir",  type=Path,
                        default=Path("python/training/llm/dataset"))
    parser.add_argument("--val-fraction", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=1729)
    args = parser.parse_args()

    seed_files = sorted(args.seed_dir.glob("*.jsonl"))
    if not seed_files:
        raise SystemExit(f"No seed files in {args.seed_dir}")

    all_convs: List[Conversation] = []
    for f in seed_files:
        items = load_seed_file(f)
        print(f"  · {f.name}: {len(items)} examples")
        all_convs.extend(items)

    if not all_convs:
        raise SystemExit("All seed files empty after validation.")

    train, val = split(all_convs, args.val_fraction, args.seed)

    n_train = write_jsonl(args.out_dir / "train.jsonl", train)
    n_val   = write_jsonl(args.out_dir / "valid.jsonl", val)
    # mlx-lm also looks for test.jsonl — duplicate validation as a placeholder.
    n_test  = write_jsonl(args.out_dir / "test.jsonl",  val)

    print(
        f"\nWrote: train={n_train}  valid={n_val}  test={n_test}  "
        f"→ {args.out_dir}"
    )


if __name__ == "__main__":
    main()
