"""Atlassian Document Format (ADF) helpers.

v1 ships a minimal markdown -> ADF converter sufficient for comments and
short descriptions: paragraphs, line breaks, bold, italic, inline code,
code blocks, bullet lists. Anything richer is escaped as a paragraph of
plain text.

Phase 3 may swap this for a fuller implementation; the interface stays.
"""

from __future__ import annotations

import re
from typing import Any

_FENCE = re.compile(r"^```(\w+)?\s*$")
_BULLET = re.compile(r"^[-*]\s+(.*)$")
_INLINE = re.compile(r"(\*\*(.+?)\*\*|\*(.+?)\*|`([^`]+)`)")


def markdown_to_adf(text: str) -> dict[str, Any]:
    if not text:
        return _doc([])
    blocks: list[dict[str, Any]] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = _FENCE.match(lines[i].strip())
        if m:
            lang = m.group(1) or None
            i += 1
            buf: list[str] = []
            while i < len(lines) and not _FENCE.match(lines[i].strip()):
                buf.append(lines[i])
                i += 1
            i += 1  # skip closing fence
            blocks.append(_code_block("\n".join(buf), lang))
            continue
        if _BULLET.match(lines[i]):
            items: list[dict[str, Any]] = []
            while i < len(lines) and _BULLET.match(lines[i]):
                items.append(_list_item(_BULLET.match(lines[i]).group(1)))
                i += 1
            blocks.append({"type": "bulletList", "content": items})
            continue
        if not lines[i].strip():
            i += 1
            continue
        para_lines: list[str] = []
        while i < len(lines) and lines[i].strip() and not _FENCE.match(lines[i].strip()) \
                and not _BULLET.match(lines[i]):
            para_lines.append(lines[i])
            i += 1
        blocks.append(_paragraph("\n".join(para_lines)))
    return _doc(blocks)


def plain_text_adf(text: str) -> dict[str, Any]:
    return _doc([_paragraph(text)] if text else [])


# ----- builders ----------------------------------------------------------

def _doc(content: list[dict[str, Any]]) -> dict[str, Any]:
    return {"version": 1, "type": "doc", "content": content}


def _paragraph(text: str) -> dict[str, Any]:
    return {"type": "paragraph", "content": _inline(text)}


def _list_item(text: str) -> dict[str, Any]:
    return {"type": "listItem", "content": [_paragraph(text)]}


def _code_block(text: str, language: str | None) -> dict[str, Any]:
    node: dict[str, Any] = {
        "type": "codeBlock",
        "content": [{"type": "text", "text": text}] if text else [],
    }
    if language:
        node["attrs"] = {"language": language}
    return node


def _inline(text: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    pos = 0
    for m in _INLINE.finditer(text):
        if m.start() > pos:
            out.append({"type": "text", "text": text[pos:m.start()]})
        bold, italic, code = m.group(2), m.group(3), m.group(4)
        if bold is not None:
            out.append({"type": "text", "text": bold, "marks": [{"type": "strong"}]})
        elif italic is not None:
            out.append({"type": "text", "text": italic, "marks": [{"type": "em"}]})
        elif code is not None:
            out.append({"type": "text", "text": code, "marks": [{"type": "code"}]})
        pos = m.end()
    if pos < len(text):
        out.append({"type": "text", "text": text[pos:]})
    return out or [{"type": "text", "text": text}]
