# syntax=docker/dockerfile:1.7
# ---- build stage: resolve and compile dependencies ----------------------------
FROM python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- runtime stage: minimal, non-root, read-only friendly ---------------------
FROM python:3.12-slim AS runtime
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# Apply OS security patches published after the base image was cut, then create a
# dedicated unprivileged user (UID/GID fixed so k8s runAsUser matches).
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /install /usr/local
WORKDIR /app
COPY --chown=app:app main.py .

USER 10001:10001
EXPOSE 8080
# Health is checked by Kubernetes probes (/healthz, /readyz) rather than a Docker HEALTHCHECK.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--no-server-header"]
