"""
Canvas AI Studio 라우트 테스트.

핵심 계약:
  - 비로그인 사용자는 페이지도, 생성 엔드포인트도 쓸 수 없다 (AI 비용 유발 방지).
  - /studio/generate 는 /api/* 가 아니므로 CSRF 검사를 통과해야 한다.
  - 서버에 AI API가 설정되지 않으면 503으로 명확히 거부한다 (브라우저에 키를 묻지 않는다).
"""
from __future__ import annotations

import json

from app.blueprints import canvas_studio


class _FakeResponse:
    def __init__(self, body: dict):
        self._body = json.dumps(body).encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


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
    app.config_obj.CANVAS_AI_API_URL = "https://ai.example.invalid/generate"
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
        app.config_obj.CANVAS_AI_API_URL = ""
        app.config_obj.CANVAS_AI_API_KEY = ""


def test_generate_success_forwards_to_configured_endpoint(client, login, user_factory, app, monkeypatch):
    app.config_obj.CANVAS_AI_API_URL = "https://ai.example.invalid/generate"
    app.config_obj.CANVAS_AI_API_KEY = "test-key"

    captured = {}

    def _fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["auth"] = req.headers.get("Authorization")
        captured["body"] = json.loads(req.data.decode("utf-8"))
        return _FakeResponse({"markdown": "# 제목\n\n본문"})

    monkeypatch.setattr(canvas_studio.urllib.request, "urlopen", _fake_urlopen)

    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"image": "data:image/png;base64,abc", "prompt": "요약해줘"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 200
        assert res.get_json()["markdown"] == "# 제목\n\n본문"
        assert captured["url"] == "https://ai.example.invalid/generate"
        assert captured["auth"] == "Bearer test-key"
        assert captured["body"]["prompt"] == "요약해줘"
    finally:
        app.config_obj.CANVAS_AI_API_URL = ""
        app.config_obj.CANVAS_AI_API_KEY = ""
