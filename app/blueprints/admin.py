"""
관리자 대시보드 블루프린트.

요구사항 3번: "관리자 페이지에서 접속 기록 등을 확인"

제공 화면:
  /admin                 대시보드 (KPI, 시간대별 차트, 상위 IP/경로, 최근 경보)
  /admin/logs            접속 로그 조회 (다중 필터 + 페이지네이션 + CSV)
  /admin/threats         보안 이벤트 (공격 탐지 내역)
  /admin/logins          로그인 시도 (브루트포스 추적)
  /admin/ips             IP 분석 및 차단 관리
  /admin/deployments     배포 이력 (CI/CD 결과)
  /admin/system          시스템 상태

모든 라우트는 admin 역할을 요구한다 (수직 권한 상승 차단).
"""
from __future__ import annotations

import csv
import io
import logging
from datetime import datetime, timedelta
from functools import wraps

from flask import (
    Blueprint,
    Response,
    abort,
    current_app,
    flash,
    g,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

from app.core import db
from app.core.logging_mw import writer_stats

log = logging.getLogger(__name__)
bp = Blueprint("admin", __name__)

LOG_PAGE_SIZE = 50


def admin_required(fn):
    """
    관리자 전용 접근 제어.
    OWASP A01(Broken Access Control) 방어의 핵심 — 모든 관리 라우트에 적용.
    """
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get("user_id"):
            flash("관리자 로그인이 필요합니다.", "error")
            return redirect(url_for("auth.login", next=request.path))

        if session.get("role") != "admin":
            log.warning(
                "권한 상승 시도: user=%s(role=%s) → %s ip=%s",
                session.get("username"), session.get("role"),
                request.path, getattr(g, "client_ip", "?"),
            )
            db.record_security_event(
                "high", "privilege_escalation",
                f"비관리자 '{session.get('username')}' 가 관리자 페이지 접근 시도",
                ip=getattr(g, "client_ip", None), path=request.path,
            )
            abort(403)
        return fn(*args, **kwargs)
    return wrapper


def _parse_int(name: str, default: int, lo: int, hi: int) -> int:
    try:
        return max(lo, min(hi, int(request.args.get(name, default))))
    except (TypeError, ValueError):
        return default


# ================================================================= 대시보드

@bp.get("/")
@admin_required
def dashboard():
    hours = _parse_int("hours", 24, 1, 720)
    since = datetime.now() - timedelta(hours=hours)

    # ---- KPI ----
    kpi = {
        "total_requests": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= %s", (since,)),
        "unique_ips": db.query_scalar(
            "SELECT COUNT(DISTINCT ip) FROM access_logs WHERE ts >= %s", (since,)),
        "threat_requests": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= %s AND threat_score >= 35", (since,)),
        "error_requests": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= %s AND status_code >= 400", (since,)),
        "avg_duration": db.query_scalar(
            "SELECT ROUND(AVG(duration_ms),1) FROM access_logs WHERE ts >= %s", (since,)) or 0,
        "p95_duration": db.query_scalar(
            "SELECT MAX(duration_ms) FROM (SELECT duration_ms FROM access_logs "
            "WHERE ts >= %s ORDER BY duration_ms LIMIT 999999) t", (since,)) or 0,
        "failed_logins": db.query_scalar(
            "SELECT COUNT(*) FROM login_attempts WHERE ts >= %s AND success=0", (since,)),
        "open_events": db.query_scalar(
            "SELECT COUNT(*) FROM security_events WHERE is_resolved=0"),
        "blocked_ips": db.query_scalar("SELECT COUNT(*) FROM blocked_ips"),
        "total_users": db.query_scalar("SELECT COUNT(*) FROM users"),
        "total_posts": db.query_scalar("SELECT COUNT(*) FROM posts WHERE is_deleted=0"),
    }

    # ---- 시간대별 트래픽 (차트용) ----
    # 24시간 이하는 시간 단위, 그 이상은 일 단위로 집계
    if hours <= 48:
        bucket_fmt, label = "%%Y-%%m-%%d %%H:00", "hour"
    else:
        bucket_fmt, label = "%%Y-%%m-%%d", "day"

    timeline = db.query_all(
        f"SELECT DATE_FORMAT(ts, '{bucket_fmt}') AS bucket, "
        "COUNT(*) AS total, "
        "SUM(CASE WHEN threat_score >= 35 THEN 1 ELSE 0 END) AS threats, "
        "SUM(CASE WHEN status_code >= 400 THEN 1 ELSE 0 END) AS errors "
        "FROM access_logs WHERE ts >= %s "
        "GROUP BY bucket ORDER BY bucket",
        (since,),
    )

    # ---- 상위 IP ----
    top_ips = db.query_all(
        "SELECT ip, COUNT(*) AS hits, "
        "MAX(threat_score) AS max_threat, "
        "SUM(CASE WHEN status_code >= 400 THEN 1 ELSE 0 END) AS errors, "
        "MAX(ts) AS last_seen, "
        "MIN(ts) AS first_seen "
        "FROM access_logs WHERE ts >= %s "
        "GROUP BY ip ORDER BY hits DESC LIMIT 12",
        (since,),
    )

    # ---- 상위 경로 ----
    top_paths = db.query_all(
        "SELECT path, COUNT(*) AS hits, ROUND(AVG(duration_ms),1) AS avg_ms, "
        "SUM(CASE WHEN status_code >= 400 THEN 1 ELSE 0 END) AS errors "
        "FROM access_logs WHERE ts >= %s "
        "GROUP BY path ORDER BY hits DESC LIMIT 12",
        (since,),
    )

    # ---- 상태 코드 분포 ----
    status_dist = db.query_all(
        "SELECT status_code, COUNT(*) AS cnt FROM access_logs "
        "WHERE ts >= %s GROUP BY status_code ORDER BY cnt DESC",
        (since,),
    )

    # ---- 위협 유형 분포 ----
    threat_types = db.query_all(
        "SELECT event_type, severity, COUNT(*) AS cnt FROM security_events "
        "WHERE ts >= %s GROUP BY event_type, severity ORDER BY cnt DESC LIMIT 10",
        (since,),
    )

    # ---- 최근 경보 ----
    recent_events = db.query_all(
        "SELECT id, ts, severity, event_type, ip, path, detail, is_resolved "
        "FROM security_events ORDER BY ts DESC LIMIT 15"
    )

    # ---- 최근 접속 ----
    recent_logs = db.query_all(
        "SELECT ts, ip, method, path, status_code, duration_ms, username, "
        "threat_score, threat_tags FROM access_logs "
        "ORDER BY ts DESC LIMIT 20"
    )

    # ---- 최근 배포 ----
    deployments = db.query_all(
        "SELECT deployed_at, git_commit, git_ref, app_version, actor, mode "
        "FROM deployments ORDER BY deployed_at DESC LIMIT 5"
    )

    return render_template(
        "admin/dashboard.html",
        kpi=kpi, timeline=timeline, timeline_label=label,
        top_ips=top_ips, top_paths=top_paths,
        status_dist=status_dist, threat_types=threat_types,
        recent_events=recent_events, recent_logs=recent_logs,
        deployments=deployments, hours=hours,
    )


# ================================================================= 접속 로그

@bp.get("/logs")
@admin_required
def logs():
    page = _parse_int("page", 1, 1, 100000)
    offset = (page - 1) * LOG_PAGE_SIZE

    where, params = _build_log_filters()

    total = db.query_scalar(
        f"SELECT COUNT(*) FROM access_logs WHERE {where}", params)

    rows = db.query_all(
        "SELECT id, ts, ip, method, path, query_string, status_code, duration_ms, "
        "bytes_sent, username, user_agent, referer, country, threat_score, threat_tags "
        f"FROM access_logs WHERE {where} "
        "ORDER BY ts DESC LIMIT %s OFFSET %s",
        (*params, LOG_PAGE_SIZE, offset),
    )

    total_pages = max(1, (int(total or 0) + LOG_PAGE_SIZE - 1) // LOG_PAGE_SIZE)

    return render_template(
        "admin/logs.html",
        rows=rows, page=page, total=total, total_pages=total_pages,
        page_size=LOG_PAGE_SIZE, filters=request.args,
    )


def _build_log_filters() -> tuple[str, list]:
    """
    쿼리스트링을 WHERE 절로 변환.
    ⚠️ 값은 전부 파라미터 바인딩한다 — 관리 화면도 SQLi 대상이다.
    """
    clauses = ["1=1"]
    params: list = []

    ip = (request.args.get("ip") or "").strip()
    if ip:
        clauses.append("ip LIKE %s")
        params.append(f"%{ip}%")

    path = (request.args.get("path") or "").strip()
    if path:
        clauses.append("path LIKE %s")
        params.append(f"%{path}%")

    method = (request.args.get("method") or "").strip().upper()
    if method in ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"):
        clauses.append("method = %s")
        params.append(method)

    status = (request.args.get("status") or "").strip()
    if status.isdigit():
        clauses.append("status_code = %s")
        params.append(int(status))
    elif status in ("2xx", "3xx", "4xx", "5xx"):
        base = int(status[0]) * 100
        clauses.append("status_code BETWEEN %s AND %s")
        params.extend([base, base + 99])

    username = (request.args.get("username") or "").strip()
    if username:
        clauses.append("username LIKE %s")
        params.append(f"%{username}%")

    if request.args.get("threats_only") == "1":
        clauses.append("threat_score >= 35")

    min_score = (request.args.get("min_score") or "").strip()
    if min_score.isdigit():
        clauses.append("threat_score >= %s")
        params.append(int(min_score))

    hours = (request.args.get("hours") or "").strip()
    if hours.isdigit() and int(hours) > 0:
        clauses.append("ts >= %s")
        params.append(datetime.now() - timedelta(hours=min(int(hours), 8760)))

    date_from = (request.args.get("from") or "").strip()
    if date_from:
        try:
            params.append(datetime.strptime(date_from, "%Y-%m-%d"))
            clauses.append("ts >= %s")
        except ValueError:
            pass

    date_to = (request.args.get("to") or "").strip()
    if date_to:
        try:
            params.append(datetime.strptime(date_to, "%Y-%m-%d") + timedelta(days=1))
            clauses.append("ts < %s")
        except ValueError:
            pass

    return " AND ".join(clauses), params


@bp.get("/logs.csv")
@admin_required
def logs_csv():
    """진단 보고서 첨부용 CSV 내보내기 (최대 10,000행)."""
    where, params = _build_log_filters()
    rows = db.query_all(
        "SELECT ts, ip, method, path, query_string, status_code, duration_ms, "
        "username, user_agent, threat_score, threat_tags "
        f"FROM access_logs WHERE {where} ORDER BY ts DESC LIMIT 10000",
        params,
    )

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow([
        "시각", "IP", "메서드", "경로", "쿼리스트링", "상태코드",
        "응답시간(ms)", "사용자", "User-Agent", "위협점수", "위협태그",
    ])
    for r in rows:
        writer.writerow([
            r["ts"], r["ip"], r["method"], r["path"], r.get("query_string") or "",
            r["status_code"], r["duration_ms"], r.get("username") or "",
            (r.get("user_agent") or "")[:200],
            r["threat_score"], r.get("threat_tags") or "",
        ])

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    # BOM 을 붙여 Excel 에서 한글이 깨지지 않게 한다
    payload = "\ufeff" + buf.getvalue()
    return Response(
        payload,
        mimetype="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="access_logs_{stamp}.csv"'},
    )


# ================================================================= 보안 이벤트

@bp.get("/threats")
@admin_required
def threats():
    page = _parse_int("page", 1, 1, 100000)
    severity = (request.args.get("severity") or "").strip()
    event_type = (request.args.get("type") or "").strip()
    show_resolved = request.args.get("resolved") == "1"

    clauses, params = ["1=1"], []
    if severity in ("info", "low", "medium", "high", "critical"):
        clauses.append("severity = %s")
        params.append(severity)
    if event_type:
        clauses.append("event_type LIKE %s")
        params.append(f"%{event_type}%")
    if not show_resolved:
        clauses.append("is_resolved = 0")
    where = " AND ".join(clauses)

    total = db.query_scalar(f"SELECT COUNT(*) FROM security_events WHERE {where}", params)
    rows = db.query_all(
        f"SELECT * FROM security_events WHERE {where} ORDER BY ts DESC LIMIT %s OFFSET %s",
        (*params, LOG_PAGE_SIZE, (page - 1) * LOG_PAGE_SIZE),
    )

    summary = db.query_all(
        "SELECT severity, COUNT(*) AS cnt FROM security_events "
        "WHERE is_resolved=0 GROUP BY severity"
    )

    total_pages = max(1, (int(total or 0) + LOG_PAGE_SIZE - 1) // LOG_PAGE_SIZE)
    return render_template(
        "admin/threats.html", rows=rows, summary=summary, page=page,
        total=total, total_pages=total_pages, filters=request.args,
    )


@bp.post("/threats/<int:event_id>/resolve")
@admin_required
def resolve_threat(event_id: int):
    db.execute("UPDATE security_events SET is_resolved=1 WHERE id=%s", (event_id,))
    flash("이벤트를 처리 완료로 표시했습니다.", "success")
    return redirect(request.referrer or url_for("admin.threats"))


# ================================================================= 로그인 시도

@bp.get("/logins")
@admin_required
def logins():
    page = _parse_int("page", 1, 1, 100000)
    only_failed = request.args.get("failed") == "1"

    clauses, params = ["1=1"], []
    if only_failed:
        clauses.append("success = 0")
    ip = (request.args.get("ip") or "").strip()
    if ip:
        clauses.append("ip LIKE %s")
        params.append(f"%{ip}%")
    where = " AND ".join(clauses)

    total = db.query_scalar(f"SELECT COUNT(*) FROM login_attempts WHERE {where}", params)
    rows = db.query_all(
        f"SELECT * FROM login_attempts WHERE {where} ORDER BY ts DESC LIMIT %s OFFSET %s",
        (*params, LOG_PAGE_SIZE, (page - 1) * LOG_PAGE_SIZE),
    )

    # 브루트포스 후보: 최근 24시간 내 실패 5회 이상인 IP
    suspects = db.query_all(
        "SELECT ip, COUNT(*) AS fails, COUNT(DISTINCT username) AS accounts, "
        "MAX(ts) AS last_try "
        "FROM login_attempts WHERE success=0 AND ts >= %s "
        "GROUP BY ip HAVING fails >= 5 ORDER BY fails DESC LIMIT 10",
        (datetime.now() - timedelta(hours=24),),
    )

    total_pages = max(1, (int(total or 0) + LOG_PAGE_SIZE - 1) // LOG_PAGE_SIZE)
    return render_template(
        "admin/logins.html", rows=rows, suspects=suspects, page=page,
        total=total, total_pages=total_pages, filters=request.args,
    )


# ================================================================= IP 관리

@bp.get("/ips")
@admin_required
def ips():
    hours = _parse_int("hours", 168, 1, 8760)
    since = datetime.now() - timedelta(hours=hours)

    rows = db.query_all(
        "SELECT a.ip, COUNT(*) AS hits, MAX(a.threat_score) AS max_threat, "
        "SUM(CASE WHEN a.threat_score >= 35 THEN 1 ELSE 0 END) AS threat_hits, "
        "SUM(CASE WHEN a.status_code >= 400 THEN 1 ELSE 0 END) AS errors, "
        "COUNT(DISTINCT a.path) AS distinct_paths, "
        "MIN(a.ts) AS first_seen, MAX(a.ts) AS last_seen, "
        "MAX(a.country) AS country, "
        "(SELECT COUNT(*) FROM login_attempts l WHERE l.ip = a.ip AND l.success=0) AS failed_logins, "
        "(SELECT COUNT(*) FROM blocked_ips b WHERE b.ip = a.ip) AS is_blocked "
        "FROM access_logs a WHERE a.ts >= %s "
        "GROUP BY a.ip ORDER BY max_threat DESC, hits DESC LIMIT 100",
        (since,),
    )

    blocked = db.query_all(
        "SELECT * FROM blocked_ips ORDER BY blocked_at DESC LIMIT 100")

    return render_template("admin/ips.html", rows=rows, blocked=blocked, hours=hours)


@bp.post("/ips/block")
@admin_required
def block_ip():
    ip = (request.form.get("ip") or "").strip()
    reason = (request.form.get("reason") or "관리자 수동 차단").strip()[:255]
    if not ip:
        flash("IP를 입력하세요.", "error")
        return redirect(url_for("admin.ips"))

    db.execute(
        "INSERT INTO blocked_ips (ip, reason, created_by) VALUES (%s,%s,%s) "
        "ON DUPLICATE KEY UPDATE reason=VALUES(reason), blocked_at=NOW()",
        (ip[:45], reason, session.get("username")),
    )
    db.insert(
        "INSERT INTO security_events (severity, event_type, ip, detail) "
        "VALUES ('info','ip_blocked',%s,%s)",
        (ip[:45], f"관리자 '{session.get('username')}' 가 차단: {reason}"),
    )
    flash(f"{ip} 를 차단했습니다.", "success")
    return redirect(url_for("admin.ips"))


@bp.post("/ips/unblock")
@admin_required
def unblock_ip():
    ip = (request.form.get("ip") or "").strip()
    db.execute("DELETE FROM blocked_ips WHERE ip=%s", (ip,))
    flash(f"{ip} 차단을 해제했습니다.", "success")
    return redirect(url_for("admin.ips"))


# ================================================================= 배포 이력

@bp.get("/deployments")
@admin_required
def deployments():
    rows = db.query_all(
        "SELECT * FROM deployments ORDER BY deployed_at DESC LIMIT 100")
    return render_template("admin/deployments.html", rows=rows)


# ================================================================= 시스템

@bp.get("/system")
@admin_required
def system():
    cfg = current_app.config_obj

    table_sizes = db.query_all(
        "SELECT table_name AS name, table_rows AS row_count, "
        "ROUND((data_length + index_length)/1024/1024, 2) AS size_mb "
        "FROM information_schema.tables WHERE table_schema = %s "
        "ORDER BY (data_length + index_length) DESC",
        (cfg.DB_NAME,),
    )

    oldest_log = db.query_one("SELECT MIN(ts) AS t FROM access_logs")
    log_count = db.query_scalar("SELECT COUNT(*) FROM access_logs")

    return render_template(
        "admin/system.html",
        config=cfg,
        db_health=db.healthcheck(),
        log_writer=writer_stats(),
        table_sizes=table_sizes,
        oldest_log=(oldest_log or {}).get("t"),
        log_count=log_count,
    )


@bp.post("/system/purge-logs")
@admin_required
def purge_logs():
    """보존 기간이 지난 접속 로그 정리 (개인정보 최소 보관 원칙)."""
    cfg = current_app.config_obj
    days = cfg.ACCESS_LOG_RETENTION_DAYS
    cutoff = datetime.now() - timedelta(days=days)
    deleted = db.execute("DELETE FROM access_logs WHERE ts < %s", (cutoff,))
    flash(f"{days}일 이전 접속 로그 {deleted}건을 삭제했습니다.", "success")
    return redirect(url_for("admin.system"))
