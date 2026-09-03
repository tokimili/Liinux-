"""메인 블루프린트 — 홈, 프로젝트 소개, 데이터 흐름 안내."""
from __future__ import annotations

from flask import Blueprint, current_app, render_template

from app.core import db

bp = Blueprint("main", __name__)


@bp.get("/")
def index():
    cfg = current_app.config_obj

    stats = {
        "posts": db.query_scalar("SELECT COUNT(*) FROM posts WHERE is_deleted=0"),
        "users": db.query_scalar("SELECT COUNT(*) FROM users"),
        "requests_today": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= CURDATE()"
        ),
        "threats_today": db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE ts >= CURDATE() AND threat_score >= 35"
        ),
    }

    recent_posts = db.query_all(
        "SELECT p.id, p.title, p.view_count, p.created_at, u.username "
        "FROM posts p JOIN users u ON u.id = p.user_id "
        "WHERE p.is_deleted = 0 "
        "ORDER BY p.created_at DESC LIMIT 5"
    )

    last_deploy = db.query_one(
        "SELECT deployed_at, git_commit, app_version, actor, mode "
        "FROM deployments ORDER BY deployed_at DESC LIMIT 1"
    )

    return render_template(
        "index.html",
        stats=stats,
        recent_posts=recent_posts,
        last_deploy=last_deploy,
        config=cfg,
    )


@bp.get("/about")
def about():
    """프로젝트 아키텍처와 데이터 흐름 설명 (포트폴리오 방문자용)."""
    return render_template("about.html")
