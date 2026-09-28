variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region. Must be permitted by any allowed-locations policy, have Total Regional vCPU headroom, and offer a Gen2 nested-virtualization VM size."
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
  description = "SonarQube Helm chart version. REQUIRED, no default: agentic support depends on a chart published from the merged agentic branch. See README 'Release status' before setting this."
  type        = string
}

# The chart composes the Server image tag from Chart.AppVersion when `edition` is set
# and this is empty. On chart 2026.5.1000 the appVersion is still 2026.4.0, so leaving
# this empty SILENTLY DEPLOYS 2026.4. Set it explicitly until `helm show chart` reports
# a 2026.5 appVersion. Example: "2026.5.0-enterprise".
variable "sonarqube_image_tag" {
  type    = string
  default = ""
}

variable "enable_agentic" {
  description = "Deploy Vortex, the Agent Orchestrator and both agent runtimes. Leave false until the chart version you pinned actually ships the agentic components."
  type        = bool
  default     = false
}

variable "system_vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

variable "sandbox_vm_size" {
  description = "Must be a generation 2 size supporting nested virtualization."
  type        = string
  default     = "Standard_D8s_v5"
}

variable "sandbox_max_nodes" {
  type    = number
  default = 2
}

# The chart ships BLANK image defaults for all four agentic components, so these are required
# when enable_agentic is true — chart validation fails with "image.repository is not set"
# otherwise. Take them from the release's approved image manifest; do not guess tags.
variable "agentic_images" {
  description = "Release-approved image references for each agentic component."
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

# Each replica handles one job at a time, so this is your concurrency. Fixed replicas keep the
# sandbox pool provisioned; see README "Known limitations".
variable "runtime_replica_count" {
  type    = number
  default = 1
}

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

# No default on purpose. The RuntimeClass name is environment-specific: AKS has used both
# kata-vm-isolation and kata-mshv-vm-isolation, and the chart documents the latter as its AKS
# example. Discover it before you apply:
#   kubectl get runtimeclass
# Pod Sandboxing runs each runtime pod in a VM with its own guest kernel. SonarQube's
# documentation describes it as the control that keeps LLM-influenced code away from the host, so
# it defaults on. The chart supports turning it off — no validation requires a sandbox — and doing
# so removes the Azure Linux pool, the Gen2 nested-virtualization SKU, the feature registration and
# the RuntimeClass discovery. Without it, isolation rests on standard container controls only.
variable "enable_pod_sandboxing" {
  type    = bool
  default = true
}

variable "sandbox_runtime_class" {
  description = "RuntimeClass to schedule the agent runtimes onto. Required when enable_agentic AND enable_pod_sandboxing are true. Discover with `kubectl get runtimeclass`; do not guess."
  type        = string
  default     = ""
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
