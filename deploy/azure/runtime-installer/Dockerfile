FROM golang:1.24-bookworm AS build

WORKDIR /src
COPY deploy/azure/runtime-installer/go.mod deploy/azure/runtime-installer/main.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/hyperlight-runtime .

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/hyperlight-runtime /usr/local/libexec/hyperlight-runtime
COPY deploy/azure/runtime-installer/install-runtime.sh /usr/local/sbin/install-hyperlight-runtime
COPY deploy/kind-nested/hyperlight-launcher-seccomp.json /usr/local/share/hyperlight-launcher.json

RUN chmod 0755 \
    /usr/local/libexec/hyperlight-runtime \
    /usr/local/sbin/install-hyperlight-runtime

ENTRYPOINT ["/usr/local/sbin/install-hyperlight-runtime"]
CMD ["serve"]
