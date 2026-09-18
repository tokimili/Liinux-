"""
Canvas AI Studio — web 쪽 라우트 테스트.

핵심 계약:
  - 비로그인 사용자는 페이지도, 생성 엔드포인트도 쓸 수 없다 (AI 비용 유발 방지).
  - /studio/generate 는 /api/* 가 아니므로 CSRF 검사를 통과해야 한다.
  - web 은 AI 키를 직접 갖지 않는다 — ai-proxy 컨테이너를 내부망으로 호출만 한다.
    (ai-proxy 자체 로직은 tests/test_ai_proxy_server.py 에서 별도로 검증한다)
"""
from __future__ import annotations

import json
import urllib.error

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


def test_generate_without_proxy_token_returns_503(client, login, user_factory):
    token = _login_and_get_csrf(client, login, user_factory)
    res = client.post(
        "/studio/generate",
        json={"image": "data:image/png;base64,abc", "prompt": "test"},
        headers={"X-CSRF-Token": token},
    )
    assert res.status_code == 503
    assert "설정되지" in res.get_json()["error"]


def test_generate_rejects_missing_image(client, login, user_factory, app):
    app.config_obj.CANVAS_AI_PROXY_TOKEN = "test-internal-token"
    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"prompt": "test"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 400
    finally:
        app.config_obj.CANVAS_AI_PROXY_TOKEN = ""


def test_generate_forwards_to_ai_proxy_and_returns_markdown(client, login, user_factory, app, monkeypatch):
    app.config_obj.CANVAS_AI_PROXY_TOKEN = "test-internal-token"
    captured = {}

    def _fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["token_header"] = req.headers.get("X-internal-token")
        captured["body"] = json.loads(req.data.decode("utf-8"))
        captured["timeout"] = timeout
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
        assert captured["url"] == canvas_studio.AI_PROXY_URL
        assert captured["token_header"] == "test-internal-token"
        assert captured["body"] == {"image": "data:image/png;base64,abc", "prompt": "요약해줘"}
    finally:
        app.config_obj.CANVAS_AI_PROXY_TOKEN = ""


def test_generate_propagates_ai_proxy_error(client, login, user_factory, app, monkeypatch):
    app.config_obj.CANVAS_AI_PROXY_TOKEN = "test-internal-token"

    def _fake_urlopen(req, timeout=None):
        body = json.dumps({"error": "AI API 키가 서버에 설정되지 않았습니다."}).encode("utf-8")
        raise urllib.error.HTTPError(req.full_url, 503, "Service Unavailable", None, __import__("io").BytesIO(body))

    monkeypatch.setattr(canvas_studio.urllib.request, "urlopen", _fake_urlopen)

    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"image": "data:image/png;base64,abc", "prompt": "test"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 503
        assert "설정되지" in res.get_json()["error"]
    finally:
        app.config_obj.CANVAS_AI_PROXY_TOKEN = ""


def test_generate_ai_proxy_unreachable_returns_502(client, login, user_factory, app, monkeypatch):
    app.config_obj.CANVAS_AI_PROXY_TOKEN = "test-internal-token"

    def _fake_urlopen(req, timeout=None):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(canvas_studio.urllib.request, "urlopen", _fake_urlopen)

    try:
        token = _login_and_get_csrf(client, login, user_factory)
        res = client.post(
            "/studio/generate",
            json={"image": "data:image/png;base64,abc", "prompt": "test"},
            headers={"X-CSRF-Token": token},
        )
        assert res.status_code == 502
    finally:
        app.config_obj.CANVAS_AI_PROXY_TOKEN = ""
