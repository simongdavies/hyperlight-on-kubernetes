#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
source "$project_root/deploy/common.sh"

if [[ -f $project_root/deploy/azure/config.env ]]; then
    source "$project_root/deploy/azure/config.env"
fi

acr_name=${ACR_NAME:-hyperlightacr}
cluster_name=${CLUSTER_NAME:-hyperlight-cluster}
resource_group=${RESOURCE_GROUP:-hyperlight-rg}
image_tag=${AKS_IMAGE_TAG:-aks-nested}
device_count=${DEVICE_COUNT:-32}
device_uid=${DEVICE_UID:-1000}
device_gid=${DEVICE_GID:-1000}
registry=${REGISTRY:-$acr_name.azurecr.io}
plugin_local=hyperlight-device-plugin:kind-nested
demo_local=hyperlight-nested-demo:bb153b2
installer_local=hyperlight-runtime-installer:$image_tag
plugin_image=$registry/hyperlight-device-plugin:$image_tag
demo_image=$registry/hyperlight-nested-demo:$image_tag
installer_image=$registry/hyperlight-runtime-installer:$image_tag

require() {
    command -v "$1" >/dev/null 2>&1 ||
        fail "$1 is required"
}

fail() {
    log_error "$*"
    exit 1
}

check_cluster() {
    require kubectl
    kubectl cluster-info >/dev/null 2>&1 ||
        fail "kubectl cannot reach an AKS cluster"
}

cluster_create() {
    require az
    require kubectl
    KVM_NODE_COUNT=${KVM_NODE_COUNT:-1} \
        KVM_NODE_MIN_COUNT=${KVM_NODE_MIN_COUNT:-1} \
        KVM_NODE_MAX_COUNT=${KVM_NODE_MAX_COUNT:-2} \
        "$project_root/deploy/azure/setup.sh" --kvm-only
}

connect_cluster() {
    require az
    require kubectl
    az aks get-credentials \
        --resource-group "$resource_group" \
        --name "$cluster_name" \
        --overwrite-existing \
        --file "${KUBECONFIG:-$HOME/.kube/config}"
    kubectl config use-context "$cluster_name" >/dev/null
    kubectl cluster-info
    log_success "kubectl is connected to $cluster_name"
}

check_kvm_nodes() {
    local count
    count=$(kubectl get nodes \
        -l hyperlight.dev/enabled=true,hyperlight.dev/hypervisor=kvm \
        --no-headers 2>/dev/null | wc -l)
    ((count > 0)) || fail "no enabled KVM nodes were found"
}

acr_login() {
    require az
    require docker
    local token
    token=$(az acr login --name "$acr_name" --expose-token \
        --output tsv --query accessToken)
    printf '%s' "$token" |
        docker login "$registry" \
            --username 00000000-0000-0000-0000-000000000000 \
            --password-stdin
}

build_images() {
    require docker
    log_info "Building pinned nested Hyperlight and device-plugin images"
    bash "$project_root/scripts/kind-nested-wsl.sh" build
    log_info "Building AKS node runtime installer"
    docker build \
        -f "$project_root/deploy/azure/runtime-installer/Dockerfile" \
        -t "$installer_local" \
        "$project_root"
    log_success "AKS images built"
}

publish_images() {
    acr_login
    for source in "$plugin_local" "$demo_local" "$installer_local"; do
        docker image inspect "$source" >/dev/null 2>&1 ||
            fail "local image is missing: $source (run build first)"
    done
    docker tag "$plugin_local" "$plugin_image"
    docker tag "$demo_local" "$demo_image"
    docker tag "$installer_local" "$installer_image"
    docker push "$plugin_image"
    docker push "$demo_image"
    docker push "$installer_image"
    log_success "AKS images published with tag $image_tag"
}

apply_device_plugin() {
    export IMAGE=$plugin_image
    export DEVICE_COUNT=$device_count
    export DEVICE_UID=$device_uid
    export DEVICE_GID=$device_gid
    envsubst '${IMAGE} ${DEVICE_COUNT} ${DEVICE_UID} ${DEVICE_GID}' \
        <"$project_root/deploy/manifests/device-plugin.yaml" |
        kubectl apply -f -
}

apply_runtime() {
    export RUNTIME_INSTALLER_IMAGE=$installer_image
    envsubst '${RUNTIME_INSTALLER_IMAGE}' \
        <"$project_root/deploy/azure/runtime-installer.yaml" |
        kubectl apply -f -
}

wait_for_runtime() {
    kubectl rollout status daemonset/hyperlight-runtime-installer \
        -n hyperlight-node-system --timeout=10m
    local expected ready
    expected=$(kubectl get nodes \
        -l hyperlight.dev/enabled=true,hyperlight.dev/hypervisor=kvm \
        --no-headers | wc -l)
    for _ in {1..120}; do
        ready=$(kubectl get nodes \
            -l hyperlight.dev/runtime=delegated,hyperlight.dev/hypervisor=kvm \
            --no-headers | wc -l)
        [[ $ready == "$expected" ]] && return
        sleep 5
    done
    fail "not all KVM nodes acquired the delegated-runtime readiness label"
}

