# --------------------------------------------------------------------------
# SonarQube Helm release
# --------------------------------------------------------------------------
#
# Static values live in sonarqube-values.yaml. Everything environment-specific is overlaid here
# as separate YAML documents, which Helm merges in order. Each optional block is emitted on its
# own rather than merged into one map, because a Terraform conditional requires both branches to
# share a type and these do not.

locals {
  # Emit an image override only when one is supplied. The chart ships working public defaults as
  # of 2026.5.0, so overriding them with empty strings would fail validation. A `for` with `if` is
  # used rather than a ternary for the same type-unification reason as above.
  image_override = {
    for name, img in var.agentic_images :
    name => { for k, v in { image = img } : k => v if img.repository != "" }
  }

  # Runtime egress. On an object backend the runtime fetches presigned URLs over HTTPS, so the
  # storage host must be reachable; on a filesystem backend storage is a mount and needs nothing.
  egress_domains = concat(
    var.llm_allowed_domains,
    local.use_blob ? [local.blob_host] : [],
  )

  # Every agentic workload goes to the tainted agentic pool. The chart falls back to the
  # top-level nodeSelector and tolerations (which pin SonarQube Server to its own pool) for any
  # component that leaves its own empty, so each one is set explicitly, the egress proxy and the
  # key-derivation hook included.
  agentic_scheduling = {
    nodeSelector = { workload = "agentic" }
    tolerations = [{
      key      = "workload"
      operator = "Equal"
      value    = "agentic"
      effect   = "NoSchedule"
    }]
  }

  # ---- Backend-independent agentic configuration -------------------------------------------
  agentic = {
    # An input the chart requires and does not create. A pre-install hook derives one signing
    # key per communication hop from it.
    agenticSigningSecret = {
      existingSecret = one(kubernetes_secret_v1.agentic_instance[*].metadata[0].name)
      key            = "instance-secret"
    }

    # The chart DEFAULTS gvisor.enabled to true, which deploys a privileged installer DaemonSet
    # that rewrites containerd configuration — unsupported on AKS managed nodes. Turning it off
    # is what gives the runtimes the standard Kubernetes configuration. agentRuntimeSandbox is
    # left at its chart default (disabled); this module configures no alternative sandbox runtime.
    gvisor = { enabled = false }

    agentKeyDerivation = local.agentic_scheduling

    vortexAnalysis = merge(local.image_override.vortex, local.agentic_scheduling, {
      enabled = true
    })

    agentOrchestrator = merge(local.image_override.orchestrator, local.agentic_scheduling, {
      enabled   = true
      scheduler = { enabled = true }
    })

    hunterAgent      = local.runtime_values["hunter"]
    remediationAgent = local.runtime_values["remediation"]

    # No enabled flag — the proxy renders whenever a runtime does. Confirm it exists in the chart
    # version you pinned, and test an allowed and a denied destination.
    # egressExcludeCidrs keeps only link-local. The blob private endpoint sits on a private VNet
    # address, so excluding RFC1918 ranges here would cut the runtimes off from their artifacts.
    agentEgressProxy = merge(local.agentic_scheduling, {
      allowedDomains = local.egress_domains
      networkPolicy = {
        enabled            = true
        egressPorts        = [80, 443]
        egressExcludeCidrs = ["169.254.0.0/16"] # cloud metadata endpoint
      }
    })
  }

  runtime_values = {
    for family, override in {
      hunter      = local.image_override.hunter
      remediation = local.image_override.remediation
      } : family => merge(override, local.agentic_scheduling, {
        enabled       = true
        replicaCount  = var.runtime_replica_count
        networkPolicy = { enabled = true }
    })
  }

  # ---- Azure Blob: presigned SAS locators, nothing mounted ----------------------------------
  #
  # The chart has no dedicated Azure fields, so azure.container and azure.connection-string go
  # through each component's generic env passthrough. `bucket` is set alongside azure.container
  # because the library documents it as "bucket / container name" for Azure too.
  # Terraform evaluates BOTH branches of a conditional, so this local is built even when
  # use_blob is false and these count=0 resources are empty. one() yields null there instead
  # of failing the plan with "Invalid index" - which it otherwise does for every configuration
  # that is not agentic-plus-blob, including the default enable_agentic = false.
  storage_blob = {
    # SonarQube Server writes the analyzer context Vortex restores.
    sonarProperties = {
      "sonar.agentic.storage.type"            = "AZURE"
      "sonar.agentic.storage.bucket"          = local.vortex_store
      "sonar.agentic.storage.azure.container" = local.vortex_store
    }
    sonarSecretProperties = one(kubernetes_secret_v1.azure_storage_props[*].metadata[0].name)

    vortexAnalysis = {
      storage = {
        type   = "AZURE"
        bucket = local.vortex_store
        # Required by chart validation for any non-filesystem type, even though the library
        # documents region as an S3-only setting and AzureObjectStore ignores it. The
        # Orchestrator never trips this because its own region defaults to us-east-1.
        region = var.location
      }
      env = [{
        name  = "SONAR_AGENTIC_STORAGE_AZURE_CONTAINER"
        value = local.vortex_store
        }, {
        name = "SONAR_AGENTIC_STORAGE_AZURE_CONNECTION_STRING"
        valueFrom = { secretKeyRef = {
          name = one(kubernetes_secret_v1.azure_storage[*].metadata[0].name)
          key  = "SONAR_AGENTIC_STORAGE_AZURE_CONNECTION_STRING"
        } }
      }]
    }

    agentOrchestrator = {
      storage = {
        type   = "AZURE"
        bucket = local.jobs_store
      }
      env = [{
        name  = "SONAR_AGENTIC_ORCHESTRATOR_STORAGE_AZURE_CONTAINER"
        value = local.jobs_store
        }, {
        name = "SONAR_AGENTIC_ORCHESTRATOR_STORAGE_AZURE_CONNECTION_STRING"
        valueFrom = { secretKeyRef = {
          name = one(kubernetes_secret_v1.azure_storage[*].metadata[0].name)
          key  = "SONAR_AGENTIC_ORCHESTRATOR_STORAGE_AZURE_CONNECTION_STRING"
        } }
      }]
    }
    # The runtimes need no storage configuration at all: they act on locators.
  }

  # ---- Azure Files: file:// locators on a shared mount --------------------------------------
  storage_files = {
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

    vortexAnalysis = {
      storage = {
        type       = "FILESYSTEM"
        filesystem = { baseDir = local.vortex_base_dir }
      }
      extraVolumes = [{
        name                  = "vortex-context"
        persistentVolumeClaim = { claimName = local.vortex_claim }
      }]
      # Vortex only reads context; SonarQube Server writes it.
      extraVolumeMounts = [{
        name      = "vortex-context"
        mountPath = local.vortex_base_dir
        readOnly  = true
      }]
    }

    agentOrchestrator = {
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
    }

    # Each runtime mounts ONLY its own subtree, so neither can see the other's files. Chart
    # validation requires the mountPath to sit at or above storage.filesystem.baseDir.
    hunterAgent      = local.runtime_storage_files["hunter"]
    remediationAgent = local.runtime_storage_files["remediation"]
  }

  runtime_storage_files = {
    for family in ["hunter", "remediation"] : family => {
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
    }
  }
}

