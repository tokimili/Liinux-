-- =====================================================================
-- 0001_initial_schema.sql
-- 로컬 VM 보안 실습 포트폴리오 — 초기 스키마
-- 대상: MySQL 8.0 / MariaDB 10.6+
-- =====================================================================

SET NAMES utf8mb4;

-- ---------------------------------------------------------------------
-- 사용자
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id            INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  username      VARCHAR(32)   NOT NULL,
  email         VARCHAR(190)  NOT NULL,
  -- 해시 알고리즘 교체(bcrypt -> argon2 등)를 견디도록 넉넉하게
  password_hash VARCHAR(255)  NOT NULL,
  role          ENUM('user','admin') NOT NULL DEFAULT 'user',
  is_active     TINYINT(1)    NOT NULL DEFAULT 1,
  created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_login_at DATETIME      NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_username (username),
  UNIQUE KEY uq_users_email (email),
  KEY idx_users_role (role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 게시글
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS posts (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id     INT UNSIGNED NOT NULL,
  title       VARCHAR(200) NOT NULL,
  content     TEXT         NOT NULL,
  view_count  INT UNSIGNED NOT NULL DEFAULT 0,
  is_deleted  TINYINT(1)   NOT NULL DEFAULT 0,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_posts_user (user_id),
  KEY idx_posts_created (created_at DESC),
  KEY idx_posts_live (is_deleted, created_at DESC),
  FULLTEXT KEY ft_posts_search (title, content),
  CONSTRAINT fk_posts_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 댓글
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS comments (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  post_id    INT UNSIGNED NOT NULL,
  user_id    INT UNSIGNED NOT NULL,
  content    VARCHAR(1000) NOT NULL,
  is_deleted TINYINT(1)   NOT NULL DEFAULT 0,
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_comments_post (post_id, created_at),
  CONSTRAINT fk_comments_post FOREIGN KEY (post_id)
    REFERENCES posts(id) ON DELETE CASCADE,
  CONSTRAINT fk_comments_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 업로드 파일
--   stored_name 은 서버가 생성한 안전한 이름(UUID),
--   original_name 은 사용자가 올린 원본 이름(표시용, 이스케이프 필요)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS uploads (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  post_id       INT UNSIGNED NULL,
  user_id       INT UNSIGNED NOT NULL,
  original_name VARCHAR(255) NOT NULL,
  stored_name   VARCHAR(255) NOT NULL,
  mime_type     VARCHAR(120) NULL,
  size_bytes    INT UNSIGNED NOT NULL DEFAULT 0,
  sha256        CHAR(64)     NULL,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_uploads_stored (stored_name),
  KEY idx_uploads_post (post_id),
  CONSTRAINT fk_uploads_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 접속 로그 (관리자 대시보드의 핵심 데이터 소스)
--
-- 설계 의도:
--  - 대시보드가 시간대별/경로별/IP별 집계를 자주 하므로 인덱스를 목적별로 구성
--  - threat_score / threat_tags 로 위협 탐지 결과를 함께 적재해
--    "로그 분석으로 공격을 탐지했다"는 증거를 만든다 (로드맵 Phase 5)
-- =====================================================================
CREATE TABLE IF NOT EXISTS access_logs (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  ts            DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  ip            VARCHAR(45)   NOT NULL,           -- IPv6 대응
  method        VARCHAR(10)   NOT NULL,
  path          VARCHAR(512)  NOT NULL,
  query_string  VARCHAR(1024) NULL,
  status_code   SMALLINT UNSIGNED NOT NULL,
  duration_ms   INT UNSIGNED  NOT NULL DEFAULT 0,
  bytes_sent    INT UNSIGNED  NOT NULL DEFAULT 0,
  user_id       INT UNSIGNED  NULL,
  username      VARCHAR(32)   NULL,               -- 비정규화(조인 없이 조회)
  user_agent    VARCHAR(512)  NULL,
  referer       VARCHAR(512)  NULL,
  country       VARCHAR(2)    NULL,               -- cloudflared 가 넣어주면 사용
  is_admin_path TINYINT(1)    NOT NULL DEFAULT 0,
  threat_score  TINYINT UNSIGNED NOT NULL DEFAULT 0,  -- 0~100
  threat_tags   VARCHAR(255)  NULL,               -- 예: "sqli,scanner"
  PRIMARY KEY (id),
  KEY idx_logs_ts (ts DESC),
  KEY idx_logs_ip_ts (ip, ts DESC),
  KEY idx_logs_status (status_code, ts DESC),
  KEY idx_logs_threat (threat_score, ts DESC),
  KEY idx_logs_path (path(191)),
  KEY idx_logs_user (user_id, ts DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 로그인 시도 (브루트포스 탐지 및 차단)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS login_attempts (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  ts         DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  ip         VARCHAR(45)  NOT NULL,
  username   VARCHAR(64)  NOT NULL,
  success    TINYINT(1)   NOT NULL DEFAULT 0,
  user_agent VARCHAR(512) NULL,
  reason     VARCHAR(64)  NULL,   -- bad_password / no_such_user / locked ...
  PRIMARY KEY (id),
  KEY idx_attempts_ip_ts (ip, ts DESC),
  KEY idx_attempts_user_ts (username, ts DESC),
  KEY idx_attempts_success (success, ts DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 보안 이벤트 (대시보드 경보 패널)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS security_events (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  ts          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  severity    ENUM('info','low','medium','high','critical') NOT NULL DEFAULT 'info',
  event_type  VARCHAR(64)  NOT NULL,  -- sqli_attempt / xss_attempt / brute_force ...
  ip          VARCHAR(45)  NULL,
  path        VARCHAR(512) NULL,
  detail      TEXT         NULL,
  is_resolved TINYINT(1)   NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_events_ts (ts DESC),
  KEY idx_events_sev (severity, ts DESC),
  KEY idx_events_type (event_type, ts DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 차단된 IP (fail2ban 과 별개로 앱 레벨 차단)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS blocked_ips (
  ip         VARCHAR(45)  NOT NULL,
  reason     VARCHAR(255) NULL,
  blocked_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at DATETIME     NULL,   -- NULL = 영구
  created_by VARCHAR(32)  NULL,
  PRIMARY KEY (ip),
  KEY idx_blocked_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 배포 이력 (CI/CD 가 배포 때마다 기록 -> 대시보드에 표시)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS deployments (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  deployed_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  git_commit  VARCHAR(40)  NULL,
  git_ref     VARCHAR(120) NULL,
  app_version VARCHAR(40)  NULL,
  actor       VARCHAR(80)  NULL,   -- github actor
  mode        VARCHAR(20)  NULL,   -- secure / vulnerable
  note        VARCHAR(255) NULL,
  PRIMARY KEY (id),
  KEY idx_deploy_ts (deployed_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 스키마 버전 관리
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    VARCHAR(20) NOT NULL,
  applied_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO schema_migrations (version) VALUES ('0001');
