#!/bin/bash
set -euo pipefail

cluster_name=hyperlight-nested
kind_version=v0.33.0
kind_sha256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
node_image=kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d
hyperlight_commit=bb153b2db78e2c8a8bf035a40c65afe8f93afdca
minijail_commit=8d20993c7189a948995bd20901abecc041e1a28e
plugin_image=hyperlight-device-plugin:kind-nested
demo_image=hyperlight-nested-demo:bb153b2

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cache_root=${HYPERLIGHT_KIND_CACHE:-"$HOME/.cache/hyperlight-kind"}
native_root=$cache_root/worktree
tool_root=$cache_root/tools
hyperlight_root=${HYPERLIGHT_SOURCE_CACHE:-"$HOME/.cache/hyperlight-k8s-source"}
minijail_root=${MINIJAIL_SOURCE_CACHE:-"$HOME/.cache/hyperlight-minijail"}

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    echo "error: $*" >&2
    exit 1
}

sync_native() {
    [[ ${HYPERLIGHT_KIND_NATIVE:-0} == 1 ]] && return
    [[ ${1:-} == demo ]] ||
        log "Syncing the working tree to native WSL storage: $native_root"
    mkdir -p "$native_root"
    rsync -a --delete \
        --exclude .git \
        --exclude .kind-nested-assets \
        "$source_root/" "$native_root/"
    find "$native_root" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
    sed -i 's/\r$//' \
        "$native_root/deploy/kind-nested/hyperlight-cgroup-hook" \
        "$native_root/deploy/kind-nested/hyperlight-runc"
    chmod 0755 \
        "$native_root/deploy/kind-nested/entrypoint.sh" \
        "$native_root/deploy/kind-nested/privileged-entrypoint.sh" \
        "$native_root/deploy/kind-nested/hyperlight-cgroup-hook" \
        "$native_root/deploy/kind-nested/hyperlight-runc"
    exec env \
        HYPERLIGHT_KIND_NATIVE=1 \
        HYPERLIGHT_KIND_CACHE="$cache_root" \
        bash "$native_root/scripts/kind-nested-wsl.sh" "$@"
}

require_command() {
    command -v "$1" >/dev/null || fail "required command is unavailable: $1"
}

bootstrap_kind() {
    mkdir -p "$tool_root"
    local kind=$tool_root/kind-$kind_version
    if [[ ! -x $kind ]]; then
        log "Installing pinned KIND $kind_version in $tool_root"
        local temporary=$kind.download
        curl -fL --retry 3 \
            "https://kind.sigs.k8s.io/dl/$kind_version/kind-linux-amd64" \
            -o "$temporary"
        echo "$kind_sha256  $temporary" | sha256sum -c -
        chmod 0755 "$temporary"
        mv "$temporary" "$kind"
    fi
    export PATH=$tool_root:$PATH
    ln -sfn "kind-$kind_version" "$tool_root/kind"
    [[ $(kind version) == *"$kind_version"* ]] ||
        fail "unexpected KIND version: $(kind version)"
}

landlock_abi() {
    python3 -c 'import ctypes; print(ctypes.CDLL(None, use_errno=True).syscall(444, 0, 0, 1))'
}

check_host() {
    log "Checking Ubuntu-24.04 WSL prerequisites"
    require_command docker
    require_command kubectl
    require_command git
    require_command curl
    require_command python3
    require_command rsync
    require_command sha256sum
    require_command cargo
    require_command just

    grep -qi microsoft /proc/version ||
        fail "this workflow is supported only inside WSL"
    . /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID == 24.04 ]] ||
        fail "Ubuntu 24.04 is required (found $PRETTY_NAME)"
    [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] ||
        fail "unified cgroup v2 is required"
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] ||
        fail "/dev/kvm must exist and be read-write for $(id -un)"
    unshare --user --map-root-user true ||
        fail "unprivileged user namespaces are unavailable"
    local abi
    abi=$(landlock_abi)
    [[ $abi =~ ^[0-9]+$ ]] && ((abi >= 5)) ||
        fail "Landlock ABI 5 or newer is required (found $abi)"
    [[ $(docker info --format '{{.CgroupVersion}}') == 2 ]] ||
        fail "Docker must use cgroup v2"
    [[ $(docker info --format '{{.CgroupDriver}}') == systemd ]] ||
        fail "Docker must use the systemd cgroup driver"
    docker run --rm --privileged --device /dev/kvm:/dev/kvm \
        ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3 \
        bash -ceu '
            test "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs
            test -w /sys/fs/cgroup/cgroup.procs
            test -r /dev/kvm
            test -w /dev/kvm
            grep -qw cpu /sys/fs/cgroup/cgroup.controllers
            grep -qw memory /sys/fs/cgroup/cgroup.controllers
            grep -qw pids /sys/fs/cgroup/cgroup.controllers
        '
    echo "PASS WSL kernel, KVM, Landlock ABI $abi, user namespaces and cgroup delegation"
}

