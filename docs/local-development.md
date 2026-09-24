# Local Development with KIND

Quick start for testing Hyperlight on Kubernetes without cloud infrastructure.

## Nested Hyperlight containment demo (Ubuntu-24.04 WSL)

This workflow is separate from the small example application below. It runs the
real nested containment scenario from signed Hyperlight commit
`bb153b2db78e2c8a8bf035a40c65afe8f93afdca`:

```text
outer guest -> separate confined host-function process
            -> inner Hyperlight sandbox in the same worker OS process
            -> inner guest-function calls
```

### Required host

- Ubuntu 24.04 running under WSL
- `/dev/kvm` readable and writable by the current user
- unified cgroup v2 with Docker's systemd cgroup driver
- unprivileged user namespaces
- Landlock ABI 5 or newer
- Docker and kubectl

The setup fails before cluster creation when any requirement is unavailable.
It does not change WSL services or lifecycle, and it does not install global
tools.

### Commands

Run from this checkout inside Ubuntu-24.04 WSL:

```bash
# Static checks only
bash ./scripts/kind-nested-wsl.sh test

# Build pinned sources and local images
bash ./scripts/kind-nested-wsl.sh build

# Create/configure KIND and run the real smoke proof
bash ./scripts/kind-nested-wsl.sh setup

# Paced presentation. Prepared clusters start immediately; after reset, this
# performs setup first.
bash ./scripts/kind-nested-wsl.sh demo

# Automation presentation
bash ./scripts/kind-nested-wsl.sh demo --noninteractive

# State and cleanup
bash ./scripts/kind-nested-wsl.sh status
bash ./scripts/kind-nested-wsl.sh reset
```

The wrapper copies the working tree once into
`~/.cache/hyperlight-kind/worktree` and performs source builds, Docker builds,
and KIND operations there. Hyperlight and Minijail checkouts and Cargo caches
are reused across runs. KIND `v0.33.0`, the node image digest, the Hyperlight
commit, the Minijail commit, and the strict helper digest are pinned.

### Security boundary

The KIND node receives `/dev/kvm`, and the existing device plugin injects it
through CDI. The `hyperlight-delegated` RuntimeClass selects a narrow
containerd `runc` wrapper. Before application start, its OCI runtime hook moves
the init process into an `application` child, enables `cpu`, `memory`, and
`pids` beneath the Kubernetes container cgroup, and delegates only the sibling
`hyperlight-provider` subtree to UID 1000.

The application container is not privileged, runs as UID/GID 1000 with strict
supplementary groups, has all Linux capabilities dropped, and sees the
container cgroup as its cgroup namespace root. It can write the delegated
provider subtree but cannot modify pod-parent, sibling-pod, node, or host
cgroups. Kubelet applies the local `hyperlight-launcher.json` seccomp profile
to the application and Minijail launcher. It permits the namespace and mount
operations Minijail needs while denying kernel/module loading, BPF, tracing,
key creation/request, performance, swap/reboot, userfaultfd, and
cross-process-memory syscalls. The launcher permits `keyctl` because Minijail
uses `KEYCTL_JOIN_SESSION_KEYRING` to isolate the worker's session keyring.
Before `/program` executes, Minijail adds the landed stricter worker seccomp
filter, which denies all keyring access, and the Landlock policy.

The landed provider verifies and uses:

- the delegated `cpu`, `memory`, and `pids` cgroup-v2 subtree
- a root-owned, immutable, SHA-256-pinned Minijail helper
- user, PID, mount, IPC, and network namespaces
- seccomp child-process and keyring denial
- required Landlock ABI 5 filesystem confinement
- a generation-bound KVM descriptor transferred only to the inner sandbox host

The presentation captures the live process tree and cgroup membership while
the fixture is paused, then verifies worker shutdown, an empty provider cgroup,
and deletion of the Kubernetes Job pod.

This arrangement is suitable for local KIND qualification. Production rollout
still requires packaging, lifecycle ownership, compatibility testing, and
support policy for the runtime handler on each target node OS.

## Prerequisites

- **Docker** - Container runtime
- **KIND** - Kubernetes IN Docker (v0.20+, includes containerd 1.7+ with CDI support)
- **kubectl** - Kubernetes CLI
- **/dev/kvm** - KVM enabled on host (required for Hyperlight)

