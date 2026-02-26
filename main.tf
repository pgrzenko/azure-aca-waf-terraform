###############################################################################
# main.tf – Azure Container Apps + Application Gateway WAF
# Author : Flow64 / Przemyslaw Grzenkowicz
# Version: 1.0.0
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state – Azure Storage Backend
  backend "azurerm" {
    # Values injected at init time via -backend-config or pipeline variables:
    #   resource_group_name  = "rg-tfstate"
    #   storage_account_name = "<unique>"
    #   container_name       = "tfstate"
    #   key                  = "aca-waf/terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}

###############################################################################
# Random suffix – keeps globally-unique names stable across plan/apply
###############################################################################
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix   = random_string.suffix.result
  name_pfx = "${var.project}-${var.environment}"
}

###############################################################################
# Resource Group
###############################################################################
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_pfx}"
  location = var.location
  tags     = var.tags
}

###############################################################################
# Virtual Network & Subnets
###############################################################################
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

# Subnet for Application Gateway (must be dedicated, /24 minimum recommended)
resource "azurerm_subnet" "agw" {
  name                 = "snet-agw"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Subnet for Container Apps Environment (delegated)
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
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

###############################################################################
# Log Analytics Workspace (observability backbone)
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
###############################################################################
resource "azurerm_container_app_environment" "main" {
  name                           = "cae-${local.name_pfx}"
  resource_group_name            = azurerm_resource_group.main.name
  location                       = azurerm_resource_group.main.location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id       = azurerm_subnet.aca.id
  internal_load_balancer_enabled = true   # Traffic enters ONLY via App Gateway
  tags                           = var.tags
}

###############################################################################
# Container App – Sample Hello-World API (httpbin)
###############################################################################
resource "azurerm_container_app" "api" {
  name                         = "ca-api-${local.name_pfx}"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  tags                         = var.tags

  template {
    min_replicas = var.aca_min_replicas
    max_replicas = var.aca_max_replicas

    container {
      name   = "httpbin"
      image  = "kennethreitz/httpbin:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "APP_ENV"
        value = var.environment
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/status/200"
        port      = 80
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/status/200"
        port      = 80
      }
    }

    # Scale on HTTP concurrent requests
    custom_scale_rule {
      name             = "http-scaler"
      custom_rule_type = "http"
      metadata = {
        concurrentRequests = "50"
      }
    }
  }

  ingress {
    external_enabled           = false   # Internal only – App Gateway is the entry point
    target_port                = 80
    allow_insecure_connections = false

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

###############################################################################
# Public IP for Application Gateway
###############################################################################
resource "azurerm_public_ip" "agw" {
  name                = "pip-agw-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

###############################################################################
# WAF Policy (OWASP 3.2, Prevention mode)
###############################################################################
resource "azurerm_web_application_firewall_policy" "main" {
  name                = "wafpol-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }

    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
    }
  }

  # Example custom rule – block known bad IPs (extend as needed)
  custom_rules {
    name      = "RateLimitRule"
    priority  = 1
    rule_type = "RateLimitRule"
    action    = "Block"

    rate_limit_duration       = "OneMin"
    rate_limit_threshold      = 300
    group_rate_limit_by       = "ClientAddr"

    match_conditions {
      match_variables {
        variable_name = "RemoteAddr"
      }
      operator           = "IPMatch"
      negation_condition = true
      match_values       = ["0.0.0.0/0"]   # Placeholder – tighten per env
    }
  }
}

###############################################################################
# Application Gateway v2 (WAF_v2 SKU)
###############################################################################
locals {
  agw_frontend_port_name        = "feport-http"
  agw_frontend_ip_config_name   = "feip-public"
  agw_backend_pool_name         = "bepool-aca"
  agw_backend_http_settings_name = "be-http-settings"
  agw_http_listener_name        = "listener-http"
  agw_request_routing_rule_name = "rule-http"
  agw_probe_name                = "probe-aca"

  # ACA internal FQDN – used as backend address
  aca_fqdn = azurerm_container_app.api.ingress[0].fqdn
}

resource "azurerm_application_gateway" "main" {
  name                = "agw-${local.name_pfx}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  firewall_policy_id = azurerm_web_application_firewall_policy.main.id

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 2   # Autoscale overrides this when min/max set
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 5
  }

  gateway_ip_configuration {
    name      = "gwip"
    subnet_id = azurerm_subnet.agw.id
  }

  frontend_port {
    name = local.agw_frontend_port_name
    port = 80
  }

  frontend_ip_configuration {
    name                 = local.agw_frontend_ip_config_name
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  backend_address_pool {
    name  = local.agw_backend_pool_name
    fqdns = [local.aca_fqdn]
  }

  probe {
    name                = local.agw_probe_name
    protocol            = "Http"
    host                = local.aca_fqdn
    path                = "/status/200"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3

    match {
      status_code = ["200-399"]
    }
  }

  backend_http_settings {
    name                  = local.agw_backend_http_settings_name
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
    probe_name            = local.agw_probe_name
    host_name             = local.aca_fqdn
  }

  http_listener {
    name                           = local.agw_http_listener_name
    frontend_ip_configuration_name = local.agw_frontend_ip_config_name
    frontend_port_name             = local.agw_frontend_port_name
    protocol                       = "Http"
    # NOTE: In production, replace this listener with HTTPS and attach a cert:
    # ssl_certificate_name = "my-cert"
    # frontend_port name   = "feport-https" (port 443)
  }

  request_routing_rule {
    name                       = local.agw_request_routing_rule_name
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = local.agw_http_listener_name
    backend_address_pool_name  = local.agw_backend_pool_name
    backend_http_settings_name = local.agw_backend_http_settings_name
  }
}

###############################################################################
# Diagnostic Settings – stream AGW + ACA logs to Log Analytics
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "agw" {
  name                       = "diag-agw"
  target_resource_id         = azurerm_application_gateway.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "ApplicationGatewayAccessLog" }
  enabled_log { category = "ApplicationGatewayFirewallLog" }
  metric { category = "AllMetrics" }
}