prepare_source() {
    log "Preparing signed Hyperlight source $hyperlight_commit"
    mkdir -p "$cache_root"
    if [[ ! -d $hyperlight_root/.git ]]; then
        git clone --filter=blob:none --no-checkout \
            https://github.com/simongdavies/hyperlight.git "$hyperlight_root"
    fi
    git -C "$hyperlight_root" fetch --depth=1 origin "$hyperlight_commit"
    git -C "$hyperlight_root" checkout --detach "$hyperlight_commit"
    [[ -z $(git -C "$hyperlight_root" status --porcelain) ]] ||
        fail "Hyperlight cache is dirty: $hyperlight_root"
    git -C "$hyperlight_root" verify-commit "$hyperlight_commit"
    [[ $(git -C "$hyperlight_root" rev-parse HEAD) == "$hyperlight_commit" ]] ||
        fail "Hyperlight source pin mismatch"

    log "Preparing pinned Minijail source $minijail_commit"
    if [[ ! -d $minijail_root/.git ]]; then
        git clone https://chromium.googlesource.com/chromiumos/platform/minijail \
            "$minijail_root"
    fi
    git -C "$minijail_root" fetch --depth=1 origin "$minijail_commit"
    git -C "$minijail_root" checkout --detach "$minijail_commit"
    [[ -z $(git -C "$minijail_root" diff --cached --name-only) ]] ||
        fail "Minijail cache contains staged changes: $minijail_root"
    [[ -z $(git -C "$minijail_root" ls-files --others --exclude-standard) ]] ||
        fail "Minijail cache contains untracked files: $minijail_root"
}

build_assets() {
    prepare_source
    log "Building the digest-pinned strict Minijail helper"
    (
        cd "$hyperlight_root"
        python3 dev/process-isolation/build_minijail.py \
            "$minijail_root" --verify-recorded
    )

    log "Building the landed nested Hyperlight fixture and guest"
    if ! cargo +1.94 hyperlight --version 2>/dev/null | grep -qF 0.1.14; then
        cargo +1.94 install --locked --force --version 0.1.14 cargo-hyperlight
    fi
    (
        cd "$hyperlight_root"
        cargo +1.95 build --release --locked \
            -p hyperlight-host \
            --features process-isolation \
            --example nested_sandbox
        just build-rust-guests release
        just move-rust-guests release
    )

    local assets=$native_root/.kind-nested-assets
    rm -rf "$assets"
    install -d -m 0755 "$assets"
    install -m 0755 \
        "$hyperlight_root/target/release/examples/nested_sandbox" \
        "$assets/nested_sandbox"
    install -m 0755 \
        "$hyperlight_root/src/tests/rust_guests/bin/release/simpleguest" \
        "$assets/simpleguest"
    install -m 0755 "$minijail_root/minijail0" "$assets/minijail0"
    echo "d16432b3f6fcf1b0859f36dae50440863e6bff441b67eab688b02275d5e951b6  /usr/libexec/hyperlight/minijail0" \
        >"$assets/minijail0.sha256"
}

build_images() {
    build_assets
    log "Building local container images from native WSL storage"
    (
        cd "$native_root"
        docker build -t "$plugin_image" device-plugin
        docker build -t "$demo_image" -f deploy/kind-nested/Dockerfile .
    )
}

