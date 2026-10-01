# SonarQube Server 2026.5 Enterprise Edition + agentic components on Azure AKS (v3)

Production-oriented Terraform templates for SonarQube Server 2026.5 Enterprise Edition on Azure
Kubernetes Service (AKS), optionally with the 2026.5 agentic components: Sonar Vortex analysis,
the Agent Orchestrator, SonarQube Hunter Agent and SonarQube Remediation Agent.

v3 merges the private networking, Application Gateway, automated TLS and DNS from
[sonarqube-server-azure-aks-installation](https://github.com/sonar-solutions/sonarqube-server-azure-aks-installation)
into the 2026.5 agentic templates, so one `terraform apply` produces an HTTPS endpoint with no
public database or storage endpoint.

`enable_agentic` defaults to `false`. With it off this deploys SonarQube Server Enterprise behind
Application Gateway, without the agentic capabilities.

## What it creates

| Component | Azure service | Purpose |
| --- | --- | --- |
| Virtual network | VNet with `aks`, `appgw`, `postgresql` and `private` subnets | Private network for every component |
| AKS cluster | Kubernetes Service, Azure CNI overlay, Cilium network policy | Runs SonarQube Server and the agentic workloads, and enforces the chart's NetworkPolicies |
| `system` node pool | 2× `Standard_D4s_v5`, `CriticalAddonsOnly` | Kubernetes add-ons only |
| `sonarqube` node pool | 1× `Standard_D8ds_v5`, tainted | SonarQube Server only |
| `agentic` node pool | 2× `Standard_D8s_v5`, tainted, `enable_agentic = true` only | Vortex, Orchestrator, egress proxy, key-derivation hook, both agent runtimes |
| PostgreSQL | Flexible Server 16, delegated subnet, private DNS, zone-redundant HA | SonarQube database, shared with the Orchestrator |
| Blob storage | Storage account with a private endpoint, two containers | Agent job artifacts and Vortex analyzer context |
| Server load balancer | AKS-managed. `internal`: fixed address in `private`. `gateway-restricted`: public IP in the node resource group that admits only the gateway | Application Gateway's only backend |
| Application Gateway | Standard_v2 | HTTPS on 443, HTTP-to-HTTPS redirect on 80 |
| TLS certificate | Let's Encrypt via ACME DNS-01 | Issued on apply, re-issued on apply inside the 30-day window |
| DNS record | A record in your existing Azure DNS zone | `<host_name>.<domain_name>` |
| Log Analytics | Workspace + Container insights | Container logs for every workload |
| SonarQube release | Helm | The official chart from the SonarSource repository |

## Prerequisites

- Terraform and Azure CLI installed and operational.
- An Enterprise Edition licence, plus entitlement for each agentic capability you enable
  (Enterprise Edition licensing alone does not enable them). SonarQube Server must use the new
  license management, not Server ID based licensing.
- An existing Azure DNS zone for your domain, delegated from your registrar.
- The identity running Terraform needs **DNS Zone Contributor** on the DNS zone for the ACME
  DNS-01 challenge. With the default `sonarqube_exposure = "internal"` it also needs **Owner** (or
  Contributor plus User Access Administrator), because the module grants the cluster identity
  Network Contributor on the VNet. With Contributor alone, use `gateway-restricted`.
- Shared key access must be allowed on storage accounts. The object-store library authenticates
  to Azure by connection string only; an Azure Policy that disables shared key access breaks it.
- A region permitted by any allowed-locations Azure Policy, with availability zones (for
  PostgreSQL HA) and vCPU headroom for all three pools, plus any tags your policy mandates.
  AKS creates its own node resource group (`MC_…`) in the cluster's region, so a policy that
  restricts *resource group* locations applies too, even when `create_resource_group = false`.
  Check the subscription's per-region AKS cluster quota as well (`az aks list` counts what is
  already used).
- **`az login` may not be sufficient.** The azurerm provider needs a Microsoft Graph-scoped token,
  and a Conditional Access policy can refuse it while ordinary `az` commands keep working.
  Confirm with `az account get-access-token --scope https://graph.microsoft.com/.default`.
