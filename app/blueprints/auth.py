"""
인증 블루프린트 — 회원가입 / 로그인 / 로그아웃.

secure 모드 방어:
  - scrypt 비밀번호 해싱
  - 파라미터 바인딩 (SQLi 차단)
  - 타이밍 공격 대비 (없는 사용자도 더미 해시 검증)
  - 브루트포스 차단 (IP+계정 단위 시도 횟수 제한)
  - 세션 고정 공격 대비 (로그인 성공 시 세션 재발급)

vulnerable 모드 취약점:
  - 로그인 쿼리를 문자열 조립 → SQL Injection (인증 우회)
  - 브루트포스 제한 없음
  - 비밀번호 평문 비교 경로
"""
from __future__ import annotations

import logging
import re

from flask import (
    Blueprint, current_app, flash, g, redirect,
    render_template, request, session, url_for,
)

from app.core import db
from app.core.security import (
    DUMMY_PASSWORD_HASH, hash_password, minutes_ago, verify_password,
)

log = logging.getLogger(__name__)
bp = Blueprint("auth", __name__)

_USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,32}$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")


def _mode() -> str:
    return current_app.config_obj.SECURITY_MODE


def _record_attempt(username: str, success: bool, reason: str | None = None) -> None:
    try:
        db.insert(
            "INSERT INTO login_attempts (ip, username, success, user_agent, reason) "
            "VALUES (%s,%s,%s,%s,%s)",
            (
                getattr(g, "client_ip", "0.0.0.0"),
                (username or "")[:64],
                1 if success else 0,
                (request.headers.get("User-Agent") or "")[:512],
                reason,
            ),
        )
    except Exception as exc:  # noqa: BLE001
        log.debug("로그인 시도 기록 실패: %s", exc)


def _is_locked_out(username: str) -> tuple[bool, int]:
    """
    최근 N분 내 실패 횟수가 임계값을 넘으면 잠금.
    IP 단위와 계정 단위를 모두 본다 (분산 시도 / 표적 시도 양쪽 대응).
    """
    cfg = current_app.config_obj
    if cfg.SECURITY_MODE == "vulnerable":
        return False, 0  # [VULN] 브루트포스 제한 없음

    since = minutes_ago(cfg.LOGIN_LOCKOUT_MINUTES)
    ip = getattr(g, "client_ip", "0.0.0.0")

    fails = db.query_scalar(
        "SELECT COUNT(*) FROM login_attempts "
        "WHERE success=0 AND ts >= %s AND (ip=%s OR username=%s)",
        (since, ip, (username or "")[:64]),
    )
    remaining = max(0, cfg.LOGIN_MAX_ATTEMPTS - int(fails or 0))
    return int(fails or 0) >= cfg.LOGIN_MAX_ATTEMPTS, remaining


def _rotate_session(user: dict) -> None:
    """세션 고정 공격(Session Fixation) 방어: 기존 세션을 버리고 새로 만든다."""
    session.clear()
    session["user_id"] = user["id"]
    session["username"] = user["username"]
    session["role"] = user["role"]
    session.permanent = True


# ------------------------------------------------------------------ 회원가입

@bp.route("/register", methods=["GET", "POST"])
def register():
    if session.get("user_id"):
        return redirect(url_for("main.index"))

    if request.method == "GET":
        return render_template("auth/register.html")

    username = (request.form.get("username") or "").strip()
    email = (request.form.get("email") or "").strip().lower()
    password = request.form.get("password") or ""
    password2 = request.form.get("password2") or ""

    errors = []
    if not _USERNAME_RE.match(username):
        errors.append("아이디는 영문/숫자/밑줄 3~32자여야 합니다.")
    if not _EMAIL_RE.match(email) or len(email) > 190:
        errors.append("이메일 형식이 올바르지 않습니다.")
    if len(password) < 10:
        errors.append("비밀번호는 10자 이상이어야 합니다.")
    if password != password2:
        errors.append("비밀번호 확인이 일치하지 않습니다.")
    # 흔한 비밀번호 거부 (OWASP 권고)
    if password.lower() in ("password12", "1234567890", "qwertyuiop", "admin12345"):
        errors.append("너무 흔한 비밀번호입니다.")

    if errors:
        for e in errors:
            flash(e, "error")
        return render_template("auth/register.html",
                               username=username, email=email), 400

    exists = db.query_one(
        "SELECT id FROM users WHERE username=%s OR email=%s LIMIT 1",
        (username, email),
    )
    if exists:
        flash("이미 사용 중인 아이디 또는 이메일입니다.", "error")
        return render_template("auth/register.html"), 409

    uid = db.insert(
        "INSERT INTO users (username, email, password_hash, role) VALUES (%s,%s,%s,'user')",
        (username, email, hash_password(password)),
    )
    log.info("신규 가입: id=%s username=%s", uid, username)
    flash("회원가입이 완료되었습니다. 로그인해 주세요.", "success")
    return redirect(url_for("auth.login"))


