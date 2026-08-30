FROM python:3.13-alpine

LABEL org.opencontainers.image.title="OpenClaw Pi compatibility probe" \
      org.opencontainers.image.description="Rootless outbound-only Supabase Guardian, queue and Ollama health probe" \
      org.opencontainers.image.source="https://github.com/mnwersdfppa/no-cost-ai" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache ca-certificates tini \
    && addgroup -S -g 10001 openclaw \
    && adduser -S -D -H -u 10001 -G openclaw openclaw \
    && mkdir -p /app /data \
    && chown -R 10001:10001 /app /data

COPY --chown=10001:10001 openclaw_compat.py /app/openclaw_compat.py
COPY --chown=10001:10001 entrypoint.sh /app/entrypoint.sh

RUN chmod 0555 /app/openclaw_compat.py /app/entrypoint.sh

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OPENCLAW_COMPAT_MODE=oneshot \
    RECEIPT_PATH=/data/openclaw-compat-receipt.json \
    PROBE_INTERVAL_SECONDS=120

USER 10001:10001
WORKDIR /app
VOLUME ["/data"]

HEALTHCHECK --interval=60s --timeout=10s --start-period=10s --retries=3 \
  CMD ["python3", "/app/openclaw_compat.py", "--self-test"]

ENTRYPOINT ["/sbin/tini", "--", "/app/entrypoint.sh"]