- Pin an exact published chart version, `2026.5.1000` or later:
  `helm repo update && helm search repo sonarqube/sonarqube --versions`.

This module deploys the agent runtimes with the standard, supported Kubernetes configuration. It
does not configure alternative runtime sandboxing technologies. Organizations with
platform-mandated workload-isolation controls should validate those controls independently against
their AKS environment and the released SonarQube chart.

## Quick start

```sh
git clone https://github.com/sonar-solutions/sonarqube-server-2026-5-azure-aks-installation-v3.git
cd sonarqube-server-2026-5-azure-aks-installation-v3

cp terraform.tfvars.json.example terraform.tfvars.json
# Edit terraform.tfvars.json. subscription_id, sonarqube_chart_version, domain_name,
# dns_resource_group_name, acme_email and storage_account_name have no usable default.

terraform init
terraform plan
terraform apply
```

None of the `.tf` files need editing and all configuration resides in `terraform.tfvars.json`.
Use the Let's Encrypt staging directory (`acme_server_url`) for trial runs to avoid rate limits:
production allows only a handful of certificates per week for the same hostname, and every
destroy-and-reapply issues a new one. Application Gateway is the slowest resource; allow up to an
hour for it.

SonarQube is then served at `terraform output -raw sonarqube_url`. Apply your license under
**Administration → Configuration → License manager** and change the admin password when prompted.

### Settings encryption

SonarQube generates its own key, so it cannot exist before the server runs. After first boot:

1. **Administration → Configuration → Encryption → Generate Secret Key**, save it to a file.
2. `kubectl create secret generic sonarqube-encryption-secret -n sonarqube --from-file=sonar-secret.txt=./sonar-secret.txt`
3. Set `enable_settings_encryption = true` and re-apply.

This key encrypts stored LLM provider credentials and is mounted into the Orchestrator, so do it
before enabling the agentic capabilities. Use a file, not `--from-literal`, to keep the key out of
shell history.

## Configuration inputs

| Variable | Default | Description |
| --- | --- | --- |
| `subscription_id` | *(required)* | Azure subscription to deploy into |
| `sonarqube_chart_version` | *(required)* | An exact published version, `2026.5.1000` or later |
| `domain_name` | *(required)* | Existing Azure DNS zone, e.g. `example.com` |
| `dns_resource_group_name` | *(required)* | Resource group holding that zone |
| `acme_email` | *(required)* | ACME account email for expiry notices |
| `host_name` | `sonarqube` | Served at `https://<host_name>.<domain_name>` |
| `acme_server_url` | Let's Encrypt production | Set the staging directory while testing |
| `storage_account_name` | `""` | Required with the agentic components. Globally unique, 3–24 lowercase alphanumerics |
| `location` | `westeurope` | Must satisfy allowed-locations policy, zones and vCPU quota |
| `resource_group_name` | `sonarqube-2026-5` | |
| `sonarqube_exposure` | `internal` | `gateway-restricted` needs no role assignment; the Server's load balancer IP admits only the gateway |
| `create_resource_group` | `true` | `false` deploys into an existing resource group named `resource_group_name` |
| `cluster_name` | `sonarqube-aks` | |
| `postgres_name` | `sonarqube-pg` | Globally unique across Azure; `plan` will not catch a collision |
| `postgres_sku` | `GP_Standard_D4ds_v5` | |
| `postgres_high_availability` | `true` | Zone-redundant HA. `false` where the region or subscription does not offer it (`az postgres flexible-server list-skus -l <region>`) |
| `vnet_cidr`, `aks_subnet_cidr`, `appgw_subnet_cidr`, `postgresql_subnet_cidr`, `private_subnet_cidr` | `10.0.0.0/16`, `.1.0/24`, `.2.0/24`, `.3.0/28`, `.4.0/24` | Must not overlap each other or peered networks |
| `pod_cidr`, `service_cidr` | `10.244.0.0/16`, `10.2.0.0/16` | Overlay ranges; must not overlap the VNet |
| `system_vm_size` / `system_node_count` | `Standard_D4s_v5` / `2` | Add-ons only |
| `sonarqube_vm_size` | `Standard_D8ds_v5` | SonarQube Server, one node |
| `agentic_vm_size` / `agentic_node_count` | `Standard_D8s_v5` / `2` | Agentic pool |
| `enable_agentic` | `false` | Deploys Vortex, the Orchestrator and both agent runtimes, plus their node pool, storage and secrets. Setting it back to `false` destroys all of that, including stored data |
| `agentic_paused` | `false` | Upgrade switch: removes the agentic components from the Helm release but keeps their node pool, storage and data. See Upgrade |
| `runtime_replica_count` | `1` | Concurrent jobs per runtime |
| `agentic_images` | all blank | Optional overrides; set when mirroring to a private registry |
| `llm_allowed_domains` | `["api.anthropic.com"]` | Egress proxy allowlist. The blob host is added automatically |
| `storage_backend` | `azureblob` | `azurefiles` is the fallback where policy forbids blob endpoints |
| `enable_settings_encryption` | `false` | Turn on for the second apply |
| `tags` | `{}` | Applied to every Azure resource |

