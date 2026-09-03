"""
게시판 블루프린트 — 데이터 흐름(요청→검증→DB→응답)의 본체.

secure 모드 방어:
  - 모든 쿼리 파라미터 바인딩 (SQLi)
  - Jinja2 자동 이스케이프 유지 (XSS)
  - 소유권 검증 (IDOR)
  - 업로드 3중 검증 + 실행 불가 저장 (웹셸)
  - 검색어 길이/문자 제한

vulnerable 모드 취약점:
  - VULN-02 검색 SQL Injection
  - VULN-03 저장형 XSS (|safe 렌더링)
  - VULN-04 IDOR (소유권 검증 없음)
  - VULN-05 업로드 검증 없음
"""
from __future__ import annotations

import logging
import os
import uuid
from functools import wraps

from flask import (
    Blueprint,
    abort,
    current_app,
    flash,
    g,
    redirect,
    render_template,
    request,
    send_from_directory,
    session,
    url_for,
)

from app.core import db
from app.core.security import (
    file_sha256,
    get_extension,
    is_safe_upload,
    sanitize_filename,
)

log = logging.getLogger(__name__)
bp = Blueprint("board", __name__)

PAGE_SIZE = 10


def _mode() -> str:
    return current_app.config_obj.SECURITY_MODE


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get("user_id"):
            flash("로그인이 필요합니다.", "error")
            return redirect(url_for("auth.login", next=request.path))
        return fn(*args, **kwargs)
    return wrapper


# ------------------------------------------------------------------ 목록 / 검색

