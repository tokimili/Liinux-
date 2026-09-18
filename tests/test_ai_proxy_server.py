"""
ai-proxy — 실제 Claude/OpenAI 비전 API 호출을 전담하는 별도 Flask 앱 테스트.

이 앱은 메인 app(app/__init__.py)과 완전히 분리되어 있어 DB·세션이 필요
없다 — 순수 함수형 라우트라 test_client() 만으로 바로 검증 가능하다.

핵심 계약:
  - X-Internal-Token 이 없거나 틀리면 거부한다 (web 만 호출할 수 있어야 함).
  - provider/키가 서버(ai-proxy)에 설정되지 않으면 503.
  - provider 에 따라 올바른 SDK/REST 호출(anthropic/openai/gemini)로 위임한다.
"""
from __future__ import annotations

import json

import pytest

from app import ai_proxy_server


@pytest.fixture
def proxy_client(monkeypatch):
    monkeypatch.setattr(ai_proxy_server, "INTERNAL_TOKEN", "shared-secret")
    monkeypatch.setattr(ai_proxy_server, "PROVIDER", "")
    monkeypatch.setattr(ai_proxy_server, "API_KEY", "")
    monkeypatch.setattr(ai_proxy_server, "MODEL_OVERRIDE", "")
    return ai_proxy_server.app.test_client()


def _auth_headers(token="shared-secret"):
    return {"X-Internal-Token": token}


def test_healthz(proxy_client):
    res = proxy_client.get("/healthz")
    assert res.status_code == 200
    assert res.get_json()["status"] == "ok"


def test_generate_rejects_missing_token(proxy_client):
    res = proxy_client.post("/generate", json={"image": "data:image/png;base64,abc"})
    assert res.status_code == 403


def test_generate_rejects_wrong_token(proxy_client):
    res = proxy_client.post(
        "/generate", json={"image": "data:image/png;base64,abc"}, headers=_auth_headers("wrong")
    )
    assert res.status_code == 403


def test_generate_no_internal_token_configured_returns_503(proxy_client, monkeypatch):
    monkeypatch.setattr(ai_proxy_server, "INTERNAL_TOKEN", "")
    res = proxy_client.post(
        "/generate", json={"image": "data:image/png;base64,abc"}, headers=_auth_headers("anything")
    )
    assert res.status_code == 503


def test_generate_without_provider_returns_503(proxy_client):
    res = proxy_client.post(
        "/generate", json={"image": "data:image/png;base64,abc"}, headers=_auth_headers()
    )
    assert res.status_code == 503
    assert "제공사" in res.get_json()["error"]


def test_generate_rejects_missing_image(proxy_client, monkeypatch):
    monkeypatch.setattr(ai_proxy_server, "PROVIDER", "anthropic")
    monkeypatch.setattr(ai_proxy_server, "API_KEY", "test-key")
    res = proxy_client.post("/generate", json={"prompt": "test"}, headers=_auth_headers())
    assert res.status_code == 400


def test_generate_success_anthropic(proxy_client, monkeypatch):
    monkeypatch.setattr(ai_proxy_server, "PROVIDER", "anthropic")
    monkeypatch.setattr(ai_proxy_server, "API_KEY", "test-key")
    captured = {}

    class _FakeBlock:
        type = "text"
        text = "# 제목\n\n본문"

    class _FakeResponse:
        content = [_FakeBlock()]

    class _FakeMessages:
        def create(self, **kwargs):
            captured.update(kwargs)
            return _FakeResponse()

    class _FakeClient:
        def __init__(self, api_key=None, timeout=None):
            captured["api_key"] = api_key
            self.messages = _FakeMessages()

    monkeypatch.setattr(ai_proxy_server.anthropic, "Anthropic", _FakeClient)

    res = proxy_client.post(
        "/generate",
        json={"image": "data:image/png;base64,abc", "prompt": "요약해줘"},
        headers=_auth_headers(),
    )
    assert res.status_code == 200
    assert res.get_json()["markdown"] == "# 제목\n\n본문"
    assert captured["api_key"] == "test-key"
    assert captured["model"] == "claude-haiku-4-5"
    image_block, text_block = captured["messages"][0]["content"]
    assert image_block["source"]["media_type"] == "image/png"
    assert image_block["source"]["data"] == "abc"
    assert text_block["text"] == "요약해줘"


