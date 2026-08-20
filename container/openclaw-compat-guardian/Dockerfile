# syntax=docker/dockerfile:1.10
FROM python:3.12-slim-bookworm

ARG TARGETOS
ARG TARGETARCH
ARG BUILDPLATFORM
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="OpenClaw Compatibility Guardian" \
      org.opencontainers.image.description="Non-privileged multi-architecture preflight for Raspberry Pi and cloud OpenClaw recovery" \
      org.opencontainers.image.source="https://github.com/mnwersdfppa/no-cost-ai" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="MIT" \
      io.openclaw.supported-platforms="linux/amd64,linux/arm64" \
      io.openclaw.provider-secret-included="false" \
      io.openclaw.second-telegram-poller="false" \
      io.openclaw.privileged-required="false"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OPENCLAW_ROOT=/openclaw \
    OPENCLAW_RUNTIME_DIR=/runtime

WORKDIR /opt/openclaw-compat-guardian
COPY guardian.py /opt/openclaw-compat-guardian/guardian.py

RUN python3 -m py_compile /opt/openclaw-compat-guardian/guardian.py \
    && python3 /opt/openclaw-compat-guardian/guardian.py self-test \
    && groupadd --gid 65532 guardian \
    && useradd --uid 65532 --gid 65532 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin guardian \
    && mkdir -p /openclaw /runtime \
    && chown 65532:65532 /runtime

USER 65532:65532

HEALTHCHECK --interval=5m --timeout=10s --start-period=10s --retries=2 \
  CMD ["python3", "/opt/openclaw-compat-guardian/guardian.py", "self-test"]

ENTRYPOINT ["python3", "/opt/openclaw-compat-guardian/guardian.py"]
CMD ["doctor"]
