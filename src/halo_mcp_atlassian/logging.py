"""structlog configuration with secret redaction.

- JSON to stderr
- Authorization headers and any key matching /token|secret|password|cookie/i are redacted
- Request/response bodies are NEVER logged
"""

from __future__ import annotations

import logging
import re
import sys
from typing import Any

import structlog

_REDACT_KEY = re.compile(r"(authorization|token|secret|password|cookie|api[_-]?key)", re.I)
_REDACT_VALUE = "***REDACTED***"


def _redact(_logger: Any, _name: str, event_dict: dict[str, Any]) -> dict[str, Any]:
    return {k: (_REDACT_VALUE if _REDACT_KEY.search(k) else v) for k, v in event_dict.items()}


def configure(level: str = "INFO") -> None:
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stderr,
        level=getattr(logging, level.upper(), logging.INFO),
    )
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            _redact,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, level.upper(), logging.INFO)
        ),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stderr),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str) -> structlog.stdlib.BoundLogger:
    return structlog.get_logger(name)