resource "helm_release" "sonarqube" {
  name       = "sonarqube"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube"
  version    = var.sonarqube_chart_version
  namespace  = local.ns
  timeout    = 1800

  values = compact([
    file("${path.module}/sonarqube-values.yaml"),

    # The Server is exposed on an internal load balancer at a fixed private address, which is the
    # Application Gateway's only backend. serverBaseURL makes links the Server emits (Remediation
    # Agent pull requests, notifications, webhooks) carry the public HTTPS hostname.
    yamlencode({
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/azure-load-balancer-internal"        = "true"
          "service.beta.kubernetes.io/azure-load-balancer-internal-subnet" = azurerm_subnet.private.name
          "service.beta.kubernetes.io/azure-load-balancer-ipv4"            = local.sonarqube_internal_ip
        }
      }
      sonarProperties = {
        "sonar.core.serverBaseURL" = local.sonarqube_url
      }
    }),

    yamlencode({
      jdbcOverwrite = {
        enabled               = true
        jdbcUrl               = "jdbc:postgresql://${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.sonarqube.name}?sslmode=require"
        jdbcUsername          = var.db_username
        jdbcSecretName        = kubernetes_secret_v1.db.metadata[0].name
        jdbcSecretPasswordKey = "password"
      }
    }),

    # Pin the Server image explicitly only when overriding. As of chart 2026.5.1000 the appVersion
    # is 2026.5.0, so `edition: enterprise` composes sonarqube:2026.5.0-enterprise on its own.
    var.sonarqube_image_tag == "" ? "" : yamlencode({
      image = { tag = var.sonarqube_image_tag }
    }),

    # SonarQube generates its own settings-encryption key, so the first apply leaves this off and
    # a second apply turns it on once the secret exists.
    var.enable_settings_encryption ? yamlencode({
      sonarSecretKey = "sonarqube-encryption-secret"
    }) : "",

    var.enable_agentic ? yamlencode(local.agentic) : "",
    local.use_blob ? yamlencode(local.storage_blob) : "",
    local.use_files ? yamlencode(local.storage_files) : "",
  ])

  depends_on = [
    azurerm_role_assignment.aks_network, # internal load balancer in the private subnet
    azurerm_kubernetes_cluster_node_pool.sonarqube,
    azurerm_kubernetes_cluster_node_pool.agentic, # empty unless enable_agentic = true
    azurerm_postgresql_flexible_server_database.sonarqube,
    azurerm_storage_container.jobs, # empty unless storage_backend = azureblob
    azurerm_storage_container.vortex,
    azurerm_private_endpoint.blob,
    kubernetes_persistent_volume_claim_v1.jobs, # empty unless storage_backend = azurefiles
    kubernetes_persistent_volume_claim_v1.vortex,
    kubernetes_secret_v1.db,
    kubernetes_secret_v1.monitoring,
    kubernetes_secret_v1.agentic_instance,
    kubernetes_secret_v1.azure_storage,
  ]
}
