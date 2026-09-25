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

variable "sandbox_runtime_class" {
  description = "RuntimeClass AKS creates for pod sandboxing. Confirm with `kubectl get runtimeclass` — older clusters use kata-mshv-vm-isolation."
  type        = string
  default     = "kata-vm-isolation"
}

variable "llm_allowed_domains" {
  description = "Hostnames the agent runtimes may reach through the egress proxy, in addition to shared storage."
  type        = list(string)
  default     = ["api.anthropic.com"]
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
