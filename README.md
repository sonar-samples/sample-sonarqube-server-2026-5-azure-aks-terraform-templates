# SonarQube Server 2026.5 Enterprise with agentic components — Azure AKS installation

Terraform for SonarQube Server 2026.5 Enterprise on Azure Kubernetes Service, optionally with the
2026.5 agentic components: Sonar Vortex analysis, the Agent Orchestrator, the SonarQube Hunter
Agent, and the SonarQube Remediation Agent.

Companion to the blueprint *Installing SonarQube Server 2026.5 Enterprise and its agentic
components on Azure AKS*. For a SonarQube Server deployment without the agentic components,
including private networking, Application Gateway and automated TLS, see
[sonarqube-server-azure-aks-installation](https://github.com/sonar-solutions/sonarqube-server-azure-aks-installation).

## Release status — read before setting a chart version

**The GA chart changes are merged; the only remaining gate is publication.** Verified 2026-09-29:

| | |
| --- | --- |
| [PR #981](https://github.com/SonarSource/helm-chart-sonarqube/pull/981) | merged 2026-09-29 — "Release SonarQube Server 2026.5.0 LTA, support K8s 1.37/OCP 4.22" |
| `master` `Chart.yaml` | `version: 2026.5.1000`, **`appVersion: 2026.5.0`** |
| Agentic image defaults | populated and public — `sonarsource/sonar-vortex`, `sonarqube-agent-orchestrator`, `sonarqube-hunter-agent`, `sonarqube-remediation-agent`, all at `2026.5.0` |
| `sonarqube:2026.5.0-enterprise` | published |
| **Published Helm index** | **still 2026.4.1 — no 2026.5.x package yet** |

Two earlier problems are now closed. `appVersion` matches the chart version, so `edition:
enterprise` composes `sonarqube:2026.5.0-enterprise` correctly and `sonarqube_image_tag` is only
needed to override. And the agentic image defaults are real and public, so `agentic_images` is only
needed when mirroring into a private registry.

What remains is the release pipeline publishing `2026.5.1000` to
`https://SonarSource.github.io/helm-chart-sonarqube`. Until it appears there, `terraform apply`
cannot resolve the chart. A source merge is not a release.

`enable_agentic` defaults to `false`. With it off, this deploys SonarQube Server Enterprise on AKS
from a published chart — useful and complete on its own.

### Release acceptance criteria

One gate and three confirmations. Run them before setting `enable_agentic = true`.

```sh
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update

# THE GATE — is 2026.5.1000 published? Everything else is merged already.
helm search repo sonarqube/sonarqube --versions | head -20

# Confirmations, all expected to pass on 2026.5.1000
helm show chart sonarqube/sonarqube --version 2026.5.1000 | grep -E '^(version|appVersion):'
helm show values sonarqube/sonarqube --version 2026.5.1000 \
  | grep -E '^(agentOrchestrator|hunterAgent|remediationAgent|vortexAnalysis):'
helm template sonarqube sonarqube/sonarqube --version 2026.5.1000 \
  --set edition=enterprise | grep -E 'image:.*sonarqube'
```

`helm repo update` first, or a cached index will report the old version and you will conclude it
is unpublished when it is not.

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
| `sonarqube_chart_version` | *(required)* | An exact published version — `2026.5.1000` once the index carries it |
| `sonarqube_image_tag` | `""` | Optional override. Empty takes the chart default, correct as of appVersion 2026.5.0 |
| `enable_agentic` | `false` | Deploys Vortex, the Orchestrator and both runtimes |
| `enable_pod_sandboxing` | `true` | VM isolation per runtime pod. Off removes the sandbox pool, RuntimeClass, Azure Linux and nested-virt requirements |
| `sandbox_runtime_class` | `""` | Required with `enable_agentic` **and** `enable_pod_sandboxing`. `kata-vm-isolation` on current AKS |
| `runtime_replica_count` | `1` | Concurrent jobs per runtime |
| `agentic_images` | all blank | Optional overrides. Blank repository takes the chart default; set only when mirroring |
| `llm_allowed_domains` | `["api.anthropic.com"]` | Egress proxy allowlist |
| `storage_backend` | `azureblob` | `azureblob` for presigned SAS locators, `azurefiles` for a mounted share |
| `storage_account_name` | `""` | Required with `azureblob`. Globally unique, 3–24 lowercase alphanumerics |
| `jobs_storage_size` | `100Gi` | Azure Files share for job artifacts (`azurefiles` only) |
| `vortex_storage_size` | `100Gi` | Azure Files share for analyzer context (`azurefiles` only) |
| `share_dir_mode` / `share_file_mode` | `0777` | `azurefiles` only. Reference setting; see Design notes |
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
privileged DaemonSet that rewrites containerd configuration AKS manages itself. With
`enable_pod_sandboxing = true` this module sets `gvisor.enabled = false` and uses
`agentRuntimeSandbox` with the RuntimeClass you supply.

**What to set `sandbox_runtime_class` to.** **`kata-vm-isolation`** — confirmed by SonarSource
engineering as the Azure configuration (`agentRuntimeSandbox.enabled: true`,
`runtimeClassName: kata-vm-isolation`), matching Microsoft's documentation and what this module was
validated against on Kubernetes 1.35 and 1.36. Older clusters may instead expose
`kata-mshv-vm-isolation`, which is the name the SonarQube chart's own comments cite as its AKS
example. The variable has no default on purpose: the name is a property of your cluster, and a
wrong value fails at pod start with an unsupported-handler error rather than at plan time. Read it
off the cluster and use it verbatim:

```sh
kubectl get runtimeclass
kubectl get runtimeclass kata-vm-isolation -o jsonpath='{.handler}{"\n"}{.scheduling}'
```

Also check whether the class carries a `scheduling.nodeSelector`. Kubernetes merges it into every
runtime pod, so a key that collides with this module's `workload: sandbox` selector makes those
pods permanently unschedulable. On the validated cluster the class carried
`kubernetes.azure.com/kata-vm-isolation: "true"`, a different key, so the two combine rather than
conflict.

**Sandboxing is a toggle, and it interacts with your storage choice.** Set
`enable_pod_sandboxing = false` and the module creates no sandbox node pool, needs no RuntimeClass,
no Azure Linux OS SKU, no Gen2 nested-virtualization SKU and no feature registration; the runtimes
schedule on the system pool under the default container runtime. The chart supports this — no
validation requires a sandbox — but SonarQube's own documentation describes the sandbox as the
control that keeps LLM-influenced code away from the host, so treat turning it off as a security
decision rather than a simplification, and record it as one.

The interaction that matters: with Pod Sandboxing on, a mounted volume reaches the pod VM through
`virtiofsd` rather than directly. Microsoft documents that Kata pods may not reach the IOPS
traditional containers achieve on Azure Files. **This module's filesystem storage has not been
exercised with sandboxing enabled** — see Known limitations. An object-storage backend avoids the
question entirely, because the runtime reaches storage over the network instead of through a mount.

**Two storage backends, selected by `storage_backend`.** Sonar's `sonar-object-store` library
supports `S3`, `AZURE`, `GCS`, `FILESYSTEM` and `NFS`. This module implements the two that make
sense on AKS, and the choice is an isolation decision as much as a storage one:

| | `azureblob` (default) | `azurefiles` |
| --- | --- | --- |
| Library provider | `AzureObjectStore` — native SAS presigned URLs | `FilesystemObjectStore` |
| What the runtime is handed | A presigned `https` URL scoped to **one object and one verb**, expiring after the presign TTL (default 6 h) | A direct `file://` path on a volume it mounts |
| Isolation enforced by | The locator itself — a leaked URL is useless after expiry and cannot be repurposed | **Your deployment** — mount scoping and permissions |
| Azure resources | Storage account + two containers | Two ReadWriteMany file shares + a custom StorageClass |
| Authentication | Connection string in a Kubernetes secret. No Managed Identity path | None — reached by mount |
| Egress allowlist | Must include `<account>.blob.core.windows.net` | Nothing — storage is not a network call |
| Pod Sandboxing interaction | None; the runtime mounts nothing. Verified: the runtime pods carry only `agentic-keys` | Volume reaches the pod VM through `virtiofsd`; **untested here** |
| Maturity | Validated end to end by this module against the 2026.5.1000 chart | Validated end to end, but not with Pod Sandboxing |

`azureblob` is the default. It is the backend Sonar supports for Azure, it is the stronger
isolation model for an untrusted runtime, and it sidesteps the sandboxing question entirely — the
library's own documentation notes that with a filesystem backend "isolation between jobs and
tenants is a deployment concern rather than something the library enforces with signed URLs."
It has now been exercised end to end against the 2026.5.1000 chart with Pod Sandboxing enabled.

`azurefiles` remains supported as the fallback where policy forbids blob endpoints. Its
interaction with Kata sandboxing is still uncovered by this module's testing.

Blob needs `type: AZURE` plus `azure.container` and `azure.connection-string` under each
component's storage prefix. The chart exposes no dedicated Azure fields and its
`agentOrchestrator.storage.type` comment omits `AZURE`, but that is a documentation gap rather
than a capability gap — the Orchestrator reads the same library under
`sonar.agentic.orchestrator.storage.`, so this module supplies those two settings through the
chart's generic `env` passthrough. The runtimes receive no storage configuration at all on either
backend; they act on locators.

MinIO is separately ruled out: its images are no longer anonymously pullable
(`quay.io/minio/minio` returns 401 repo-wide).

**On `azurefiles`, the custom StorageClass is load-bearing and its modes are a reference setting.** AKS's built-in
`azurefile-csi` sets no `uid`, `gid` or `file_mode`, so an SMB mount lands root-owned and the
agentic containers — uid 900, 1000 and 10001 — cannot write to it. Without permissive modes the
shares still bind and the pods still start; jobs fail later, on write. The `0777` defaults are what was validated and are appropriate for a lab **only**. On a filesystem
backend the mount permissions are the isolation boundary between untrusted runtimes — the library
does not enforce it with signed URLs — so for anything beyond evaluation set `share_gid` to a gid
the pods carry, drop the modes to `0770`, add a matching pod `fsGroup`, and retest the write. The
per-runtime `subPath` mounts limit what each runtime sees, but permissive modes weaken that.

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
- **Azure Files has not been exercised with Pod Sandboxing enabled.** The validated run used
  chart 2026.4.1, which deploys no agent runtimes, so no sandboxed pod ever mounted either share.
  The earlier internal deployment that did run the agentic components used S3 object storage, where
  the runtime reaches storage over the network and never mounts a volume. Kata plus an SMB volume
  through `virtiofsd` is therefore untested here, and Microsoft documents IOPS caveats for Kata on
  Azure Files. Validate it, or use object storage, or run without sandboxing.
- **The agentic components have not been exercised from this configuration.** A full apply and
  destroy were validated against published chart 2026.4.1, which accepts the agentic values but
  does not implement them. That proves the infrastructure, shares, mounts, secrets and release
  mechanism — not that the agentic containers can read and write those shares.
- **Azure Files is SMB.** Throughput and IOPS differ from managed disks, and Standard tier is the
  default here. Raise to `Premium_LRS` in the StorageClass if job staging is slow.
- **SonarQube Server cannot receive the blob connection string through an environment
  variable.** The object-store library reads `azure.connection-string`, hyphenated. The
  Orchestrator and Vortex are Spring Boot and bind it from `SONAR_..._CONNECTION_STRING` through
  relaxed binding; the Server maps `SONAR_X_Y` to `sonar.x.y` and can never emit the hyphen, so
  the value silently never binds and the Server aborts at startup with "Invalid connection
  string". This module routes the Server through the chart's `sonarSecretProperties` instead,
  which merges a secret into `sonar.properties`. Keep that wiring if you fork the storage code.

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

### Validated on 2026-09-29 — agentic stack on `azureblob`

A full apply in `northeurope` with `enable_agentic = true`, `enable_pod_sandboxing = true` and
`storage_backend = "azureblob"`, against chart `2026.5.1000` built from source (the package was
not yet published):

| | |
| --- | --- |
| All seven pods | `1/1 Running`, zero restarts |
| SonarQube Server | resolved `sonar.agentic.storage.azure.connection-string`; no "Invalid connection string" |
| Blob containers | `agent-jobs` and `vortex-context` created |
| Agent runtimes | scheduled to the sandbox pool under RuntimeClass `kata-vm-isolation` |
| Kata isolation | genuine — guest kernel `6.6.137.mshv1-1.azl3` vs host `6.6.137.mshv2-2.azl3` |
| Runtime storage | none; the only volume on a runtime pod is `agentic-keys` |
| Repeat `terraform plan` | `No changes` |

Two defects surfaced only at runtime, neither reachable by `terraform validate` or
`helm template`: the Server's connection-string binding (above), and the sandbox pool pinning
`node_count = 0` against its own autoscaler, which scaled the pool back to zero on the *second*
apply and evicted both runtimes. Both are fixed here.

Not covered: a Hunter or Remediation job executed end to end, which needs a licence, an LLM
provider and a bound project.

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
