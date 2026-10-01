# SonarQube Server 2026.5 Enterprise Edition with agentic components - Azure AKS Installation

This repository contains Terraform templates for deploying SonarQube Server 2026.5 Enterprise Edition on Azure Kubernetes Service (AKS), optionally with the agentic components: Sonar Vortex analysis, the Agent Orchestrator, SonarQube Hunter Agent, and SonarQube Remediation Agent.

## Infrastructure Components

| Component | Azure Service |
|-----------|--------------|
| Container Orchestration | Azure Kubernetes Service (AKS), Azure CNI overlay, Cilium network policy |
| Database | Azure Database for PostgreSQL Flexible Server (v16, zone-redundant HA, private VNet access) |
| Agentic Storage | Azure Blob Storage (private endpoint) |
| HTTPS / Ingress | Azure Application Gateway (Standard_v2) |
| TLS Certificate | Let's Encrypt via ACME - issued on apply |
| Networking | Azure Virtual Network |
| DNS | Azure DNS |
| Monitoring | Azure Log Analytics + Container insights |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) authenticated (`az login`)
- A SonarQube Server Enterprise Edition license, plus entitlement for each agentic capability you enable
- SonarQube Server must be using the [new license management](https://docs.sonarsource.com/sonarqube-server/2025.4/instance-administration/license-administration/online-license-management) and not Server ID based licensing.
- A registered domain with an Azure DNS zone, and DNS Zone Contributor on that zone

## Quick Start

```bash
# Edit terraform.tfvars.json with your specific values
cp terraform.tfvars.json.example terraform.tfvars.json

# Run Terraform commands
terraform init
terraform plan
terraform apply
```

Access SonarQube at `https://<host_name>.<domain_name>`
Default login: `admin` / `admin` (change immediately)

> **The certificate renews only when Terraform runs.** Terraform issues a trusted Let's Encrypt certificate during `terraform apply` and re-issues it on any apply within 30 days of expiry. Schedule `terraform apply` at least every two weeks.

## Configuration Values

Copy `terraform.tfvars.json.example` into `terraform.tfvars.json` and update the specific values for your environment:

```json
{
  "subscription_id": "00000000-0000-0000-0000-000000000000",
  "location": "westeurope",
  "resource_group_name": "sonarqube-2026-5",
  "cluster_name": "sonarqube-aks",
  "postgres_name": "sonarqube-pg-changeme",

  "domain_name": "example.com",
  "dns_resource_group_name": "dns-zones",
  "host_name": "sonarqube",
  "acme_email": "platform-team@example.com",

  "vnet_cidr": "10.0.0.0/16",
  "aks_subnet_cidr": "10.0.1.0/24",
  "appgw_subnet_cidr": "10.0.2.0/24",
  "postgresql_subnet_cidr": "10.0.3.0/28",
  "private_subnet_cidr": "10.0.4.0/24",

  "sonarqube_chart_version": "2026.5.1001",
  "sonarqube_exposure": "internal",

  "enable_agentic": false,
  "agentic_paused": false,
  "runtime_replica_count": 1,
  "llm_allowed_domains": ["api.anthropic.com"],
  "storage_account_name": "acmesqagentic01",

  "enable_settings_encryption": false,

  "tags": { "Team": "", "Owner": "" }
}
```

**Notes:**
- `sonarqube_chart_version` - pin an exact published version, `2026.5.1000` or later
- `sonarqube_exposure` - `internal` (default) uses an internal load balancer and grants the cluster Network Contributor on the VNet. `gateway-restricted` needs no role assignment: the Server gets a public IP that admits only the Application Gateway.
- `enable_agentic` - also creates the agentic node pool, storage, and secrets. Setting it back to `false` destroys them and their data; use `agentic_paused` for upgrades.
- `llm_allowed_domains` - every runtime destination (LLM, identity, DevOps). The Blob storage host is added automatically.
- Subnet CIDRs must not overlap each other or any network you peer with. `postgresql_subnet_cidr` requires at least a /28.
- `runtime_replica_count` - concurrent jobs per agent runtime
- `enable_settings_encryption` - set `true` on a second apply, after creating the `sonarqube-encryption-secret` from a key generated in the SonarQube UI
- `postgres_name` and `storage_account_name` must be globally unique
- Set `postgres_high_availability` to `false` where zone-redundant HA is not offered (`az postgres flexible-server list-skus -l <region>`)
- `create_resource_group` - set `false` to deploy into an existing resource group
- `acme_server_url` can be set to the Let's Encrypt staging URL (`https://acme-staging-v02.api.letsencrypt.org/directory`) for testing to avoid rate limits
- Every input is documented in `variables.tf`

## Configuration Files

| File | Description |
|------|-------------|
| `main.tf` | Providers |
| `network.tf` | VNet, subnets, public IPs |
| `aks.tf` | Resource group, AKS cluster, `system`, `sonarqube` and `agentic` node pools |
| `postgresql.tf` | PostgreSQL Flexible Server with zone-redundant HA, database, private DNS |
| `storage.tf` | Blob storage account, private endpoint, containers |
| `tls.tf` | ACME registration and certificate issuance via DNS-01 challenge |
| `appgateway.tf` | Application Gateway with HTTPS, ACME certificate, backend routing |
| `dns.tf` | DNS A record in the existing Azure DNS zone |
| `monitoring.tf` | Log Analytics workspace |
| `secrets.tf` | Kubernetes secrets, including the agentic signing secret |
| `sonarqube.tf` | SonarQube Helm release, including the agentic components |
| `sonarqube-values.yaml` | Helm chart values |
| `variables.tf` | Variable definitions |
| `outputs.tf` | Access URL, addresses, certificate expiry |

## Resources Created

| Resource | Name |
|----------|------|
| Virtual Network + Subnets | `<cluster_name>-vnet` (AKS, App Gateway, PostgreSQL, private endpoints) |
| AKS Cluster | `<cluster_name>` |
| System Node Pool | `system` (Standard_D4s_v5, 2 nodes) |
| SonarQube Node Pool | `sonarqube` (Standard_D8ds_v5, 1 node, tainted) |
| Agentic Node Pool | `agentic` (Standard_D8s_v5, 2 nodes, tainted, `enable_agentic = true` only) |
| Application Gateway | `<cluster_name>-appgw` |
| PostgreSQL Flexible Server | `<postgres_name>` (v16, zone-redundant HA, private VNet access) |
| Storage Account | `<storage_account_name>` (`enable_agentic = true` only) |
| TLS Certificate / DNS A Record | `<host_name>.<domain_name>` |
| Log Analytics Workspace | `<cluster_name>-logs` |
| Helm Release | `sonarqube` (Enterprise Edition) |

## Notes

- Before production use, confirm from inside each agent runtime pod that allowlisted hosts are reachable only through the egress proxy and that a direct connection is blocked. Cilium enforces the chart's NetworkPolicies; without a policy engine, AKS enforces none.
- A rejected analyzer-context upload (HTTP 413) does not fail the scan, so Vortex silently loses context. Standard_v2 enforces no body limit; on WAF_v2, raise the request body and file upload limits.
- To change `location`, run `terraform destroy` first. Re-applying in a new region fails.

## Upgrade

Set `agentic_paused` to `true` and update `sonarqube_chart_version`, then run `terraform apply`. Complete the database migration at `https://<host_name>.<domain_name>/setup`, wait for status `UP`, then set `agentic_paused` to `false` and apply again.

## Cleanup

```bash
terraform destroy
```

If the AKS cluster was deleted outside Terraform, first run `terraform state list | grep -E '^(helm_release|kubernetes_)' | xargs terraform state rm`.
