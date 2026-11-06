"""最小 HTTP 客户端，只用标准库。"""

from __future__ import annotations

import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request


class EnvironmentError(Exception):
    """网关不可达、响应不是 JSON 等环境问题。"""


def device_headers(device_id: str, timestamp: int) -> dict[str, str]:
    """网关要求设备 ID、时间戳与签名同时出现：token = sha256(id + timestamp)。"""
    ts = str(timestamp)
    return {
        "X-Device-Id": device_id,
        "Timestamp": ts,
        "X-Device-Token": hashlib.sha256((device_id + ts).encode("utf-8")).hexdigest(),
    }


class Client:
    def __init__(self, base_url: str, device_id: str, timeout: float = 10.0):
        self.base_url = base_url.rstrip("/")
        self.device_id = device_id
        self.timeout = timeout

    def request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        query: dict | None = None,
        token: str | None = None,
    ) -> tuple[int, dict]:
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(query)

        data = None
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "blog-e2e/1",
            **device_headers(self.device_id, int(time.time())),
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        if token:
            headers["Authorization"] = "Bearer " + token

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.status, _decode(response.read())
        except urllib.error.HTTPError as err:
            return err.code, _decode(err.read())
        except urllib.error.URLError as err:
            raise EnvironmentError(f"{method} {url}: {err.reason}") from err


def _decode(raw: bytes) -> dict:
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as err:
        raise EnvironmentError(f"response is not JSON: {raw[:200]!r}") from err
    if not isinstance(payload, dict):
        raise EnvironmentError(f"response is not an object: {payload!r}")
    return payload
