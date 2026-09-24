#!/bin/bash
set -euo pipefail

cgroup_mount=/sys/fs/cgroup
cgroup_relative=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)
[[ -n $cgroup_relative && $cgroup_relative != / ]] || {
    echo "FAIL the runtime did not place the container below a Kubernetes cgroup" >&2
    exit 1
}
cgroup_root=$cgroup_mount$cgroup_relative
supervisor_group=$cgroup_root/hyperlight-supervisor
application_group=$cgroup_root/hyperlight-application
provider_group=$cgroup_root/hyperlight-provider
helper=/usr/libexec/hyperlight/minijail0
helper_digest=d16432b3f6fcf1b0859f36dae50440863e6bff441b67eab688b02275d5e951b6
demo_log=/tmp/hyperlight-nested-demo.log
demo_input=/tmp/hyperlight-nested-demo.input
pace_seconds=${DEMO_PACE_SECONDS:-0}

fail() {
    echo "FAIL $*" >&2
    exit 1
}

explain() {
    printf '\n%s\n' "$*"
    if [[ $pace_seconds =~ ^[0-9]+$ ]] && ((pace_seconds > 0)); then
        sleep "$pace_seconds"
    fi
}

read_populated() {
    local path=$1
    awk '$1 == "populated" { print $2 }' "$path/cgroup.events"
}

kill_group() {
    local path=$1
    if [[ -e $path/cgroup.kill ]]; then
        printf 1 >"$path/cgroup.kill" 2>/dev/null || true
    fi
}

cleanup() {
    local status=${1:-$?}
    trap - EXIT INT TERM
    exec 3>&- 2>/dev/null || true
    kill_group "$provider_group"
    kill_group "$application_group"
    for _ in {1..100}; do
        [[ ! -d $provider_group || $(read_populated "$provider_group") == 0 ]] &&
            [[ ! -d $application_group || $(read_populated "$application_group") == 0 ]] &&
            break
        sleep 0.05
    done
    find "$provider_group" -depth -type d -exec rmdir {} + 2>/dev/null || true
    rmdir "$application_group" 2>/dev/null || true
    rm -f "$demo_input"
    exit "$status"
}

prepare() {
    [[ $(stat -fc %T "$cgroup_mount") == cgroup2fs ]] ||
        fail "unified cgroup v2 is required"
    [[ -w $cgroup_root/cgroup.procs ]] ||
        fail "the KIND demo requires a writable Kubernetes container cgroup"
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] ||
        fail "/dev/kvm was not injected read-write"
    [[ -x $helper ]] || fail "the strict Minijail helper is missing"
    echo "$helper_digest  $helper" | sha256sum -c - >/dev/null ||
        fail "the strict Minijail helper digest is invalid"

    local abi
    abi=$(python3 -c 'import ctypes; print(ctypes.CDLL(None, use_errno=True).syscall(444, 0, 0, 1))')
    [[ $abi =~ ^[0-9]+$ ]] && ((abi >= 5)) ||
        fail "Landlock ABI 5 or newer is required (found $abi)"

    for stale in "$provider_group" "$application_group" "$supervisor_group"; do
        if [[ -d $stale ]]; then
            [[ $(read_populated "$stale") == 0 ]] ||
                fail "stale cgroup remains populated: $stale"
            rmdir "$stale" || fail "stale cgroup could not be removed: $stale"
        fi
    done
    mkdir "$supervisor_group" "$application_group" "$provider_group"
    printf '%s\n' "$$" >"$supervisor_group/cgroup.procs"
    printf '%s\n' '+cpu +memory +pids' >"$cgroup_root/cgroup.subtree_control" ||
        fail "cpu, memory and pids are not delegated by the KIND runtime"
    printf '%s\n' '+cpu +memory +pids' >"$provider_group/cgroup.subtree_control" ||
        fail "provider child controllers could not be enabled"
    [[ -e $provider_group/cgroup.kill ]] ||
        fail "cgroup.kill is required for bounded cleanup"

    chown 1000:1000 \
        "$cgroup_root/cgroup.procs" \
        "$application_group" \
        "$application_group/cgroup.procs" \
        "$provider_group" \
        "$provider_group/cgroup.procs" \
        "$provider_group/cgroup.subtree_control"

    export HYPERLIGHT_MESH_PROCESS_CGROUP_ROOT=$provider_group
    export HYPERLIGHT_MESH_PROCESS_MINIJAIL=$helper
    export HYPERLIGHT_MESH_PROCESS_MINIJAIL_SHA256=$helper_digest
}

