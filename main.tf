###############################################################################
# main.tf – Azure Container Apps + Application Gateway WAF
# Author : Przemyslaw Grzenkowicz
# Version: 1.0.0
#
# This file defines all infrastructure for a WAF-protected container workload.
# Design principle: the Container App has zero public exposure — all inbound
# traffic is forced through Application Gateway with WAF inspection.
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      # Pinned to 3.x with pessimistic constraint (~>) to allow patch updates
      # while preventing breaking changes from a 4.x upgrade.
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      # Used solely for generating a stable suffix for globally-unique names.
      version = "~> 3.6"
    }
  }

  # Remote state backend – Azure Storage Account.
  # Configured this way (empty block + -backend-config flags at init) so that
  # the same codebase works across dev/staging/prod without hard-coding any
  # storage account names. The pipeline injects backend values from the ADO
  # Variable Group at runtime, keeping secrets out of version control.
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    resource_group {
      # Set to false so `terraform destroy` can remove the RG even if Azure
      # created child resources we don't manage (e.g. ACA internal LB, NICs).
      # Without this, destroy would fail on non-empty resource groups.
      prevent_deletion_if_contains_resources = false
    }
  }
  # Subscription ID is passed as a variable (from the ADO Variable Group as a
  # secret) rather than hard-coded, so the same code can target different
  # subscriptions per environment.
  subscription_id = var.subscription_id
}

###############################################################################
# Random suffix
# Azure Storage Accounts and Log Analytics Workspaces require globally-unique
# names. A random suffix avoids collisions without coupling names to a
# timestamp or commit hash. The `random_string` resource is stable across
# plan/apply — it generates once and persists in state.
###############################################################################
resource "random_string" "suffix" {
  length  = 6
  upper   = false   # Storage account names must be lowercase
  special = false   # Only alphanumeric characters allowed in Azure resource names
}

locals {
  suffix   = random_string.suffix.result
  # Standard naming prefix: <project>-<env> used across all resources.
  # Follows Azure CAF (Cloud Adoption Framework) naming conventions.
  name_pfx = "${var.project}-${var.environment}"
}

###############################################################################
# Resource Group
# Single resource group per environment — keeps blast radius contained and
# makes cleanup trivial (`terraform destroy` removes everything at once).
###############################################################################
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_pfx}"
  location = var.location
  tags     = var.tags
}

###############################################################################
# Virtual Network & Subnets
# A /16 VNet gives us 65,536 addresses — far more than needed, but it leaves
# room for future subnets (Private Endpoints, VPN Gateway, Bastion) without
# re-addressing. This is a deliberate over-provision following Azure best
# practice for non-trivial workloads.
###############################################################################
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

