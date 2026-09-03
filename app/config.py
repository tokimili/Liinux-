"""
애플리케이션 설정.

모든 설정은 환경변수로 주입한다 (12-Factor App 원칙).
비밀정보를 코드에 하드코딩하지 않는 것 자체가 포트폴리오의 평가 항목이다.
"""
import os


def _bool(key: str, default: bool = False) -> bool:
    raw = os.environ.get(key)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _int(key: str, default: int) -> int:
    try:
        return int(os.environ.get(key, default))
    except (TypeError, ValueError):
        return default


class Config:
    # ---- Flask ----
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-only-insecure-key-change-me")
    JSON_AS_ASCII = False
    MAX_CONTENT_LENGTH = _int("MAX_UPLOAD_MB", 5) * 1024 * 1024

    # ---- 데이터베이스 ----
    DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
    DB_PORT = _int("DB_PORT", 3306)
    DB_USER = os.environ.get("DB_USER", "vmlab")
    DB_PASSWORD = os.environ.get("DB_PASSWORD", "vmlab_dev_pw")
    DB_NAME = os.environ.get("DB_NAME", "vmlab")
    DB_POOL_SIZE = _int("DB_POOL_SIZE", 5)

    # ---- 보안 모드 (이 프로젝트의 핵심 스위치) ----
    # secure : 방어 적용 버전 (patched). 외부 공개 가능.
    # vulnerable : 의도적 취약점 활성화. 격리 네트워크에서만 사용.
    SECURITY_MODE = os.environ.get("SECURITY_MODE", "secure").strip().lower()

    # ---- 세션 쿠키 ----
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    SESSION_COOKIE_SECURE = _bool("SESSION_COOKIE_SECURE", False)
    PERMANENT_SESSION_LIFETIME = _int("SESSION_LIFETIME_MIN", 60) * 60

    # ---- 업로드 ----
    UPLOAD_DIR = os.environ.get("UPLOAD_DIR", "/app/uploads")
    ALLOWED_UPLOAD_EXT = {"png", "jpg", "jpeg", "gif", "pdf", "txt", "md"}

    # ---- 접속 로그 ----
    # 프록시(Nginx/cloudflared) 뒤에서 실제 클라이언트 IP를 얻기 위해 신뢰할 홉 수
    TRUSTED_PROXY_COUNT = _int("TRUSTED_PROXY_COUNT", 1)
    LOG_EXCLUDE_PREFIXES = ("/static/", "/healthz", "/favicon.ico")
    ACCESS_LOG_RETENTION_DAYS = _int("ACCESS_LOG_RETENTION_DAYS", 90)

    # ---- 관리자 대시보드 ----
    ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
    # 최초 부팅 시에만 사용. 운영에서는 반드시 환경변수로 교체.
    ADMIN_INITIAL_PASSWORD = os.environ.get("ADMIN_INITIAL_PASSWORD", "ChangeMe!2026")

    # ---- 로그인 브루트포스 방어 ----
    LOGIN_MAX_ATTEMPTS = _int("LOGIN_MAX_ATTEMPTS", 5)
    LOGIN_LOCKOUT_MINUTES = _int("LOGIN_LOCKOUT_MINUTES", 15)

    # ---- 배포 메타 (CI/CD가 주입) ----
    APP_VERSION = os.environ.get("APP_VERSION", "dev")
    GIT_COMMIT = os.environ.get("GIT_COMMIT", "unknown")
    DEPLOYED_AT = os.environ.get("DEPLOYED_AT", "")

    @property
    def is_vulnerable_mode(self) -> bool:
        return self.SECURITY_MODE == "vulnerable"


class DevConfig(Config):
    DEBUG = True


class ProdConfig(Config):
    DEBUG = False
    SESSION_COOKIE_SECURE = _bool("SESSION_COOKIE_SECURE", True)


def get_config():
    env = os.environ.get("FLASK_ENV", "production").strip().lower()
    return DevConfig() if env in ("dev", "development") else ProdConfig()
