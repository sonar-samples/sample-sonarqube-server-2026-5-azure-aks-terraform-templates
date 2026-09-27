# SonarQube Server 2026.5 Enterprise with AI agents on Azure AKS

Terraform for an AKS cluster that runs SonarQube Server 2026.5 Enterprise and, optionally, the
2026.5 AI agents — Sonar Vortex, the SonarQube Remediation Agent, and the SonarQube Hunter Agent.

Provisions a resource group, an AKS cluster with a system pool and an optional pod sandboxing
pool, Azure Database for PostgreSQL Flexible Server, in-cluster S3-compatible storage, the
Kubernetes secrets the chart expects, and the SonarQube Helm release from the official chart
repository.

## Release status — read before setting a chart version

**Verified 2026-09-27: there is no published 2026.5 chart. The agentic pack is not installable
from the official Helm repository yet.**

| | |
| --- | --- |
| Published index (`SonarSource.github.io/helm-chart-sonarqube`) | newest `sonarqube` chart is **2026.4.1**. No 2026.5.x. |
| GitHub `master` | `charts/sonarqube/Chart.yaml` declares **2026.5.1000**, and all seven agentic value blocks are present |
| `appVersion` on `master` | still **2026.4.0**, so the default Enterprise image resolves to `sonarqube:2026.4.0-enterprise` |

**A source merge is not a release.** The published Helm index is the release authority for
customers. Do not install from a git checkout of `master` and do not treat 2026.5.1000 as
available until it appears in that index.

### Release acceptance criteria

Run all four before setting `enable_agentic = true`. Every one must pass.

```sh
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update

# 1. A 2026.5.x chart is published
helm search repo sonarqube/sonarqube --versions | head -20

# 2. appVersion is 2026.5
helm show chart sonarqube/sonarqube --version <2026.5-version> | grep -E '^(version|appVersion):'

# 3. All four agentic value blocks exist
helm show values sonarqube/sonarqube --version <2026.5-version> \
  | grep -E '^(agentOrchestrator|hunterAgent|remediationAgent|vortexAnalysis):'

# 4. The Enterprise image resolves to 2026.5
helm template sonarqube sonarqube/sonarqube --version <2026.5-version> \
  --set edition=enterprise | grep -E 'image:.*sonarqube'
```

### The appVersion trap

Criterion 2 is not bookkeeping. The chart composes the Server image tag from `Chart.AppVersion`
whenever `edition` is set and `image.tag` is not:

```
{{- $imageTag = printf "%s-%s" .Chart.AppVersion .Values.edition -}}
```

So against a 2026.5.1000 chart whose appVersion is still 2026.4.0, `edition: enterprise` alone
deploys **SonarQube 2026.4** with no error anywhere. That is why `sonarqube_image_tag` exists:
set it explicitly until criterion 2 passes, and verify after deploying with
`curl .../api/server/version`.

### What this means for you today

- `enable_agentic` defaults to **false**. With it false this deploys SonarQube Server Enterprise
  on AKS from the current published chart — useful and complete on its own.
- `sonarqube_chart_version` has **no default**. Pin a version you confirmed with criterion 1.
- Set `sonarqube_image_tag` until criterion 2 passes.

The internal early-access path used to validate the agentic components — Repox, a private ECR,
and pre-GA licensing — is not a customer distribution path and is deliberately absent from this
configuration. Once released, customers use the official chart and public images, and may mirror
those images into their own registry for air-gapped or registry-policy reasons.

## Layout

| File | Contents |
| --- | --- |
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | azurerm, kubernetes and helm provider configuration |
| `variables.tf` | All inputs |
| `main.tf` | Resource group, AKS cluster, pod sandboxing node pool |
| `postgres.tf` | PostgreSQL Flexible Server, database, firewall rule |
| `storage.tf` | Namespace, Azure Files StorageClass, and two ReadWriteMany shares |
| `secrets.tf` | Database, monitoring and agentic signing secrets |
| `sonarqube.tf` | The SonarQube Helm release |
| `sonarqube-values.yaml.tftpl` | Helm values, templated on the inputs |
| `outputs.tf` | Connection details and helper commands |

## Usage

```sh
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan
terraform apply
```

Then:

```sh
$(terraform output -raw get_credentials_command)
$(terraform output -raw port_forward_command)
```

SonarQube is at `http://127.0.0.1:9000`. Apply your license under **Administration →
Configuration → License Manager** and change the admin password.

### Enabling settings encryption

SonarQube generates its own settings encryption key, so it cannot be created before the server
runs. After first boot:

1. **Administration → Configuration → Encryption → Generate Secret Key**, save it to a file.
2. `kubectl create secret generic sonarqube-encryption-secret -n sonarqube --from-file=sonar-secret.txt=./sonar-secret.txt`
3. Set `enable_settings_encryption = true` and re-apply.

This key encrypts stored LLM provider credentials and is mounted into the Agent Orchestrator, so
do it before enabling the agents.

## Requirements

- Terraform >= 1.7, Azure CLI >= 2.80.0 (`az login`), `kubectl`, Helm 3.
- A SonarQube Server Enterprise license. The Hunter Agent and Remediation Agent are separate
  subscriptions on top of it.
- A region that satisfies all three of: permitted by any allowed-locations Azure Policy, has
  Total Regional vCPU headroom, and offers a generation 2 nested-virtualization VM size.
