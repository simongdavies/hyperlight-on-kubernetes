FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgcc-s1 \
        procps \
        python3 \
        util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && test "$(id -u ubuntu)" = 1000 \
    && test "$(id -g ubuntu)" = 1000 \
    && install -d -o root -g root -m 0755 /opt/hyperlight /usr/libexec/hyperlight

COPY .kind-nested-assets/nested_sandbox /opt/hyperlight/nested_sandbox
COPY .kind-nested-assets/simpleguest /opt/hyperlight/simpleguest
COPY .kind-nested-assets/minijail0 /usr/libexec/hyperlight/minijail0
COPY .kind-nested-assets/minijail0.sha256 /usr/libexec/hyperlight/minijail0.sha256
COPY deploy/kind-nested/entrypoint.sh /usr/local/bin/hyperlight-kind-entrypoint
COPY deploy/kind-nested/privileged-entrypoint.sh /usr/local/bin/hyperlight-kind-privileged-entrypoint

RUN chmod 0755 \
        /opt/hyperlight/nested_sandbox \
        /opt/hyperlight/simpleguest \
        /usr/local/bin/hyperlight-kind-entrypoint \
        /usr/local/bin/hyperlight-kind-privileged-entrypoint \
    && chown root:1000 /usr/libexec/hyperlight/minijail0 \
    && chmod 0750 /usr/libexec/hyperlight/minijail0 \
    && chown root:root /usr/libexec/hyperlight/minijail0.sha256 \
    && chmod 0644 /usr/libexec/hyperlight/minijail0.sha256

ENTRYPOINT ["/usr/local/bin/hyperlight-kind-entrypoint"]
CMD ["demo"]
