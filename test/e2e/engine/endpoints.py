"""从 go-zero .api 文件生成端点清单。

用例绑定 operation，不绑定路径：契约调整路由时，用例不需要跟着改。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
API_ROOT = REPO_ROOT / "protocol" / "api"
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "spec" / "endpoints.json"

_PREFIX_RE = re.compile(r"^prefix:\s*(\S+)\s*$")
_HANDLER_RE = re.compile(r"^@handler\s+(\w+)\s*$")
_DOC_RE = re.compile(r'^@doc\s+"([^"]*)"')
_ROUTE_RE = re.compile(r"^(get|post|put|delete|patch)\s+(\S+)")


def parse_api_file(path: Path, scope: str) -> list[dict]:
    """解析单个 .api 文件，返回其中的路由。"""
    endpoints: list[dict] = []
    prefix = ""
    handler = ""
    doc = ""

    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()

        # 每个 @server 块重新读取 prefix，避免沿用上一个块的值
        if line.startswith("@server"):
            prefix = ""
            continue

        match = _PREFIX_RE.match(line)
        if match:
            prefix = match.group(1)
            continue

        match = _HANDLER_RE.match(line)
        if match:
            handler = match.group(1)
            continue

        match = _DOC_RE.match(line)
        if match:
            doc = match.group(1)
            continue

        match = _ROUTE_RE.match(line)
        if not match or not handler:
            continue

        method, route = match.group(1).upper(), match.group(2)
        if route.startswith(("http://", "https://")):
            handler = ""
            continue

        try:
            file_label = str(path.relative_to(REPO_ROOT))
        except ValueError:
            file_label = str(path)

        endpoints.append(
            {
                "operation": f"{scope}:{handler}",
                "handler": handler,
                "method": method,
                "path": prefix.rstrip("/") + "/" + route.lstrip("/"),
                "doc": doc,
                "file": file_label,
                "line": lineno,
            }
        )
        handler = ""
        doc = ""

    return endpoints


def collect(api_root: Path = API_ROOT) -> dict:
    """遍历 api_root 下的 scope 目录，返回可写入 endpoints.json 的结构。"""
    if not api_root.is_dir():
        raise FileNotFoundError(f"api root not found: {api_root}")

    operations: dict[str, dict] = {}
    for scope_dir in sorted(p for p in api_root.iterdir() if p.is_dir()):
        for path in sorted(scope_dir.glob("*.api")):
            for endpoint in parse_api_file(path, scope_dir.name):
                op = endpoint["operation"]
                if op in operations:
                    raise ValueError(
                        f"duplicate operation {op}: "
                        f"{operations[op]['file']}:{operations[op]['line']} and "
                        f"{endpoint['file']}:{endpoint['line']}"
                    )
                operations[op] = endpoint

    return {
        "generated_from": str(api_root.relative_to(REPO_ROOT)),
        "count": len(operations),
        "operations": dict(sorted(operations.items())),
    }


def dumps(inventory: dict) -> str:
    return json.dumps(inventory, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def write(inventory: dict, output: Path = DEFAULT_OUTPUT) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(dumps(inventory), encoding="utf-8")


def load(path: Path = DEFAULT_OUTPUT) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))
