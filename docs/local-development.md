# Local Development with KIND

Quick start for testing Hyperlight on Kubernetes without cloud infrastructure.

## Nested Hyperlight containment demo (Ubuntu 24.04)

This workflow is separate from the small example application below. It builds
the Hyperlight fork branch `simongdavies-land-vm-authority` at its pinned,
signed tip `bb153b2db78e2c8a8bf035a40c65afe8f93afdca`, then runs the nested
containment fixture included in that repository state. The containment work
spans the branch history; the pinned tip itself makes the fixture output
concise:

```text
outer guest -> separate confined host-function process
            -> inner Hyperlight sandbox in the same worker OS process
            -> inner guest-function calls
```

### Required host

- Ubuntu 24.04, either native or running under WSL
- `/dev/kvm` readable and writable by the current user
- unified cgroup v2
- unprivileged user namespaces
- Landlock ABI 5 or newer
- Docker using cgroup v2 and the systemd cgroup driver
- kubectl, Git, curl, rsync, Python 3, `jq`, and CA certificates
- GCC, binutils, Make, `pkg-config`, `libcap-dev`, Clang, CMake,
  `protobuf-compiler`, `libssl-dev`
- Rust toolchains 1.94 and 1.95, plus `just`

The setup fails before cluster creation when any requirement is unavailable.
It does not change host services or lifecycle, and it does not install global
tools.

On a clean Ubuntu 24.04 host, install the native packages and grant the current
user access to Docker and KVM:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates clang cmake curl docker.io git jq libcap-dev libssl-dev \
  build-essential pkg-config protobuf-compiler python3 rsync
sudo systemctl enable --now docker
sudo usermod -aG docker,kvm "$USER"
```

Start a new login session after changing group membership. If `/dev/kvm`
retains an old numeric group after package installation, reapply Ubuntu's
packaged device rule once:

```bash
sudo systemd-tmpfiles --create \
  /usr/lib/tmpfiles.d/static-nodes-permissions.conf
```

Install kubectl using its
[official Linux instructions](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/),
then install the pinned Rust toolchains and `just`:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
  sh -s -- -y --default-toolchain 1.95
source "$HOME/.cargo/env"
rustup toolchain install 1.94 1.95
cargo install --locked just
```

The repository and pinned Hyperlight fork are fetched anonymously over HTTPS;
no GitHub SSH key or access token is required.

For a clean reproduction of the published branch:

```bash
git clone --branch simongdavies-kubernetes-process-integration --single-branch \
  https://github.com/simongdavies/hyperlight-on-kubernetes.git
cd hyperlight-on-kubernetes
```

### Commands

Run from this checkout on Ubuntu 24.04:

```bash
# Static checks only
bash ./scripts/kind-nested.sh test

# Build pinned sources and local images
bash ./scripts/kind-nested.sh build

# Create/configure KIND and run the real smoke proof
bash ./scripts/kind-nested.sh setup

# Paced presentation. Prepared clusters start immediately; after reset, this
# performs setup first.
bash ./scripts/kind-nested.sh demo

# Automation presentation
bash ./scripts/kind-nested.sh demo --noninteractive

# State and cleanup
bash ./scripts/kind-nested.sh status
bash ./scripts/kind-nested.sh reset
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

Ubuntu 24.04 can additionally set
`kernel.apparmor_restrict_unprivileged_userns=1`. On those hosts the setup
loads `deploy/kind-nested/hyperlight-userns.apparmor`, pinning the permission
to create a user namespace to the named `hyperlight-userns` profile. The
`hyperlight-delegated` runtime wrapper applies that profile directly to its OCI
process; ordinary containers remain unchanged. The sysctl stays enabled.

Newer kernels also reject Minijail's private procfs mount when the parent
container has the standard OCI masked and read-only proc paths. On the same
restricted-host path, the RuntimeClass wrapper removes those proc masks before
launch. This is narrower than `privileged`: the application still runs as UID
1000 with no Linux capabilities, no privilege escalation, the named seccomp
profile, a cgroup namespace, and no host PID namespace. Minijail immediately
creates its private user, PID, mount, IPC, and network namespaces and applies
its stricter seccomp and Landlock policy. WSL and hosts without the AppArmor
restriction retain the standard proc masks.

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
