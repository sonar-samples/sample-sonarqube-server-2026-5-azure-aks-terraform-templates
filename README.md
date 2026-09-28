# SonarQube Server 2026.5 Enterprise with agentic components — Azure AKS installation

Terraform for SonarQube Server 2026.5 Enterprise on Azure Kubernetes Service, optionally with the
2026.5 agentic components: Sonar Vortex analysis, the Agent Orchestrator, the SonarQube Hunter
Agent, and the SonarQube Remediation Agent.

Companion to the blueprint *Installing SonarQube Server 2026.5 Enterprise and its agentic
components on Azure AKS*. For a SonarQube Server deployment without the agentic components,
including private networking, Application Gateway and automated TLS, see
[sonarqube-server-azure-aks-installation](https://github.com/sonar-solutions/sonarqube-server-azure-aks-installation).

## Release status — read before setting a chart version

**This is a reference deployment design, not a generally available installation path.** Verified
2026-09-27: the published SonarQube Helm repository exposes 2026.4.1 as its newest package and no
2026.5.x chart is listed. The agentic chart code on the source repository's `master` branch
identifies itself as `2026.5.1000`, still declares `appVersion: 2026.4.0`, and ships **blank image
defaults for all four agentic components**.

A source merge is not a release. The published Helm index is what you install from.

`enable_agentic` therefore defaults to `false`. With it off, this deploys SonarQube Server
Enterprise on AKS from a published chart — useful and complete on its own.

### Release acceptance criteria

Run all four before setting `enable_agentic = true`. Every one must pass.

```sh
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update

# 1. A 2026.5.x chart is published
helm search repo sonarqube/sonarqube --versions | head -20

# 2. appVersion is 2026.5, not a stale 2026.4
helm show chart sonarqube/sonarqube --version <version> | grep -E '^(version|appVersion):'

# 3. All four agentic value blocks exist
helm show values sonarqube/sonarqube --version <version> \
  | grep -E '^(agentOrchestrator|hunterAgent|remediationAgent|vortexAnalysis):'

# 4. The Enterprise image resolves to 2026.5
helm template sonarqube sonarqube/sonarqube --version <version> \
  --set edition=enterprise | grep -E 'image:.*sonarqube'
```

Criterion 3 matters because a chart without those blocks does not fail — it installs SonarQube
Server and silently ignores every agentic value. Criterion 2 matters because the chart composes the
Server image tag from `Chart.AppVersion` when `edition` is set and no tag is given, so a stale
appVersion deploys the wrong Server with no error. `sonarqube_image_tag` exists to override that.

You also need an approved image manifest for the four agentic components. The chart's defaults are
blank and validation rejects a blank repository, so there is no safe fallback.

## Infrastructure Components

| Component | Azure service | Purpose |
| --- | --- | --- |
| Resource group | Resource Manager | Holds everything this module creates |
| AKS cluster | Kubernetes Service | Runs SonarQube Server and the agentic workloads |
| System node pool | Virtual Machine Scale Sets | SonarQube Server, Orchestrator, Vortex, egress proxy |
| Sandbox node pool | VMSS with Pod Sandboxing | Agent runtimes only; tainted, Azure Linux, Gen2 nested-virt |
| PostgreSQL | Database for PostgreSQL Flexible Server | SonarQube database, shared with the Orchestrator |
| Two file shares | Azure Files via CSI, ReadWriteMany | Agent job artifacts, and Vortex analyzer context |
| SonarQube release | Helm | The official chart from the SonarSource repository |

## Prerequisites

- Terraform >= 1.7, Azure CLI >= 2.80.0, `kubectl`, Helm 3.
- A SonarQube Server Enterprise or Data Center Edition licence, plus written confirmation of
  entitlement for each agentic feature you enable. Edition licensing alone does not enable them.
- A region that satisfies all three of: permitted by any allowed-locations Azure Policy, has Total
  Regional vCPU headroom for both pools, and offers a Gen2 nested-virtualization VM size.
- Any resource tags your subscription policy mandates, via `tags`. A tag policy denies the very
  first resource, so check before the first apply.
- **`az login` may not be sufficient.** The azurerm provider needs a Microsoft Graph-scoped token,
  and a Conditional Access policy can refuse it while ordinary `az` commands keep working — the
  error points at `provider "azurerm"` and gives no hint of the cause. Confirm with
  `az account get-access-token --scope https://graph.microsoft.com/.default`.

For the agentic components, confirm AKS Pod Sandboxing for your target subscription and region
against current Azure documentation, then record the RuntimeClass the cluster actually produces:

```sh
az feature register --namespace Microsoft.ContainerService -n KataVMIsolationPreview
az provider register --namespace Microsoft.ContainerService
kubectl get runtimeclass
```

## Quick Start

```sh
git clone https://github.com/sonar-solutions/sonarqube-server-2026-5-azure-aks-installation.git
cd sonarqube-server-2026-5-azure-aks-installation

cp terraform.tfvars.json.example terraform.tfvars.json
# Edit terraform.tfvars.json with your values

terraform init
terraform plan
terraform apply
```

None of the `.tf` files need editing. All configuration lives in `terraform.tfvars.json`.

Then:

```sh
$(terraform output -raw get_credentials_command)
$(terraform output -raw port_forward_command)
```

SonarQube is at `http://127.0.0.1:9000`. Apply your licence under **Administration →
Configuration → License Manager** and change the admin password.

### Enabling settings encryption

SonarQube generates its own settings-encryption key, so it cannot exist before the server runs.
After first boot:

1. **Administration → Configuration → Encryption → Generate Secret Key**, save it to a file.
2. `kubectl create secret generic sonarqube-encryption-secret -n sonarqube --from-file=sonar-secret.txt=./sonar-secret.txt`
3. Set `enable_settings_encryption` to `true` and re-apply.

This key encrypts stored LLM provider credentials and is mounted into the Agent Orchestrator, so do
it before enabling the agentic features. Use a file rather than `--from-literal` to keep the key out
of shell history.

## Configuration Values

| Variable | Default | Description |
| --- | --- | --- |
| `subscription_id` | *(required)* | Azure subscription to deploy into |
| `location` | `westeurope` | Must satisfy policy, quota and Gen2 nested-virt SKU availability |
| `resource_group_name` | `sonarqube-2026-5` | |
| `cluster_name` | `sonarqube-aks` | |
| `postgres_name` | `sonarqube-pg` | Globally unique across Azure |
| `db_username` | `sonarqube` | |
| `kubernetes_version` | `null` | `null` takes the region's latest non-preview version |
| `system_vm_size` | `Standard_D4s_v5` | |
| `sandbox_vm_size` | `Standard_D8s_v5` | Must be Gen2 with nested virtualization |
| `sandbox_max_nodes` | `2` | |
| `sonarqube_chart_version` | *(required)* | An exact published version, never a floating `2026.5` |
| `sonarqube_image_tag` | `""` | Approved Server image tag. Required while appVersion lags |
| `enable_agentic` | `false` | Deploys Vortex, the Orchestrator and both runtimes |
| `sandbox_runtime_class` | `""` | Required with `enable_agentic`. Discover it; do not guess |
| `runtime_replica_count` | `1` | Concurrent jobs per runtime |
| `agentic_images` | all blank | Required with `enable_agentic`; chart defaults are blank |
| `llm_allowed_domains` | `["api.anthropic.com"]` | Egress proxy allowlist |
| `jobs_storage_size` | `100Gi` | Azure Files share for job artifacts |
| `vortex_storage_size` | `100Gi` | Azure Files share for analyzer context |
| `share_dir_mode` / `share_file_mode` | `0777` | Reference setting; see Design notes |
| `share_gid` | `0` | Set with `0770` modes for least privilege |
| `enable_settings_encryption` | `false` | Turn on for the second apply |
| `tags` | `{}` | Applied to every Azure resource |

## Configuration Files

| File | Contents |
| --- | --- |
| `main.tf` | Terraform and provider configuration |
| `variables.tf` | All inputs |
| `aks.tf` | Resource group, AKS cluster, system and sandbox node pools |
| `postgresql.tf` | Flexible Server, database, firewall rule |
| `storage.tf` | Namespace, Azure Files StorageClass, two ReadWriteMany shares |
| `secrets.tf` | Database, monitoring and agentic signing secrets |
| `sonarqube.tf` | The Helm release and its values overlay |
| `sonarqube-values.yaml` | Static base values; everything else is overlaid by `sonarqube.tf` |
| `outputs.tf` | Connection details and helper commands |
| `terraform.tfvars.json.example` | Copy to `terraform.tfvars.json` and edit |

## Design notes

**Pod Sandboxing, not gVisor.** AKS has no gVisor, and the chart's `gvisor.installer` is a
privileged DaemonSet that rewrites containerd configuration AKS manages itself. This module sets
`gvisor.enabled = false` and uses `agentRuntimeSandbox` with the RuntimeClass you supply. Check
whether that class carries a `scheduling.nodeSelector` — Kubernetes merges it into every runtime
pod, and a colliding key makes those pods permanently unschedulable.

**Azure Files, not MinIO.** Azure Blob Storage has no S3-compatible API, and MinIO container images
are no longer anonymously pullable (`quay.io/minio/minio` returns 401 repo-wide), so an in-cluster
MinIO would require registry credentials before the install could finish. The chart describes
S3-compatible object storage as its recommended production backend for job storage; Azure Files
over `ReadWriteMany` is a viable AKS option, and it needs no storage credentials at all. Select
from the released chart's documented storage matrix for your own deployment.

**The custom StorageClass is load-bearing, and its modes are a reference setting.** AKS's built-in
`azurefile-csi` sets no `uid`, `gid` or `file_mode`, so an SMB mount lands root-owned and the
agentic containers — uid 900, 1000 and 10001 — cannot write to it. Without permissive modes the
shares still bind and the pods still start; jobs fail later, on write. The `0777` defaults are what
was validated and are appropriate for a lab. Otherwise set `share_gid` to a gid the pods carry,
drop the modes to `0770`, add a matching pod `fsGroup`, and retest the write.

**Subdirectory isolation.** The Orchestrator mounts the jobs share at its root and writes each
runtime's jobs into a subdirectory named after that runtime. Each runtime mounts only its own
subtree via `subPath`. Chart validation requires each component's mount path to sit at or above its
`storage.filesystem.baseDir`.

**Two shares, not one.** Job artifacts and Vortex analyzer context have opposite retention
lifecycles; the `deleteOlderThan` housekeeping settings apply to job artifacts only. SonarQube
Server writes the context share and Vortex mounts it read-only.

**Per-component tolerations.** The sandbox pool is tainted, so a node selector alone leaves the
runtime pods pending. Tolerations are set on the runtimes only — a release-wide toleration would
make SonarQube Server itself eligible for a sandbox node.

**PostgreSQL uses a public endpoint narrowed to the cluster's outbound IP.** That is a reference
simplification that keeps the module self-contained, not a production baseline. For production use
a delegated subnet with private access and no public endpoint.

## Resources Created

Fifteen resources with `enable_agentic = false`, eighteen with it enabled: resource group, AKS
cluster, sandbox node pool, PostgreSQL server, database and firewall rule, Kubernetes namespace,
Azure Files StorageClass, two PersistentVolumeClaims, three Kubernetes secrets, four generated
passwords, and the Helm release.

## Known limitations

- **No ingress.** Access is by port-forward. CI scanners cannot reach the server, so this is not a
  complete deployment on its own — add Application Gateway, DNS and TLS from the base repository.
- **Fixed runtime replicas keep the sandbox pool provisioned.** `min_count = 0` permits scale-down
  only when nothing schedulable needs the pool. True scale-to-zero requires validated chart
  autoscaling that drives runtime replicas to zero.
- **The agentic components have not been exercised from this configuration.** A full apply and
  destroy were validated against published chart 2026.4.1, which accepts the agentic values but
  does not implement them. That proves the infrastructure, shares, mounts, secrets and release
  mechanism — not that the agentic containers can read and write those shares.
- **Azure Files is SMB.** Throughput and IOPS differ from managed disks, and Standard tier is the
  default here. Raise to `Premium_LRS` in the StorageClass if job staging is slow.

### Validated on 2026-09-27

A full apply and destroy in `northeurope` against chart 2026.4.1:

| | |
| --- | --- |
| 18-resource apply | completed, Helm release `deployed` |
| Kubernetes version | resolved from the region default (`1.36.3`) rather than pinned |
| `node_provisioning_profile { mode = "Manual" }` | accepted by the Azure API |
| AKS egress IP lookup and PostgreSQL firewall rule | resolved and created |
| Azure Files RWX shares | both Bound; non-root container write confirmed |
| Explicit `sonarqube_image_tag` | produced `2026.4.1.126914`, overriding appVersion composition |
| `terraform destroy` | 17 resources destroyed, resource group removed, no leftovers |

The destroy path completed cleanly despite the providers reading credentials from the cluster being
deleted. That remains a theoretical weak point on a refresh after the cluster is removed out of
band; if you hit it, destroy `helm_release.sonarqube` first.

## Upgrade

Change `sonarqube_chart_version` to the new published version, re-confirm the acceptance criteria
above, and re-apply. Follow the released chart's upgrade notes, and back up the database and both
file shares first. The upgrade path from 2026.4 has not been tested from this module.

## Cleanup

```sh
terraform destroy
```

This removes the PostgreSQL server, both Azure Files shares, and all retained analysis, context and
artifact data. Before running it: back up anything you need, confirm retention requirements, and
rotate or revoke the LLM and DevOps credentials you issued.