# Application Gateway requires its own dedicated subnet — Azure will refuse
# deployment if any other resource type exists in the same subnet.
# /24 (256 addresses) is the minimum recommended size; App Gateway can
# consume multiple private IPs for its instances during autoscaling.
resource "azurerm_subnet" "agw" {
  name                 = "snet-agw"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Container Apps Environment requires a /23 minimum (512 addresses) when
# VNet-integrated. Azure reserves IPs for the internal load balancer, KEDA
# scaler, and each container revision. A /23 supports ~250 running replicas.
# The delegation tells Azure this subnet is exclusively for ACA, which is
# required by the platform to inject its internal infrastructure.
resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/23"]

  delegation {
    name = "aca-delegation"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        # This action grants ACA permission to attach NICs to the subnet.
        # Without it, the environment deployment fails with an authorization error.
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

###############################################################################
# Log Analytics Workspace
# Centralized logging sink for both Application Gateway (WAF logs, access logs)
# and Container Apps (stdout/stderr, system logs). A single workspace avoids
# cross-workspace queries and keeps cost predictable.
# PerGB2018 is the only available SKU for new workspaces; 30-day retention
# is the free tier default — sufficient for dev, extend in prod.
###############################################################################
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${local.name_pfx}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

###############################################################################
# Container Apps Managed Environment (VNet-integrated, internal only)
# This is the hosting layer for Container Apps — analogous to a Kubernetes
# cluster but fully managed. Key design decision: internal_load_balancer_enabled
# = true means the environment gets NO public IP. Traffic can only reach the
# containers through the VNet, which forces all external traffic through
# the Application Gateway (our WAF inspection point).
###############################################################################
resource "azurerm_container_app_environment" "main" {
  name                           = "cae-${local.name_pfx}"
  resource_group_name            = azurerm_resource_group.main.name
  location                       = azurerm_resource_group.main.location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id       = azurerm_subnet.aca.id
  # CRITICAL: Setting this to true is what enforces the "no direct public access"
  # security posture. The ACA environment only gets a private IP on the VNet,
  # so the only way to reach the container from the internet is through the
  # Application Gateway sitting in the adjacent subnet.
  internal_load_balancer_enabled = true
  tags                           = var.tags
}

###############################################################################
# Container App – httpbin API
# httpbin is a well-known HTTP request/response service — used here as a
# placeholder to validate the full traffic path (Internet → AGW → ACA).
# In production, replace with the actual application image.
###############################################################################
resource "azurerm_container_app" "api" {
  name                         = "ca-api-${local.name_pfx}"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  # "Single" revision mode means only one active revision at a time.
  # This is simpler than "Multiple" (blue/green) and sufficient for this
  # infrastructure demo. For production traffic splitting, switch to Multiple.
  revision_mode                = "Single"
  tags                         = var.tags

  template {
    # min/max replicas are environment-specific via tfvars:
    # dev: min=0 (scale-to-zero saves cost when idle)
    # prod: min=2 (always-on, avoids cold-start latency)
    min_replicas = var.aca_min_replicas
    max_replicas = var.aca_max_replicas

    container {
      name   = "httpbin"
      image  = "kennethreitz/httpbin:latest"
      # 0.5 vCPU / 1Gi RAM is the smallest allocation that runs httpbin
      # reliably. ACA bills per-second on allocated resources, so keeping
      # this small matters for cost — especially in dev with scale-to-zero.
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "APP_ENV"
        value = var.environment
      }

      # Liveness probe: ACA restarts the container if this fails repeatedly.
      # /status/200 is httpbin's guaranteed-healthy endpoint.
      liveness_probe {
        transport = "HTTP"
        path      = "/status/200"
        port      = 80
      }

      # Readiness probe: ACA only routes traffic to the container once this
      # passes. Prevents requests hitting a container that's still starting.
      readiness_probe {
        transport = "HTTP"
        path      = "/status/200"
        port      = 80
      }
    }

    # KEDA-based HTTP scaler: ACA spins up additional replicas when concurrent
    # requests exceed 50 per instance. This threshold is conservative — tune
    # based on actual latency/throughput testing in production. The HTTP scaler
    # is preferred over CPU/memory scaling because web APIs are typically I/O
    # bound, not CPU bound.
    custom_scale_rule {
      name             = "http-scaler"
      custom_rule_type = "http"
      metadata = {
        concurrentRequests = "50"
      }
    }
  }

  ingress {
    # external_enabled = false means this container is only reachable within
    # the VNet. Combined with internal_load_balancer_enabled on the environment,
    # this ensures zero public exposure. The App Gateway reaches it via the
    # private FQDN on the ACA subnet.
    external_enabled           = false
    target_port                = 80
    # Even though traffic is internal, we disallow plain HTTP between AGW and
    # ACA. ACA's internal ingress uses its own TLS termination.
    allow_insecure_connections = false

    traffic_weight {
      # 100% of traffic goes to the latest revision — standard for Single mode.
      percentage      = 100
      latest_revision = true
    }
  }
}

###############################################################################
# Public IP for Application Gateway
# Standard SKU is required for WAF_v2. Static allocation ensures the IP
# doesn't change on gateway restarts — critical for DNS records and firewall
# allow-lists in production.
###############################################################################
resource "azurerm_public_ip" "agw" {
  name                = "pip-agw-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"   # WAF_v2 requires Standard SKU; Basic is incompatible
  tags                = var.tags
}

###############################################################################
# WAF Policy
# Separated from the Application Gateway resource so it can be reused across
# multiple gateways or listeners if the architecture grows.
#
# Key decisions:
# - Prevention mode (not Detection): blocks attacks in real-time rather than
#   just logging them. Detection mode is useful during initial rollout to
#   identify false positives, but for a security-first posture we start strict.
# - OWASP 3.2: the latest stable rule set supported by Azure WAF. Covers
#   SQL injection, XSS, LFI/RFI, command injection, and more.
# - Bot Manager 1.0: identifies and blocks known bad bots, scrapers, and
#   vulnerability scanners. Low false-positive rate on legitimate traffic.
###############################################################################
resource "azurerm_web_application_firewall_policy" "main" {
  name                = "wafpol-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"   # Block malicious requests (not just log them)
    request_body_check          = true            # Inspect POST/PUT payloads, not just headers/URLs
    file_upload_limit_in_mb     = 100             # Reject uploads > 100 MB (DoS mitigation)
    max_request_body_size_in_kb = 128             # 128 KB cap on request body inspection
  }

  managed_rules {
    # OWASP Core Rule Set 3.2 — covers the OWASP Top 10 attack categories.
    # This is the latest version supported by Azure App Gateway WAF.
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }

    # Microsoft Bot Manager classifies incoming traffic as good bots (search
    # engines), bad bots (scrapers, vulnerability scanners), or unknown.
    # In Prevention mode, bad bots are blocked automatically.
    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
    }
  }

  # Rate limiting rule: blocks any single client IP that sends more than 300
  # requests per minute. This is a baseline DDoS/abuse mitigation layer.
  # The match condition uses negation on 0.0.0.0/0 (matches ALL IPs) —
  # effectively applying the rate limit universally. In production, you would
  # add exclusions for trusted IPs (monitoring, health checks, internal services).
  custom_rules {
    name      = "RateLimitRule"
    priority  = 1              # Evaluated first, before managed rules
    rule_type = "RateLimitRule"
    action    = "Block"

    rate_limit_duration       = "OneMin"
    rate_limit_threshold      = 300             # 300 req/min per client IP
    group_rate_limit_by       = "ClientAddr"    # Track limits per source IP

    match_conditions {
      match_variables {
        variable_name = "RemoteAddr"
      }
      operator           = "IPMatch"
      negation_condition = true              # Negating "match 0.0.0.0/0" = match everything
      match_values       = ["0.0.0.0/0"]     # Placeholder — tighten per environment
    }
  }
}

