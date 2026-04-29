FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.txt .
RUN apt-get update && apt-get install -y --no-install-recommends curl \
&& groupadd --system app \
&& useradd --system --gid app --create-home --home-dir /home/app app \
&& pip install -r requirements.txt \
&& rm -rf /var/lib/apt/lists/*
COPY --chown=app:app . .
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=4 CMD curl -fsS http://localhost:8000/health || exit 1
CMD ["gunicorn", "backend.main:app", "-k", "uvicorn.workers.UvicornWorker", "--workers", "1", "--bind", "0.0.0.0:8000"]
