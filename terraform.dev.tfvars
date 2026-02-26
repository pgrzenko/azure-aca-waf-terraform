###############################################################################
# terraform.dev.tfvars – Development environment overrides
# Usage: terraform plan -var-file=terraform.dev.tfvars
###############################################################################

subscription_id  = "00000000-0000-0000-0000-000000000000"   # Replace with real value
project          = "flow64api"
environment      = "dev"
location         = "westeurope"
aca_min_replicas = 0   # Scale-to-zero in dev to save cost
aca_max_replicas = 3

tags = {
  project    = "flow64api"
  managed_by = "terraform"
  owner      = "flow64"
  env        = "dev"
  cost_center = "engineering"
}