def test_generate_success_openai_with_model_override(proxy_client, monkeypatch):
    monkeypatch.setattr(ai_proxy_server, "PROVIDER", "openai")
    monkeypatch.setattr(ai_proxy_server, "API_KEY", "test-key")
    monkeypatch.setattr(ai_proxy_server, "MODEL_OVERRIDE", "gpt-4o-mini-test")
    captured = {}

    class _FakeMessage:
        content = "# 제목\n\n본문"

    class _FakeChoice:
        message = _FakeMessage()

    class _FakeResponse:
        choices = [_FakeChoice()]

    class _FakeCompletions:
        def create(self, **kwargs):
            captured.update(kwargs)
            return _FakeResponse()

    class _FakeChat:
        def __init__(self):
            self.completions = _FakeCompletions()

    class _FakeClient:
        def __init__(self, api_key=None, timeout=None):
            self.chat = _FakeChat()

    monkeypatch.setattr(ai_proxy_server.openai, "OpenAI", _FakeClient)

    res = proxy_client.post(
        "/generate",
        json={"image": "data:image/png;base64,abc", "prompt": "요약해줘"},
        headers=_auth_headers(),
    )
    assert res.status_code == 200
    assert res.get_json()["markdown"] == "# 제목\n\n본문"
    assert captured["model"] == "gpt-4o-mini-test"
    text_part, image_part = captured["messages"][0]["content"]
    assert text_part["text"] == "요약해줘"
    assert image_part["image_url"]["url"] == "data:image/png;base64,abc"


def test_generate_upstream_error_returns_502(proxy_client, monkeypatch):
    monkeypatch.setattr(ai_proxy_server, "PROVIDER", "anthropic")
    monkeypatch.setattr(ai_proxy_server, "API_KEY", "test-key")

    class _FakeMessages:
        def create(self, **kwargs):
            raise ai_proxy_server.anthropic.APIConnectionError(request=None)

    class _FakeClient:
        def __init__(self, api_key=None, timeout=None):
            self.messages = _FakeMessages()

    monkeypatch.setattr(ai_proxy_server.anthropic, "Anthropic", _FakeClient)

    res = proxy_client.post(
        "/generate",
        json={"image": "data:image/png;base64,abc", "prompt": "test"},
        headers=_auth_headers(),
    )
    assert res.status_code == 502


class _FakeGeminiResponse:
    def __init__(self, body: dict):
        self._body = json.dumps(body).encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_generate_success_gemini(proxy_client, monkeypatch):
    """gemini: 신용카드 없이 무료 API 키로 연동 테스트할 수 있는 provider."""
    monkeypatch.setattr(ai_proxy_server, "PROVIDER", "gemini")
    monkeypatch.setattr(ai_proxy_server, "API_KEY", "test-key")
    captured = {}

    def _fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["timeout"] = timeout
        return _FakeGeminiResponse({
            "candidates": [{"content": {"parts": [{"text": "# 제목\n\n본문"}]}}],
        })

    monkeypatch.setattr(ai_proxy_server.urllib.request, "urlopen", _fake_urlopen)

    res = proxy_client.post(
        "/generate",
        json={"image": "data:image/png;base64,abc", "prompt": "요약해줘"},
        headers=_auth_headers(),
    )
    assert res.status_code == 200
    assert res.get_json()["markdown"] == "# 제목\n\n본문"
    assert "gemini-2.0-flash" in captured["url"]
    assert "test-key" in captured["url"]


def test_generate_gemini_upstream_error_returns_502(proxy_client, monkeypatch):
    monkeypatch.setattr(ai_proxy_server, "PROVIDER", "gemini")
    monkeypatch.setattr(ai_proxy_server, "API_KEY", "test-key")

    def _fake_urlopen(req, timeout=None):
        raise ai_proxy_server.urllib.error.URLError("connection refused")

    monkeypatch.setattr(ai_proxy_server.urllib.request, "urlopen", _fake_urlopen)

    res = proxy_client.post(
        "/generate",
        json={"image": "data:image/png;base64,abc", "prompt": "test"},
        headers=_auth_headers(),
    )
    assert res.status_code == 502
