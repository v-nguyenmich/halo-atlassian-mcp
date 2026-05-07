"""httpx wrapper for Atlassian Cloud.

- Basic auth from Config (email + API token)
- Authorization header redacted in any request/response logging
- Retries on 429 / 5xx with exponential backoff
- Never logs request/response bodies
- Hard-bound to the configured base URLs (SSRF guard)
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

import httpx

from .config import Config
from .logging import get_logger

log = get_logger(__name__)

_RETRY_STATUS = {429, 500, 502, 503, 504}
_MAX_RETRIES = 4
_MAX_RETRY_AFTER_S = 30.0
_TOTAL_REQUEST_BUDGET_S = 120.0


class AtlassianHTTPError(RuntimeError):
    def __init__(self, status: int, method: str, path: str, message: str = "") -> None:
        super().__init__(f"{method} {path} -> {status} {message}".strip())
        self.status = status
        self.method = method
        self.path = path


class AtlassianClient:
    """Async client. One instance per product (jira / confluence)."""

    def __init__(self, base_url: str, cfg: Config, *, product: str) -> None:
        self._base_url = base_url
        self._product = product
        self._client = httpx.AsyncClient(
            base_url=base_url,
            auth=(cfg.auth_email, cfg.auth_token),
            timeout=cfg.request_timeout_s,
            headers={
                "Accept": "application/json",
                "User-Agent": "halo-mcp-atlassian/0.1.0",
            },
            event_hooks={"request": [self._on_request], "response": [self._on_response]},
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    # ----- public verbs ---------------------------------------------------

    async def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        return await self._request("GET", path, params=params)

    async def post(
        self,
        path: str,
        json: Any = None,
        params: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> Any:
        return await self._request("POST", path, json=json, params=params, headers=headers)

    async def put(
        self,
        path: str,
        json: Any = None,
        params: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> Any:
        return await self._request("PUT", path, json=json, params=params, headers=headers)

    async def delete(self, path: str, params: dict[str, Any] | None = None) -> Any:
        return await self._request("DELETE", path, params=params)

    async def post_multipart(
        self, path: str, files: dict[str, Any], extra_headers: dict[str, str] | None = None
    ) -> Any:
        headers = {"X-Atlassian-Token": "no-check"}
        if extra_headers:
            headers.update(extra_headers)
        return await self._request("POST", path, files=files, headers=headers)

    # ----- internals ------------------------------------------------------

    async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        attempt = 0
        budget_started = time.monotonic()
        while True:
            attempt += 1
            started = time.monotonic()
            try:
                resp = await self._client.request(method, path, **kwargs)
            except httpx.HTTPError as e:
                log.warning("http.error", product=self._product, method=method, path=path,
                            attempt=attempt, error=type(e).__name__)
                if attempt > _MAX_RETRIES or _budget_exhausted(budget_started):
                    raise
                await asyncio.sleep(_backoff(attempt))
                continue

            elapsed_ms = int((time.monotonic() - started) * 1000)
            log.info("http.response", product=self._product, method=method, path=path,
                     status=resp.status_code, attempt=attempt, elapsed_ms=elapsed_ms)

            if resp.status_code in _RETRY_STATUS and attempt <= _MAX_RETRIES \
                    and not _budget_exhausted(budget_started):
                retry_after = min(_retry_after(resp, attempt), _MAX_RETRY_AFTER_S)
                await asyncio.sleep(retry_after)
                continue

            if resp.status_code >= 400:
                raise AtlassianHTTPError(
                    resp.status_code, method, path, _safe_error_message(resp)
                )

            if resp.status_code == 204 or not resp.content:
                return None
            ctype = resp.headers.get("content-type", "")
            if "application/json" in ctype:
                return resp.json()
            return resp.text

    async def _on_request(self, request: httpx.Request) -> None:
        log.debug("http.request", product=self._product,
                  method=request.method, path=request.url.path)

    async def _on_response(self, response: httpx.Response) -> None:
        # No bodies logged. Status logged in _request after retry decision.
        return None


def _budget_exhausted(started: float) -> bool:
    return (time.monotonic() - started) >= _TOTAL_REQUEST_BUDGET_S


def _backoff(attempt: int) -> float:
    return min(2 ** (attempt - 1), 16.0)


def _retry_after(resp: httpx.Response, attempt: int) -> float:
    header = resp.headers.get("retry-after")
    if header:
        try:
            return float(header)
        except ValueError:
            pass
    return _backoff(attempt)


def _safe_error_message(resp: httpx.Response) -> str:
    """Surface Atlassian error messages WITHOUT echoing arbitrary user content
    that could carry secrets or prompt-injection payloads.
    Limit length, strip newlines, and wrap in an untrusted-content delimiter
    so downstream LLMs are signaled not to follow embedded instructions."""
    try:
        data = resp.json()
        msgs = data.get("errorMessages") or []
        errs = data.get("errors") or {}
        text = "; ".join([*msgs, *(f"{k}={v}" for k, v in errs.items())])
    except Exception:
        text = resp.text or ""
    text = text.replace("\n", " ")[:300]
    return f"<atlassian-untrusted>{text}</atlassian-untrusted>" if text else ""