start_demo() {
    rm -f "$demo_log" "$demo_input"
    mkfifo -m 0600 "$demo_input"
    exec 3<>"$demo_input"
    (
        printf '%s\n' "$BASHPID" >"$application_group/cgroup.procs"
        exec setpriv \
            --reuid=1000 \
            --regid=1000 \
            --init-groups \
            --inh-caps=-all \
            --ambient-caps=-all \
            --bounding-set=-all \
            script -qefc \
            "/opt/hyperlight/nested_sandbox demo /opt/hyperlight/simpleguest" \
            /dev/null <&3
    ) >"$demo_log" 2>&1 &
    demo_pid=$!

    for _ in {1..300}; do
        if grep -q "Press Enter to stop the nested topology" "$demo_log" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$demo_pid" 2>/dev/null; then
            cat "$demo_log" >&2 || true
            wait "$demo_pid" || true
            fail "the nested demo exited before its inspection pause"
        fi
        sleep 0.1
    done
    cat "$demo_log" >&2 || true
    fail "the nested demo did not reach its inspection pause"
}

run_demo() {
    prepare
    trap 'cleanup $?' EXIT
    trap 'cleanup 130' INT
    trap 'cleanup 143' TERM

    explain "This pod is a privileged local KIND harness. Hyperlight itself runs as UID 1000."
    echo "Host kernel: $(uname -r)"
    echo "Container cgroup: $cgroup_relative"
    echo "Cgroup: $(stat -fc %T "$cgroup_mount") with controllers $(cat "$cgroup_root/cgroup.controllers")"
    echo "Landlock ABI: $(python3 -c 'import ctypes; print(ctypes.CDLL(None).syscall(444, 0, 0, 1))')"
    echo "KVM device: $(stat -c '%A %U:%G %t:%T' /dev/kvm)"
    echo "Minijail SHA-256: $(sha256sum "$helper" | awk '{print $1}')"

    explain "Starting the outer guest and pausing while its confined host-function worker is alive."
    start_demo
    cat "$demo_log"

    explain "Observed Linux process topology inside the pod:"
    ps -eo pid,ppid,user,comm,args --forest
    echo
    echo "The nested_sandbox fixture verifies that inner-sandbox-host equals the worker PID."
    echo "No additional Linux process is created for the inner Hyperlight sandbox."
    echo "Minijail is the supervisor for the separate confined host-function process."

    explain "Observed cgroup ownership domains:"
    find "$cgroup_root" -maxdepth 3 -type d -name 'hyperlight-*' -o -path "$provider_group/*" |
        sort
    while IFS= read -r process; do
        [[ -n $process ]] || continue
        printf '  pid=%s cgroup=%s\n' "$process" \
            "$(awk -F: '$1 == "0" { print $3 }' "/proc/$process/cgroup" 2>/dev/null || echo gone)"
    done < <(pgrep -f 'nested_sandbox|/program|minijail0' || true)

    explain "Allowing the fixture to shut down the worker and inner sandbox."
    printf '\n' >&3
    wait "$demo_pid"
    exec 3>&-
    cat "$demo_log"

    explain "Cleanup evidence:"
    echo "Provider populated=$(read_populated "$provider_group")"
    echo "Application populated=$(read_populated "$application_group")"
    if pgrep -f '/program|nested_sandbox demo|minijail0' >/tmp/residue; then
        cat /tmp/residue
        fail "a nested demo process remained"
    fi
    echo "PASS no nested_sandbox, Minijail, or confined /program process remains"
    echo "PASS provider cgroup is empty"
    echo "PASS nested Hyperlight KIND demonstration"
}

case "${1:-demo}" in
    demo)
        run_demo
        ;;
    *)
        fail "unknown command: $1"
        ;;
esac
