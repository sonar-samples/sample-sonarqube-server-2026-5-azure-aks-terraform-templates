# SonarQube Server 2026.5 Enterprise Edition with agentic components - Azure AKS Installation

This repository contains Terraform templates for deploying SonarQube Server 2026.5 Enterprise Edition on Azure Kubernetes Service (AKS), optionally with the 2026.5 agentic components: Sonar Vortex analysis, the Agent Orchestrator, SonarQube Hunter Agent, and SonarQube Remediation Agent.

It extends [sonarqube-server-azure-aks-installation](https://github.com/sonar-solutions/sonarqube-server-azure-aks-installation) with the agentic components, so one `terraform apply` produces an HTTPS endpoint with private networking, no public database or storage endpoint, and isolated agent workloads. This repo contains only the Terraform templates.

`enable_agentic` defaults to `false`. With it off, this deploys SonarQube Server Enterprise Edition behind Application Gateway without the agentic capabilities.

## Infrastructure Components

| Component | Azure Service |
|-----------|--------------|
| Container Orchestration | Azure Kubernetes Service (AKS), Azure CNI overlay, Cilium network policy |
| Node Pools | `system` (add-ons only), `sonarqube` (Server only, tainted), `agentic` (agentic workloads, tainted, `enable_agentic = true` only) |
| Database | Azure Database for PostgreSQL Flexible Server (v16, zone-redundant HA, private VNet access) |
| Agentic Storage | Azure Blob Storage with a private endpoint (agent job artifacts, Vortex analyzer context) |
| HTTPS / Ingress | Azure Application Gateway (Standard_v2) |
| TLS Certificate | Let's Encrypt via ACME DNS-01, issued on apply |
| Networking | Azure Virtual Network with `aks`, `appgw`, `postgresql` and `private` subnets |
| DNS | Azure DNS (A record in an existing zone), private DNS zones for PostgreSQL and Blob |
| Monitoring | Azure Log Analytics + Container insights |
| Persistent Storage | Azure Managed Disk (managed-csi) |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) and [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and operational (`az login`)
- A SonarQube Server Enterprise Edition license, plus entitlement for each agentic capability you enable. SonarQube Server must use the new license management, not Server ID based licensing.
- An existing Azure DNS zone for your domain, delegated from your registrar
- **DNS Zone Contributor** on that zone for the identity running Terraform. With the default `sonarqube_exposure = "internal"`, that identity also needs **Owner** (or Contributor plus User Access Administrator), because the templates grant the cluster identity Network Contributor on the VNet. With Contributor alone, use `gateway-restricted`.
- No Azure Policy that disables shared key access on storage accounts. The agentic storage library authenticates to Azure Blob by connection string only.
- A region your Azure Policy allows for both resources and resource groups, with vCPU and AKS cluster quota for three node pools. AKS creates its own node resource group (`MC_...`) in the cluster's region, so a resource group location policy applies even when `create_resource_group = false`. Zone-redundant PostgreSQL HA is not offered in every region or subscription (`az postgres flexible-server list-skus -l <region>`).
- An exact published chart version, `2026.5.1000` or later: `helm repo update && helm search repo sonarqube/sonarqube --versions`

These templates deploy the agent runtimes with the standard, supported Kubernetes configuration and do not configure alternative runtime sandboxing technologies. Organizations with platform-mandated workload-isolation controls should validate those controls independently against their AKS environment and the released SonarQube chart.

## Quick Start

```bash
git clone https://github.com/sonar-samples/sample-sonarqube-server-2026-5-azure-aks-installation.git
cd sample-sonarqube-server-2026-5-azure-aks-installation

# Edit terraform.tfvars.json with your specific values
cp terraform.tfvars.json.example terraform.tfvars.json

# Run Terraform commands
terraform init
terraform plan
terraform apply
```

Access SonarQube at `https://<host_name>.<domain_name>` (`terraform output -raw sonarqube_url`).
Default login: `admin` / `admin` (change immediately). Apply your license under **Administration > Configuration > License manager**.

Application Gateway is the slowest resource and can take up to an hour to provision.

> **The certificate is issued automatically but renews only when Terraform runs.** Terraform requests, validates, and installs a trusted Let's Encrypt certificate as part of `terraform apply`, and re-issues it on any plan or apply within 30 days of expiry. Run `terraform apply` from a scheduled pipeline at least every two weeks and alert on the `certificate_not_after` output.

### Settings Encryption

SonarQube generates its own key, so the secret cannot exist before the server runs. After first boot:

1. **Administration > Configuration > Encryption > Generate Secret Key**, and save it to `sonar-secret.txt`.
2. `kubectl create secret generic sonarqube-encryption-secret -n sonarqube --from-file=sonar-secret.txt=./sonar-secret.txt`
3. Set `enable_settings_encryption` to `true` and re-apply.

This key encrypts stored LLM provider credentials and is mounted into the Agent Orchestrator, so do it before enabling the agentic capabilities.

## Configuration Values

Copy `terraform.tfvars.json.example` into `terraform.tfvars.json` and update the specific values for your environment:

```json
{
  "subscription_id": "00000000-0000-0000-0000-000000000000",
  "location": "westeurope",

  "resource_group_name": "sonarqube-2026-5",
  "cluster_name": "sonarqube-aks",
  "postgres_name": "sonarqube-pg-changeme",
  "db_username": "sonarqube",

  "domain_name": "example.com",
  "dns_resource_group_name": "dns-zones",
  "host_name": "sonarqube",
  "acme_email": "platform-team@example.com",

  "vnet_cidr": "10.0.0.0/16",
  "aks_subnet_cidr": "10.0.1.0/24",
  "appgw_subnet_cidr": "10.0.2.0/24",
  "postgresql_subnet_cidr": "10.0.3.0/28",
  "private_subnet_cidr": "10.0.4.0/24",

  "sonarqube_exposure": "internal",

  "kubernetes_version": null,

  "sonarqube_chart_version": "2026.5.1001",
  "sonarqube_image_tag": "",

  "enable_agentic": false,
  "agentic_paused": false,
  "runtime_replica_count": 1,

  "agentic_images": {
    "vortex":       { "repository": "", "tag": "" },
    "orchestrator": { "repository": "", "tag": "" },
    "hunter":       { "repository": "", "tag": "" },
    "remediation":  { "repository": "", "tag": "" }
  },

  "llm_allowed_domains": ["api.anthropic.com"],

  "storage_backend": "azureblob",
  "storage_account_name": "acmesqagentic01",

  "enable_settings_encryption": false,

  "tags": {
    "Team": "",
    "Owner": ""
  }
}
```

**Notes:**
- `subscription_id`, `sonarqube_chart_version`, `domain_name`, `dns_resource_group_name`, `acme_email`, and (with the agentic components) `storage_account_name` have no usable default. `postgres_name` and `storage_account_name` must be globally unique.
- `sonarqube_exposure`: `internal` (default) puts SonarQube Server on an internal load balancer and creates a role assignment. `gateway-restricted` needs no role assignment: the Server gets a public IP in the AKS node resource group that admits only the Application Gateway's public IP.
- `create_resource_group`: defaults to `true`. Set `false` to deploy into an existing resource group named `resource_group_name`.
- `enable_agentic`: deploys Vortex, the Orchestrator, both agent runtimes, and their node pool, storage, and secrets. Setting it back to `false` destroys all of that, including stored data. Use `agentic_paused` for upgrades (see Upgrade).
- `llm_allowed_domains`: every runtime destination, including LLM, identity/token, and DevOps endpoints. The Blob storage host is added automatically.
- `runtime_replica_count`: concurrent jobs per runtime. Replicas are fixed, so add `agentic_node_count` capacity as you raise it.
- `postgres_high_availability`: set `false` where zone-redundant HA is not offered.
- Subnet, pod, and service CIDRs must not overlap each other or any network you peer with.
- `acme_server_url` is not shown above but can be set to `https://acme-staging-v02.api.letsencrypt.org/directory` for trial runs. Let's Encrypt production allows only a few certificates per week for the same hostname, and every destroy-and-reapply issues a new one.
- `agentic_images` overrides are optional; set them when mirroring the official images to a private registry.
- Every input is documented in `variables.tf`.

## Configuration Files

| File | Description |
|------|-------------|
| `main.tf` | Providers |
| `variables.tf` | Variable definitions |
| `network.tf` | VNet, subnets, cluster network role, public IPs |
| `aks.tf` | Resource group, AKS cluster, `system`, `sonarqube` and `agentic` node pools |
| `postgresql.tf` | PostgreSQL Flexible Server with zone-redundant HA, database, private DNS |
| `storage.tf` | Namespace, private Blob storage account, private endpoint and containers (or Azure Files shares) |
| `tls.tf` | ACME registration and certificate issuance via DNS-01 challenge |
| `appgateway.tf` | Application Gateway with HTTPS, ACME certificate, backend routing |
| `dns.tf` | DNS A record in the existing Azure DNS zone |
| `monitoring.tf` | Log Analytics workspace |
| `secrets.tf` | Database, monitoring, and agentic signing secrets |
| `sonarqube.tf` | SonarQube Helm release and values overlay, including the agentic components |
| `sonarqube-values.yaml` | Static Helm chart values |
| `outputs.tf` | Access URL, addresses, certificate expiry, helper commands |
| `tests/plan_matrix.tftest.hcl` | Offline plan across every option combination (`terraform test`) |

## Resources Created

| Resource | Name |
|----------|------|
| Resource Group | `<resource_group_name>` (unless `create_resource_group = false`) |
| Virtual Network + Subnets | `<cluster_name>-vnet` (`aks`, `appgw`, `postgresql`, `private`) |
| AKS Cluster | `<cluster_name>` |
| System Node Pool | `system` (Standard_D4s_v5, 2 nodes, CriticalAddonsOnly) |
| SonarQube Node Pool | `sonarqube` (Standard_D8ds_v5, 1 node, tainted) |
| Agentic Node Pool | `agentic` (Standard_D8s_v5, 2 nodes, tainted, `enable_agentic = true` only) |
| Application Gateway | `<cluster_name>-appgw` |
| PostgreSQL Flexible Server | `<postgres_name>` (v16, zone-redundant HA, private VNet access) |
| PostgreSQL Database | `sonarqube` |
| Storage Account | `<storage_account_name>` (Blob, private endpoint, `agent-jobs` and `vortex-context` containers) |
| TLS Certificate | `<host_name>.<domain_name>` (Let's Encrypt) |
| DNS A Record | `<host_name>.<domain_name>` |
| Log Analytics Workspace | `<cluster_name>-logs` |
| Helm Release | `sonarqube` (Enterprise Edition, agentic components when enabled) |

## Verification

Check the endpoint. Expect `"status":"UP"`, then `301` to the HTTPS URL:

```bash
SONAR_URL=$(terraform output -raw sonarqube_url)
curl -s "$SONAR_URL/api/system/status"; echo
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" "http://${SONAR_URL#https://}/"
```

With `gateway-restricted`, this direct request to the Server must time out:

```bash
curl -sS -o /dev/null --connect-timeout 8 "http://$(terraform output -raw sonarqube_backend_ip):9000"
```

Point CI scanners at `$SONAR_URL` and search the scanner log for `413`. A rejected analyzer-context upload is non-fatal to the scan, so Vortex silently loses context. Standard_v2 enforces no body limit; on WAF_v2, raise `max_request_body_size_in_kb` and `file_upload_limit_in_mb`.

With the agentic components enabled, confirm that each runtime reaches its allowlisted hosts only through the egress proxy. The direct check uses an IP because the runtime NetworkPolicy allows no DNS:

```bash
NS=sonarqube
LLM_HOST=<provider-hostname>   # one entry from llm_allowed_domains
BLOB_HOST=$(terraform output -raw blob_endpoint)
LLM_IP=$(kubectl exec -n "$NS" deploy/sonarqube-sonarqube-agent-egress-proxy -- \
  getent ahostsv4 "$LLM_HOST" | awk 'NR==1 {print $1}')

for family in hunter remediation; do
  echo "== $family"
  kubectl exec -n "$NS" "deploy/sonarqube-sonarqube-agent-runtime-$family" -- \
    env LLM_HOST="$LLM_HOST" LLM_IP="$LLM_IP" BLOB_HOST="$BLOB_HOST" bash -c '
      via() { curl -sS -o /dev/null -w "%{http_connect}" --max-time 15 "https://$1" 2>/dev/null; }
      echo "LLM via proxy:      $(via "$LLM_HOST")"
      [ -n "$BLOB_HOST" ] && echo "Blob via proxy:     $(via "$BLOB_HOST")"
      echo "Unlisted via proxy: $(via example.com)"
      curl -sS -o /dev/null --noproxy "*" --connect-timeout 5 \
        --resolve "$LLM_HOST:443:$LLM_IP" "https://$LLM_HOST" 2>/dev/null
      rc=$?
      case $rc in
        7|28) echo "Direct to LLM IP:   blocked (curl exit $rc)" ;;
        *)    echo "Direct to LLM IP:   CONNECTED (curl exit $rc)" ;;
      esac'
done
```

Expect `200`, `200`, `403`, and `blocked` for both runtimes. `CONNECTED` means the proxy was bypassed and NetworkPolicy is not enforced.

These templates were validated end to end on 2026-10-01 in westeurope with chart `2026.5.1001` (SonarQube Server `2026.5.1`, agentic images `2026.5.0`) and `sonarqube_exposure = "gateway-restricted"`: every check above passed, the Enterprise license was applied, and the agentic capabilities were enabled and run. The default `internal` exposure has not yet been validated on a live subscription.

## Notes

- **Only SonarQube Server is reachable from outside the cluster.** The agentic API is served in-process by the Server, so the Orchestrator, Vortex, the egress proxy, and both runtimes stay `ClusterIP`. With `gateway-restricted`, gateway-to-Server traffic is HTTP over the Server's restricted public IP.
- **Cilium enforces the chart's NetworkPolicies.** AKS accepts NetworkPolicy objects on a cluster with no policy engine and enforces none of them.
- **Every agentic component is pinned to the `agentic` pool explicitly.** The chart falls back to the Server's `nodeSelector` and `tolerations` for any component that sets none, which would co-schedule the runtimes with the Server.
- **Keep private ranges out of the egress proxy's `egressExcludeCidrs`.** The Blob private endpoint sits on a VNet address, and the runtimes reach it through the proxy.
- **`gvisor.enabled` is set to `false` deliberately.** The chart default deploys a privileged installer DaemonSet that rewrites containerd configuration, which is unsupported on AKS managed nodes.
- **SonarQube Server cannot take the Blob connection string from an environment variable.** It maps `SONAR_X_Y` to `sonar.x.y` and can never produce the hyphen in `azure.connection-string`, so the templates pass it through `sonarSecretProperties`.
- **Change `location` by destroying first.** Re-applying with a new region replaces the VNet but plans its subnets as unchanged, and that apply fails. If AKS returns `AKSCapacityHeavyUsage`, the region is refusing new clusters.
- **Reusing a storage account name straight after a destroy can leave stale DNS.** Pick a fresh `storage_account_name` per run.

## Upgrade

SonarQube Server restarts into `DB_MIGRATION_NEEDED` after an upgrade, while its readiness probe still passes, and Vortex stays unready until the migration completes, so a one-shot `helm upgrade` times out. Back up the database first, then sequence it:

```bash
# 1. Set sonarqube_chart_version to the new release and agentic_paused = true, then
terraform apply

# 2. Migrate the database. Browse /setup, or:
curl -s -u <admin>:<password> -X POST https://<host_name>.<domain_name>/api/system/migrate_db
curl -s https://<host_name>.<domain_name>/api/system/db_migration_status   # wait for MIGRATION_SUCCEEDED
curl -s https://<host_name>.<domain_name>/api/system/status                # wait for UP

# 3. Set agentic_paused = false, then
terraform apply
```

Use `agentic_paused`, never `enable_agentic = false`, for this. `agentic_paused` changes only the Helm release; `enable_agentic = false` destroys the agentic node pool, storage account, and stored data.

## Cleanup

```bash
terraform destroy
```

This removes everything the templates created, including PostgreSQL, the storage account, and all retained analysis, analyzer context, and artifact data. The Azure DNS zone (and an existing resource group used with `create_resource_group = false`) stays. Back up what you need first, and rotate or revoke the LLM and DevOps credentials you issued.

If the AKS cluster was deleted outside Terraform, remove the in-cluster resources from state, then destroy the rest:

```bash
terraform state list | grep -E '^(helm_release|kubernetes_)' | xargs terraform state rm
terraform destroy
```