# ------------------------------------------------------------------ 로그인

@bp.route("/login", methods=["GET", "POST"])
def login():
    if session.get("user_id"):
        return redirect(url_for("main.index"))

    if request.method == "GET":
        return render_template("auth/login.html")

    username = (request.form.get("username") or "").strip()
    password = request.form.get("password") or ""

    locked, remaining = _is_locked_out(username)
    if locked:
        _record_attempt(username, False, "locked")
        cfg = current_app.config_obj
        try:
            db.insert(
                "INSERT INTO security_events (severity, event_type, ip, path, detail) "
                "VALUES ('high','brute_force',%s,%s,%s)",
                (getattr(g, "client_ip", None), "/auth/login",
                 f"계정 '{username}' 대상 반복 로그인 실패로 잠금 발동"),
            )
        except Exception:
            pass
        flash(
            f"로그인 시도가 너무 많습니다. {cfg.LOGIN_LOCKOUT_MINUTES}분 후 다시 시도하세요.",
            "error",
        )
        return render_template("auth/login.html"), 429

    # ---------------- 취약 경로 ----------------
    if _mode() == "vulnerable":
        # [VULN-01] SQL Injection — 문자열 조립으로 인증 우회 가능
        #   예: username = admin' -- 
        sql = (
            "SELECT id, username, role, password_hash, is_active FROM users "
            f"WHERE username = '{username}' LIMIT 1"
        )
        try:
            rows = db.execute_raw(sql)
        except Exception as exc:  # noqa: BLE001
            # 에러 메시지를 그대로 노출 → Error-based SQLi 실습용
            flash(f"쿼리 오류: {exc}", "error")
            _record_attempt(username, False, "sql_error")
            return render_template("auth/login.html"), 500

        user = rows[0] if rows else None
        if user and (verify_password(user.get("password_hash", ""), password)
                     or "--" in username or "'" in username):
            _record_attempt(username, True, "vuln_path")
            _rotate_session(user)
            db.execute("UPDATE users SET last_login_at=NOW() WHERE id=%s", (user["id"],))
            flash(f"{user['username']}님 환영합니다.", "success")
            return redirect(url_for("main.index"))

        _record_attempt(username, False, "bad_password")
        flash("아이디 또는 비밀번호가 올바르지 않습니다.", "error")
        return render_template("auth/login.html"), 401

    # ---------------- 안전 경로 ----------------
    # 파라미터 바인딩으로 SQLi 차단
    user = db.query_one(
        "SELECT id, username, role, password_hash, is_active FROM users "
        "WHERE username=%s LIMIT 1",
        (username,),
    )

    # 타이밍 공격 대비: 사용자가 없어도 동일한 해시 연산을 수행한다
    stored = user["password_hash"] if user else DUMMY_PASSWORD_HASH
    ok = verify_password(stored, password)

    if not user or not ok:
        _record_attempt(username, False, "no_such_user" if not user else "bad_password")
        # 어느 쪽이 틀렸는지 알려주지 않는다 (계정 열거 방지)
        msg = "아이디 또는 비밀번호가 올바르지 않습니다."
        if remaining - 1 > 0:
            msg += f" (남은 시도 {remaining - 1}회)"
        flash(msg, "error")
        return render_template("auth/login.html"), 401

    if not user.get("is_active"):
        _record_attempt(username, False, "inactive")
        flash("비활성화된 계정입니다.", "error")
        return render_template("auth/login.html"), 403

    _record_attempt(username, True, None)
    _rotate_session(user)
    db.execute("UPDATE users SET last_login_at=NOW() WHERE id=%s", (user["id"],))
    log.info("로그인 성공: %s (ip=%s)", username, getattr(g, "client_ip", "?"))

    flash(f"{user['username']}님 환영합니다.", "success")
    nxt = request.form.get("next") or request.args.get("next")
    # 오픈 리다이렉트 방어: 내부 경로만 허용
    if nxt and nxt.startswith("/") and not nxt.startswith("//"):
        return redirect(nxt)
    return redirect(url_for("main.index"))


# ------------------------------------------------------------------ 로그아웃

@bp.route("/logout", methods=["POST", "GET"])
def logout():
    # secure 모드에서는 POST + CSRF 토큰을 요구하는 것이 정석이지만
    # 실습 편의를 위해 GET도 허용하고 세션만 확실히 파기한다.
    username = session.get("username")
    session.clear()
    if username:
        log.info("로그아웃: %s", username)
    flash("로그아웃되었습니다.", "success")
    return redirect(url_for("main.index"))
