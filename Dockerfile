# syntax=docker/dockerfile:1.7
# Build with --platform linux/amd64,linux/arm64.
ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:392307d22300de8b5986851a12d9176dfc0fc073e65bf6523ebd7dcbeb23564e

FROM ${PYTHON_IMAGE} AS wheels
WORKDIR /build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1
COPY requirements.txt .
RUN python -m pip install --upgrade pip==25.0.1 && \
    python -m pip wheel --wheel-dir /wheels -r requirements.txt

FROM ${PYTHON_IMAGE} AS runtime
ARG APP_UID=10001
ARG APP_GID=10001
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache
RUN groupadd --gid ${APP_GID} montecarlo && \
    useradd --uid ${APP_UID} --gid ${APP_GID} --home-dir /app --no-create-home --shell /usr/sbin/nologin montecarlo
COPY --from=wheels /wheels /wheels
RUN python -m pip install --no-cache-dir /wheels/* && rm -rf /wheels
COPY --chown=${APP_UID}:${APP_GID} app/montecarlo ./montecarlo
USER ${APP_UID}:${APP_GID}
ENTRYPOINT ["python", "-m", "montecarlo"]
