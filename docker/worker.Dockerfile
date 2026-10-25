FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir uv==0.11.32

WORKDIR /workspace
COPY pyproject.toml uv.lock ./
COPY services/worker/pyproject.toml services/worker/uv.lock ./services/worker/
COPY services/worker/src ./services/worker/src
RUN uv sync --project services/worker --locked

WORKDIR /workspace/services/worker
CMD ["/opt/venv/bin/python", "-m", "celery", "-A", "facetrack_worker.executor:app", "worker", "--pool=solo", "--concurrency=1", "--loglevel=WARNING", "--without-gossip", "--without-mingle"]
