"""
Canvas AI Studio — 도형/텍스트/이미지를 캔버스에 배치해 AI로 마크다운 변환.

보안 설계:
  - 실제 AI 제공사 키는 이 컨테이너(web)에 없다. web 은 backend(internal)
    네트워크에만 있어 인터넷에 못 나간다 — DB 유출 방지를 위한 격리
    (docker-compose.yml)를 이 기능 때문에 풀지 않았다. 대신 frontend+backend
    양쪽에 연결된 별도 ai-proxy 컨테이너(app/ai_proxy_server.py)가 인터넷
    접근과 AI 키를 전담하고, web 은 내부망으로 그 프록시만 호출한다.
  - 이 라우트는 /api/ 접두어를 쓰지 않는다. /api/* 는 읽기 전용이라 CSRF 검사를
    건너뛰는데(app/__init__.py), 이 엔드포인트는 상태 변경(외부 과금 호출)이라
    CSRF 보호 대상이어야 한다.
  - 로그인한 사용자만 사용할 수 있다 (비로그인 사용자가 AI 비용을 유발하지 못하게).
"""
from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from functools import wraps

from flask import (
    Blueprint,
    current_app,
    flash,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

log = logging.getLogger(__name__)
bp = Blueprint("canvas_studio", __name__)

MAX_PROMPT_LEN = 2000

# 내부 전용 — 같은 backend 네트워크 안의 컴포즈 서비스명이다.
# 사용자 입력이나 설정값이 아니므로 고정 상수로 둔다.
AI_PROXY_URL = "http://ai-proxy:8100/generate"


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get("user_id"):
            flash("로그인이 필요합니다.", "error")
            return redirect(url_for("auth.login", next=request.path))
        return fn(*args, **kwargs)
    return wrapper


@bp.get("/studio")
@login_required
def studio():
    return render_template("canvas_studio.html")


def _looks_like_image_data_url(image: str) -> bool:
    return image.startswith("data:image/") and "," in image


@bp.post("/studio/generate")
@login_required
def generate():
    cfg = current_app.config_obj

    if not cfg.CANVAS_AI_PROXY_TOKEN:
        return jsonify(error="AI 프록시가 서버에 설정되지 않았습니다 (.env 의 CANVAS_AI_PROXY_TOKEN)."), 503

    data = request.get_json(silent=True) or {}
    image = (data.get("image") or "").strip()
    prompt = (data.get("prompt") or "").strip()[:MAX_PROMPT_LEN]

    if not _looks_like_image_data_url(image):
        return jsonify(error="캔버스 이미지가 없거나 형식이 올바르지 않습니다."), 400

    payload = json.dumps({"image": image, "prompt": prompt}).encode("utf-8")
    req = urllib.request.Request(  # noqa: S310 -- 고정된 내부 호스트명(ai-proxy), 사용자 입력 아님
        AI_PROXY_URL,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Internal-Token": cfg.CANVAS_AI_PROXY_TOKEN,
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=cfg.CANVAS_AI_TIMEOUT_SEC + 5) as resp:  # noqa: S310  # nosec: B310 -- 고정된 내부 호스트명, 사용자 입력 아님
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            body = {}
        status = e.code if e.code in (400, 403, 503) else 502
        return jsonify(error=body.get("error") or "AI 프록시 오류"), status
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        log.warning("AI 프록시 호출 실패 user=%s", session.get("username"))
        return jsonify(error="AI 프록시 호출에 실패했습니다. 잠시 후 다시 시도하세요."), 502

    return jsonify(markdown=body.get("markdown", ""))
