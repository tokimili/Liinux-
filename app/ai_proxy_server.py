"""
AI 프록시 — Canvas AI Studio 가 실제 Claude/OpenAI 비전 API를 호출하는 유일한 통로.

web 컨테이너는 backend(internal) 네트워크에만 있어 인터넷에 못 나간다 —
DB 유출 방지를 위한 격리(docker-compose.yml)를 이 기능 때문에 풀지 않으려고,
인터넷이 필요한 부분만 이 별도 컨테이너로 떼어냈다. frontend+backend 양쪽에
붙어서, web 이 backend 망 안에서 보낸 요청만 받아 실제 AI API로 중계한다.

web → ai-proxy 는 공유 비밀(X-Internal-Token)로 인증한다. 이 서비스는
app/__init__.py 의 메인 앱과 완전히 분리된 별도 Flask 앱이다 — DB·세션·
CSRF 등 메인 앱의 기반이 전혀 필요 없고, 오히려 그것들이 없어야
공격 표면이 최소화된다.
"""
from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

import anthropic
import openai
from flask import Flask, jsonify, request

from app.core.security import constant_time_compare

log = logging.getLogger(__name__)

app = Flask(__name__)

INTERNAL_TOKEN = os.environ.get("CANVAS_AI_PROXY_TOKEN", "")
PROVIDER = os.environ.get("CANVAS_AI_PROVIDER", "").strip().lower()
MODEL_OVERRIDE = os.environ.get("CANVAS_AI_MODEL", "").strip()
API_KEY = os.environ.get("CANVAS_AI_API_KEY", "")
TIMEOUT_SEC = int(os.environ.get("CANVAS_AI_TIMEOUT_SEC") or 30)

MAX_OUTPUT_TOKENS = 4096
DEFAULT_PROMPT = (
    "이 구도를 분석해서, 그림을 그리는 AI가 바로 실행할 수 있는 작업 지시서를 "
    "마크다운으로 작성해줘. 구성 요소별 위치·비율·스타일·색상을 구체적으로 적어줘."
)

# 비전 지원 모델 중 제공사별로 가장 저렴한(또는 무료) 기본값.
# gemini: Google AI Studio 에서 신용카드 없이 무료 API 키 발급 가능
#   (https://aistudio.google.com/apikey). "-latest" 별칭을 쓴다 — Google이
#   구체적 모델명(gemini-2.0-flash 등)을 자주 갈아치우는데, 이 별칭은 그때마다
#   자동으로 최신 flash 모델을 가리켜서 코드를 매번 안 고쳐도 된다. 그래도
#   별칭 자체가 없어지는 경우엔 CANVAS_AI_MODEL 에 직접 지정할 것
#   (https://ai.google.dev/gemini-api/docs/models 에서 확인).
_DEFAULT_MODELS = {
    "anthropic": "claude-haiku-4-5",
    "openai": "gpt-4o-mini",
    "gemini": "gemini-flash-latest",
}


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


def _call_anthropic(media_type: str, b64data: str, prompt: str, model: str) -> str:
    client = anthropic.Anthropic(api_key=API_KEY, timeout=TIMEOUT_SEC)
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


def _call_openai(image_data_url: str, prompt: str, model: str) -> str:
    client = openai.OpenAI(api_key=API_KEY, timeout=TIMEOUT_SEC)
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


def _call_gemini(media_type: str, b64data: str, prompt: str, model: str) -> str:
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        f"?key={API_KEY}"
    )
    payload = json.dumps({
        "contents": [{
            "parts": [
                {"inline_data": {"mime_type": media_type, "data": b64data}},
                {"text": prompt},
            ],
        }],
    }).encode("utf-8")
    req = urllib.request.Request(  # noqa: S310  # nosec: B310 -- 고정된 Google API 호스트, 사용자 입력 아님
        url, data=payload, method="POST", headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as resp:  # noqa: S310  # nosec: B310
        body = json.loads(resp.read().decode("utf-8"))
    return body["candidates"][0]["content"]["parts"][0]["text"]


@app.get("/healthz")
def healthz():
    return jsonify(status="ok", provider=PROVIDER or None)


@app.post("/generate")
def generate():
    if not INTERNAL_TOKEN:
        return jsonify(error="AI 프록시 내부 토큰이 설정되지 않았습니다 (.env 의 CANVAS_AI_PROXY_TOKEN)."), 503

    sent_token = request.headers.get("X-Internal-Token", "")
    if not constant_time_compare(sent_token, INTERNAL_TOKEN):
        return jsonify(error="unauthorized"), 403

    if PROVIDER not in ("anthropic", "openai", "gemini"):
        return jsonify(error="AI 제공사가 서버에 설정되지 않았습니다 (.env 의 CANVAS_AI_PROVIDER)."), 503
    if not API_KEY:
        return jsonify(error="AI API 키가 서버에 설정되지 않았습니다 (.env 의 CANVAS_AI_API_KEY)."), 503

    data = request.get_json(silent=True) or {}
    image = (data.get("image") or "").strip()
    prompt = (data.get("prompt") or "").strip() or DEFAULT_PROMPT

    parsed = _parse_data_url(image)
    if not parsed:
        return jsonify(error="캔버스 이미지가 없거나 형식이 올바르지 않습니다."), 400
    media_type, b64data = parsed

    model = MODEL_OVERRIDE or _DEFAULT_MODELS[PROVIDER]

    try:
        if PROVIDER == "anthropic":
            markdown = _call_anthropic(media_type, b64data, prompt, model)
        elif PROVIDER == "openai":
            markdown = _call_openai(image, prompt, model)
        else:
            markdown = _call_gemini(media_type, b64data, prompt, model)
    except (anthropic.APIError, openai.APIError) as e:
        log.warning("Canvas AI API 호출 실패: provider=%s %s: %s", PROVIDER, type(e).__name__, e)
        return jsonify(error="AI API 호출에 실패했습니다. 잠시 후 다시 시도하세요."), 502
    except (urllib.error.HTTPError, urllib.error.URLError, KeyError, json.JSONDecodeError) as e:
        log.warning("Canvas AI API 호출 실패: provider=%s %s: %s", PROVIDER, type(e).__name__, e)
        return jsonify(error="AI API 호출에 실패했습니다. 잠시 후 다시 시도하세요."), 502

    return jsonify(markdown=markdown)
