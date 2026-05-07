from halo_mcp_atlassian.adf import markdown_to_adf, plain_text_adf


def test_empty():
    assert markdown_to_adf("") == {"version": 1, "type": "doc", "content": []}


def test_paragraph_with_bold_italic_code():
    doc = markdown_to_adf("hello **world** *foo* `bar`")
    para = doc["content"][0]
    assert para["type"] == "paragraph"
    marks = [n.get("marks", []) for n in para["content"]]
    types = [m[0]["type"] for m in marks if m]
    assert "strong" in types and "em" in types and "code" in types


def test_bullet_list():
    doc = markdown_to_adf("- one\n- two")
    assert doc["content"][0]["type"] == "bulletList"
    assert len(doc["content"][0]["content"]) == 2


def test_code_block():
    doc = markdown_to_adf("```python\nprint(1)\n```")
    block = doc["content"][0]
    assert block["type"] == "codeBlock"
    assert block["attrs"]["language"] == "python"


def test_plain_text():
    doc = plain_text_adf("hi")
    assert doc["content"][0]["content"][0]["text"] == "hi"
