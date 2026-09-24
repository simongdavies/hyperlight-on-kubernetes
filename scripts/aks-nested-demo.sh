#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
namespace=hyperlight-system
cluster_name=${CLUSTER_NAME:-hyperlight-cluster}
resource_group=${RESOURCE_GROUP:-hyperlight-rg}
acr_name=${ACR_NAME:-hyperlightacr}
image_tag=${AKS_IMAGE_TAG:-aks-nested}
demo_image=${REGISTRY:-$acr_name.azurecr.io}/hyperlight-nested-demo:$image_tag
noninteractive=0
color=0
demo_log=

if [[ -t 1 && -z ${NO_COLOR-} && ${TERM-} != dumb ]]; then
    color=1
fi

if [[ ${1:-} == --noninteractive ]]; then
    noninteractive=1
    shift
fi
[[ $# == 0 ]] || {
    echo "usage: $0 [--noninteractive]" >&2
    exit 2
}

style() {
    local code=$1
    shift
    if ((color)); then
        printf '\033[%sm%s\033[0m' "$code" "$*"
    else
        printf '%s' "$*"
    fi
}

pause() {
    ((noninteractive)) && return
    [[ -t 0 && -t 1 ]] || {
        echo "interactive demo requires a terminal; use --noninteractive" >&2
        exit 1
    }
    read -r -p "Press Enter to continue... " _
}

section() {
    printf '\n\n'
    style '1;36' '================================================================'
    printf '\n'
    style '1;36' "$1"
    printf '\n'
    style '1;36' '================================================================'
    printf '\n'
    style '1;33' '[EXPLANATION] '
    if ((color)); then
        printf '\033[33m%b\033[0m' "$2"
    else
        printf '%b' "$2"
    fi
    printf '\n'
    pause
}

run() {
    local rendered=
    printf -v rendered ' %q' "$@"
    printf '\n'
    style '1;35' '[COMMAND]'
    style '35' " \$$rendered"
    printf '\n'
    style '1;37' '[OUTPUT]'
    printf '\n'
    "$@"
}

run_shell() {
    local command=$1
    printf '\n'
    style '1;35' '[COMMAND]'
    style '35' " \$ $command"
    printf '\n'
    style '1;37' '[OUTPUT]'
    printf '\n'
    eval "$command"
}

run_as() {
    local display=$1
    shift
    printf '\n'
    style '1;35' '[COMMAND]'
    style '35' " \$ $display"
    printf '\n'
    style '1;37' '[OUTPUT]'
    printf '\n'
    "$@"
}

wait_for_job() {
    local complete failed
    for _ in {1..120}; do
        complete=$(kubectl get job hyperlight-nested-demo -n "$namespace" \
            -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')
        [[ $complete == True ]] && return
        failed=$(kubectl get job hyperlight-nested-demo -n "$namespace" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')
        if [[ $failed == True ]]; then
            kubectl logs -n "$namespace" job/hyperlight-nested-demo \
                --all-containers || true
            return 1
        fi
        sleep 5
    done
    echo "timed out waiting for job/hyperlight-nested-demo" >&2
    return 1
}

show_nested_result() {
    awk '
        /^Hyperlight nested sandbox demo$/ {
            seen++
            if (seen == 1) show=1
        }
        show && /PASS inner guest image supplied as a read-only file capability/ {
            print "Security checks"
            print "  Inner guest input"
            print "    Action: the controller opened the inner guest binary and transferred the worker a read-only file descriptor."
            print "    Observed: the worker read the guest bytes from that descriptor and started the inner VM."
            print "    Meaning: the worker received one approved open file, not a replaceable path or broad filesystem access."
            next
        }
        show && /PASS result exported as a read-only file capability/ {
            print ""
            print "  Result return"
            print "    Action: the worker wrote the result to an anonymous in-memory file and exported a read-only descriptor."
            print "    Observed: the controller verified that resource matched the function return."
            print "    Meaning: one bounded result crossed the boundary without a shared writable directory."
            next
        }
        show && /PASS undeclared child-process creation denied/ {
            print ""
            print "  Child-process denial"
            print "    Action: the worker tried to launch another executable directly and from a thread."
            print "    Observed: both attempts failed with EPERM."
            print "    Meaning: the worker can host the inner VM in-process but cannot create undeclared OS processes."
            next
        }
        show && /PASS guest, marker and result bound to generation/ {
            generation=$NF
            print ""
            print "  Current-worker resource ownership"
            print "    Observed: guest input, recovery record and result all belong to worker generation " generation "."
            print "    Meaning: a replacement worker cannot accept stale resources from a prior generation."
            next
        }
        show { print }
        /Press Enter to stop the nested topology/ {
            if (show) exit
        }
    ' "$demo_log"
}

cleanup() {
    [[ -z ${demo_log:-} ]] || rm -f "$demo_log"
}
trap cleanup EXIT

kubectl config use-context "$cluster_name" >/dev/null

section "1. Confirm the Azure and kubectl target" \
    "The demo uses the current Azure subscription, resource group $resource_group, AKS cluster $cluster_name and ACR $acr_name. These commands make both the cloud and Kubernetes targets explicit before changing a workload."
run az account show --query '{subscription:name,id:id,user:user.name}' -o table
run kubectl config current-context
run kubectl cluster-info

section "2. Show the AKS node-pool boundary" \
    "The system pool runs Kubernetes services. The separate Ubuntu KVM pool uses a nested-virtualization-capable VM size and is labelled for Hyperlight. Only that user pool receives the node installer, /dev/kvm Device Plugin and delegated RuntimeClass workloads."
run az aks nodepool list -g "$resource_group" --cluster-name "$cluster_name" \
    --query '[].{name:name,mode:mode,os:osSKU,size:vmSize,count:count,min:minCount,max:maxCount,state:provisioningState}' -o table
run kubectl get nodes -L agentpool,hyperlight.dev/hypervisor,hyperlight.dev/runtime -o wide

section "3. Confirm KVM/CDI allocation" \
    "The existing Device Plugin sees /dev/kvm on the KVM node and advertises configurable hyperlight.dev/hypervisor allocation slots. A slot is scheduling capacity for the shared KVM device, not another physical KVM device. CDI injects /dev/kvm only into containers that request one slot."
run kubectl get daemonset,pods -n "$namespace" \
    -l app.kubernetes.io/name=hyperlight-device-plugin -o wide
run_shell "kubectl logs -n $namespace daemonset/hyperlight-device-plugin --tail=30 | grep -E 'Detected hypervisor|CDI spec written|Advertising|Registered with kubelet'"
run kubectl get nodes -l hyperlight.dev/hypervisor=kvm \
    -o custom-columns='NAME:.metadata.name,KVM:.metadata.labels.hyperlight\.dev/hypervisor,ALLOCATABLE:.status.allocatable.hyperlight\.dev/hypervisor'

section "4. Show the narrow privileged node integration" \
    "AKS owns containerd and does not provide KIND-style containerdConfigPatches. A privileged DaemonSet performs one node-admin task on KVM nodes: install the static wrapper/hook and seccomp profile, add the hyperlight-delegated handler, validate containerd, restart it only after a change, and label the node ready. Application pods do not inherit this privilege."
run kubectl get daemonset,pods -n hyperlight-node-system \
    -l app.kubernetes.io/name=hyperlight-runtime-installer -o wide
run_shell "kubectl logs -n hyperlight-node-system daemonset/hyperlight-runtime-installer --tail=30"
run kubectl get nodes -l hyperlight.dev/hypervisor=kvm \
    -o custom-columns='NAME:.metadata.name,RUNTIME:.metadata.labels.hyperlight\.dev/runtime'

section "5. RuntimeClass is the explicit opt-in" \
    "runtimeClassName: hyperlight-delegated selects only nodes whose installer completed. Ordinary pods continue to use AKS's normal runc path. The wrapper requires a non-root OCI user and a private cgroup namespace before it makes the pod's namespaced cgroup mount writable."
run kubectl get runtimeclass hyperlight-delegated -o yaml

section "6. Inspect the unprivileged workload" \
    "This Job requests one KVM allocation and opts into the delegated runtime. It runs as UID/GID 1000, drops every Linux capability, disables privilege escalation and service-account tokens, uses strict supplementary-group handling, and has a 1 CPU / 512 MiB outer ceiling."
export DEMO_IMAGE="$demo_image"
run_as "envsubst '\${DEMO_IMAGE}' < deploy/azure/nested-job.yaml" \
    bash -c 'envsubst '"'"'${DEMO_IMAGE}'"'"' < "$1"' _ "$root/deploy/azure/nested-job.yaml"

section "7. Create the AKS Job" \
    "Any previous run is removed first. Kubernetes then schedules this execution onto a KVM node that has both the CDI device resource and delegated-runtime readiness label."
run kubectl delete job hyperlight-nested-demo -n "$namespace" \
    --ignore-not-found --cascade=foreground --wait=true
run_shell "envsubst '\${DEMO_IMAGE}' < '$root/deploy/azure/nested-job.yaml' | kubectl apply -f -"
run kubectl get pods -n "$namespace" -l job-name=hyperlight-nested-demo -o wide
run_as "wait for job/hyperlight-nested-demo (stop immediately on failure)" \
    wait_for_job
demo_log=$(mktemp)
kubectl logs -n "$namespace" job/hyperlight-nested-demo >"$demo_log"
demo_node=$(kubectl get pod -n "$namespace" -l job-name=hyperlight-nested-demo \
    -o jsonpath='{.items[0].spec.nodeName}')

section "8. Confirm the container/runtime boundary" \
    "Before launching Hyperlight, the container reports its effective identity, KVM access, delegated cgroup tree, Minijail and Landlock prerequisites. This is application-container evidence, not guest output."
run_as "kubectl logs -n $namespace job/hyperlight-nested-demo | sed -n '1,/Starting the nested Hyperlight application/p'" \
    sed -n '1,/Starting the nested Hyperlight application/p' "$demo_log"

section "9. Run the nested Hyperlight call" \
    "The outer guest calls a host function in a separate Minijail-confined worker. That worker starts the inner Hyperlight guest in-process, handles two callbacks, and returns the composed value. The translated checks explain the explicit file-descriptor capabilities, child-process denial and generation binding."
run_as "kubectl logs -n $namespace job/hyperlight-nested-demo  # nested application result" \
    show_nested_result

section "10. Verify application-level cleanup" \
    "The application shuts down the inner VM and worker, then verifies no worker process or populated worker cgroup remains before exiting successfully."
run_as "kubectl logs -n $namespace job/hyperlight-nested-demo  # cleanup section" \
    awk '/PASS nested worker and inner sandbox stopped cleanly/{show=1} show{print}' "$demo_log"

section "11. Delete the pod and verify node-runtime cleanup" \
    "Deleting the Job drives kubelet, containerd and the wrapper's delete path. The check runs in the node-installer pod on the exact node that hosted this Job and fails if a runtime-state file or delegated provider cgroup remains."
run kubectl delete job hyperlight-nested-demo -n "$namespace" --wait=true
installer_pod=$(kubectl get pods -n hyperlight-node-system \
    -l app.kubernetes.io/name=hyperlight-runtime-installer \
    --field-selector "spec.nodeName=$demo_node" \
    -o jsonpath='{.items[0].metadata.name}')
run_as "kubectl exec node-installer on $demo_node -- check-runtime-residue" \
    kubectl exec -n hyperlight-node-system "$installer_pod" -- bash -ceu '
        shopt -s nullglob
        state=(/host-runtime-state/*.cgroup)
        ((${#state[@]} == 0)) || {
            printf "Unexpected runtime state:\n" >&2
            printf "  %s\n" "${state[@]}" >&2
            exit 1
        }
        if find /host-cgroup -type d -name hyperlight-provider -print -quit |
            grep -q .; then
            echo "Unexpected delegated provider cgroup remains." >&2
            exit 1
        fi
        echo "No runtime-state files or delegated provider cgroups remain."
    '

section "12. Cluster cleanup command" \
    "The workload is gone but the reusable AKS integration is still installed. Run the command below when finished. It refuses removal while delegated pods exist, restores containerd on every KVM node, removes Kubernetes components, then deletes the entire resource group including AKS and ACR. Add --wait to block until Azure confirms deletion."
printf '\n'
style '1;35' '[COMMAND]'
style '35' " \$ bash ./scripts/aks-nested.sh cluster-delete --yes --wait"
printf '\n'

echo
echo "PASS the AKS RuntimeClass demo completed and left no pod, runtime-state file, or delegated cgroup residue."
