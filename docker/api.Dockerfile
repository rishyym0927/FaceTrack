FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv

RUN pip install --no-cache-dir uv==0.11.32

WORKDIR /workspace/services/api
COPY services/api/pyproject.toml services/api/uv.lock ./
COPY services/api/app ./app
COPY services/api/alembic.ini ./
COPY services/api/alembic ./alembic
COPY services/api/tools ./tools
RUN uv sync --locked

EXPOSE 8000
CMD ["/opt/venv/bin/python", "-m", "uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
