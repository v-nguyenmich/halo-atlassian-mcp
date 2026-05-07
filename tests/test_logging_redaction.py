

from halo_mcp_atlassian.logging import configure, get_logger


def test_redacts_secret_keys(capsys):
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


def test_redacts_nested_secrets(capsys):
    configure("INFO")
    log = get_logger("test")
    log.info("event",
             extras={"user": {"api_token": "deepsecret"}, "ok": "visible"},
             items=[{"password": "p"}, {"safe": "s"}])
    out = capsys.readouterr().err
    assert "deepsecret" not in out
    assert "\"p\"" not in out  # password value redacted
    assert "visible" in out
    assert "safe" in out