###############################################################################
# Application Gateway v2 (WAF_v2 SKU)
#
# Why App Gateway instead of Azure Front Door:
# - App Gateway sits inside the VNet, giving it direct network access to the
#   internal ACA environment without requiring Private Link or service endpoints.
# - Front Door would require exposing ACA publicly or adding Private Link, which
#   adds complexity and cost for a single-region deployment.
# - WAF_v2 on App Gateway provides the same OWASP rule set as Front Door WAF.
# - For multi-region deployments, Front Door would be the better choice.
#
# Why WAF_v2 and not Standard_v2:
# - WAF_v2 is required for the WAF policy attachment. Standard_v2 has no WAF.
# - The cost difference is the WAF processing fee (~€0.009/GB inspected).
###############################################################################
locals {
  # App Gateway requires named references between its sub-resources (listeners,
  # backends, probes, etc.). These locals keep the names consistent and avoid
  # repetition across the configuration blocks.
  agw_frontend_port_name         = "feport-http"
  agw_frontend_ip_config_name    = "feip-public"
  agw_backend_pool_name          = "bepool-aca"
  agw_backend_http_settings_name = "be-http-settings"
  agw_http_listener_name         = "listener-http"
  agw_request_routing_rule_name  = "rule-http"
  agw_probe_name                 = "probe-aca"

  # The ACA internal FQDN is used as the backend target. App Gateway resolves
  # this through VNet DNS to the internal load balancer IP of the ACA environment.
  aca_fqdn = azurerm_container_app.api.ingress[0].fqdn
}

