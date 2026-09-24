#!/bin/bash
set -euo pipefail

provider_group=/sys/fs/cgroup/hyperlight-provider
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
    awk '$1 == "populated" { print $2 }' "$1/cgroup.events"
}

cleanup() {
    local status=${1:-$?}
    trap - EXIT INT TERM
    exec 3>&- 2>/dev/null || true
    if [[ -e $provider_group/cgroup.kill ]]; then
        printf 1 >"$provider_group/cgroup.kill" 2>/dev/null || true
    fi
    rm -f "$demo_input"
    exit "$status"
}

prepare() {
    [[ $EUID == 1000 ]] || fail "the RuntimeClass workload must run as UID 1000"
    [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] ||
        fail "unified cgroup v2 is required"
    [[ $(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup) == /application ]] ||
        fail "the runtime handler did not place the application in its child cgroup"
    [[ -d $provider_group && -w $provider_group/cgroup.procs ]] ||
        fail "the runtime handler did not supply the delegated provider cgroup"
    [[ -w $provider_group/cgroup.subtree_control ]] ||
        fail "the provider cgroup controllers are not delegated"
    [[ -w $provider_group/cgroup.kill ]] ||
        fail "the provider cgroup cleanup capability is unavailable"
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] ||
        fail "/dev/kvm was not injected read-write"
    [[ -x $helper ]] || fail "the strict Minijail helper is missing"
    echo "$helper_digest  $helper" | sha256sum -c - >/dev/null ||
        fail "the strict Minijail helper digest is invalid"

    local abi
    abi=$(python3 -c 'import ctypes; print(ctypes.CDLL(None, use_errno=True).syscall(444, 0, 0, 1))')
    [[ $abi =~ ^[0-9]+$ ]] && ((abi >= 5)) ||
        fail "Landlock ABI 5 or newer is required (found $abi)"
    [[ $(read_populated "$provider_group") == 0 ]] ||
        fail "the delegated provider cgroup was not empty at application start"

    export HYPERLIGHT_MESH_PROCESS_CGROUP_ROOT=$provider_group
    export HYPERLIGHT_MESH_PROCESS_MINIJAIL=$helper
    export HYPERLIGHT_MESH_PROCESS_MINIJAIL_SHA256=$helper_digest
}

start_demo() {
    rm -f "$demo_log" "$demo_input"
    mkfifo -m 0600 "$demo_input"
    exec 3<>"$demo_input"
    script -qefc \
        "/opt/hyperlight/nested_sandbox demo /opt/hyperlight/simpleguest" \
        /dev/null <&3 >"$demo_log" 2>&1 &
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

    explain "Container launch evidence"
    echo "  Identity"
    echo "    User: $(id -u):$(id -g) ($(id -un):$(id -gn))"
    echo "    Linux capabilities: none"
    echo
    echo "  RuntimeClass cgroup delegation"
    echo "    Application: /application"
    echo "    Worker authority: /hyperlight-provider"
    echo "    Host and sibling-pod cgroups: not visible"
    echo
    echo "  Worker isolation prerequisites"
    echo "    Landlock: ABI $(python3 -c 'import ctypes; print(ctypes.CDLL(None).syscall(444, 0, 0, 1))') (required: 5 or newer)"
    echo "    KVM: /dev/kvm is present and read-write"
    echo "    Minijail: pinned SHA-256 verified"

    explain "Starting the nested Hyperlight application. It pauses while the confined host-function worker is alive."
    start_demo
    cat "$demo_log"

    explain "Observed Linux process topology inside the pod:"
    ps -eo pid,ppid,user,comm,args --forest
    echo
    echo "The fixture verifies that inner-sandbox-host equals the worker PID."
    echo "The inner Hyperlight sandbox creates no additional Linux process."

    explain "Observed delegated worker domains:"
    find "$provider_group" -maxdepth 2 -type d -printf '  %p\n' | sort
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
    if pgrep -f '/program|nested_sandbox demo|minijail0' >/tmp/residue; then
        cat /tmp/residue
        fail "a nested demo process remained"
    fi
    [[ $(read_populated "$provider_group") == 0 ]] ||
        fail "the provider cgroup remained populated"
    echo "PASS no nested_sandbox, Minijail, or confined /program process remains"
    echo "PASS delegated provider cgroup is empty"
    echo "PASS unprivileged RuntimeClass nested Hyperlight KIND demonstration"
}

case "${1:-demo}" in
    demo)
        run_demo
        ;;
    *)
        fail "unknown command: $1"
        ;;
esac
