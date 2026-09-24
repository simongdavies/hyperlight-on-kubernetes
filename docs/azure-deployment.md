# Azure Deployment (AKS + ACR)

How to deploy a Hyperlight Application to Azure Kubernetes Service.

## Prerequisites

- **Azure CLI** (`az`) - [Install](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- **aks-preview extension** - Required for MSHV node pools
  ```bash
  az extension add --name aks-preview
  ```
- **kubectl** - Kubernetes CLI
- **Azure subscription** with permissions to create resources
- **KVM node kernel with Landlock ABI 5 or newer** - normally Linux 6.10+;
  the installer fails before changing containerd when this is unavailable

## Quick Start

For the KVM-only nested Hyperlight qualification path:

```bash
# Creates the system and Ubuntu KVM pools, skips MSHV, creates ACR,
# and writes the kubectl context.
just nested-aks-cluster-create
just nested-aks-connect

# Builds the pinned nested fixture and node installer, publishes all images,
# then installs the device plugin and delegated RuntimeClass.
just nested-aks-setup

# Runs the paced presentation. Use --noninteractive for automation.
just nested-aks-demo
just nested-aks-demo --noninteractive

# Restore containerd and delete AKS, ACR, and the resource group.
just nested-aks-cluster-delete --yes --wait
```

`nested-aks-setup` changes containerd on the KVM nodes. Read
[Delegated RuntimeClass for process placement](#delegated-runtimeclass-for-process-placement)
before using it outside a disposable qualification cluster.

If Azure CLI reports an expired refresh token, authenticate before retrying:

```bash
az login --tenant "$(az account show --query tenantId -o tsv)"
```

### Option A: With ACR (private registry)

```bash
# 1. Create Azure infrastructure (one-time)
just azure-up

# 2. Connect kubectl to the cluster
just get-aks-credentials

# 3. Build and push the device plugin to ACR
just plugin-build
just plugin-acr-push

# 4. Deploy to AKS
just plugin-azure-deploy

# 5. Verify
just status
```

### Option B: Without ACR (use GHCR)

If you don't need a private registry and want to use the public GHCR images:

```bash
# 1. Create AKS cluster only (no ACR)
just azure-up-no-acr

# 2. Connect kubectl to the cluster
just get-aks-credentials

# 3. Deploy from GHCR (no build needed assuming the plugin is already published)
just plugin-azure-deploy ghcr

# 4. Verify
just status
```

## What Gets Created

All resources are created in the same resource group (`hyperlight-rg` by default).

| Resource | Name | Description |
|----------|------|-------------|
| Resource Group | `hyperlight-rg` | Container for all resources |
| Container Registry | `hyperlightacr` | Docker images (optional, skip with `--no-acr`) |
| AKS Cluster | `hyperlight-cluster` | Kubernetes cluster |
| KVM Node Pool | `kvmpool` | Ubuntu nodes with /dev/kvm |
| MSHV Node Pool | `mshvpool` | AzureLinux nodes with /dev/mshv |

## Configuration

Override defaults with environment variables:

```bash
export RESOURCE_GROUP="my-rg"
export CLUSTER_NAME="my-cluster"
export ACR_NAME="myacr"
export LOCATION="eastus"

just azure-up
```

| Variable | Default | Description |
|----------|---------|-------------|
| `RESOURCE_GROUP` | `hyperlight-rg` | Azure resource group |
| `CLUSTER_NAME` | `hyperlight-cluster` | AKS cluster name |
| `ACR_NAME` | `hyperlightacr` | Container registry (must be globally unique) |
| `LOCATION` | `westus3` | Azure region |

## Node Pools

### KVM Pool

For workloads using Linux KVM hypervisor.

| Setting | Value |
|---------|-------|
| OS | Ubuntu |
| VM Size | Standard_D4s_v3 (nested virt capable) |
| Device | `/dev/kvm` |
| Autoscale | 1-5 nodes |

Create only the system and KVM pools when qualifying delegated process
placement:

```bash
just nested-aks-cluster-create
just nested-aks-connect
```

That recipe uses one system node and one KVM node initially, with the KVM pool
allowed to autoscale to two nodes. Override `KVM_NODE_COUNT`,
`KVM_NODE_MIN_COUNT`, or `KVM_NODE_MAX_COUNT` when a larger qualification pool
is intentional.

### MSHV Pool

For workloads using Microsoft Hypervisor (Azure-only).

| Setting | Value |
|---------|-------|
| OS | AzureLinux |
| Workload Runtime | KataMshvVmIsolation |
| Device | `/dev/mshv` |
| Autoscale | 1-5 nodes |

## Deployment Steps

### 1. Create Infrastructure

```bash
just azure-up
```

This runs `deploy/azure/setup.sh` which creates:
- Resource group
- ACR (attached to AKS for pull access)
- AKS cluster with system node pool
- KVM node pool
- MSHV node pool

### 2. Build and Push

```bash
# Build locally
just plugin-build

# Push to ACR
just plugin-acr-push
```

### 3. Deploy Device Plugin

```bash
just plugin-azure-deploy
```

### 4. Verify

```bash
# Check device plugin
just status

# Check node resources
kubectl get nodes -o custom-columns='NAME:.metadata.name,HYPERVISOR:.metadata.labels.hyperlight\.dev/hypervisor,CAPACITY:.status.allocatable.hyperlight\.dev/hypervisor'
```

### 5. Test Device Injection

Deploy test pods to verify the hypervisor devices are properly injected:

```bash
# Deploy test pods (KVM and MSHV)
kubectl apply -f deploy/manifests/examples/test-pod-kvm.yaml
kubectl apply -f deploy/manifests/examples/test-pod-mshv.yaml

# Check they're running
kubectl get pods -l app.kubernetes.io/name=hyperlight-test

# View logs - should show device exists
kubectl logs hyperlight-test-kvm
kubectl logs hyperlight-test-mshv

# Cleanup test pods
kubectl delete pod hyperlight-test-kvm hyperlight-test-mshv
```

Expected output:
```
=== Hyperlight KVM Test Pod ===
Checking for /dev/kvm...
✓ /dev/kvm exists
...
HYPERLIGHT_HYPERVISOR=kvm
HYPERLIGHT_DEVICE_PATH=/dev/kvm
```

## Delegated RuntimeClass for process placement

The nested Hyperlight workload needs two independent node capabilities:

1. The existing Device Plugin/CDI path injects `/dev/kvm`.
2. The `hyperlight-delegated` RuntimeClass creates a pod-scoped cgroup-v2
   subtree before the application starts.

AKS does not expose a supported equivalent of KIND's
`containerdConfigPatches`. The repository therefore uses a privileged
DaemonSet as a narrow node installer:

| Component | Path | Responsibility |
|-----------|------|----------------|
| Static wrapper and OCI hook | `deploy/azure/runtime-installer/main.go` | Selects the real node `runc`, makes only the pod's namespaced cgroup mount writable, creates the delegated subtree, and removes it on container deletion |
| Node installer | `deploy/azure/runtime-installer/install-runtime.sh` | Checks KVM/cgroup v2, installs runtime assets and seccomp, adds one managed containerd block, validates it, and restarts containerd only when needed |
| Installer DaemonSet | `deploy/azure/runtime-installer.yaml` | Runs only on enabled Ubuntu KVM nodes and labels a node `hyperlight.dev/runtime=delegated` after successful installation |
| RuntimeClass | `deploy/azure/runtime-installer.yaml` | Selects handler `hyperlight-delegated` and schedules only to ready KVM nodes |
| Qualification Job | `deploy/azure/nested-job.yaml` | Runs the real nested fixture as UID/GID 1000 without privilege or Linux capabilities |
| Workflow | `scripts/aks-nested.sh` | Builds, publishes, deploys, demonstrates, checks cleanup, and undeploys |

### Security boundary

The installer DaemonSet is privileged because changing a node's container
runtime is inherently a node-admin operation. It runs in the separate
`hyperlight-node-system` namespace and receives only the host paths it changes:

- `/etc/containerd`
- `/opt/hyperlight-runtime`
- `/run/hyperlight-runtime`
- `/var/lib/kubelet/seccomp`
- read-only `/sys/fs/cgroup` and `/dev/kvm`

The application Job is not privileged. It runs as UID/GID 1000, drops all
capabilities, disables privilege escalation and service-account mounting, and
uses the named `hyperlight-launcher.json` seccomp profile. The cgroup namespace
hides node and sibling-pod cgroups. Kubernetes CPU and memory limits remain the
outer ceiling for every delegated worker cgroup.

The wrapper reads the actual non-root UID/GID from each OCI specification and
delegates to that identity; it does not grant a fixed cluster-wide user.
Container creation fails closed for root workloads or when the runtime did not
provide a private cgroup namespace.

### Build and deploy

Run from Ubuntu-24.04 WSL:

```bash
# Build locally.
just nested-aks-build

# Push the plugin, workload, and installer with one shared AKS_IMAGE_TAG.
export AKS_IMAGE_TAG=aks-nested
just nested-aks-publish

# Install on the current cluster's KVM nodes.
just nested-aks-deploy
just nested-aks-status
```

For a new disposable qualification environment, the complete lifecycle is:

```bash
just nested-aks-cluster-create
just nested-aks-setup
just nested-aks-demo
just nested-aks-cluster-delete --yes --wait
```

`nested-aks-cluster-create` creates the resource group, Basic ACR, AKS system
pool, and one autoscaling Ubuntu `Standard_D4s_v3` KVM node. It also attaches
ACR and writes the kubeconfig context. `nested-aks-connect` can safely refresh
that context later.

The installer:

- refuses nodes without `/dev/kvm`, unified cgroup v2, or Landlock ABI 5+;
- supports containerd configuration version 2 and 3 plugin paths;
- discovers the node's real `runc` path rather than assuming one;
- validates the complete containerd configuration before restart;
- restores the previous configuration if validation or restart fails;
- adds readiness labels only after `containerd config dump` shows the handler.

### Run and clean up

```bash
just nested-aks-demo
```

The command waits for the Job, prints the application output, deletes the Job,
then verifies on the selected node that no runtime-state file or
`hyperlight-provider` cgroup remains.

Remove application pods before uninstalling the node integration:

```bash
just nested-aks-undeploy
```

The command refuses to proceed while any pod still selects
`hyperlight-delegated`. It explicitly invokes uninstall on every node and stops
on the first failure. Each installer pod removes the managed containerd block,
restarts containerd, removes installed assets, and clears its node readiness
label before the DaemonSet is deleted.

### AKS lifecycle limitations

This is a qualification/prototype path, not a Microsoft-supported custom AKS
runtime contract. AKS owns and replaces node images and
`/etc/containerd/config.toml`. The DaemonSet makes installation repeatable for
new autoscaled or replacement nodes, but every AKS Kubernetes or node-image
upgrade must be requalified. Containerd restarts can briefly interrupt CRI
operations, so deploy and remove the installer only during a controlled
maintenance window.

The September 2026 live qualification reached the real workload container on
AKS Kubernetes 1.35 with containerd 2.3.3, verified CDI `/dev/kvm` allocation,
installed the delegated runtime, and verified cleanup and containerd restore.
The default Ubuntu 24.04 node image used kernel `6.8.0-1067-azure`, which
reported Landlock ABI 4. The pinned Hyperlight worker policy requires ABI 5 for
the filesystem `ioctl` device restriction, so this image is intentionally
unsupported rather than silently running a weaker profile. A Linux 6.10+ AKS
node image (or another image that reports ABI 5+) must be qualified before the
nested demo can complete securely.

The current prototype does not support `kubectl exec` or exec-based probes in
delegated pods. PID 1 is moved to the `application` leaf before child
controllers are enabled, and additional runtime exec processes cannot be
placed in the now-empty parent cgroup. The qualification Job deliberately uses
log retrieval rather than runtime exec.

For Microsoft-managed VM-isolated pods, AKS Pod Sandboxing/Kata is the
supported alternative. It is a different execution model and does not provide
this pod-scoped host-process placement capability.

## Running the Example Hyperlight App

Once the device plugin is deployed, you can run the example application. The app is built with security best practices:

- **`scratch` base image** (empty filesystem, ~2.7MB total)
- **Static musl binary** (no runtime dependencies)
- **Non-root user** (UID 65534/nobody)
- **Read-only filesystem**
- **All capabilities dropped**
- **Seccomp RuntimeDefault profile**

### Using ACR (Private)

```bash
# Build the example app
just app-build

# Push to ACR
just app-acr-push

# Deploy (creates both KVM and MSHV deployments)
just app-azure-deploy

# Check pods
kubectl get pods -l app=hyperlight-hello

# View logs from KVM pod
kubectl logs -l app=hyperlight-hello,hypervisor=kvm -f

# View logs from MSHV pod
kubectl logs -l app=hyperlight-hello,hypervisor=mshv -f
```

### Using GHCR (Public)

If the app is published to GHCR, deploy without building:

```bash
just app-azure-deploy ghcr
```

### Cleanup

```bash
just app-undeploy
```

## Resource Management

```bash
# Stop cluster when not in use (saves compute costs)
just azure-stop

# Start cluster when needed
just azure-start

# Check cluster status
az aks show -g hyperlight-rg -n hyperlight-cluster --query powerState.code

# Destroy everything when done
just azure-down
```

You can also destroy just the cluster (keeping ACR):
```bash
just azure-down-cluster
```

## Troubleshooting

### ACR name already taken

ACR names must be globally unique. Choose a different name:
```bash
export ACR_NAME="myuniquename123"
just azure-up
```

### Cluster not starting

```bash
# Check cluster status
az aks show -g hyperlight-rg -n hyperlight-cluster --query provisioningState

# View cluster events
az aks show -g hyperlight-rg -n hyperlight-cluster
```

### Node pool issues

```bash
# List node pools
az aks nodepool list -g hyperlight-rg --cluster-name hyperlight-cluster -o table

# Check specific pool
az aks nodepool show -g hyperlight-rg --cluster-name hyperlight-cluster -n kvmpool
```

### Device plugin not running

```bash
# Check pods
kubectl get pods -n hyperlight-system

# Check logs
just logs

# Describe pod
kubectl describe pod -n hyperlight-system -l app.kubernetes.io/name=hyperlight-device-plugin
```

## Next Steps

- [Local Development](local-development.md) - Test locally with KIND
- [GHCR Publishing](ghcr-publishing.md) - Publish images publicly
- [Architecture](architecture.md) - How the device plugin works
