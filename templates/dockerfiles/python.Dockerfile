# Python web app (FastAPI / Flask / Django) behind gunicorn or uvicorn.
# KIND=web or internal. Expected endpoint:
#   GET /healthz → 200 {"status":"ok","version": os.environ["RELEASE_SHA"]}
# Registry: CONTAINER_PORT=8000 HEALTH_PATH=/healthz RELEASE_PATH=/healthz RELEASE_KEY=version
# Migrations: RELEASE_COMMAND=alembic upgrade head   (Django: python manage.py migrate --noinput)
FROM python:3.12.16-slim
# Security fixes published after the base image was built: CI's scan refuses
# fixable CRITICAL vulnerabilities, and base images lag behind the fixes.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8000
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
# /data: mount point for persistent data (VOLUMES=<app>-data:/data), owned by
# the app user so a new named volume is writable.
RUN useradd --system --uid 10001 app && mkdir -p /data && chown -R app /app /data
ARG RELEASE_SHA
ENV RELEASE_SHA=$RELEASE_SHA
USER app
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --start-interval=1s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status == 200 else 1)"
# FastAPI shown; Django: ["gunicorn", "project.wsgi", "-b", "0.0.0.0:8000", "--graceful-timeout", "20"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--timeout-graceful-shutdown", "20"]
