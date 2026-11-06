"""安全分级与用例校验。

安全清单是白名单：规则未覆盖的 operation 一律按 unimplemented 处理，
新增接口必须先登记，避免"默认放行"。
"""

from __future__ import annotations

import fnmatch
import json
from pathlib import Path

LEVELS = ("normal", "heavy", "destructive", "unimplemented")
DEFAULT_SAFETY = Path(__file__).resolve().parents[1] / "spec" / "safety.json"


class SpecError(Exception):
    """契约或安全清单不满足执行条件。"""


def load_safety(path: Path = DEFAULT_SAFETY) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def classify(safety: dict, operation: str) -> str:
    """按规则顺序匹配，先命中者生效；未命中视为 unimplemented。"""
    for rule in safety.get("rules", []):
        if not fnmatch.fnmatchcase(operation, rule["match"]):
            continue
        level = rule["level"]
        if level not in LEVELS:
            raise SpecError(f"unknown safety level {level!r} for {operation}")
        return level
    return "unimplemented"


def validate_cases(inventory: dict, safety: dict, cases: list[dict]) -> None:
    """执行前一次性校验，任何一条不满足都按清单漂移处理。

    heavy 不在这里拒绝：执行器按 --allow-heavy 跳过，而不是让整轮失败。
    """
    operations = inventory.get("operations", {})
    for case in cases:
        op = case.get("operation", "")
        if op not in operations:
            raise SpecError(f"case {case.get('id', '?')} references unknown operation {op}")
        level = classify(safety, op)
        if level == "destructive":
            raise SpecError(f"case {case.get('id', '?')} targets destructive operation {op}")
        if level == "unimplemented":
            raise SpecError(f"case {case.get('id', '?')} targets unclassified operation {op}")