create_cluster() {
    bootstrap_kind
    if kind get clusters 2>/dev/null | grep -qx "$cluster_name"; then
        if ! docker exec "$cluster_name-control-plane" \
            /opt/hyperlight-runtime/hyperlight-runc --version >/dev/null ||
            ! docker exec "$cluster_name-control-plane" \
                grep -q 'BinaryName = "/opt/hyperlight-runtime/hyperlight-runc"' \
                /etc/containerd/config.toml ||
            ! docker exec "$cluster_name-control-plane" \
                test -r /var/lib/kubelet/seccomp/hyperlight-launcher.json; then
            log "Recreating KIND cluster $cluster_name with the Hyperlight RuntimeClass handler"
            kind delete cluster --name "$cluster_name"
        else
            log "KIND cluster $cluster_name already has the Hyperlight runtime handler"
        fi
    fi
    if ! kind get clusters 2>/dev/null | grep -qx "$cluster_name"; then
        log "Creating KIND cluster $cluster_name"
        local rendered_config=$cache_root/kind-config.yaml
        sed "s|\${NATIVE_ROOT}|$native_root|g" \
            "$native_root/deploy/kind-nested/kind-config.yaml" >"$rendered_config"
        kind create cluster \
            --name "$cluster_name" \
            --image "$node_image" \
            --config "$rendered_config"
    fi
    kubectl config use-context "kind-$cluster_name" >/dev/null
    docker exec "$cluster_name-control-plane" test -r /dev/kvm
    docker exec "$cluster_name-control-plane" test -w /dev/kvm
    docker exec "$cluster_name-control-plane" \
        /opt/hyperlight-runtime/hyperlight-runc --version >/dev/null
    docker exec "$cluster_name-control-plane" \
        test -x /opt/hyperlight-runtime/hyperlight-cgroup-hook
    docker exec "$cluster_name-control-plane" \
        test -r /var/lib/kubelet/seccomp/hyperlight-launcher.json
    docker exec "$cluster_name-control-plane" \
        grep -q 'BinaryName = "/opt/hyperlight-runtime/hyperlight-runc"' \
        /etc/containerd/config.toml
}

load_images() {
    log "Loading local images into KIND"
    kind load docker-image --name "$cluster_name" "$plugin_image" "$demo_image"
}

deploy_plugin() {
    log "Deploying the existing Hyperlight device plugin"
    sed \
        -e "s|\${IMAGE}|$plugin_image|g" \
        -e 's|\${DEVICE_COUNT}|32|g' \
        -e 's|\${DEVICE_UID}|1000|g' \
        -e 's|\${DEVICE_GID}|1000|g' \
        -e 's|imagePullPolicy: Always|imagePullPolicy: Never|' \
        "$native_root/deploy/local/device-plugin.yaml" |
        kubectl apply -f -
    kubectl rollout status daemonset/hyperlight-device-plugin \
        -n hyperlight-system --timeout=180s
    for _ in {1..60}; do
        local capacity
        capacity=$(kubectl get node "$cluster_name-control-plane" \
            -o jsonpath='{.status.allocatable.hyperlight\.dev/hypervisor}' 2>/dev/null || true)
        [[ $capacity == 32 ]] && return
        sleep 2
    done
    fail "the device plugin did not advertise hyperlight.dev/hypervisor"
}

deploy_runtime_class() {
    log "Deploying the Hyperlight delegated-cgroup RuntimeClass"
    kubectl apply -f "$native_root/deploy/kind-nested/runtime-class.yaml"
}

run_job() {
    local pace=${1:-0}
    log "Running the nested Hyperlight Kubernetes Job"
    kubectl delete job hyperlight-nested-demo -n hyperlight-system \
        --ignore-not-found --cascade=foreground --wait=true
    sed "s|\${DEMO_PACE_SECONDS}|$pace|" \
        "$native_root/deploy/kind-nested/job.yaml" |
        kubectl apply -f -
    if ! kubectl wait --for=condition=complete \
        job/hyperlight-nested-demo -n hyperlight-system --timeout=300s; then
        kubectl get pods -n hyperlight-system -o wide
        kubectl describe job hyperlight-nested-demo -n hyperlight-system
        kubectl logs -n hyperlight-system job/hyperlight-nested-demo --all-containers || true
        return 1
    fi
    kubectl logs -n hyperlight-system job/hyperlight-nested-demo
    kubectl logs -n hyperlight-system job/hyperlight-nested-demo |
        grep -q 'PASS unprivileged RuntimeClass nested Hyperlight KIND demonstration' ||
        fail "the nested scenario did not emit its final proof"
}

setup() {
    check_host
    bootstrap_kind
    build_images
    create_cluster
    load_images
    deploy_plugin
    deploy_runtime_class
    run_job 0
}

