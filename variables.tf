###############################################################################
# variables.tf – Input variable definitions
#
# Design: all environment-specific values live in .tfvars files. This file
# defines sensible defaults for dev. Sensitive values (subscription_id) have
# no default — they must be explicitly provided via tfvars or pipeline
# variables, which prevents accidental deployments to wrong subscriptions.
###############################################################################

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
  # No default — forces explicit injection from the pipeline Variable Group
  # (stored as a secret). This is a safety measure: you can never accidentally
  # plan/apply against the wrong subscription.
}

variable "project" {
  description = "Short project name used in resource naming"
  type        = string
  default     = "flow64api"
  # Used as the first segment in all resource names (e.g., rg-flow64api-dev).
  # Keep it short — Azure has name length limits (e.g., 24 chars for Storage).
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  default     = "dev"

  # Validation prevents typos (e.g., "production" instead of "prod") that would
  # create orphaned resources with unexpected names. Terraform fails at plan
  # time rather than deploying to a mystery environment.
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
  # West Europe (Netherlands) chosen for low latency to Central European users.
  # All resources deploy to the same region to avoid cross-region data transfer
  # costs and latency. Multi-region would require Front Door instead of App GW.
}

variable "aca_min_replicas" {
  description = "Minimum Container App replicas (0 = scale-to-zero)"
  type        = number
  default     = 1
  # Dev override: 0 (scale-to-zero saves ~€5/mo when idle)
  # Prod override: 2 (always-on avoids 5-10s cold-start latency that would
  # cause health probe failures and user-facing timeouts)
}

variable "aca_max_replicas" {
  description = "Maximum Container App replicas"
  type        = number
  default     = 5
  # Upper bound for autoscaling. KEDA scales up based on the HTTP concurrent
  # requests rule defined in main.tf. Set higher in prod if load testing shows
  # the need. Each replica costs ~€0.000012/s when active.
}

variable "tags" {
  description = "Common resource tags applied to every resource"
  type        = map(string)
  default = {
    project    = "flow64api"
    managed_by = "terraform"
    owner      = "flow64"
  }
  # Tags enable cost attribution, ownership tracking, and policy enforcement.
  # "managed_by = terraform" tells operators not to make manual changes that
  # would cause state drift. Environment-specific tags (env, cost_center) are
  # added in the tfvars files.
}