- Any resource tags your subscription policy mandates, via `var.tags`. A tag policy denies the
  very first resource, so check before the first apply.

When `enable_agentic = true`, register Azure Pod Sandboxing first:

```sh
az feature register --namespace Microsoft.ContainerService -n KataVMIsolationPreview
az feature show --namespace Microsoft.ContainerService -n KataVMIsolationPreview \
  --query properties.state -o tsv     # wait for: Registered
az provider register --namespace Microsoft.ContainerService
```

## Design notes

**Pod sandboxing, not gVisor.** AKS has no gVisor. The chart's `gvisor.installer` is a privileged
DaemonSet that rewrites containerd configuration, which AKS manages itself. This configuration
sets `gvisor.enabled = false` and uses `agentRuntimeSandbox` with the AKS-provided RuntimeClass.
Confirm the name on your cluster — older clusters use `kata-mshv-vm-isolation`:

```sh
kubectl get runtimeclass
```

Also check whether it carries a `scheduling.nodeSelector`. Kubernetes merges that into every
runtime pod; a key colliding with the `workload: sandbox` selector here would make the pods
permanently unschedulable.

**Tolerations are per-component.** The sandbox pool is tainted, so a node selector alone leaves
runtime pods pending. Tolerations are set on `hunterAgent` and `remediationAgent` only — a
release-wide toleration would make SonarQube Server itself eligible for a sandbox node.

**Two storage secrets with the same credentials.** The Orchestrator reads `AGENTIC_STORAGE_*`;
Vortex reads `SONAR_AGENTIC_STORAGE_*`. Both key names are read literally by the chart.

**Azure Files, not MinIO.** Azure Blob Storage has no S3-compatible API, and the MinIO container
images are no longer anonymously pullable — `quay.io/minio/minio` returns 401 repo-wide, so an
in-cluster MinIO would require registry credentials before you could finish the install. This
configuration provisions two `ReadWriteMany` Azure Files shares instead: one for agent job
artifacts, one for Vortex analyzer context. A filesystem backend needs no storage credentials at
all, and it leaves the LLM provider as the only entry in the egress allowlist.

**The custom StorageClass is load-bearing.** AKS's built-in `azurefile-csi` sets no `uid`, `gid`
or `file_mode`, so an SMB mount lands root-owned and the agentic containers — which run as uid
900, 1000 and 10001 — cannot write to it. `sonarqube-agentic-files` sets `dir_mode=0777` and
`file_mode=0777`, which also avoids the shared-`fsGroup` coordination the chart warns about for
block storage. Verified: a non-root container writes to the share successfully. Without this
class, the PVCs still bind and the pods still start — jobs fail later, on write.

**Subdirectory isolation.** The Orchestrator mounts the jobs share at its root and writes each
runtime's jobs into a subdirectory named after that runtime. Each runtime mounts only its own
subdirectory via `subPath`, so neither can see the other's files. Chart validation requires each
component's `extraVolumeMounts` path to sit at or above its `storage.filesystem.baseDir`.

**Two shares, not one.** Agent job artifacts and Vortex analyzer context have opposite retention
lifecycles. The `deleteOlderThan` housekeeping settings apply to job artifacts only; a short
lifecycle policy on the context share deletes context that is still current. SonarQube Server
writes the context share and Vortex mounts it read-only.

**PostgreSQL uses a public endpoint restricted to the cluster's outbound IP.** This keeps the
module self-contained. For a delegated subnet with no public endpoint, see
[Installing SonarQube Server Enterprise on Azure AKS](https://www.sonarsource.com/developers/blueprints/installing-sonarqube-server-enterprise-on-azure-aks/).

## Known limitations

- **No ingress.** Access is by port-forward. CI scanners cannot reach the server, so this is not a
  complete deployment on its own — add Application Gateway, DNS and TLS from the blueprint above.
- **The agentic components have not been exercised from this configuration.** A full apply was
  validated on 2026-09-27 against published chart 2026.4.1, which accepts the agentic values but
  does not implement them. That proves the infrastructure, the shares, the mounts, the secrets and
  the release mechanism; it does not prove the agentic containers can read and write those shares.
  That needs a published chart that ships them.
- **Azure Files is SMB.** Throughput and IOPS differ from managed disks, and the Standard tier is
  the default here. Raise to `Premium_LRS` in the StorageClass if job staging is slow.

### Validated on 2026-09-27

A full `apply` and `destroy` cycle in `northeurope` against chart 2026.4.1:

| | |
| --- | --- |
| 18-resource apply | completed, `sonarqube_status = "deployed"` |
| Kubernetes version | resolved from the region default (`1.36.3`) rather than pinned |
| `node_provisioning_profile { mode = "Manual" }` | accepted by the Azure API |
| AKS egress IP lookup and PostgreSQL firewall rule | resolved and created |
| Azure Files RWX shares | both Bound; non-root container write confirmed |
| Explicit `sonarqube_image_tag` | produced `2026.4.1.126914`, overriding appVersion composition |
| `terraform destroy` | 17 resources destroyed, resource group removed, no leftovers |

The destroy path completed cleanly despite the providers reading credentials from the cluster
being deleted. That pattern is still a theoretical weak point on a refresh after the cluster is
removed out of band, but a normal destroy works.

## Teardown

```sh
terraform destroy
```

This deletes the database and every analysis result with it.