@bp.get("/")
def list_posts():
    try:
        page = max(1, int(request.args.get("page", 1)))
    except ValueError:
        page = 1
    keyword = (request.args.get("q") or "").strip()
    offset = (page - 1) * PAGE_SIZE

    # ---------------- 취약 경로 ----------------
    if _mode() == "vulnerable" and keyword:
        # [VULN-02] 검색어를 문자열로 조립 → UNION SELECT 로 users 테이블 탈취 가능
        sql = (
            "SELECT p.id, p.title, p.view_count, p.created_at, u.username "
            "FROM posts p JOIN users u ON u.id = p.user_id "
            f"WHERE p.is_deleted = 0 AND p.title LIKE '%{keyword}%' "
            "ORDER BY p.created_at DESC LIMIT 50"
        )
        try:
            posts = db.execute_raw(sql)
            total = len(posts)
        except Exception as exc:  # noqa: BLE001
            flash(f"쿼리 오류: {exc}", "error")  # 에러 노출 (Error-based SQLi)
            posts, total = [], 0
        return render_template(
            "board/list.html", posts=posts, page=1, total=total,
            page_size=PAGE_SIZE, keyword=keyword, total_pages=1,
        )

    # ---------------- 안전 경로 ----------------
    if keyword:
        if len(keyword) > 100:
            flash("검색어가 너무 깁니다.", "error")
            keyword = keyword[:100]
        like = f"%{keyword}%"
        total = db.query_scalar(
            "SELECT COUNT(*) FROM posts WHERE is_deleted=0 AND (title LIKE %s OR content LIKE %s)",
            (like, like),
        )
        posts = db.query_all(
            "SELECT p.id, p.title, p.view_count, p.created_at, u.username "
            "FROM posts p JOIN users u ON u.id = p.user_id "
            "WHERE p.is_deleted = 0 AND (p.title LIKE %s OR p.content LIKE %s) "
            "ORDER BY p.created_at DESC LIMIT %s OFFSET %s",
            (like, like, PAGE_SIZE, offset),
        )
    else:
        total = db.query_scalar("SELECT COUNT(*) FROM posts WHERE is_deleted=0")
        posts = db.query_all(
            "SELECT p.id, p.title, p.view_count, p.created_at, u.username "
            "FROM posts p JOIN users u ON u.id = p.user_id "
            "WHERE p.is_deleted = 0 "
            "ORDER BY p.created_at DESC LIMIT %s OFFSET %s",
            (PAGE_SIZE, offset),
        )

    total_pages = max(1, (int(total or 0) + PAGE_SIZE - 1) // PAGE_SIZE)
    return render_template(
        "board/list.html", posts=posts, page=page, total=total,
        page_size=PAGE_SIZE, keyword=keyword, total_pages=total_pages,
    )


# ------------------------------------------------------------------ 상세

@bp.get("/<int:post_id>")
def view_post(post_id: int):
    post = db.query_one(
        "SELECT p.*, u.username FROM posts p JOIN users u ON u.id = p.user_id "
        "WHERE p.id=%s AND p.is_deleted=0",
        (post_id,),
    )
    if not post:
        abort(404)

    db.execute("UPDATE posts SET view_count = view_count + 1 WHERE id=%s", (post_id,))

    comments = db.query_all(
        "SELECT c.id, c.content, c.created_at, u.username, c.user_id "
        "FROM comments c JOIN users u ON u.id = c.user_id "
        "WHERE c.post_id=%s AND c.is_deleted=0 ORDER BY c.created_at ASC",
        (post_id,),
    )
    files = db.query_all(
        "SELECT id, original_name, size_bytes, mime_type FROM uploads WHERE post_id=%s",
        (post_id,),
    )

    return render_template(
        "board/view.html", post=post, comments=comments, files=files,
    )


# ------------------------------------------------------------------ 작성

@bp.route("/new", methods=["GET", "POST"])
@login_required
def create_post():
    if request.method == "GET":
        return render_template("board/form.html", post=None)

    title = (request.form.get("title") or "").strip()
    content = (request.form.get("content") or "").strip()

    if not title or not content:
        flash("제목과 내용을 입력하세요.", "error")
        return render_template("board/form.html", post=None), 400
    if len(title) > 200:
        flash("제목은 200자 이내여야 합니다.", "error")
        return render_template("board/form.html", post=None), 400

    post_id = db.insert(
        "INSERT INTO posts (user_id, title, content) VALUES (%s,%s,%s)",
        (session["user_id"], title, content),
    )

    # 첨부파일 처리
    upload = request.files.get("attachment")
    if upload and upload.filename:
        ok, msg = _handle_upload(upload, post_id)
        if not ok:
            flash(f"첨부 실패: {msg}", "error")

    flash("게시글이 등록되었습니다.", "success")
    return redirect(url_for("board.view_post", post_id=post_id))


# ------------------------------------------------------------------ 수정 (IDOR 지점)

@bp.route("/<int:post_id>/edit", methods=["GET", "POST"])
@login_required
def edit_post(post_id: int):
    post = db.query_one("SELECT * FROM posts WHERE id=%s AND is_deleted=0", (post_id,))
    if not post:
        abort(404)

    # ---------------- 소유권 검증 ----------------
    if _mode() == "vulnerable":
        # [VULN-04] IDOR — 소유권을 확인하지 않는다.
        #   /board/<남의글id>/edit 로 타인 게시글을 수정할 수 있다.
        pass
    else:
        is_owner = post["user_id"] == session.get("user_id")
        is_admin = session.get("role") == "admin"
        if not (is_owner or is_admin):
            log.warning(
                "IDOR 시도 차단: user=%s 가 post=%s (소유자=%s) 접근",
                session.get("user_id"), post_id, post["user_id"],
            )
            db.record_security_event(
                "medium", "idor_attempt",
                f"user_id={session.get('user_id')} 가 타인 게시글({post_id}) 수정 시도",
                ip=getattr(g, "client_ip", None), path=request.path,
            )
            abort(403)

    if request.method == "GET":
        return render_template("board/form.html", post=post)

    title = (request.form.get("title") or "").strip()
    content = (request.form.get("content") or "").strip()
    if not title or not content:
        flash("제목과 내용을 입력하세요.", "error")
        return render_template("board/form.html", post=post), 400

    db.execute(
        "UPDATE posts SET title=%s, content=%s WHERE id=%s",
        (title[:200], content, post_id),
    )
    flash("게시글이 수정되었습니다.", "success")
    return redirect(url_for("board.view_post", post_id=post_id))


# ------------------------------------------------------------------ 삭제

@bp.post("/<int:post_id>/delete")
@login_required
def delete_post(post_id: int):
    post = db.query_one("SELECT user_id FROM posts WHERE id=%s AND is_deleted=0", (post_id,))
    if not post:
        abort(404)

    # 중첩 if 를 유지한다: 바깥은 "모드 스위치", 안쪽은 "소유권 검증"으로
    # 역할이 다르다. 한 줄로 합치면 취약 모드 토글 지점이 눈에 띄지 않는다.
    if _mode() != "vulnerable":  # noqa: SIM102
        if post["user_id"] != session.get("user_id") and session.get("role") != "admin":
            abort(403)

    db.execute("UPDATE posts SET is_deleted=1 WHERE id=%s", (post_id,))
    flash("게시글이 삭제되었습니다.", "success")
    return redirect(url_for("board.list_posts"))


# ------------------------------------------------------------------ 댓글 (XSS 지점)

@bp.post("/<int:post_id>/comment")
@login_required
def add_comment(post_id: int):
    content = (request.form.get("content") or "").strip()
    if not content:
        flash("댓글 내용을 입력하세요.", "error")
        return redirect(url_for("board.view_post", post_id=post_id))
    if len(content) > 1000:
        content = content[:1000]

    exists = db.query_one("SELECT id FROM posts WHERE id=%s AND is_deleted=0", (post_id,))
    if not exists:
        abort(404)

    # 저장 자체는 원문을 보관한다 (정석).
    # XSS 방어는 "출력 시 이스케이프"로 한다 → 템플릿에서 분기.
    db.insert(
        "INSERT INTO comments (post_id, user_id, content) VALUES (%s,%s,%s)",
        (post_id, session["user_id"], content),
    )
    flash("댓글이 등록되었습니다.", "success")
    return redirect(url_for("board.view_post", post_id=post_id))


# ------------------------------------------------------------------ 업로드

def _handle_upload(upload, post_id: int | None) -> tuple[bool, str]:
    cfg = current_app.config_obj
    os.makedirs(cfg.UPLOAD_DIR, exist_ok=True)

    head = upload.stream.read(512)
    upload.stream.seek(0)

    if _mode() == "vulnerable":
        # [VULN-05] 검증 없음 → shell.php 업로드 가능 (웹셸)
        stored = upload.filename  # 원본 이름 그대로 (경로 탐색도 가능)
        dest = os.path.join(cfg.UPLOAD_DIR, stored)
        upload.save(dest)
        log.warning("[VULN] 검증 없이 업로드 저장: %s", dest)
    else:
        ok, msg = is_safe_upload(upload.filename, head, cfg.ALLOWED_UPLOAD_EXT)
        if not ok:
            db.record_security_event(
                "high", "malicious_upload",
                f"차단된 업로드: {upload.filename} — {msg}",
                ip=getattr(g, "client_ip", None), path=request.path,
            )
            return False, msg

        # 서버가 이름을 생성한다 → 경로 탐색·확장자 위조 원천 차단
        ext = get_extension(upload.filename)
        stored = f"{uuid.uuid4().hex}.{ext}"
        dest = os.path.join(cfg.UPLOAD_DIR, stored)
        upload.save(dest)
        # 실행 권한 제거
        try:
            os.chmod(dest, 0o644)
        except OSError:
            pass

    data_size = os.path.getsize(dest)
    try:
        with open(dest, "rb") as fh:
            digest = file_sha256(fh.read())
    except OSError:
        digest = None

    db.insert(
        "INSERT INTO uploads (post_id, user_id, original_name, stored_name, "
        "mime_type, size_bytes, sha256) VALUES (%s,%s,%s,%s,%s,%s,%s)",
        (
            post_id, session["user_id"],
            sanitize_filename(upload.filename)[:255],
            stored[:255],
            (upload.mimetype or "")[:120],
            data_size, digest,
        ),
    )
    return True, "ok"


@bp.get("/file/<int:file_id>")
def download_file(file_id: int):
    """
    첨부파일 다운로드.
    항상 attachment 로 내려보내 브라우저가 실행/렌더하지 않게 한다
    (업로드된 HTML/SVG 를 통한 XSS 차단).
    """
    row = db.query_one(
        "SELECT original_name, stored_name, mime_type FROM uploads WHERE id=%s",
        (file_id,),
    )
    if not row:
        abort(404)

    cfg = current_app.config_obj
    return send_from_directory(
        cfg.UPLOAD_DIR,
        row["stored_name"],
        as_attachment=(_mode() != "vulnerable"),
        download_name=row["original_name"],
    )
