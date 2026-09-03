"""
pytest 공용 픽스처.

CI 는 MariaDB 서비스 컨테이너를 띄우고 이 픽스처가 그것에 붙는다.
DB 가 없으면 테스트를 skip 하지 않고 **실패**시킨다 —
"DB가 없어서 통과한 CI"는 배포 게이트로서 의미가 없기 때문이다.
"""
from __future__ import annotations

import os
import sys
import uuid

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import create_app  # noqa: E402
from app.config import Config  # noqa: E402
from app.core import db  # noqa: E402
from app.core.security import hash_password  # noqa: E402

TEST_PASSWORD = "TestPass!2026"


class _TestConfig(Config):
    """테스트 전용 설정. SECURITY_MODE 는 각 테스트가 오버라이드한다."""
    TESTING = True
    DEBUG = False
    SECRET_KEY = "test-secret-key-not-for-production"
    SECURITY_MODE = "secure"
    SESSION_COOKIE_SECURE = False
    WTF_CSRF_ENABLED = False
    UPLOAD_DIR = "/tmp/vmlab-test-uploads"
    APP_VERSION = "test"
    GIT_COMMIT = "testcommit"
    LOGIN_MAX_ATTEMPTS = 5
    LOGIN_LOCKOUT_MINUTES = 15


def _make_config(mode: str = "secure") -> _TestConfig:
    cfg = _TestConfig()
    cfg.SECURITY_MODE = mode
    return cfg


@pytest.fixture(scope="session")
def _schema():
    """세션 시작 시 스키마를 한 번 적용한다."""
    cfg = _make_config()
    db.init_db(cfg)

    migration = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "migrations", "0001_initial_schema.sql",
    )
    with open(migration, encoding="utf-8") as fh:
        sql = fh.read()

    # migrate.py 의 파서를 재사용해 동일한 방식으로 적용한다
    sys.path.insert(0, os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
    from migrate import split_statements  # noqa: E402

    with db.get_cursor(commit=True) as cur:
        for stmt in split_statements(sql):
            cur.execute(stmt)
    return True


@pytest.fixture(autouse=True)
def _isolate_login_attempts(_schema):
    """
    테스트 간 브루트포스 잠금 누출 방지.

    _is_locked_out() 은 **IP 단위**로도 잠금을 판단한다(분산 시도 대응).
    테스트는 모두 127.0.0.1 에서 오므로, SQLi 인증우회 테스트처럼
    의도적으로 로그인을 실패시키는 테스트가 임계값을 채우면
    그 뒤의 모든 테스트가 "정상 로그인 실패"로 무너진다.

    즉 이건 방어 로직의 결함이 아니라 테스트 격리 문제이므로,
    각 테스트 시작 전에 이 IP 의 시도 기록만 비운다.
    잠금 자체를 검증하는 테스트는 자기 안에서 실패를 다시 쌓는다.
    """
    db.execute("DELETE FROM login_attempts WHERE ip IN ('127.0.0.1','::1')")
    yield


@pytest.fixture
def app(_schema):
    """secure 모드 앱 (기본)."""
    os.makedirs(_TestConfig.UPLOAD_DIR, exist_ok=True)
    application = create_app(_make_config("secure"))
    yield application


@pytest.fixture
def vuln_app(_schema):
    """vulnerable 모드 앱 — 취약점이 실제로 재현되는지 확인용."""
    os.makedirs(_TestConfig.UPLOAD_DIR, exist_ok=True)
    application = create_app(_make_config("vulnerable"))
    yield application


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def vuln_client(vuln_app):
    return vuln_app.test_client()


@pytest.fixture
def unique():
    """테스트 간 이름 충돌을 막는 짧은 랜덤 접미사."""
    return uuid.uuid4().hex[:8]


@pytest.fixture
def user_factory(app, unique):
    """테스트용 사용자를 만들고 (username, password, id) 를 반환."""
    created: list[int] = []

    def _create(role: str = "user", prefix: str = "u"):
        name = f"{prefix}_{unique}_{len(created)}"
        uid = db.insert(
            "INSERT INTO users (username, email, password_hash, role) "
            "VALUES (%s,%s,%s,%s)",
            (name, f"{name}@test.local", hash_password(TEST_PASSWORD), role),
        )
        created.append(uid)
        return name, TEST_PASSWORD, uid

    yield _create

    for uid in created:
        db.execute("DELETE FROM users WHERE id=%s", (uid,))


@pytest.fixture
def login(client):
    """CSRF 토큰을 포함해 실제 로그인 폼을 통과하는 헬퍼."""
    def _login(username: str, password: str):
        # 세션에 CSRF 토큰을 생성시키기 위해 먼저 GET
        page = client.get("/auth/login")
        assert page.status_code == 200
        with client.session_transaction() as sess:
            token = sess.get("csrf_token", "")
        return client.post(
            "/auth/login",
            data={"username": username, "password": password, "csrf_token": token},
            follow_redirects=False,
        )
    return _login


@pytest.fixture
def csrf(client):
    """현재 세션의 CSRF 토큰을 얻는다."""
    def _token():
        with client.session_transaction() as sess:
            if "csrf_token" not in sess:
                client.get("/auth/login")
            with client.session_transaction() as s2:
                return s2.get("csrf_token", "")
    return _token