## Configuration files

| File | Contents |
| --- | --- |
| `main.tf` | Terraform and provider configuration |
| `variables.tf` | All inputs, documented in place |
| `network.tf` | VNet, subnets, cluster network role, gateway public IP |
| `aks.tf` | Resource group, AKS cluster, `system`, `sonarqube` and `agentic` pools |
| `postgresql.tf` | Private Flexible Server, private DNS, database |
| `storage.tf` | Namespace, private blob account and containers, or the Azure Files shares |
| `appgateway.tf` | Application Gateway listeners, backend, probe and redirect |
| `tls.tf` | ACME registration and certificate |
| `dns.tf` | Public A record |
| `monitoring.tf` | Log Analytics workspace |
| `secrets.tf` | Database, monitoring and agentic signing secrets |
| `sonarqube.tf` | The Helm release and its values overlay |
| `sonarqube-values.yaml` | Static base values |
| `outputs.tf` | URL, addresses, certificate expiry and helper commands |
| `tests/plan_matrix.tftest.hcl` | Offline plan across every on/off combination: `terraform test` |

## Notes

- **Only SonarQube Server is reachable from outside the cluster.** The agentic API is served
  in-process by the Server, so the Orchestrator, Vortex, the egress proxy and both runtimes stay
  `ClusterIP`. With `internal` exposure nothing but the gateway has a public address. With
  `gateway-restricted`, the Server's load balancer also has a public IP, but AKS writes an NSG rule
  that admits only the gateway's IP, and traffic from the gateway to the Server is HTTP over that
  address. Confirm a direct request to `sonarqube_backend_ip` on port 9000 times out.
- **Cilium enforces the chart's NetworkPolicies.** AKS accepts NetworkPolicy objects on a cluster
  with no policy engine and enforces none of them. Before production use, verify from inside each
  runtime pod that an allowlisted host connects through the proxy (`200`), an unlisted host is
  refused (`403`), and a direct connection to the allowlisted host's IP with the proxy bypassed
  fails with curl exit 7 or 28. The blueprint's "Verify runtime egress isolation" step has the
  copy-paste commands. Test the direct path by IP: the runtime policy allows no DNS, so a direct
  request by name fails at resolution and proves nothing about the connection.
- **Every agentic component is pinned to the `agentic` pool explicitly.** The chart falls back to
  the Server's top-level `nodeSelector` and `tolerations` for any component that sets none, which
  would co-schedule the runtimes with the Server. Keep the explicit scheduling if you fork
  `sonarqube.tf`.
- **Certificate renewal runs on apply.** The ACME provider re-issues the certificate during a plan
  or apply inside 30 days of expiry. Run `terraform apply` from a pipeline at least every two weeks,
  and alert on the `certificate_not_after` output.
- **Request-body limits.** Standard_v2 enforces none, so analyzer-context uploads pass. If policy
  requires WAF_v2, its policy's `max_request_body_size_in_kb` and `file_upload_limit_in_mb` apply
  in Prevention mode. A rejected upload is an HTTP 413 the scanner logs as non-fatal, so Vortex
  silently loses context.