prepare_demo() {
    bootstrap_kind
    local cluster_missing=0
    kind get clusters 2>/dev/null | grep -qx "$cluster_name" ||
        cluster_missing=1
    if kind get clusters 2>/dev/null | grep -qx "$cluster_name" &&
        docker exec "$cluster_name-control-plane" \
            /opt/hyperlight-runtime/hyperlight-runc --version >/dev/null 2>&1 &&
        docker exec "$cluster_name-control-plane" \
            crictl inspecti "$plugin_image" >/dev/null 2>&1 &&
        docker exec "$cluster_name-control-plane" \
            crictl inspecti "$demo_image" >/dev/null 2>&1 &&
        kubectl --context "kind-$cluster_name" get daemonset \
            hyperlight-device-plugin -n hyperlight-system \
            -o jsonpath='{.status.numberReady}' 2>/dev/null | grep -qx 1 &&
        kubectl --context "kind-$cluster_name" get runtimeclass \
            hyperlight-delegated >/dev/null 2>&1; then
        log "Using the prepared KIND cluster"
        return
    fi

    check_host
    if ((cluster_missing)); then
        log "The KIND cluster is absent; rebuilding current images before setup"
        build_images
    elif ! docker image inspect "$plugin_image" "$demo_image" >/dev/null 2>&1; then
        log "One or more demo images are missing; building them now"
        build_images
    fi
    create_cluster
    load_images
    deploy_plugin
    deploy_runtime_class
}

status() {
    bootstrap_kind
    kubectl config use-context "kind-$cluster_name" >/dev/null
    kubectl get nodes -o wide
    kubectl get pods -n hyperlight-system -o wide
    kubectl get events -n hyperlight-system --sort-by=.lastTimestamp | tail -30
}

reset() {
    bootstrap_kind
    if kind get clusters 2>/dev/null | grep -qx "$cluster_name"; then
        log "Deleting KIND cluster $cluster_name"
        kind delete cluster --name "$cluster_name"
    else
        log "KIND cluster $cluster_name does not exist"
    fi
}

test_scripts() {
    bash -n \
        "$native_root/scripts/kind-nested-wsl.sh" \
        "$native_root/scripts/kind-nested-demo.sh" \
        "$native_root/deploy/kind-nested/entrypoint.sh" \
        "$native_root/deploy/kind-nested/privileged-entrypoint.sh" \
        "$native_root/deploy/kind-nested/hyperlight-runc" \
        "$native_root/deploy/kind-nested/hyperlight-cgroup-hook"
    grep -q 'kind: Job' "$native_root/deploy/kind-nested/job.yaml"
    grep -q 'runtimeClassName: hyperlight-delegated' \
        "$native_root/deploy/kind-nested/job.yaml"
    grep -q 'runAsUser: 1000' "$native_root/deploy/kind-nested/job.yaml"
    ! grep -q 'privileged: true' "$native_root/deploy/kind-nested/job.yaml"
    grep -q 'privileged: true' \
        "$native_root/deploy/kind-nested/job-privileged.yaml"
    grep -q 'hyperlight.dev/hypervisor: "1"' \
        "$native_root/deploy/kind-nested/job.yaml"
    grep -q 'BinaryName = "/opt/hyperlight-runtime/hyperlight-runc"' \
        "$native_root/deploy/kind-nested/kind-config.yaml"
    grep -q 'handler: hyperlight-delegated' \
        "$native_root/deploy/kind-nested/runtime-class.yaml"
    grep -q 'localhostProfile: hyperlight-launcher.json' \
        "$native_root/deploy/kind-nested/job.yaml"
    grep -q '"defaultAction": "SCMP_ACT_ALLOW"' \
        "$native_root/deploy/kind-nested/hyperlight-launcher-seccomp.json"
    grep -q 'kind: Cluster' "$native_root/deploy/kind-nested/kind-config.yaml"
    grep -q 'hostPath: /dev/kvm' "$native_root/deploy/kind-nested/kind-config.yaml"
    echo "PASS nested KIND scripts and Kubernetes Job manifest"
}

sync_native "$@"
command=${1:-setup}
shift || true
case "$command" in
    setup) setup "$@" ;;
    build) check_host; bootstrap_kind; build_images ;;
    smoke) create_cluster; load_images; deploy_plugin; deploy_runtime_class; run_job 0 ;;
    demo)
        prepare_demo
        exec "$native_root/scripts/kind-nested-demo.sh" "$@"
        ;;
    status) status ;;
    test) test_scripts ;;
    reset) reset ;;
    *)
        fail "usage: $0 {setup|build|smoke|demo|status|test|reset}"
        ;;
esac
