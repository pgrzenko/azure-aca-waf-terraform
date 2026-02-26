###############################################################################
# variables.tf
###############################################################################

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "project" {
  description = "Short project name used in resource naming"
  type        = string
  default     = "flow64api"
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "aca_min_replicas" {
  description = "Minimum Container App replicas (0 = scale-to-zero)"
  type        = number
  default     = 1
}

variable "aca_max_replicas" {
  description = "Maximum Container App replicas"
  type        = number
  default     = 5
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default = {
    project     = "flow64api"
    managed_by  = "terraform"
    owner       = "flow64"
  }
}
