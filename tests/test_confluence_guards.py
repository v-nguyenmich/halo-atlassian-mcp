import os
import tempfile

import pytest

from halo_mcp_atlassian.tools.confluence import (
    _resolve_upload_path,
    _validate_storage_body,
)


def test_path_jail_accepts_file_inside_root(tmp_path):
    f = tmp_path / "ok.png"
    f.write_bytes(b"x")
    assert _resolve_upload_path("ok.png", str(tmp_path)) == os.path.realpath(str(f))


def test_path_jail_rejects_absolute_outside_root(tmp_path):
    other = tempfile.NamedTemporaryFile(delete=False)
    other.write(b"x")
    other.close()
    try:
        with pytest.raises(ValueError, match="escapes upload_root"):
            _resolve_upload_path(other.name, str(tmp_path))
    finally:
        os.unlink(other.name)


def test_path_jail_rejects_dot_dot(tmp_path):
    with pytest.raises(ValueError, match="escapes upload_root"):
        _resolve_upload_path("../etc/passwd", str(tmp_path))


def test_path_jail_rejects_missing_file(tmp_path):
    with pytest.raises(ValueError, match="regular file"):
        _resolve_upload_path("nope.png", str(tmp_path))


@pytest.mark.parametrize("body", [
    "<p>ok</p><script>alert(1)</script>",
    '<p onclick="x">ok</p>',
    '<a href="javascript:alert(1)">x</a>',
    '<iframe src="x"></iframe>',
    '<ac:structured-macro ac:name="html"><ac:plain-text-body>x</ac:plain-text-body></ac:structured-macro>',
    '<ac:structured-macro ac:name="include"></ac:structured-macro>',
])
def test_storage_body_rejects_dangerous(body):
    with pytest.raises(ValueError):
        _validate_storage_body(body)


def test_storage_body_accepts_safe_content():
    _validate_storage_body(
        '<h2>Title</h2><p>body <code>x</code></p>'
        '<ac:structured-macro ac:name="code"><ac:parameter ac:name="language">python</ac:parameter>'
        '<ac:plain-text-body><![CDATA[print(1)]]></ac:plain-text-body></ac:structured-macro>'
    )
