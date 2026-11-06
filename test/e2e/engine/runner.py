"""执行用例套件并汇总结果。"""

from __future__ import annotations

import json
import re
import time
import uuid
from pathlib import Path

from .httpc import Client, EnvironmentError
from .spec import SpecError, classify, validate_cases

EXIT_OK = 0
EXIT_ASSERT = 1
EXIT_ENV = 2
EXIT_SPEC = 3

CASES_DIR = Path(__file__).resolve().parents[1] / "cases"
RESULTS_DIR = Path(__file__).resolve().parents[1] / "results"

LOGIN_OPERATION = "app:PasswordLogin"

_VAR_RE = re.compile(r"\{\{(\w+)\}\}")


def load_suite(name: str) -> list[dict]:
    path = CASES_DIR / f"{name}.json"
    if not path.is_file():
        raise SpecError(f"suite not found: {name}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    cases = payload.get("cases")
    if not isinstance(cases, list) or not cases:
        raise SpecError(f"suite {name} has no cases")
    return cases


def login(client: Client, inventory: dict, account: str, password: str) -> str:
    endpoint = inventory["operations"].get(LOGIN_OPERATION)
    if endpoint is None:
        raise SpecError(f"{LOGIN_OPERATION} is missing from endpoint inventory")

    status, payload = client.request(
        endpoint["method"],
        endpoint["path"],
        body={"account": account, "password": password},
    )
    data = payload.get("data") or {}
    token = (data.get("token") or {}).get("access_token")
    if status != 200 or payload.get("code") != "SUCCESS" or not token:
        raise EnvironmentError(
            f"login failed: http={status} code={payload.get('code')!r} message={payload.get('message')!r}"
        )
    return token


def run(
    inventory: dict,
    safety: dict,
    cases: list[dict],
    base_url: str,
    account: str | None,
    password: str | None,
    timeout: float,
    allow_heavy: bool,
) -> tuple[int, dict]:
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    client = Client(base_url, f"e2e-{run_id}", timeout)

    try:
        validate_cases(inventory, safety, cases)
    except SpecError as err:
        return EXIT_SPEC, _report(run_id, base_url, [], str(err))

    token = None
    if account and password:
        try:
            token = login(client, inventory, account, password)
        except (EnvironmentError, SpecError) as err:
            return EXIT_ENV, _report(run_id, base_url, [], str(err))

    results = []
    variables: dict[str, str] = {}
    for case in cases:
        operation = case.get("operation", "")
        level = classify(safety, operation)

        if level == "heavy" and not allow_heavy:
            results.append(_result(case, "skip", "heavy operation; pass --allow-heavy"))
            continue
        if case.get("auth") and not token:
            results.append(_result(case, "skip", "missing E2E_ACCOUNT / E2E_PASSWORD"))
            continue

        endpoint = inventory["operations"][operation]
        try:
            path = _render_path(endpoint["path"], case.get("path_params", {}), variables)
        except SpecError as err:
            return EXIT_SPEC, _report(run_id, base_url, results, str(err))

        try:
            status, payload = client.request(
                endpoint["method"],
                path,
                body=case.get("body"),
                query=case.get("query"),
                token=token if case.get("auth") else None,
            )
        except EnvironmentError as err:
            results.append(_result(case, "fail", str(err)))
            return EXIT_ENV, _report(run_id, base_url, results, "environment error")

        message = assert_case(case, status, payload)
        if message is None and case.get("capture"):
            message = _capture(payload, case["capture"], variables)
            results.append(_result(case, "pass" if message is None else "fail", message, status, payload))
            if message is not None:
                return EXIT_ASSERT, _report(run_id, base_url, results, "capture failed")
            continue
        results.append(_result(case, "pass" if message is None else "fail", message, status, payload))

    code = EXIT_ASSERT if any(r["result"] == "fail" for r in results) else EXIT_OK
    return code, _report(run_id, base_url, results, "")


def _render_path(path: str, path_params: dict, variables: dict[str, str]) -> str:
    """把路径参数里的 {{var}} 替换成前序用例捕获的值。"""
    rendered = path
    for key, value in path_params.items():
        rendered = rendered.replace(":" + key, _expand(str(value), variables))
    return rendered


def _expand(value: str, variables: dict[str, str]) -> str:
    def replace(match: re.Match) -> str:
        name = match.group(1)
        if name not in variables:
            raise SpecError(f"missing variable {name}")
        return variables[name]

    return _VAR_RE.sub(replace, value)


def _capture(payload: dict, spec: dict, variables: dict[str, str]) -> str | None:
    """按点号路径从响应里取值，供后续用例引用。"""
    for name, dotted in spec.items():
        current = payload
        try:
            for part in dotted.split("."):
                current = current[int(part)] if part.isdigit() else current[part]
        except (KeyError, IndexError, TypeError):
            return f"capture {name} from {dotted} failed"
        if current is None or current == "":
            return f"capture {name} from {dotted} is empty"
        variables[name] = str(current)
    return None


def assert_case(case: dict, status: int, payload: dict) -> str | None:
    expect = case.get("expect", {})
    want_status = expect.get("status", 200)
    if status != want_status:
        return f"http status {status}, want {want_status}"

    want_code = expect.get("code", "SUCCESS")
    code = payload.get("code")
    if code != want_code:
        return f"code {code!r}, want {want_code!r}: {payload.get('message')!r}"

    data_type = expect.get("data_type")
    if data_type:
        data = payload.get("data")
        checks = {
            "object": lambda value: isinstance(value, dict),
            "array": lambda value: isinstance(value, list),
            "any": lambda _value: True,
        }
        if data_type not in checks:
            return f"unknown data_type {data_type!r}"
        if not checks[data_type](data):
            return f"data is {type(data).__name__}, want {data_type}"
    return None


def _result(
    case: dict,
    outcome: str,
    message: str | None = None,
    status: int | None = None,
    payload: dict | None = None,
) -> dict:
    return {
        "id": case.get("id", "?"),
        "operation": case.get("operation", ""),
        "result": outcome,
        "message": message or "",
        "http_status": status,
        "trace_id": (payload or {}).get("trace_id", ""),
    }


def _report(run_id: str, base_url: str, results: list[dict], error: str) -> dict:
    summary = {
        "pass": sum(1 for r in results if r["result"] == "pass"),
        "fail": sum(1 for r in results if r["result"] == "fail"),
        "skip": sum(1 for r in results if r["result"] == "skip"),
    }
    return {
        "run_id": run_id,
        "base_url": base_url,
        "error": error,
        "summary": summary,
        "results": results,
    }


def write_report(report: dict) -> Path:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    path = RESULTS_DIR / f"{report['run_id']}.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def render(report: dict) -> None:
    if report["error"]:
        print(f"ERROR: {report['error']}")
    for item in report["results"]:
        suffix = f"  {item['message']}" if item["message"] else ""
        print(f"[{item['result'].upper():4}] {item['id']:<20} {item['operation']}{suffix}")
    summary = report["summary"]
    print(
        f"\npass={summary['pass']} fail={summary['fail']} skip={summary['skip']} "
        f"run_id={report['run_id']}"
    )
