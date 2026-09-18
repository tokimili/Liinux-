"""
Canvas AI Studio — 도형/텍스트/이미지를 캔버스에 배치해 AI로 마크다운 변환.

보안 설계:
  - AI API URL/토큰은 서버 설정(.env)에만 존재한다. 브라우저는 절대 모른다 —
    클라이언트가 엔드포인트를 직접 호출하게 하면 누구나 그 키로 과금을 일으킬 수 있다.
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


@bp.post("/studio/generate")
@login_required
def generate():
    cfg = current_app.config_obj

    if not cfg.CANVAS_AI_API_URL or not cfg.CANVAS_AI_API_KEY:
        return jsonify(error="AI API가 서버에 설정되지 않았습니다 (.env 의 CANVAS_AI_API_URL/KEY)."), 503

    data = request.get_json(silent=True) or {}
    image = (data.get("image") or "").strip()
    prompt = (data.get("prompt") or "").strip()[:MAX_PROMPT_LEN]
    canvas_json = data.get("canvas")

    if not image.startswith("data:image/"):
        return jsonify(error="캔버스 이미지가 없습니다."), 400

    # 서버 설정값이지만, file:// 등으로 잘못 입력됐을 때 urlopen 이
    # 로컬 파일을 열어버리는 것을 막기 위해 스킴을 명시적으로 검증한다.
    if not cfg.CANVAS_AI_API_URL.startswith(("https://", "http://")):
        log.error("CANVAS_AI_API_URL 스킴이 http(s) 가 아닙니다: %r", cfg.CANVAS_AI_API_URL[:20])
        return jsonify(error="AI API 설정이 올바르지 않습니다."), 500

    payload = json.dumps({
        "image": image,
        "canvas": canvas_json,
        "prompt": prompt or "이 레이아웃을 마크다운으로 변환해주세요.",
    }).encode("utf-8")

    req = urllib.request.Request(  # noqa: S310 — 스킴은 위에서 http(s) 로 검증됨
        cfg.CANVAS_AI_API_URL,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {cfg.CANVAS_AI_API_KEY}",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=cfg.CANVAS_AI_TIMEOUT_SEC) as resp:  # noqa: S310 — 스킴은 위에서 http(s) 로 검증됨
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        log.warning("Canvas AI API 오류 응답: status=%s user=%s", e.code, session.get("username"))
        return jsonify(error=f"AI API 오류 (HTTP {e.code})"), 502
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        log.warning("Canvas AI API 호출 실패: %s user=%s", type(e).__name__, session.get("username"))
        return jsonify(error="AI API 호출에 실패했습니다. 잠시 후 다시 시도하세요."), 502

    markdown = (
        body.get("markdown") or body.get("content") or body.get("result") or body.get("text") or ""
    )
    return jsonify(markdown=markdown)
