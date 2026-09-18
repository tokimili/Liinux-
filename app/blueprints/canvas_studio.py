"""
Canvas AI Studio — 도형/텍스트/이미지를 캔버스에 배치해 AI로 마크다운 변환.

보안 설계:
  - AI API 키/모델 설정은 서버 설정(.env)에만 존재한다. 브라우저는 절대 모른다 —
    클라이언트가 엔드포인트를 직접 호출하게 하면 누구나 그 키로 과금을 일으킬 수 있다.
  - 이 라우트는 /api/ 접두어를 쓰지 않는다. /api/* 는 읽기 전용이라 CSRF 검사를
    건너뛰는데(app/__init__.py), 이 엔드포인트는 상태 변경(외부 과금 호출)이라
    CSRF 보호 대상이어야 한다.
  - 로그인한 사용자만 사용할 수 있다 (비로그인 사용자가 AI 비용을 유발하지 못하게).

제공사(provider)는 .env 의 CANVAS_AI_PROVIDER 로 anthropic/openai 중 코드 수정
없이 전환한다. 토큰 비용 절감이 목적이므로 기본 모델은 각 제공사의 비전 지원
모델 중 가장 저렴한 것으로 잡았다 — 필요하면 CANVAS_AI_MODEL 로 덮어쓴다.
"""
from __future__ import annotations

import logging
from functools import wraps

import anthropic
import openai
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
DEFAULT_PROMPT = (
    "이 구도를 분석해서, 그림을 그리는 AI가 바로 실행할 수 있는 작업 지시서를 "
    "마크다운으로 작성해줘. 구성 요소별 위치·비율·스타일·색상을 구체적으로 적어줘."
)
MAX_OUTPUT_TOKENS = 4096

# 비전 지원 모델 중 제공사별로 가장 저렴한 기본값. 가격/모델 라인업은 자주
# 바뀌므로, 운영 중 더 싼 모델이 나오면 .env 의 CANVAS_AI_MODEL 로 덮어쓴다.
_DEFAULT_MODELS = {
    "anthropic": "claude-haiku-4-5",
    "openai": "gpt-4o-mini",
}


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


def _parse_data_url(image: str) -> tuple[str, str] | None:
    """'data:image/png;base64,XXXX' -> ('image/png', 'XXXX'). 형식이 아니면 None."""
    if not image.startswith("data:image/"):
        return None
    try:
        header, b64data = image.split(",", 1)
        media_type = header.split(";")[0].split(":", 1)[1]
    except (ValueError, IndexError):
        return None
    return media_type, b64data


def _call_anthropic(media_type: str, b64data: str, prompt: str, model: str, api_key: str, timeout: float) -> str:
    client = anthropic.Anthropic(api_key=api_key, timeout=timeout)
    response = client.messages.create(
        model=model,
        max_tokens=MAX_OUTPUT_TOKENS,
        messages=[{
            "role": "user",
            "content": [
                {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": b64data}},
                {"type": "text", "text": prompt},
            ],
        }],
    )
    return "".join(block.text for block in response.content if block.type == "text")


def _call_openai(image_data_url: str, prompt: str, model: str, api_key: str, timeout: float) -> str:
    client = openai.OpenAI(api_key=api_key, timeout=timeout)
    response = client.chat.completions.create(
        model=model,
        max_completion_tokens=MAX_OUTPUT_TOKENS,
        messages=[{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": image_data_url}},
            ],
        }],
    )
    return response.choices[0].message.content or ""


@bp.post("/studio/generate")
@login_required
def generate():
    cfg = current_app.config_obj
    provider = cfg.CANVAS_AI_PROVIDER

    if provider not in ("anthropic", "openai"):
        return jsonify(error="AI 제공사가 서버에 설정되지 않았습니다 (.env 의 CANVAS_AI_PROVIDER)."), 503
    if not cfg.CANVAS_AI_API_KEY:
        return jsonify(error="AI API 키가 서버에 설정되지 않았습니다 (.env 의 CANVAS_AI_API_KEY)."), 503

    data = request.get_json(silent=True) or {}
    image = (data.get("image") or "").strip()
    prompt = (data.get("prompt") or "").strip()[:MAX_PROMPT_LEN] or DEFAULT_PROMPT

    parsed = _parse_data_url(image)
    if not parsed:
        return jsonify(error="캔버스 이미지가 없거나 형식이 올바르지 않습니다."), 400
    media_type, b64data = parsed

    model = cfg.CANVAS_AI_MODEL or _DEFAULT_MODELS[provider]

    try:
        if provider == "anthropic":
            markdown = _call_anthropic(media_type, b64data, prompt, model, cfg.CANVAS_AI_API_KEY, cfg.CANVAS_AI_TIMEOUT_SEC)
        else:
            markdown = _call_openai(image, prompt, model, cfg.CANVAS_AI_API_KEY, cfg.CANVAS_AI_TIMEOUT_SEC)
    except (anthropic.APIError, openai.APIError) as e:
        log.warning("Canvas AI API 호출 실패: provider=%s %s user=%s", provider, type(e).__name__, session.get("username"))
        return jsonify(error="AI API 호출에 실패했습니다. 잠시 후 다시 시도하세요."), 502

    return jsonify(markdown=markdown)
