# --------------------------------------------------------------------------
# SonarQube Helm release
# --------------------------------------------------------------------------
#
# Static values live in sonarqube-values.yaml. Everything environment-specific is overlaid
# here with yamlencode, so there is no string templating to get wrong and the agentic block
# is a real conditional rather than a template directive.

locals {
  # Emit an image override only when one is supplied. As of chart 2026.5.1000 the chart ships
  # working public defaults, so overriding them with empty strings would fail validation. A `for`
  # with `if` is used rather than a ternary because a conditional needs both branches to share a
  # type, and "a map with an image key" and "an empty map" do not.
  image_override = {
    for name, img in var.agentic_images :
    name => { for k, v in { image = img } : k => v if img.repository != "" }
  }

  agentic = {
    # An input the chart requires and does not create. A pre-install hook derives one signing
    # key per communication hop from it.
    agenticSigningSecret = {
      existingSecret = kubernetes_secret_v1.agentic_instance[0].metadata[0].name
      key            = "instance-secret"
    }

    # AKS Pod Sandboxing, not gVisor. These are different mechanisms: the chart's gvisor path
    # installs its own runtime with a privileged DaemonSet that would fight the containerd
    # configuration AKS manages itself.
    gvisor = { enabled = false }
    agentRuntimeSandbox = {
      enabled          = var.enable_pod_sandboxing
      runtimeClassName = var.enable_pod_sandboxing ? var.sandbox_runtime_class : ""
    }

    # SonarQube Server writes the analyzer context Vortex restores, so it mounts the same share.
    sonarProperties = {
      "sonar.agentic.storage.type"                = "FILESYSTEM"
      "sonar.agentic.storage.filesystem.base-dir" = local.vortex_base_dir
    }
    extraVolumes = [{
      name                  = "vortex-context"
      persistentVolumeClaim = { claimName = local.vortex_claim }
    }]
    extraVolumeMounts = [{
      name      = "vortex-context"
      mountPath = local.vortex_base_dir
    }]

    # Not an agent — a long-lived analysis service. bucket/region are meaningless for a file
    # backend and the chart gates them on storage type.
    vortexAnalysis = merge(local.image_override.vortex, {
      enabled      = true
      nodeSelector = { workload = "system" }
      storage = {
        type       = "FILESYSTEM"
        filesystem = { baseDir = local.vortex_base_dir }
      }
      extraVolumes = [{
        name                  = "vortex-context"
        persistentVolumeClaim = { claimName = local.vortex_claim }
      }]
      extraVolumeMounts = [{
        name      = "vortex-context"
        mountPath = local.vortex_base_dir
        readOnly  = true
      }]
    })

    # Mounts the jobs share at its root and writes each runtime's jobs into a subdirectory
    # named after that runtime.
    agentOrchestrator = merge(local.image_override.orchestrator, {
      enabled      = true
      scheduler    = { enabled = true }
      nodeSelector = { workload = "system" }
      storage = {
        type       = "FILESYSTEM"
        filesystem = { baseDir = local.jobs_base_dir }
      }
      extraVolumes = [{
        name                  = "agentic-jobs"
        persistentVolumeClaim = { claimName = local.jobs_claim }
      }]
      extraVolumeMounts = [{
        name      = "agentic-jobs"
        mountPath = local.jobs_base_dir
      }]
    })

    hunterAgent      = local.runtime_values["hunter"]
    remediationAgent = local.runtime_values["remediation"]

    # No enabled flag — the proxy renders whenever a runtime does. Confirm it exists in the
    # chart version you pinned. With a filesystem backend only the LLM provider needs allowing;
    # add identity, DevOps and storage endpoints if your setup reaches them.
    agentEgressProxy = {
      allowedDomains = var.llm_allowed_domains
      networkPolicy = {
        enabled            = true
        egressPorts        = [80, 443]
        egressExcludeCidrs = ["169.254.0.0/16"] # cloud metadata endpoint
      }
    }
  }

  # Each runtime mounts ONLY its own subtree, so neither can see the other's files. Chart
  # validation requires the mountPath to sit at or above storage.filesystem.baseDir.
  runtime_values = {
    for family, override in {
      hunter      = local.image_override.hunter
      remediation = local.image_override.remediation
      } : family => merge(override, {
        enabled      = true
        replicaCount = var.runtime_replica_count
        # With sandboxing off there is no sandbox pool, so the runtimes share the system pool.
        nodeSelector = { workload = var.enable_pod_sandboxing ? "sandbox" : "system" }
        # Per-component, never release-wide: a global toleration would make SonarQube Server
        # itself eligible for a sandbox node.
        tolerations = var.enable_pod_sandboxing ? [{
          key      = "workload"
          operator = "Equal"
          value    = "sandbox"
          effect   = "NoSchedule"
        }] : []
        networkPolicy = { enabled = true }
        storage = {
          type       = "FILESYSTEM"
          filesystem = { baseDir = "${local.jobs_base_dir}/${family}" }
        }
        extraVolumes = [{
          name                  = "agentic-jobs"
          persistentVolumeClaim = { claimName = local.jobs_claim }
        }]
        extraVolumeMounts = [{
          name      = "agentic-jobs"
          mountPath = "${local.jobs_base_dir}/${family}"
          subPath   = family
        }]
    })
  }
}

resource "helm_release" "sonarqube" {
  name       = "sonarqube"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube"
  version    = var.sonarqube_chart_version
  namespace  = local.ns
  timeout    = 1800

  # A list of YAML documents, merged by Helm in order. Each optional block is gated on its own
  # rather than merged into one map, because a Terraform conditional requires both branches to
  # have the same type and these blocks do not.
  values = compact([
    file("${path.module}/sonarqube-values.yaml"),

    yamlencode({
      jdbcOverwrite = {
        enabled               = true
        jdbcUrl               = "jdbc:postgresql://${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.sonarqube.name}?sslmode=require"
        jdbcUsername          = var.db_username
        jdbcSecretName        = kubernetes_secret_v1.db.metadata[0].name
        jdbcSecretPasswordKey = "password"
      }
    }),

    # Pin the Server image explicitly. With `edition` set and no tag the chart composes one from
    # Chart.AppVersion, so a chart whose appVersion lags its version deploys the older Server.
    # Chart version and image version are a tested tuple; take both from the release notes.
    var.sonarqube_image_tag == "" ? "" : yamlencode({
      image = { tag = var.sonarqube_image_tag }
    }),

    # Only reference the settings-encryption secret once it exists. SonarQube generates the key
    # itself, so the first apply leaves this off and a second apply turns it on.
    var.enable_settings_encryption ? yamlencode({
      sonarSecretKey = "sonarqube-encryption-secret"
    }) : "",

    var.enable_agentic ? yamlencode(local.agentic) : "",
  ])

  depends_on = [
    azurerm_kubernetes_cluster_node_pool.sandbox, # empty when sandboxing is off
    azurerm_postgresql_flexible_server_firewall_rule.aks,
    kubernetes_persistent_volume_claim_v1.jobs,
    kubernetes_persistent_volume_claim_v1.vortex,
    kubernetes_secret_v1.db,
    kubernetes_secret_v1.monitoring,
    kubernetes_secret_v1.agentic_instance,
  ]
}
