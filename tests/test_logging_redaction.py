

from halo_mcp_atlassian.logging import configure, get_logger


def test_redacts_secret_keys(monkeypatch, capsys):
    configure("INFO")
    log = get_logger("test")
    log.info("event",
             authorization="Basic abc",
             api_key="xxx",
             token="yyy",
             ok="visible")
    out = capsys.readouterr().err
    assert "Basic abc" not in out
    assert "xxx" not in out
    assert "yyy" not in out
    assert "visible" in out
    assert "***REDACTED***" in out