- **Keep private ranges out of the proxy's `egressExcludeCidrs`.** The blob private endpoint sits
  on a VNet address, and the runtimes reach it through the proxy.
- **gvisor.enabled is set to false deliberately.** The chart default deploys a privileged installer
  DaemonSet that rewrites containerd configuration, unsupported on AKS managed nodes.
- **SonarQube Server cannot take the blob connection string from an environment variable.** It
  maps `SONAR_X_Y` to `sonar.x.y` and can never emit the hyphen in `azure.connection-string`, so
  this module routes it through `sonarSecretProperties`. Keep that wiring if you fork it.
- **Runtime replicas are fixed**, so the agentic pool stays provisioned. Add agentic nodes
  alongside `runtime_replica_count`.
- **Change `location` by destroying first, not by re-applying.** A plan for a new region replaces
  the VNet but updates its subnets in place, because they keep the same names. Deleting the VNet
  deletes the subnets, so that apply fails. Run `terraform destroy`, then apply with the new
  region. If AKS returns `AKSCapacityHeavyUsage`, the region is refusing new clusters; pick
  another one.
- **Reusing a storage account name straight after a destroy leaves stale DNS.** Pick a fresh
  `storage_account_name` per run or confirm from inside the cluster.

## Validation

Validated end to end on 2026-10-01 in westeurope with chart `2026.5.1001` (SonarQube Server
`2026.5.1`, agentic images `2026.5.0`), using `sonarqube_exposure = "gateway-restricted"`:

- HTTPS on the public hostname with a trusted Let's Encrypt certificate, HTTP redirected to HTTPS,
  gateway backend healthy, and the Server's own public IP unreachable except from the gateway.
- SonarQube Server on the `sonarqube` pool and every agentic workload on the `agentic` pool; all
  five derived signing-key secrets present.
- From inside the Hunter Agent and Remediation Agent pods: the LLM host and the blob host through
  the proxy return `200` (blob over the private endpoint at a `10.0.4.x` address), an unlisted host
  returns `403`, and a direct connection to the LLM host's IP is blocked (curl exit 28).
- Enterprise license applied and the agentic capabilities enabled and run.
- A repeat `terraform plan` after each apply reports no changes.

The default `internal` exposure, which creates a role assignment, has not yet been validated on a
live subscription.

## Upgrade

**Upgrading with the agentic components enabled needs a manual step inside the apply window.**
SonarQube does not migrate its own schema. After the Helm upgrade the Server restarts into
`DB_MIGRATION_NEEDED`, yet its readiness probe still passes, so
Kubernetes and Helm both report the pod healthy. Vortex health-checks against the Server, stays
un-ready, and `helm upgrade` blocks until it times out.

Sequence it rather than doing it in one shot, and back up the database first.

```sh
# 1. Upgrade the Server alone: set sonarqube_chart_version to the new release and
#    agentic_paused = true, then
terraform apply

# 2. Migrate the database. Browse /setup, or:
curl -s -u <admin>:<password> -X POST https://<host_name>.<domain_name>/api/system/migrate_db
curl -s https://<host_name>.<domain_name>/api/system/db_migration_status   # wait for MIGRATION_SUCCEEDED
curl -s https://<host_name>.<domain_name>/api/system/status                # wait for UP

# 3. Re-enable the agentic components: set agentic_paused = false, then
terraform apply
```

Use `agentic_paused`, never `enable_agentic = false`, for this. `enable_agentic` also controls the
agentic node pool, storage account and secrets, so turning it off destroys them along with the
stored analyzer context and job artifacts. `agentic_paused` changes only the Helm release.

## Cleanup

```sh
terraform destroy
```

This removes PostgreSQL, the blob containers, the Application Gateway, the DNS record and all
retained analysis, context and artifact data. The Azure DNS zone itself is not managed here and
stays. Back up what you need first, confirm retention requirements, and rotate or revoke the LLM
and DevOps credentials you issued.

If the AKS cluster was deleted outside Terraform, the destroy fails because Terraform can no
longer reach the cluster to remove the in-cluster resources. Remove those from state, then
destroy the rest:

```sh
terraform state list | grep -E '^(helm_release|kubernetes_)' | xargs terraform state rm
terraform destroy
```
