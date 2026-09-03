"""
애플리케이션 팩토리.

SECURITY_MODE 환경변수 하나로 secure(patched) / vulnerable 을 전환한다.
동일한 코드베이스에서 "취약 → 방어" Before/After 를 증명하는 것이
이 프로젝트 포트폴리오의 핵심 구조다.
"""
from __future__ import annotations

import logging
import os
import sys

from flask import Flask, g, jsonify, render_template, request, session

from app.config import get_config
from app.core import db
from app.core.logging_mw import register_access_logging, writer_stats
from app.core.security import generate_csrf_token, constant_time_compare


def _setup_logging(debug: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if debug else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        stream=sys.stdout,
    )
    # 접속 로그는 DB에 남기므로 werkzeug 의 중복 로그는 줄인다
    logging.getLogger("werkzeug").setLevel(logging.WARNING)


def create_app(config=None) -> Flask:
    cfg = config or get_config()

    app = Flask(
        __name__,
        template_folder="templates",
        static_folder="static",
        static_url_path="/static",
    )
    app.config.from_object(cfg)
    app.config_obj = cfg  # 미들웨어에서 참조

    _setup_logging(app.config.get("DEBUG", False))
    log = logging.getLogger(__name__)

    if cfg.SECURITY_MODE == "vulnerable":
        log.warning("=" * 66)
        log.warning(" SECURITY_MODE=vulnerable — 의도적 취약점이 활성화되었습니다.")
        log.warning(" 격리된 사설 네트워크에서만 사용하십시오.")
        log.warning(" 인터넷에 노출하면 실제로 침해됩니다.")
        log.warning("=" * 66)

    # ---------------- 데이터베이스 ----------------
    db.init_db(cfg)

    # ---------------- 블루프린트 ----------------
    from app.blueprints.main import bp as main_bp
    from app.blueprints.auth import bp as auth_bp
    from app.blueprints.board import bp as board_bp
    from app.blueprints.admin import bp as admin_bp
    from app.blueprints.api import bp as api_bp

    app.register_blueprint(main_bp)
    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(board_bp, url_prefix="/board")
    app.register_blueprint(admin_bp, url_prefix="/admin")
    app.register_blueprint(api_bp, url_prefix="/api")

    # ---------------- 접속 로그 ----------------
    register_access_logging(app)

    # ---------------- CSRF 보호 ----------------
    _register_csrf(app, cfg)

    # ---------------- 보안 헤더 ----------------
    _register_security_headers(app, cfg)

    # ---------------- 공통 컨텍스트 ----------------
    @app.context_processor
    def inject_globals():
        return {
            "current_user": {
                "id": session.get("user_id"),
                "username": session.get("username"),
                "role": session.get("role"),
            } if session.get("user_id") else None,
            "security_mode": cfg.SECURITY_MODE,
            "is_vulnerable": cfg.SECURITY_MODE == "vulnerable",
            "app_version": cfg.APP_VERSION,
            "git_commit": (cfg.GIT_COMMIT or "")[:7],
            "csrf_token": _get_or_create_csrf_token,
        }

    # ---------------- 에러 핸들러 ----------------
    _register_error_handlers(app)

    # ---------------- 헬스체크 (CI/CD 와 Docker healthcheck 가 사용) ----------------
    @app.get("/healthz")
    def healthz():
        health = db.healthcheck()
        payload = {
            "status": "ok" if health["ok"] else "degraded",
            "mode": cfg.SECURITY_MODE,
            "version": cfg.APP_VERSION,
            "commit": (cfg.GIT_COMMIT or "")[:7],
            "db": health,
            "log_writer": writer_stats(),
        }
        return jsonify(payload), (200 if health["ok"] else 503)

    log.info(
        "앱 초기화 완료 | mode=%s version=%s commit=%s",
        cfg.SECURITY_MODE, cfg.APP_VERSION, (cfg.GIT_COMMIT or "")[:7],
    )
    return app


# ===================================================== CSRF

def _get_or_create_csrf_token() -> str:
    if "csrf_token" not in session:
        session["csrf_token"] = generate_csrf_token()
    return session["csrf_token"]


