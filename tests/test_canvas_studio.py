"""
Canvas AI Studio 라우트 테스트.

핵심 계약:
  - 비로그인 사용자는 페이지도, 생성 엔드포인트도 쓸 수 없다 (AI 비용 유발 방지).
  - /studio/generate 는 /api/* 가 아니므로 CSRF 검사를 통과해야 한다.
  - 서버에 AI 제공사/키가 설정되지 않으면 503으로 명확히 거부한다 (브라우저에 묻지 않는다).
  - provider 에 따라 올바른 SDK(anthropic/openai)로 위임한다.
"""
from __future__ import annotations

from app.blueprints import canvas_studio


def _login_and_get_csrf(client, login, user_factory, form_path="/studio"):
    username, password, _uid = user_factory()
    login(username, password)
    page = client.get(form_path)
    assert page.status_code == 200
    with client.session_transaction() as sess:
        return sess.get("csrf_token", "")


def test_studio_page_requires_login(client):
    res = client.get("/studio", follow_redirects=False)
    assert res.status_code == 302
    assert "/auth/login" in res.headers["Location"]


def test_studio_page_ok_when_logged_in(client, login, user_factory):
    username, password, _uid = user_factory()
    login(username, password)
    res = client.get("/studio")
    assert res.status_code == 200
    assert b"Canvas AI Studio" in res.data


def test_generate_requires_csrf(client):
    """CSRF 토큰 없이 보내면 로그인 여부와 무관하게 거부된다 (전역 before_request)."""
    res = client.post("/studio/generate", json={"image": "data:image/png;base64,abc"})
    assert res.status_code == 400


def test_generate_without_ai_config_returns_503(client, login, user_factory):
    token = _login_and_get_csrf(client, login, user_factory)
    res = client.post(
        "/studio/generate",
        json={"image": "data:image/png;base64,abc", "prompt": "test"},
        headers={"X-CSRF-Token": token},
    )
    assert res.status_code == 503
    assert "설정되지" in res.get_json()["error"]


def test_generate_rejects_missing_image(client, login, user_factory, app):
    app.config_obj.CANVAS_AI_PROVIDER = "anthropic"
    app.config_obj.CANVAS_AI_API_KEY = "test-key"
    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"prompt": "test"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 400
    finally:
        app.config_obj.CANVAS_AI_PROVIDER = ""
        app.config_obj.CANVAS_AI_API_KEY = ""


def test_generate_success_anthropic(client, login, user_factory, app, monkeypatch):
    app.config_obj.CANVAS_AI_PROVIDER = "anthropic"
    app.config_obj.CANVAS_AI_API_KEY = "test-key"
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

    monkeypatch.setattr(canvas_studio.anthropic, "Anthropic", _FakeClient)

    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"image": "data:image/png;base64,abc", "prompt": "요약해줘"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 200
        assert res.get_json()["markdown"] == "# 제목\n\n본문"
        assert captured["api_key"] == "test-key"
        assert captured["model"] == "claude-haiku-4-5"
        image_block, text_block = captured["messages"][0]["content"]
        assert image_block["source"]["media_type"] == "image/png"
        assert image_block["source"]["data"] == "abc"
        assert text_block["text"] == "요약해줘"
    finally:
        app.config_obj.CANVAS_AI_PROVIDER = ""
        app.config_obj.CANVAS_AI_API_KEY = ""


def test_generate_success_openai(client, login, user_factory, app, monkeypatch):
    app.config_obj.CANVAS_AI_PROVIDER = "openai"
    app.config_obj.CANVAS_AI_API_KEY = "test-key"
    app.config_obj.CANVAS_AI_MODEL = "gpt-4o-mini-test"
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
            captured["api_key"] = api_key
            self.chat = _FakeChat()

    monkeypatch.setattr(canvas_studio.openai, "OpenAI", _FakeClient)

    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"image": "data:image/png;base64,abc", "prompt": "요약해줘"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 200
        assert res.get_json()["markdown"] == "# 제목\n\n본문"
        assert captured["model"] == "gpt-4o-mini-test"
        text_part, image_part = captured["messages"][0]["content"]
        assert text_part["text"] == "요약해줘"
        assert image_part["image_url"]["url"] == "data:image/png;base64,abc"
    finally:
        app.config_obj.CANVAS_AI_PROVIDER = ""
        app.config_obj.CANVAS_AI_API_KEY = ""
        app.config_obj.CANVAS_AI_MODEL = ""


def test_generate_upstream_error_returns_502(client, login, user_factory, app, monkeypatch):
    app.config_obj.CANVAS_AI_PROVIDER = "anthropic"
    app.config_obj.CANVAS_AI_API_KEY = "test-key"

    class _FakeMessages:
        def create(self, **kwargs):
            raise canvas_studio.anthropic.APIConnectionError(request=None)

    class _FakeClient:
        def __init__(self, api_key=None, timeout=None):
            self.messages = _FakeMessages()

    monkeypatch.setattr(canvas_studio.anthropic, "Anthropic", _FakeClient)

    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"image": "data:image/png;base64,abc", "prompt": "test"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 502
    finally:
        app.config_obj.CANVAS_AI_PROVIDER = ""
        app.config_obj.CANVAS_AI_API_KEY = ""
