###############################################################################
# terraform.prod.tfvars – Production environment overrides
# Usage: terraform plan -var-file=terraform.prod.tfvars
###############################################################################

subscription_id  = "00000000-0000-0000-0000-000000000000"   # Replace with real value
project          = "flow64api"
environment      = "prod"
location         = "westeurope"
aca_min_replicas = 2   # Always-on in production
aca_max_replicas = 10

tags = {
  project     = "flow64api"
  managed_by  = "terraform"
  owner       = "flow64"
  env         = "prod"
  cost_center = "production"
  criticality = "high"
}
