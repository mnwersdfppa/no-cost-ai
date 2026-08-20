FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash \
       ca-certificates \
       coreutils \
       grep \
       python3 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 tester \
    && mkdir -p /opt/test /out \
    && chown -R tester:tester /opt/test /out

COPY --chmod=0755 docker/pi-model-route-finalizer/mock/openclaw /usr/local/bin/openclaw
COPY --chmod=0755 docker/pi-model-route-finalizer/mock/systemctl /usr/local/bin/systemctl
COPY --chmod=0755 pi/pi-model-route-finalizer-20260821.sh /opt/test/pi-model-route-finalizer-20260821.sh
COPY --chmod=0755 docker/pi-model-route-finalizer/run-test.sh /opt/test/run-test.sh

USER tester
ENV HOME=/home/tester
ENV PATH=/usr/local/bin:/usr/bin:/bin

ENTRYPOINT ["/opt/test/run-test.sh"]