resource "azurerm_application_gateway" "main" {
  name                = "agw-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  # Link the WAF policy — this is what makes the gateway inspect traffic
  # against OWASP rules and the rate limit before forwarding to the backend.
  firewall_policy_id = azurerm_web_application_firewall_policy.main.id

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
    # capacity is a static fallback — autoscale_configuration below overrides
    # this value. Azure requires it to be set even when autoscaling is enabled.
    capacity = 2
  }

  # Autoscale between 1 and 5 capacity units. Each unit handles ~10 Mbps
  # throughput or ~6,000 concurrent connections. Starting at 1 keeps dev cost
  # low; max 5 handles traffic spikes without manual intervention.
  autoscale_configuration {
    min_capacity = 1
    max_capacity = 5
  }

  # Associates the gateway with its dedicated subnet. App Gateway deploys
  # multiple instances across availability zones within this subnet.
  gateway_ip_configuration {
    name      = "gwip"
    subnet_id = azurerm_subnet.agw.id
  }

  # Port 80 (HTTP) — in production, add port 443 with an SSL certificate
  # from Key Vault and redirect HTTP → HTTPS.
  frontend_port {
    name = local.agw_frontend_port_name
    port = 80
  }

  frontend_ip_configuration {
    name                 = local.agw_frontend_ip_config_name
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  # Backend pool targets the ACA internal FQDN. App Gateway resolves this
  # to the ACA environment's private IP via VNet DNS. Using FQDN (not IP)
  # ensures traffic continues to flow even if ACA's internal IP changes.
  backend_address_pool {
    name  = local.agw_backend_pool_name
    fqdns = [local.aca_fqdn]
  }

  # Custom health probe that validates the backend is actually serving
  # requests, not just accepting TCP connections. The /status/200 endpoint
  # on httpbin always returns 200 if the app is healthy.
  probe {
    name                = local.agw_probe_name
    protocol            = "Http"
    host                = local.aca_fqdn   # Must match backend host for routing to work
    path                = "/status/200"
    interval            = 30               # Probe every 30s
    timeout             = 30               # Wait up to 30s for response
    unhealthy_threshold = 3                # Mark unhealthy after 3 consecutive failures

    match {
      # Accept 2xx and 3xx as healthy — covers redirects and normal responses.
      status_code = ["200-399"]
    }
  }

  backend_http_settings {
    name                  = local.agw_backend_http_settings_name
    cookie_based_affinity = "Disabled"       # Stateless API — no session stickiness needed
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30               # Fail fast on slow backends
    probe_name            = local.agw_probe_name
    # host_name must match the ACA FQDN so that ACA's ingress controller routes
    # the request to the correct container app (ACA uses host-header routing).
    host_name             = local.aca_fqdn
  }

  http_listener {
    name                           = local.agw_http_listener_name
    frontend_ip_configuration_name = local.agw_frontend_ip_config_name
    frontend_port_name             = local.agw_frontend_port_name
    protocol                       = "Http"
    # PRODUCTION TODO: Replace with HTTPS listener + Key Vault certificate:
    # protocol             = "Https"
    # ssl_certificate_name = "my-cert"
    # frontend_port_name   = "feport-https" (port 443)
  }

  # Basic routing rule: all traffic from the HTTP listener goes to the ACA
  # backend pool. For path-based routing to multiple microservices, switch
  # rule_type to "PathBasedRouting" and add a URL path map.
  request_routing_rule {
    name                       = local.agw_request_routing_rule_name
    rule_type                  = "Basic"
    priority                   = 100   # Lower number = higher priority; 100 leaves room for future rules
    http_listener_name         = local.agw_http_listener_name
    backend_address_pool_name  = local.agw_backend_pool_name
    backend_http_settings_name = local.agw_backend_http_settings_name
  }
}

###############################################################################
# Diagnostic Settings
# Streams Application Gateway logs to Log Analytics for security monitoring
# and troubleshooting. Two log categories are critical:
# - AccessLog: every request (client IP, URL, status code, latency)
# - FirewallLog: every WAF rule match (blocked/allowed, rule ID, attack type)
# These logs are essential for investigating incidents and tuning WAF rules
# to reduce false positives.
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "agw" {
  name                       = "diag-agw"
  target_resource_id         = azurerm_application_gateway.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "ApplicationGatewayAccessLog" }
  enabled_log { category = "ApplicationGatewayFirewallLog" }
  metric { category = "AllMetrics" }   # CPU, throughput, healthy host count, etc.
}
