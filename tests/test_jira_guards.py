
from halo_mcp_atlassian.tools.jira import _filter_update_fields, ALLOWED_UPDATE_FIELDS


def test_filter_drops_disallowed_fields():
    out = _filter_update_fields({
        "summary": "ok",
        "reporter": {"accountId": "evil"},
        "security": {"id": "1"},
        "watcher": "evil",
        "customfield_10001": "x",
    })
    assert out == {"summary": "ok"}


def test_filter_keeps_all_allowed():
    payload = {f: "v" for f in ALLOWED_UPDATE_FIELDS}
    assert _filter_update_fields(payload) == payload


def test_filter_handles_empty():
    assert _filter_update_fields({}) == {}
    assert _filter_update_fields(None) == {}