deploy() {
    require envsubst
    check_cluster
    check_kvm_nodes
    log_info "Deploying the device plugin"
    apply_device_plugin
    kubectl rollout status daemonset/hyperlight-device-plugin \
        -n hyperlight-system --timeout=5m
    log_info "Installing the delegated runtime on KVM nodes"
    apply_runtime
    wait_for_runtime
    status
    log_success "AKS delegated runtime is ready"
}

installer_pod_for_node() {
    local node=$1
    kubectl get pods -n hyperlight-node-system \
        -l app.kubernetes.io/name=hyperlight-runtime-installer \
        --field-selector "spec.nodeName=$node" \
        -o jsonpath='{.items[0].metadata.name}'
}

assert_runtime_cleanup() {
    local node=$1
    local pod
    pod=$(installer_pod_for_node "$node")
    [[ -n $pod ]] || fail "runtime installer pod not found on $node"
    kubectl exec -n hyperlight-node-system "$pod" -- bash -c '
        shopt -s nullglob
        state=(/host-runtime-state/*.cgroup)
        ((${#state[@]} == 0)) || {
            printf "runtime state remains:\n" >&2
            printf "  %s\n" "${state[@]}" >&2
            exit 1
        }
        if find /host-cgroup -type d -name hyperlight-provider -print -quit |
            grep -q .; then
            echo "delegated provider cgroup remains" >&2
            exit 1
        fi
    '
}

wait_for_job() {
    local namespace=$1
    local name=$2
    local complete failed
    for _ in {1..120}; do
        complete=$(kubectl get job "$name" -n "$namespace" \
            -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')
        [[ $complete == True ]] && return
        failed=$(kubectl get job "$name" -n "$namespace" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')
        if [[ $failed == True ]]; then
            kubectl logs -n "$namespace" "job/$name" --all-containers || true
            return 1
        fi
        sleep 5
    done
    fail "timed out waiting for job/$name"
}

smoke() {
    require envsubst
    check_cluster
    kubectl get runtimeclass hyperlight-delegated >/dev/null ||
        fail "runtime is not deployed"
    kubectl delete job hyperlight-nested-demo -n hyperlight-system \
        --ignore-not-found --wait=true
    export DEMO_IMAGE=$demo_image
    envsubst '${DEMO_IMAGE}' <"$project_root/deploy/azure/nested-job.yaml" |
        kubectl apply -f -
    wait_for_job hyperlight-system hyperlight-nested-demo ||
        {
            kubectl describe job -n hyperlight-system hyperlight-nested-demo
            kubectl logs -n hyperlight-system job/hyperlight-nested-demo --all-containers
            exit 1
        }
    local node
    node=$(kubectl get pod -n hyperlight-system \
        -l job-name=hyperlight-nested-demo \
        -o jsonpath='{.items[0].spec.nodeName}')
    kubectl logs -n hyperlight-system job/hyperlight-nested-demo
    kubectl delete job hyperlight-nested-demo -n hyperlight-system --wait=true
    for _ in {1..60}; do
        if assert_runtime_cleanup "$node" 2>/dev/null; then
            log_success "pod and delegated cgroups were cleaned up"
            return
        fi
        sleep 1
    done
    assert_runtime_cleanup "$node"
}

demo() {
    check_cluster
    bash "$project_root/scripts/aks-nested-demo.sh" "$@"
}

status() {
    check_cluster
    echo
    log_info "KVM nodes and delegated runtime readiness"
    kubectl get nodes \
        -l hyperlight.dev/enabled=true,hyperlight.dev/hypervisor=kvm \
        -o custom-columns='NAME:.metadata.name,RUNTIME:.metadata.labels.hyperlight\.dev/runtime,HYPERVISOR:.metadata.labels.hyperlight\.dev/hypervisor,CAPACITY:.status.allocatable.hyperlight\.dev/hypervisor'
    echo
    log_info "Node runtime installer"
    kubectl get daemonset,pods -n hyperlight-node-system \
        -l app.kubernetes.io/name=hyperlight-runtime-installer -o wide
    echo
    log_info "Device plugin"
    kubectl get daemonset,pods -n hyperlight-system \
        -l app.kubernetes.io/name=hyperlight-device-plugin -o wide
    echo
    kubectl get runtimeclass hyperlight-delegated
}

undeploy() {
    check_cluster
    kubectl delete job hyperlight-nested-demo -n hyperlight-system \
        --ignore-not-found --wait=true
    local delegated_pods
    delegated_pods=$(kubectl get pods --all-namespaces \
        -o jsonpath='{range .items[?(@.spec.runtimeClassName=="hyperlight-delegated")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
    [[ -z $delegated_pods ]] ||
        fail "pods still use hyperlight-delegated; delete them first: $delegated_pods"
    kubectl delete runtimeclass hyperlight-delegated --ignore-not-found
    local pod
    while read -r pod; do
        [[ -n $pod ]] || continue
        log_info "Restoring containerd on installer pod $pod"
        kubectl exec -n hyperlight-node-system "$pod" -- \
            /usr/local/sbin/install-hyperlight-runtime uninstall
    done < <(
        kubectl get pods -n hyperlight-node-system \
            -l app.kubernetes.io/name=hyperlight-runtime-installer \
            -o name
    )
    if kubectl get nodes -l hyperlight.dev/runtime=delegated \
        --no-headers | grep -q .; then
        fail "one or more nodes still have the delegated-runtime readiness label"
    fi
    kubectl delete daemonset hyperlight-runtime-installer \
        -n hyperlight-node-system --ignore-not-found --wait=true
    kubectl delete clusterrolebinding hyperlight-runtime-installer --ignore-not-found
    kubectl delete clusterrole hyperlight-runtime-installer --ignore-not-found
    kubectl delete serviceaccount hyperlight-runtime-installer \
        -n hyperlight-node-system --ignore-not-found
    kubectl delete namespace hyperlight-node-system --ignore-not-found --wait=true
    kubectl delete daemonset hyperlight-device-plugin \
        -n hyperlight-system --ignore-not-found --wait=true
    log_success "AKS Hyperlight runtime and device plugin removed"
}

cluster_delete() {
    require az
    if az aks show -g "$resource_group" -n "$cluster_name" >/dev/null 2>&1; then
        connect_cluster
        undeploy
    else
        log_warning "AKS cluster does not exist; skipping in-cluster runtime removal"
    fi
    "$project_root/deploy/azure/teardown.sh" --all "$@"
}

test_local() {
    require go
    require docker
    require envsubst
    require kubectl
    (
        cd "$project_root/deploy/azure/runtime-installer"
        gofmt -w main.go main_test.go
        go test ./...
        go vet ./...
    )
    docker build \
        -f "$project_root/deploy/azure/runtime-installer/Dockerfile" \
        -t "$installer_local" \
        "$project_root"
    export RUNTIME_INSTALLER_IMAGE=example.invalid/hyperlight-runtime-installer:test
    export DEMO_IMAGE=example.invalid/hyperlight-nested-demo:test
    envsubst '${RUNTIME_INSTALLER_IMAGE}' \
        <"$project_root/deploy/azure/runtime-installer.yaml" |
        kubectl create --dry-run=client --validate=false -f - >/dev/null
    envsubst '${DEMO_IMAGE}' <"$project_root/deploy/azure/nested-job.yaml" |
        kubectl create --dry-run=client --validate=false -f - >/dev/null
    bash -n "$project_root/deploy/azure/runtime-installer/install-runtime.sh"
    bash -n "$project_root/deploy/azure/teardown.sh"
    bash -n "$project_root/scripts/aks-nested.sh"
    bash -n "$project_root/scripts/aks-nested-demo.sh"
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -e SC1091,SC2016 \
            "$project_root/deploy/azure/setup.sh" \
            "$project_root/deploy/azure/teardown.sh" \
            "$project_root/deploy/azure/runtime-installer/install-runtime.sh" \
            "$project_root/scripts/aks-nested.sh" \
            "$project_root/scripts/aks-nested-demo.sh"
    fi
    log_success "AKS runtime assets validated locally"
}

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
  cluster-create  Create a minimal KVM-only AKS cluster and ACR
  connect         Configure kubectl for the AKS cluster
  build      Build the device plugin, nested demo, and runtime installer images
  publish    Push all three images to ACR
  deploy     Deploy the device plugin, node runtime installer, and RuntimeClass
  setup      Connect, build, publish, and deploy to an existing cluster
  smoke      Run the workload without the paced presentation
  demo       Run the paced AKS presentation; accepts --noninteractive
  status     Show KVM nodes, runtime readiness, and plugin status
  undeploy   Remove AKS Hyperlight workloads and restore containerd configuration
  cluster-delete  Undeploy and delete the resource group; accepts --yes --wait
  test       Validate runtime code, image, scripts, and manifests locally

Environment:
  ACR_NAME       Azure Container Registry name (default: hyperlightacr)
  AKS_IMAGE_TAG  Tag used for all AKS images (default: aks-nested)
  REGISTRY       Registry hostname (default: \${ACR_NAME}.azurecr.io)
  DEVICE_COUNT   Hypervisor allocation slots per node (default: 32)
EOF
}

case "${1:-}" in
    cluster-create)
        cluster_create
        ;;
    connect)
        connect_cluster
        ;;
    build)
        build_images
        ;;
    publish)
        publish_images
        ;;
    deploy)
        deploy
        ;;
    setup)
        connect_cluster
        build_images
        publish_images
        deploy
        ;;
    demo)
        shift
        demo "$@"
        ;;
    smoke)
        smoke
        ;;
    status)
        status
        ;;
    undeploy)
        undeploy
        ;;
    cluster-delete)
        shift
        cluster_delete "$@"
        ;;
    test)
        test_local
        ;;
    -h | --help | help | "")
        usage
        ;;
    *)
        fail "unknown command: $1"
        ;;
esac