def _register_csrf(app: Flask, cfg) -> None:
    """
    CSRF 토큰 검증.

    vulnerable 모드에서는 검증을 건너뛴다 → CSRF 공격 재현 가능.
    secure 모드에서는 모든 상태 변경 요청(POST/PUT/PATCH/DELETE)에 토큰을 요구.
    """
    app.jinja_env.globals["csrf_token"] = _get_or_create_csrf_token

    @app.before_request
    def _verify_csrf():
        if cfg.SECURITY_MODE == "vulnerable":
            return None  # [VULN] CSRF 방어 없음
        if request.method not in ("POST", "PUT", "PATCH", "DELETE"):
            return None
        # API 는 별도 인증 체계를 쓰므로 제외 (여기서는 읽기 전용 API 만 제공)
        if request.path.startswith("/api/"):
            return None

        sent = (
            request.form.get("csrf_token")
            or request.headers.get("X-CSRF-Token")
            or ""
        )
        expected = session.get("csrf_token", "")
        if not expected or not constant_time_compare(sent, expected):
            logging.getLogger(__name__).warning(
                "CSRF 토큰 불일치: path=%s ip=%s", request.path, getattr(g, "client_ip", "?")
            )
            return render_template("errors/csrf.html"), 400
        return None


# ===================================================== 보안 헤더

def _register_security_headers(app: Flask, cfg) -> None:
    @app.after_request
    def _apply_headers(response):
        if cfg.SECURITY_MODE == "vulnerable":
            # [VULN] 보안 헤더 없음 → XSS/클릭재킹 실습 가능
            response.headers["X-Security-Mode"] = "vulnerable"
            return response

        # 콘텐츠 스니핑 방지
        response.headers["X-Content-Type-Options"] = "nosniff"
        # 클릭재킹 방지
        response.headers["X-Frame-Options"] = "DENY"
        # 리퍼러 최소화
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        # 브라우저 기능 제한
        response.headers["Permissions-Policy"] = (
            "geolocation=(), microphone=(), camera=(), payment=()"
        )
        # XSS 완화의 핵심 — 인라인 스크립트 차단
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self' https://cdn.jsdelivr.net https://cdn.tailwindcss.com; "
            "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
            "font-src 'self' https://cdn.jsdelivr.net data:; "
            "img-src 'self' data:; "
            "connect-src 'self'; "
            "object-src 'none'; "
            "base-uri 'none'; "
            "frame-ancestors 'none'; "
            "form-action 'self'"
        )
        # HTTPS 강제 (터널/TLS 뒤에서만 의미 있음)
        if cfg.SESSION_COOKIE_SECURE:
            response.headers["Strict-Transport-Security"] = (
                "max-age=31536000; includeSubDomains"
            )
        return response


# ===================================================== 에러 핸들러

def _register_error_handlers(app: Flask) -> None:
    def _wants_json() -> bool:
        return request.path.startswith("/api/") or request.accept_mimetypes.best == "application/json"

    @app.errorhandler(400)
    def _400(e):
        if _wants_json():
            return jsonify(error="bad_request"), 400
        return render_template("errors/error.html", code=400,
                               message="잘못된 요청입니다."), 400

    @app.errorhandler(403)
    def _403(e):
        if _wants_json():
            return jsonify(error="forbidden"), 403
        return render_template("errors/error.html", code=403,
                               message="접근 권한이 없습니다."), 403

    @app.errorhandler(404)
    def _404(e):
        if _wants_json():
            return jsonify(error="not_found"), 404
        return render_template("errors/error.html", code=404,
                               message="페이지를 찾을 수 없습니다."), 404

    @app.errorhandler(413)
    def _413(e):
        if _wants_json():
            return jsonify(error="payload_too_large"), 413
        return render_template("errors/error.html", code=413,
                               message="업로드 용량 제한을 초과했습니다."), 413

    @app.errorhandler(429)
    def _429(e):
        if _wants_json():
            return jsonify(error="too_many_requests"), 429
        return render_template("errors/error.html", code=429,
                               message="요청이 너무 많습니다. 잠시 후 다시 시도하세요."), 429

    @app.errorhandler(500)
    def _500(e):
        # OWASP A10: 예외 상세를 사용자에게 노출하지 않는다
        logging.getLogger(__name__).exception("서버 내부 오류")
        if _wants_json():
            return jsonify(error="internal_server_error"), 500
        return render_template("errors/error.html", code=500,
                               message="서버 내부 오류가 발생했습니다."), 500
