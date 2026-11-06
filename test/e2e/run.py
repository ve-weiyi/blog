#!/usr/bin/env python3
"""E2E 契约测试骨架的 CLI。"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from engine import endpoints, runner, spec  # noqa: E402


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="blog E2E 契约测试骨架")
    parser.add_argument("--generate", action="store_true", help="从 protocol/api 生成端点清单")
    parser.add_argument("--check", action="store_true", help="检测端点清单是否与契约一致")
    parser.add_argument("--list", action="store_true", help="列出端点与安全分级")
    parser.add_argument("--suite", default="smoke", help="用例套件名，默认 smoke")
    parser.add_argument("--base-url", default=os.getenv("E2E_BASE_URL", ""), help="网关根地址")
    parser.add_argument("--account", default=os.getenv("E2E_ACCOUNT", ""), help="登录账号")
    parser.add_argument("--password", default=os.getenv("E2E_PASSWORD", ""), help="登录密码")
    parser.add_argument("--timeout", type=float, default=float(os.getenv("E2E_TIMEOUT", "10")))
    parser.add_argument("--allow-heavy", action="store_true", help="允许执行 heavy 级操作")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        inventory = endpoints.collect()
    except (ValueError, FileNotFoundError) as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return runner.EXIT_SPEC

    if args.generate:
        endpoints.write(inventory)
        print(f"generated {endpoints.DEFAULT_OUTPUT} ({inventory['count']} operations)")
        return runner.EXIT_OK

    if args.check:
        if not endpoints.DEFAULT_OUTPUT.is_file():
            print(f"ERROR: {endpoints.DEFAULT_OUTPUT} is missing; run --generate", file=sys.stderr)
            return runner.EXIT_SPEC
        current = endpoints.dumps(inventory)
        stored = endpoints.DEFAULT_OUTPUT.read_text(encoding="utf-8")
        if current != stored:
            print("ERROR: endpoints.json is stale; run --generate", file=sys.stderr)
            return runner.EXIT_SPEC
        print(f"ok: {inventory['count']} operations")
        return runner.EXIT_OK

    safety = spec.load_safety()

    if args.list:
        for op, endpoint in inventory["operations"].items():
            print(f"{spec.classify(safety, op):<13} {endpoint['method']:<6} {endpoint['path']:<50} {op}")
        return runner.EXIT_OK

    if not args.base_url:
        print("ERROR: --base-url or E2E_BASE_URL is required", file=sys.stderr)
        return runner.EXIT_ENV

    try:
        cases = runner.load_suite(args.suite)
        code, report = runner.run(
            inventory,
            safety,
            cases,
            args.base_url,
            args.account,
            args.password,
            args.timeout,
            args.allow_heavy,
        )
    except spec.SpecError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return runner.EXIT_SPEC

    runner.render(report)
    if report["results"]:
        print(f"report: {runner.write_report(report)}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
