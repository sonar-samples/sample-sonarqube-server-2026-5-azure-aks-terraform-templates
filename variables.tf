variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region. Must be permitted by any allowed-locations policy and have Total Regional vCPU headroom."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  type    = string
  default = "sonarqube-2026-5"
}

variable "cluster_name" {
  type    = string
  default = "sonarqube-aks"
}

variable "postgres_name" {
  description = "Globally unique across Azure."
  type        = string
  default     = "sonarqube-pg"
}

variable "kubernetes_version" {
  description = "Leave null to take the region's latest non-preview version. A pinned minor eventually becomes long-term-support-only and is then rejected at create time."
  type        = string
  default     = null
}

variable "sonarqube_chart_version" {
  description = "SonarQube Helm chart version. REQUIRED, no default. Agentic support needs 2026.5.1000 or later; see README 'Prerequisites'."
  type        = string
}

# The chart composes the Server image tag from Chart.AppVersion when `edition` is set and this
# is empty. Chart 2026.5.1000 reports appVersion 2026.5.0, so empty yields
# sonarqube:2026.5.0-enterprise. Set it only to override, e.g. "2026.5.0-enterprise".
variable "sonarqube_image_tag" {
  type    = string
  default = ""
}

variable "enable_agentic" {
  description = "Deploy Vortex, the Agent Orchestrator and both agent runtimes. Requires a chart that ships them (2026.5.1000 or later) and an entitlement that enables them."
  type        = bool
  default     = false
}

# With enable_agentic = true this pool runs the agent runtimes too. Chart requests total roughly
# 3.8 vCPU and 20.6Gi of memory, so a 4 vCPU / 16Gi size leaves the runtimes Pending.
variable "system_vm_size" {
  type    = string
  default = "Standard_D8s_v5"
}

variable "system_node_count" {
  type    = number
  default = 2
}

# OPTIONAL as of chart 2026.5.1000, which ships working public defaults:
#   sonarsource/sonar-vortex:2026.5.0
#   sonarsource/sonarqube-agent-orchestrator:2026.5.0
#   sonarsource/sonarqube-hunter-agent:2026.5.0
#   sonarsource/sonarqube-remediation-agent:2026.5.0
# Leave a repository empty and the chart default is used. Set one only to override — for example
# when mirroring official images into a private registry.
variable "agentic_images" {
  description = "Optional image overrides per agentic component. Empty repository = use the chart default."
  type = object({
    vortex       = object({ repository = string, tag = string })
    orchestrator = object({ repository = string, tag = string })
    hunter       = object({ repository = string, tag = string })
    remediation  = object({ repository = string, tag = string })
  })
  default = {
    vortex       = { repository = "", tag = "" }
    orchestrator = { repository = "", tag = "" }
    hunter       = { repository = "", tag = "" }
    remediation  = { repository = "", tag = "" }
  }
}

variable "db_username" {
  type    = string
  default = "sonarqube"
}

# Each replica handles one job at a time, so this is your concurrency. Replicas are fixed; see
# README "Notes".
variable "runtime_replica_count" {
  type    = number
  default = 1
}

# Which storage backend the agentic components use.
#
#   azureblob  - Azure Blob Storage via the AZURE provider. The runtime is handed native SAS
#                presigned URLs scoped to one object and one verb, expiring after the presign
#                TTL, and mounts nothing. Stronger isolation for an untrusted runtime.
#                Authentication is connection-string only - there is no Managed Identity path -
#                so a storage account key is held in a Kubernetes secret.
#
#   azurefiles - Azure Files over ReadWriteMany via the FILESYSTEM provider. The runtime is
#                handed a file:// path and mounts the share, so isolation rests on mount scoping
#                and permissions rather than on signed URLs.
#
# Defaults to azureblob: it is the backend Sonar supports for Azure, and the path this
# module was validated against end to end (all components healthy, repeat plan clean).
# It is also the simpler shape - the runtimes receive presigned SAS locators and mount no
# storage at all, so there is no share, no StorageClass and no mount-permission tuning.
#
# azurefiles remains supported and is the fallback where policy forbids blob endpoints. It
# hands the runtimes file:// paths, which makes mount permissions the isolation boundary.
variable "storage_backend" {
  type    = string
  default = "azureblob"

  validation {
    condition     = contains(["azurefiles", "azureblob"], var.storage_backend)
    error_message = "storage_backend must be azurefiles or azureblob."
  }
}

# Required when storage_backend is azureblob. Globally unique, 3-24 lowercase alphanumerics.
variable "storage_account_name" {
  type    = string
  default = ""
}

# Only used when storage_backend is azurefiles.
variable "jobs_storage_size" {
  description = "Azure Files share for agent job artifacts. Roughly (jobs/day x retention days x 1MB) plus headroom for in-flight repository archives."
  type        = string
  default     = "100Gi"
}

variable "vortex_storage_size" {
  description = "Azure Files share for Vortex analyzer context. Considerably larger per project than job artifacts."
  type        = string
  default     = "100Gi"
}

variable "llm_allowed_domains" {
  description = "Hostnames the agent runtimes may reach through the egress proxy, in addition to shared storage."
  type        = list(string)
  default     = ["api.anthropic.com"]
}

# Azure Files is SMB: ownership and modes come from the StorageClass mount options, not fsGroup.
# 0777 is a troubleshooting/reference setting that lets any container UID write. For anything
# beyond a lab, set share_gid to a gid the agentic pods carry and drop the modes to 0770.
variable "share_dir_mode" {
  type    = string
  default = "0777"
}

variable "share_file_mode" {
  type    = string
  default = "0777"
}

variable "share_gid" {
  description = "gid owning the Azure Files shares. Leave 0 with 0777 modes; set a real gid alongside 0770 modes and a matching pod fsGroup for least privilege."
  type        = string
  default     = "0"
}

variable "enable_settings_encryption" {
  description = "Set true on a SECOND apply, after creating the sonarqube-encryption-secret from a key generated in the SonarQube UI."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Applied to every Azure resource. Include any tag your subscription policy mandates."
  type        = map(string)
  default     = {}
}
