#!/bin/bash
set -euo pipefail

runtime_dir=/host-runtime
runtime_state=/host-runtime-state
containerd_dir=/host-containerd
containerd_config=$containerd_dir/config.toml
seccomp_dir=/host-seccomp
managed_begin='# BEGIN HYPERLIGHT DELEGATED RUNTIME'
managed_end='# END HYPERLIGHT DELEGATED RUNTIME'
node_name=${NODE_NAME:-}

log() {
    printf 'hyperlight node runtime: %s\n' "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

cleanup_temporary_files() {
    rm -f \
        "$containerd_dir"/.hyperlight-config.* \
        "$runtime_state"/containerd-config-backup.*
}

trap cleanup_temporary_files EXIT

patch_node() {
    local patch=$1
    local token=/var/run/secrets/kubernetes.io/serviceaccount/token
    local ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    [[ -n $node_name && -r $token && -r $ca ]] || return 0
    curl --fail --silent --show-error \
        --cacert "$ca" \
        -H "Authorization: Bearer $(cat "$token")" \
        -H 'Content-Type: application/merge-patch+json' \
        -X PATCH \
        --data "$patch" \
        "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}/api/v1/nodes/${node_name}" \
        >/dev/null
}

remove_managed_block() {
    local source=$1
    local destination=$2
    awk -v begin="$managed_begin" -v end="$managed_end" '
        $0 == begin { managed = 1; next }
        $0 == end { managed = 0; next }
        !managed { print }
    ' "$source" >"$destination"
}

runtime_plugin() {
    if grep -Fq 'plugins."io.containerd.cri.v1.runtime"' \
        "$containerd_config"; then
        printf '%s\n' 'io.containerd.cri.v1.runtime'
    elif grep -Fq 'plugins."io.containerd.grpc.v1.cri"' \
        "$containerd_config"; then
        printf '%s\n' 'io.containerd.grpc.v1.cri'
    else
        log "ERROR: unsupported containerd CRI configuration" >&2
        return 1
    fi
}

real_runc() {
    local candidate
    for candidate in /usr/bin/runc /usr/local/sbin/runc /usr/local/bin/runc; do
        if nsenter --target 1 --mount -- test -x "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    log "ERROR: host runc executable was not found" >&2
    return 1
}

restart_containerd() {
    log "restarting containerd after a configuration change"
    nsenter --target 1 --mount --uts --ipc --net --pid -- \
        systemctl restart containerd
    for _ in {1..60}; do
        if nsenter --target 1 --mount -- \
            systemctl is-active --quiet containerd; then
            return
        fi
        sleep 1
    done
    log "ERROR: containerd did not become active"
    return 1
}

validate_containerd_config() {
    nsenter --target 1 --mount -- \
        containerd --config /etc/containerd/config.toml config dump >/dev/null
}

install_runtime() {
    [[ -c /host-dev-kvm ]] || fail "/dev/kvm is unavailable"
    [[ -r /host-cgroup/cgroup.controllers ]] || fail "cgroup v2 is unavailable"
    [[ -f $containerd_config ]] || fail "$containerd_config is unavailable"
    local landlock_abi
    landlock_abi=$(/usr/local/libexec/hyperlight-runtime landlock-abi) ||
        fail "Landlock is unavailable"
    if [[ ! $landlock_abi =~ ^[0-9]+$ ]] || ((landlock_abi < 5)); then
        fail "Landlock ABI 5 or newer is required (found $landlock_abi); use a Linux 6.10+ node image"
    fi
    nsenter --target 1 --mount -- \
        containerd --config /etc/containerd/config.toml config dump |
        awk '/SystemdCgroup = true/ { found = 1 } END { exit !found }' ||
        fail "AKS containerd is not using the required systemd cgroup manager"

    local plugin runc temporary
    plugin=$(runtime_plugin)
    runc=$(real_runc)
    install -d -m 0755 "$runtime_dir" "$seccomp_dir"
    install -d -m 0700 "$runtime_state"
    install -m 0755 /usr/local/libexec/hyperlight-runtime "$runtime_dir/hyperlight-runtime"
    ln -sfn hyperlight-runtime "$runtime_dir/hyperlight-runc"
    ln -sfn hyperlight-runtime "$runtime_dir/hyperlight-cgroup-hook"
    printf '%s\n' "$runc" >"$runtime_dir/real-runc"
    chmod 0644 "$runtime_dir/real-runc"
    install -m 0644 /usr/local/share/hyperlight-launcher.json \
        "$seccomp_dir/hyperlight-launcher.json"

    temporary=$(mktemp "$containerd_dir/.hyperlight-config.XXXXXX")
    remove_managed_block "$containerd_config" "$temporary"
    cat >>"$temporary" <<EOF
$managed_begin
[plugins."${plugin}".containerd.runtimes.hyperlight-delegated]
  runtime_type = "io.containerd.runc.v2"
[plugins."${plugin}".containerd.runtimes.hyperlight-delegated.options]
  BinaryName = "/opt/hyperlight-runtime/hyperlight-runc"
  SystemdCgroup = true
$managed_end
EOF
    chmod --reference="$containerd_config" "$temporary"
    chown --reference="$containerd_config" "$temporary"
    if cmp -s "$containerd_config" "$temporary"; then
        rm -f "$temporary"
        log "runtime handler is already configured"
    else
        local backup
        backup=$(mktemp "$runtime_state/containerd-config-backup.XXXXXX")
        cp --preserve=all "$containerd_config" "$backup"
        mv "$temporary" "$containerd_config"
        if ! validate_containerd_config || ! restart_containerd; then
            log "restoring the previous containerd configuration"
            cp --preserve=all "$backup" "$containerd_config"
            restart_containerd || true
            rm -f "$backup"
            fail "containerd rejected the Hyperlight runtime configuration"
        fi
        rm -f "$backup"
    fi

    nsenter --target 1 --mount -- \
        containerd config dump |
        awk '/hyperlight-delegated/ { found = 1 } END { exit !found }' ||
        fail "containerd did not load the runtime handler"
    patch_node '{"metadata":{"labels":{"hyperlight.dev/runtime":"delegated"}}}'
    log "node ${node_name:-unknown} is ready"
}

uninstall_runtime() {
    if compgen -G "$runtime_state/*.cgroup" >/dev/null; then
        fail "delegated containers are still present; refusing to uninstall"
    fi
    patch_node '{"metadata":{"labels":{"hyperlight.dev/runtime":null}}}' || true
    if [[ -f $containerd_config ]] &&
        grep -Fqx "$managed_begin" "$containerd_config"; then
        local backup temporary
        temporary=$(mktemp "$containerd_dir/.hyperlight-config.XXXXXX")
        backup=$(mktemp "$runtime_state/containerd-config-backup.XXXXXX")
        cp --preserve=all "$containerd_config" "$backup"
        remove_managed_block "$containerd_config" "$temporary"
        chmod --reference="$containerd_config" "$temporary"
        chown --reference="$containerd_config" "$temporary"
        mv "$temporary" "$containerd_config"
        if ! validate_containerd_config || ! restart_containerd; then
            log "restoring containerd after uninstall failure"
            cp --preserve=all "$backup" "$containerd_config"
            restart_containerd || true
            rm -f "$backup"
            fail "containerd rejected removal of the Hyperlight runtime"
        fi
        rm -f "$backup"
    fi
    rm -f \
        "$runtime_dir/hyperlight-runc" \
        "$runtime_dir/hyperlight-cgroup-hook" \
        "$runtime_dir/hyperlight-runtime" \
        "$runtime_dir/real-runc" \
        "$seccomp_dir/hyperlight-launcher.json"
    rmdir "$runtime_dir" "$runtime_state" 2>/dev/null || true
    log "runtime handler removed"
}

case "${1:-serve}" in
    install)
        install_runtime
        ;;
    uninstall)
        uninstall_runtime
        ;;
    check)
        [[ -x $runtime_dir/hyperlight-runc ]]
        [[ -x $runtime_dir/hyperlight-cgroup-hook ]]
        [[ -r $seccomp_dir/hyperlight-launcher.json ]]
        grep -Fqx "$managed_begin" "$containerd_config"
        ;;
    serve)
        install_runtime
        trap 'exit 0' TERM INT
        while sleep 3600; do :; done
        ;;
    *)
        fail "unknown command: $1"
        ;;
esac
