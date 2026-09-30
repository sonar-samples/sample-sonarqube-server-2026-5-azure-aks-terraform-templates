# SonarQube Server 2026.5 Enterprise Edition with agentic components — Azure AKS

Terraform templates for SonarQube Server 2026.5 Enterprise Edition on Azure Kubernetes Service (AKS), optionally with the
2026.5 agentic components: Sonar Vortex analysis, the Agent Orchestrator, the SonarQube Hunter
Agent, and the SonarQube Remediation Agent.

This repo is the templates only. The walkthrough — licensing, entitlement, LLM provider
registration, ingress and verification — lives in the blueprint *Installing SonarQube Server
2026.5 Enterprise and its agentic components on Azure AKS*. For SonarQube Server without the
agentic components, including private networking, Application Gateway and automated TLS, see
[sonarqube-server-azure-aks-installation](https://github.com/sonar-solutions/sonarqube-server-azure-aks-installation).

`enable_agentic` defaults to `false`. With it off this deploys SonarQube Server Enterprise on AKS
and nothing else, which is complete and useful on its own.

## What it creates

| Component | Azure service | Purpose |
| --- | --- | --- |
| Resource group | Resource Manager | Holds everything this module creates |
| AKS cluster | Kubernetes Service | Runs SonarQube Server and the agentic workloads |
| System node pool | Virtual Machine Scale Sets | All workloads: Server, Orchestrator, Vortex, egress proxy, both agent runtimes |
| PostgreSQL | Database for PostgreSQL Flexible Server | SonarQube database, shared with the Orchestrator |
| Blob storage account | Storage account, two containers | Agent job artifacts and Vortex analyzer context (default backend) |
| SonarQube release | Helm | The official chart from the SonarSource repository |

## Prerequisites

- Terraform >= 1.7, Azure CLI >= 2.80.0, `kubectl`, Helm 3.
- An Enterprise or Data Center Edition licence, plus entitlement for each agentic capability you
  enable. Edition licensing alone does not enable them.
- A region permitted by any allowed-locations Azure Policy, with Total Regional vCPU headroom for
  the system pool, and any resource tags your subscription policy mandates via `tags`. A tag or
  location policy denies the very first resource.
- **`az login` may not be sufficient.** The azurerm provider needs a Microsoft Graph-scoped token,
  and a Conditional Access policy can refuse it while ordinary `az` commands keep working — the
  error points at `provider "azurerm"` and gives no hint of the cause. Confirm with
  `az account get-access-token --scope https://graph.microsoft.com/.default`.
- Pin an exact published chart version. Agentic support needs `2026.5.1000` or later:
  `helm repo update && helm search repo sonarqube/sonarqube --versions`. Run `helm repo update`
  first or a cached index reports the old version.

This module deploys the agent runtimes with the standard supported Kubernetes configuration. It
does not configure alternative runtime sandboxing technologies. Organizations with
platform-mandated workload-isolation controls should validate those controls independently against
their AKS environment and the released SonarQube chart.

## Quick start

```sh
git clone https://github.com/sonar-solutions/sonarqube-server-2026-5-azure-aks-installation.git
cd sonarqube-server-2026-5-azure-aks-installation

cp terraform.tfvars.json.example terraform.tfvars.json
# Edit terraform.tfvars.json — subscription_id, sonarqube_chart_version and
# storage_account_name have no usable default.

terraform init
terraform plan
terraform apply
```

None of the `.tf` files need editing. All configuration lives in `terraform.tfvars.json`.

```sh
$(terraform output -raw get_credentials_command)
$(terraform output -raw port_forward_command)
```

SonarQube is then at `http://127.0.0.1:9000`. Apply your licence under **Administration →
Configuration → License manager** and change the admin password.

Port-forward is enough for administration but **not** for validating the agentic capabilities: CI
scanners must reach the deployed URL to upload analyzer context. Add ingress and TLS before
testing Vortex, Hunter or Remediation.

### Settings encryption

SonarQube generates its own key, so it cannot exist before the server runs. After first boot:

1. **Administration → Configuration → Encryption → Generate Secret Key**, save it to a file.
2. `kubectl create secret generic sonarqube-encryption-secret -n sonarqube --from-file=sonar-secret.txt=./sonar-secret.txt`
3. Set `enable_settings_encryption = true` and re-apply.

This key encrypts stored LLM provider credentials and is mounted into the Orchestrator, so do it
before enabling the agentic capabilities. Use a file, not `--from-literal`, to keep the key out of
shell history.

## Inputs

| Variable | Default | Description |
| --- | --- | --- |
| `subscription_id` | *(required)* | Azure subscription to deploy into |
| `sonarqube_chart_version` | *(required)* | An exact published version, `2026.5.1000` or later |
| `storage_account_name` | `""` | Required with `azureblob`. Globally unique, 3–24 lowercase alphanumerics |
| `location` | `westeurope` | Must satisfy allowed-locations policy and vCPU quota |
| `resource_group_name` | `sonarqube-2026-5` | |
| `cluster_name` | `sonarqube-aks` | |
| `postgres_name` | `sonarqube-pg` | Globally unique across Azure; `plan` will not catch a collision |
| `db_username` | `sonarqube` | |
| `kubernetes_version` | `null` | `null` takes the region's latest non-preview version |
| `system_vm_size` | `Standard_D8s_v5` | Sized for the agentic path; see Notes |
| `system_node_count` | `2` | |
| `sonarqube_image_tag` | `""` | Optional override. Empty composes the tag from the chart's appVersion |
| `enable_agentic` | `false` | Deploys Vortex, the Orchestrator and both agent runtimes |
| `runtime_replica_count` | `1` | Concurrent jobs per runtime |
| `agentic_images` | all blank | Optional overrides. Blank takes the chart default; set when mirroring to a private registry |
| `llm_allowed_domains` | `["api.anthropic.com"]` | Egress proxy allowlist |
| `storage_backend` | `azureblob` | `azureblob` for presigned SAS locators, `azurefiles` for a mounted share |
| `jobs_storage_size` / `vortex_storage_size` | `100Gi` | `azurefiles` only |
| `share_dir_mode` / `share_file_mode` | `0777` | `azurefiles` only. Reference setting; see Notes |
| `share_gid` | `0` | Set with `0770` modes for least privilege |
| `enable_settings_encryption` | `false` | Turn on for the second apply |
| `tags` | `{}` | Applied to every Azure resource |

## Files

| File | Contents |
| --- | --- |
| `main.tf` | Terraform and provider configuration |
| `variables.tf` | All inputs, documented in place |
| `aks.tf` | Resource group, AKS cluster, system node pool |
| `postgresql.tf` | Flexible Server, database, firewall rule |
| `storage.tf` | Namespace, blob containers, or the Azure Files StorageClass and shares |
| `secrets.tf` | Database, monitoring and agentic signing secrets |
| `sonarqube.tf` | The Helm release and its values overlay |
| `sonarqube-values.yaml` | Static base values; everything environment-specific is overlaid by `sonarqube.tf` |
| `outputs.tf` | Connection details and helper commands |
| `terraform.tfvars.json.example` | Copy to `terraform.tfvars.json` and edit |

## Notes

- **`gvisor.enabled` is set to `false` deliberately.** The chart defaults it to `true`, which
  deploys a privileged installer DaemonSet that rewrites containerd configuration — unsupported on
  AKS managed nodes. Turning it off is what gives the runtimes the standard Kubernetes
  configuration. `agentRuntimeSandbox` is left at its chart default, disabled.
- **The system pool is sized for the agentic path.** With `enable_agentic = true` it carries all
  six workloads, whose chart requests total roughly 3.8 vCPU and 20.5Gi of memory. The Hunter
  Agent alone requests 8Gi and Vortex 6Gi, so a 16Gi node cannot hold either alongside the Server.
  Drop to a smaller size only with `enable_agentic = false`.
- **Two storage backends, selected by `storage_backend`.** `azureblob` (default) hands the runtime
  a presigned SAS URL scoped to one object and one verb, expiring after the presign TTL, and
  mounts nothing — the stronger isolation model, and the path validated end to end. `azurefiles`
  hands it a `file://` path on a ReadWriteMany share, which makes mount permissions the isolation
  boundary. Blob requires `<account>.blob.core.windows.net` in the egress allowlist; Azure Files
  needs nothing there.
- **On `azurefiles` the custom StorageClass is load-bearing.** AKS's built-in `azurefile-csi` sets
  no `uid`, `gid` or `file_mode`, so an SMB mount lands root-owned and the agentic containers
  (uid 900, 1000, 10001) cannot write to it. The shares still bind and the pods still start; jobs
  fail later, on write. The `0777` default is a lab setting — for anything beyond evaluation set
  `share_gid` to a gid the pods carry, drop the modes to `0770`, add a matching pod `fsGroup`, and
  retest the write.
- **SonarQube Server cannot take the blob connection string from an environment variable.** The
  object-store library reads `azure.connection-string`, hyphenated; the Server maps `SONAR_X_Y` to
  `sonar.x.y` and can never emit the hyphen, so the value silently never binds and the Server
  aborts with "Invalid connection string". This module routes it through the chart's
  `sonarSecretProperties` instead. Keep that wiring if you fork the storage code.
- **PostgreSQL uses a public endpoint narrowed to the cluster's outbound IP.** A reference
  simplification that keeps the module self-contained, not a production baseline. For production,
  use a delegated subnet with private access and no public endpoint.
- **No ingress.** Access is by port-forward; add Application Gateway, DNS and TLS from the base
  repository.
- **Runtime replicas are fixed**, so the pool stays provisioned. True scale-to-zero needs
  validated chart autoscaling that drives runtime replicas to zero.
- **Reusing a storage account name straight after a destroy leaves stale DNS.** Azure may keep
  resolving the name to the deleted account for a while, so `az storage` calls from your machine
  fail with `ResourceNotFound` against storage the cluster is using happily. Confirm from inside
  the cluster, or pick a fresh `storage_account_name` per run.

## Upgrade

**Upgrading with the agentic components enabled needs a manual step inside the apply window.**
SonarQube does not migrate its own schema. After the Helm upgrade the Server restarts into
`DB_MIGRATION_NEEDED` and serves nothing useful, yet its readiness probe still passes, so
Kubernetes and Helm both report the pod healthy. Vortex health-checks against the Server, stays
un-ready, and `helm upgrade` blocks until it times out.

Sequence it rather than doing it in one shot. Back up the database first.

```sh
# 1. Upgrade the Server alone: set enable_agentic = false, then
terraform apply

# 2. Migrate the database. Browse /setup, or:
curl -s -u <admin>:<password> -X POST http://<host>/api/system/migrate_db
curl -s http://<host>/api/system/db_migration_status   # wait for MIGRATION_SUCCEEDED
curl -s http://<host>/api/system/status                # wait for UP

# 3. Re-enable the agentic components: set enable_agentic = true, then
terraform apply
```

`deploymentType` is deprecated and the Server becomes a `Deployment` rather than a `StatefulSet`,
so its pod name gains a random suffix. Address it by label selector, not by a literal pod name.

## Cleanup

```sh
terraform destroy
```

This removes PostgreSQL, the blob containers or file shares, and all retained analysis, context
and artifact data. Back up what you need first, confirm retention requirements, and rotate or
revoke the LLM and DevOps credentials you issued. If a provider resolution error appears after the
cluster was removed out of band, destroy `helm_release.sonarqube` first.
