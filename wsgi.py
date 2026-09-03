"""
WSGI 엔트리포인트.

Gunicorn 이 이 모듈의 `app` 객체를 임포트해서 실행한다:
    gunicorn --config deploy/gunicorn.conf.py wsgi:app

로컬에서 개발 서버로 띄울 때는:
    FLASK_ENV=development python wsgi.py
"""
from __future__ import annotations

import os

from app import create_app

app = create_app()


if __name__ == "__main__":
    # 개발 편의용 실행 경로. 운영에서는 Gunicorn 을 사용한다.
    port = int(os.environ.get("PORT", 3000))
    host = os.environ.get("HOST", "0.0.0.0")
    app.run(host=host, port=port, debug=app.config.get("DEBUG", False))