> **Note:** The setup script automatically enables CDI (Container Device Interface) in
> KIND's containerd. CDI allows the device plugin to inject `/dev/kvm` into containers
> that request `hyperlight.dev/hypervisor` resources.

### Install KIND

```bash
# Using Go
go install sigs.k8s.io/kind@latest

# Or download binary
curl -Lo ./kind https://kind.sigs.k8s.io/docs/user/quick-start/#installation
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

### Enable KVM

```bash
# Check if KVM is available
ls -la /dev/kvm
```

If not for more details on how to verify that KVM is correctly installed and permissions are correct, follow the
guide [here](https://help.ubuntu.com/community/KVM/Installation).

## Quick Start

```bash
# 1. Create KIND cluster with local registry
just local-up

# 2. Build the device plugin
just plugin-build

# 3. Push to local registry
just plugin-local-push

# 4. Deploy to KIND
just plugin-local-deploy

# 5. Verify
just status
```

## What Gets Created

| Component | Description |
|-----------|-------------|
| KIND cluster | Single-node cluster named `hyperlight` |
| Local registry | `localhost:5000` for images |
| Node labels | `hyperlight.dev/enabled=true`, `hyperlight.dev/hypervisor=kvm` |
| /dev/kvm mount | Host KVM device mounted into KIND node |

## Testing

```bash
# Check device plugin is running
just status

# Deploy a test pod
kubectl apply -f deploy/manifests/examples/test-pod-kvm.yaml

# Check the test pod
kubectl logs hyperlight-test-kvm
```
## Running the Example Hyperlight App

Once the device plugin is running, you can deploy the example Hyperlight application:

```bash
# Build the example app
just app-build

# Push to local registry
just app-local-push

# Deploy to KIND
just app-local-deploy

# Check it's running
kubectl get pods -l app=hyperlight-hello

# View logs
kubectl logs -l app=hyperlight-hello -f
```

The example app demonstrates security best practices:
- **`scratch` base image** (empty filesystem, ~2.7MB total)
- **Static musl binary** (no runtime dependencies)
- **Non-root user** (UID 65534/nobody)
- **Read-only root filesystem**
- **All capabilities dropped**
- **Seccomp RuntimeDefault profile**

### Cleanup

```bash
just app-undeploy
```

## Teardown

```bash
# Remove cluster and registry
just local-down
```

## Troubleshooting

### KIND node can't access /dev/kvm

The KIND config mounts `/dev/kvm` from the host. Ensure:
1. KVM module is loaded: `lsmod | grep kvm`
2. You have permissions: `ls -la /dev/kvm`
3. KIND node has the mount: `docker exec hyperlight-control-plane ls -la /dev/kvm`

### Image pull errors

Check the local registry is running:
```bash
docker ps | grep kind-registry
curl http://localhost:5000/v2/_catalog
```

### Device plugin not starting

```bash
# Check pod status
kubectl get pods -n hyperlight-system

# Check logs
just logs
```

## Differences from AKS Deployment

### KIND-Specific Manifest

KIND uses a modified manifest at `deploy/local/device-plugin.yaml` that differs from the AKS manifest at `deploy/manifests/device-plugin.yaml`.

**Key difference:** Sets `terminationMessagePath: /tmp/termination-log`

**Why?** KIND runs the kubelet inside a Docker container. When we mount host `/dev` to the pod's `/dev` directory, kubelet cannot create `/dev/termination-log` (the default path) inside the container, causing pod startup to fail with:

```
Error: failed to create containerd task: ... 
open .../rootfs/dev/termination-log: read-only file system
```

Moving the termination log to `/tmp` avoids this conflict while keeping the `/dev` mount for hypervisor auto-detection.

This is a KIND-specific workaround. Cloud providers like AKS run kubelet directly on the host, so they don't have this issue.

## Limitations

- **KVM only** - MSHV is assumed not to be available on local Linux hosts
- **Single node** - KIND creates a single-node cluster
- **No autoscaling** - Unlike AKS, KIND doesn't autoscale

## Next Steps

Once you've validated locally, deploy to Azure:
- [Azure Deployment Guide](azure-deployment.md)
