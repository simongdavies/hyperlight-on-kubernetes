#!/bin/bash
set -euo pipefail

cluster_name=hyperlight-nested
namespace=hyperlight-system
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
noninteractive=0
color=0
demo_log=

if [[ -t 1 && -z ${NO_COLOR-} && ${TERM-} != dumb ]]; then
    color=1
fi

style() {
    local code=$1
    shift
    if ((color)); then
        printf '\033[%sm%s\033[0m' "$code" "$*"
    else
        printf '%s' "$*"
    fi
}

if [[ ${1:-} == --noninteractive ]]; then
    noninteractive=1
    shift
fi
[[ $# == 0 ]] || {
    echo "usage: $0 [--noninteractive]" >&2
    exit 2
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

show_file() {
    local path=$1
    run nl -ba "$path"
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
            print "    Meaning: the worker received one approved open file, not a path it could replace or broader filesystem access."
            next
        }
        show && /PASS result exported as a read-only file capability/ {
            print ""
            print "  Result return"
            print "    Action: the worker wrote the result into an anonymous in-memory file and exported a read-only descriptor to it."
            print "    Observed: the controller read that descriptor and verified its contents matched the function return value."
            print "    Meaning: the worker returned one bounded result resource without gaining access to a shared directory."
            next
        }
        show && /PASS undeclared child-process creation denied/ {
            print ""
            print "  Child-process denial"
            print "    Action: the worker tried to launch another copy of the executable, directly and from a thread."
            print "    Observed: both attempts failed with EPERM."
            print "    Meaning: the worker could run the inner VM in-process but could not create an undeclared OS process."
            next
        }
        show && /PASS guest, marker and result bound to generation/ {
            generation=$NF
            print ""
            print "  Current-worker resource ownership"
            print "    Action: the controller compared the worker-generation IDs attached to the guest input, recovery record and returned result."
            print "    Observed: all three belong to the current worker instance, generation " generation "."
            print "    Meaning: after a worker crash or restart, an old descriptor cannot be mistaken for a resource from its replacement."
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

kubectl config use-context "kind-$cluster_name" >/dev/null

section "1. Give the KIND node access to KVM" \
    "This demo has one Kubernetes node. KIND names it hyperlight-nested-control-plane because the same node runs Kubernetes control-plane services and our workload. WSL has one /dev/kvm device. The Device Plugin detects that device and publishes 32 configurable scheduling slots called hyperlight.dev/hypervisor; 32 means 'up to 32 demo allocations', not 32 physical KVM devices. A pod requesting one slot is scheduled only onto this KVM-capable node, and CDI exposes /dev/kvm inside that pod."
run kubectl get nodes \
    -o custom-columns='NAME:.metadata.name,READY:.status.conditions[-1].status,KVM-LABEL:.metadata.labels.hyperlight\.dev/hypervisor,HYPERLIGHT-DEVICES:.status.allocatable.hyperlight\.dev/hypervisor'
run kubectl get daemonset,pods -n "$namespace" \
    -l app.kubernetes.io/name=hyperlight-device-plugin -o wide
run_shell "kubectl logs -n $namespace daemonset/hyperlight-device-plugin --tail=20 | grep -E 'Detected hypervisor|CDI spec written|Advertising|Registered with kubelet'"

section "2. Add a Hyperlight runtime option to the node" \
    "The KIND configuration creates that one node and passes in four things it needs: WSL's /dev/kvm device, the runtime wrapper, the cgroup setup hook, and the launcher seccomp profile. containerd keeps its normal runc runtime for ordinary pods and adds a second option named hyperlight-delegated. CDI is enabled so the Device Plugin can inject /dev/kvm. SystemdCgroup=true makes runc use the exact cgroup path already created by kubelet/containerd; without it, the hook could prepare the wrong cgroup tree."
printf '\n'
style '1;35' '[COMMAND]'
style '35' " \$ sed \"s|\\\${NATIVE_ROOT}|$root|g\" $root/deploy/kind-nested/kind-config.yaml"
printf '\n'
style '1;37' '[OUTPUT]'
printf '\n'
sed "s|\${NATIVE_ROOT}|$root|g" "$root/deploy/kind-nested/kind-config.yaml"

section "3. The runc wrapper" \
    "This script sits immediately in front of the real runc. On container creation it makes the container's cgroup mount writable and tells runc to call the setup hook shown next. The container has a cgroup namespace: Linux presents its Kubernetes-assigned cgroup as /sys/fs/cgroup, hiding all parent, sibling-pod, and node cgroups above it. Writable therefore means writable only inside this container-owned view, subject to the file ownership set by the hook. On deletion the wrapper kills any leftover worker processes and removes the worker cgroups. The hook performs setup; the wrapper performs cleanup."
show_file "$root/deploy/kind-nested/hyperlight-runc"

section "4. The delegated-cgroup hook" \
    "Kubernetes gives the container one cgroup with the pod's 1 CPU and 512 MiB limits. Hyperlight needs child cgroups so each worker can have a smaller independent budget. cgroup v2 will not enable CPU, memory, and PID controls for children while the application is sitting directly in the parent. Before the application starts, this hook moves PID 1 into an application child and creates a separate hyperlight-provider child:\n\n  Kubernetes container cgroup: max 1 CPU / 512 MiB\n  |-- application            <- the app and outer VM\n  +-- hyperlight-provider    <- empty authority for worker cgroups\n      +-- hyperlight-<id>    <- one worker and its ProcessProfile limits\n\nThe hook gives UID 1000 access to the provider files used to create and manage worker children, plus the namespace-root enrollment file Linux requires when moving a process between these sibling cgroups. The application can rearrange only its own processes inside this namespaced tree; it cannot see or modify anything above the Kubernetes container cgroup. All children still share and cannot exceed the pod's outer limit."
show_file "$root/deploy/kind-nested/hyperlight-cgroup-hook"

section "5. RuntimeClass selection" \
    "RuntimeClass is the workload's explicit opt-in. runtimeClassName: hyperlight-delegated tells containerd to use the wrapper above. Pods that omit it continue through normal runc and do not receive worker-cgroup authority."
show_file "$root/deploy/kind-nested/runtime-class.yaml"
run kubectl get runtimeclass hyperlight-delegated -o wide

section "6. The unprivileged demo Job" \
    "This is the exact Job Kubernetes will run. The application starts an outer Hyperlight guest, handles its host-function call in a separate confined worker, and starts an inner Hyperlight guest inside that worker. Kubernetes supplies the pod lifecycle and delegated cgroup. The Job selects the delegated runtime, requests one KVM slot, runs as UID/GID 1000, rejects image-defined supplementary groups, disables setuid-style privilege escalation, and drops every Linux capability. The tiny 10m CPU and 64 MiB requests reserve enough scheduling capacity for the demo without pretending it needs a large service allocation. The 1 CPU and 512 MiB limits are safety ceilings for the application plus outer and inner VM memory. Each worker can receive a tighter ProcessProfile, but no worker can exceed the pod ceiling."
printf '\n'
style '1;35' '[COMMAND]'
style '35' " \$ sed \"s/\\\${DEMO_PACE_SECONDS}/1/\" $root/deploy/kind-nested/job.yaml"
printf '\n'
style '1;37' '[OUTPUT]'
printf '\n'
sed 's/${DEMO_PACE_SECONDS}/1/' "$root/deploy/kind-nested/job.yaml"

section "7. The launcher seccomp profile" \
    "The standard Kubernetes profile blocks operations Minijail needs to build the worker sandbox, so this pod uses a small named profile for the application and launcher. It allows the namespace, mount, and session-keyring setup Minijail requires but continues to block unrelated high-risk operations such as module loading, BPF, tracing, and cross-process memory access. That outer profile remains active. Before the worker program starts, Minijail adds its stricter worker-specific filter and Landlock filesystem policy."
show_file "$root/deploy/kind-nested/hyperlight-launcher-seccomp.json"

section "8. Deploy the scenario" \
    "Remove any prior run so the evidence belongs to this execution, apply the rendered Job, show where Kubernetes scheduled it, and wait for the Job controller to observe a successful exit. A failed prerequisite produces a failed Job rather than a success-shaped fallback."
run kubectl delete job hyperlight-nested-demo -n "$namespace" \
    --ignore-not-found --cascade=foreground --wait=true
run_shell "sed 's/\${DEMO_PACE_SECONDS}/1/' '$root/deploy/kind-nested/job.yaml' | kubectl apply -f -"
demo_pod=$(kubectl get pod -n "$namespace" \
    -l job-name=hyperlight-nested-demo \
    -o jsonpath='{.items[0].metadata.name}')
run kubectl get pod -n "$namespace" -l job-name=hyperlight-nested-demo -o wide
run kubectl wait --for=condition=complete job/hyperlight-nested-demo \
    -n "$namespace" --timeout=300s
demo_log=$(mktemp)
kubectl logs -n "$namespace" job/hyperlight-nested-demo >"$demo_log"

section "9. Confirm what Kubernetes gave the container" \
    "The container entrypoint prints this short checklist before launching the Hyperlight application. It confirms three boundaries: the pod is an unprivileged UID 1000 process, the RuntimeClass supplied only the application and worker cgroup subtrees, and the worker's Landlock, KVM, and pinned Minijail prerequisites are ready. This is container/runtime evidence, not guest output."
run_as "kubectl logs -n $namespace job/hyperlight-nested-demo | sed -n '1,/Starting the nested Hyperlight application/p'" \
    sed -n '1,/Starting the nested Hyperlight application/p' "$demo_log"

section "10. Run the nested function call" \
    "This section comes from the nested_sandbox application running inside the container. The application starts an outer Hyperlight guest. That guest asks the host to compose the value 'compose'. Hyperlight routes the host call to a separate Minijail-confined worker. Inside that same worker process, an inner Hyperlight guest runs one guest function and makes two host callbacks. The value then returns through the outer guest:\n\n  outer guest\n    +-- host call: NestedSandboxCompose(\"compose\")\n          +-- confined worker process\n                |-- inner guest function\n                |-- host callback -> process-host-function(compose)\n                +-- host callback -> process-host-function(compose)\n\n  returned value:\n    inner-guest-function(process-host-function(compose),process-host-function(compose))\n\nAfter the result, the application reports each security check as the action it performed, what the kernel/provider returned, and what that proves. Separate workers can have different ProcessProfile CPU, memory, and PID budgets. The inner VM itself is not another Linux process; it runs inside its worker."
run_as "kubectl logs -n $namespace job/hyperlight-nested-demo  # selected nested application result" \
    show_nested_result

section "11. Verify the result and worker cleanup" \
    "The returned string above proves the complete outer-guest -> worker -> inner-guest -> worker -> outer-guest call path. These final checks prove the guest image and result were passed as explicit read-only capabilities, the confined worker could not create an undeclared child process, and shutdown left no worker process or populated worker cgroup."
run_as "kubectl logs -n $namespace job/hyperlight-nested-demo  # result and cleanup section" \
    awk '/PASS nested worker and inner sandbox stopped cleanly/{show=1} show{print}' "$demo_log"

section "12. Delete the pod and prove node cleanup" \
    "Deleting the Job asks kubelet and containerd to delete the container. The wrapper's delete path kills anything left in the provider subtree, waits for it to empty, removes application/provider cgroups, and deletes its runtime-state file. The final commands fail the demo if any pod, runtime-state file, or delegated provider cgroup remains."
run kubectl delete job hyperlight-nested-demo -n "$namespace" --wait=true
run_as "kubectl get pods -n $namespace -l app.kubernetes.io/name=hyperlight-nested-demo  # expect none" \
    bash -c '
        pods=$(kubectl get pods -n "$1" \
            -l app.kubernetes.io/name=hyperlight-nested-demo \
            -o name)
        [[ -z $pods ]] || {
            printf "Unexpected remaining pods:\n%s\n" "$pods" >&2
            exit 1
        }
        echo "No demo pods remain."
    ' _ "$namespace"
run_as "docker exec $cluster_name-control-plane check-runtime-residue" \
    docker exec "$cluster_name-control-plane" sh -ceu '
        residue=$(
            find /run/hyperlight-runtime -maxdepth 1 -type f -print 2>/dev/null
            find /sys/fs/cgroup/kubelet.slice \
                -type d -name hyperlight-provider -print 2>/dev/null
        )
        if [ -n "$residue" ]; then
            printf "Unexpected runtime residue:\n%s\n" "$residue" >&2
            exit 1
        fi
        echo "No runtime-state files or delegated provider cgroups remain."
    '

echo
echo "PASS the unprivileged RuntimeClass demo completed and left no pod, runtime-state file, or delegated cgroup residue."
echo
echo "Why this is interesting:"
echo "  - Kubernetes schedules an ordinary unprivileged application pod."
echo "  - CDI grants only the KVM device capability."
echo "  - RuntimeClass grants only the delegated cgroup capability."
echo "  - Minijail confines a separate host-function process."
echo "  - The inner Hyperlight sandbox shares that worker process instead of adding another OS process."
echo
echo "Run 'bash ./scripts/kind-nested-wsl.sh reset' when you want to delete the KIND cluster."
