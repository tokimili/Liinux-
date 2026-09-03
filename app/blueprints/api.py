"""
읽기 전용 JSON API — 대시보드 차트가 폴링해서 실시간 갱신에 사용.

CSP 때문에 인라인 스크립트를 쓸 수 없으므로, 프런트엔드 JS가
이 엔드포인트를 fetch 해서 차트를 그린다.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from flask import Blueprint, jsonify, request, session

from app.core import db

bp = Blueprint("api", __name__)


def _admin_only():
    if session.get("role") != "admin":
        return jsonify(error="forbidden"), 403
    return None


def _hours() -> int:
    try:
        return max(1, min(720, int(request.args.get("hours", 24))))
    except (TypeError, ValueError):
        return 24


@bp.get("/stats/summary")
def stats_summary():
    """공개 통계 (홈페이지용, 민감정보 없음)."""
    return jsonify({
        "posts": db.query_scalar("SELECT COUNT(*) FROM posts WHERE is_deleted=0"),
        "users": db.query_scalar("SELECT COUNT(*) FROM users"),
        "requests_today": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= CURDATE()"),
    })


@bp.get("/admin/timeline")
def admin_timeline():
    guard = _admin_only()
    if guard:
        return guard

    hours = _hours()
    since = datetime.now() - timedelta(hours=hours)
    fmt = "%%Y-%%m-%%d %%H:00" if hours <= 48 else "%%Y-%%m-%%d"

    rows = db.query_all(
        f"SELECT DATE_FORMAT(ts, '{fmt}') AS bucket, COUNT(*) AS total, "
        "SUM(CASE WHEN threat_score >= 35 THEN 1 ELSE 0 END) AS threats, "
        "SUM(CASE WHEN status_code >= 400 THEN 1 ELSE 0 END) AS errors "
        "FROM access_logs WHERE ts >= %s GROUP BY bucket ORDER BY bucket",
        (since,),
    )
    return jsonify({
        "labels": [r["bucket"] for r in rows],
        "total": [int(r["total"]) for r in rows],
        "threats": [int(r["threats"] or 0) for r in rows],
        "errors": [int(r["errors"] or 0) for r in rows],
    })


@bp.get("/admin/status-dist")
def admin_status_dist():
    guard = _admin_only()
    if guard:
        return guard

    since = datetime.now() - timedelta(hours=_hours())
    rows = db.query_all(
        "SELECT CONCAT(FLOOR(status_code/100),'xx') AS grp, COUNT(*) AS cnt "
        "FROM access_logs WHERE ts >= %s GROUP BY grp ORDER BY grp",
        (since,),
    )
    return jsonify({
        "labels": [r["grp"] for r in rows],
        "values": [int(r["cnt"]) for r in rows],
    })


@bp.get("/admin/threat-dist")
def admin_threat_dist():
    guard = _admin_only()
    if guard:
        return guard

    since = datetime.now() - timedelta(hours=_hours())
    rows = db.query_all(
        "SELECT event_type, COUNT(*) AS cnt FROM security_events "
        "WHERE ts >= %s GROUP BY event_type ORDER BY cnt DESC LIMIT 8",
        (since,),
    )
    return jsonify({
        "labels": [r["event_type"] for r in rows],
        "values": [int(r["cnt"]) for r in rows],
    })


@bp.get("/admin/live")
def admin_live():
    """대시보드 상단 KPI 실시간 갱신용."""
    guard = _admin_only()
    if guard:
        return guard

    since = datetime.now() - timedelta(hours=_hours())
    return jsonify({
        "total_requests": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= %s", (since,)),
        "unique_ips": db.query_scalar(
            "SELECT COUNT(DISTINCT ip) FROM access_logs WHERE ts >= %s", (since,)),
        "threat_requests": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= %s AND threat_score >= 35", (since,)),
        "error_requests": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= %s AND status_code >= 400", (since,)),
        "open_events": db.query_scalar(
            "SELECT COUNT(*) FROM security_events WHERE is_resolved=0"),
        "server_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    })
