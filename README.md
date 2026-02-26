# Azure Container Apps + Application Gateway WAF – Terraform + Azure DevOps

Production-ready IaC for running a Dockerized API behind Azure Application Gateway (WAF_v2) with full CI/CD via Azure DevOps Pipelines.

> **Stack:** Terraform 1.7 · Azure Container Apps · App Gateway WAF_v2 · OWASP 3.2 · Azure DevOps YAML · Log Analytics

---

## Architecture Overview

```
Internet
    │  HTTPS/HTTP
    ▼
┌─────────────────────────────────────┐
│  Application Gateway (WAF_v2)       │
│  • Public IP (Standard SKU)         │
│  • WAF Policy – OWASP 3.2           │
│  • Bot Manager 1.0                  │
│  • Prevention Mode                  │
│  • Rate-limit custom rule           │
└─────────────────┬───────────────────┘
                  │ Internal VNet (10.0.2.0/23)
                  ▼
┌─────────────────────────────────────┐
│  Container Apps Environment         │
│  (VNet-integrated, internal LB)     │
│                                     │
│  ┌─────────────────────────────┐    │
│  │  Container App – httpbin    │    │
│  │  image: kennethreitz/httpbin│    │
│  │  CPU: 0.5 / RAM: 1Gi        │    │
│  │  Scale: HTTP concurrent reqs│    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
                  │
                  ▼
        Log Analytics Workspace
        (AGW + ACA diagnostics)
```

**Security posture:**
- Container App has **no public ingress** – traffic enters exclusively via App Gateway
- WAF in **Prevention mode** with OWASP 3.2 + Bot Manager rule sets
- Subnets are isolated; ACA subnet is delegated
- TLS termination point is the App Gateway (production: attach cert + HTTPS listener)
- Remote state stored in Storage Account with soft-delete + versioning

---

## Repository Structure

```
.
├── terraform/
│   ├── main.tf                  # Core infrastructure
│   ├── variables.tf             # Input variable definitions
│   ├── outputs.tf               # Output values
│   ├── terraform.dev.tfvars     # Dev environment values
│   └── terraform.prod.tfvars   # Prod environment values
│
├── pipeline/
│   └── azure-pipelines.yml      # CI/CD pipeline (4 stages)
│
├── bootstrap.sh                 # One-time backend setup script
└── README.md
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | ≥ 1.6 |
| Azure CLI | ≥ 2.55 |
| Azure DevOps | Any |
| Azure Subscription | Contributor role |

---

## Quick Start

### 1. Bootstrap Remote State (once per environment)

```bash
chmod +x bootstrap.sh
./bootstrap.sh dev westeurope
```

Copy the printed values into your ADO Variable Group (see step 3).

### 2. Update tfvars

Edit `terraform/terraform.dev.tfvars` – replace `subscription_id` with your real value.

### 3. Azure DevOps Setup

**Service Connection:**
```
Project Settings → Service Connections → New → Azure Resource Manager
Name: sc-azure-dev   (sc-azure-prod for prod)
Type: Workload Identity Federation (recommended) or Service Principal
```

**Variable Group** (`vg-terraform-dev`):

| Variable | Value | Secret? |
|----------|-------|---------|
| `TF_VAR_subscription_id` | Your subscription GUID | ✅ Yes |
| `TF_BACKEND_RG` | From bootstrap output | No |
| `TF_BACKEND_SA` | From bootstrap output | No |
| `TF_BACKEND_CONTAINER` | `tfstate` | No |

### 4. Import Pipeline

In Azure DevOps: **Pipelines → New Pipeline → Azure Repos Git → Existing YAML file**  
Path: `pipeline/azure-pipelines.yml`

### 5. Run

| Action | When |
|--------|------|
| PR opened | Validate + Plan (no Apply) |
| Merge to `main` | Validate + Plan + Apply (dev auto-approve, prod manual gate) |
| Manual trigger | Select `environment` + `action` parameters |

---

## Pipeline Stages

```
┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│  1. Validate │──▶│  2. Plan     │──▶│  3. Apply    │──▶│  4. Smoke    │
│              │   │              │   │              │   │    Test      │
│ • fmt check  │   │ • tf init    │   │ • Approval   │   │              │
│ • tf validate│   │ • tf plan    │   │   gate (prod)│   │ • HTTP retry │
│ • tfsec scan │   │ • artifact   │   │ • tf apply   │   │   to AGW IP  │
└──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
```

- **tfsec** runs on every validate – warnings don't block, errors do (configurable)
- **Manual approval gate** activates on `staging` and `prod` environments
- **Smoke test** retries HTTP check 10× with 30s backoff (App Gateway takes ~2–5 min to provision)

---

## Terraform Resources

| Resource | Purpose |
|----------|---------|
| `azurerm_resource_group` | Container for all resources |
| `azurerm_virtual_network` | Isolated network (10.0.0.0/16) |
| `azurerm_subnet` (agw) | Dedicated /24 for App Gateway |
| `azurerm_subnet` (aca) | Delegated /23 for Container Apps |
| `azurerm_log_analytics_workspace` | Centralized logging |
| `azurerm_container_app_environment` | Internal-LB ACA environment |
| `azurerm_container_app` | httpbin API with HTTP probes + autoscale |
| `azurerm_public_ip` | Static Standard IP for App Gateway |
| `azurerm_web_application_firewall_policy` | WAF – OWASP 3.2 + Bot Manager |
| `azurerm_application_gateway` | WAF_v2 SKU, autoscale 1–5 |
| `azurerm_monitor_diagnostic_setting` | Stream AGW logs to Log Analytics |

---

## Production Hardening Checklist

- [ ] Replace HTTP listener with HTTPS + SSL certificate (`azurerm_key_vault_certificate`)
- [ ] Add `azurerm_key_vault` for secrets management (Container App env vars)
- [ ] Enable Defender for Containers on the ACA environment
- [ ] Configure custom domain + DNS zone (`azurerm_dns_a_record`)
- [ ] Set `aca_min_replicas = 2` in prod (no scale-to-zero for latency-sensitive APIs)
- [ ] Add `azurerm_monitor_alert_rule` for WAF block rate and ACA 5xx
- [ ] Pin container image tag – never use `:latest` in production
- [ ] Enable Private Link on Storage Account (tfstate backend)
- [ ] Integrate tfsec findings into Azure Security Center / Defender for DevOps

---

## Outputs

After `terraform apply`:

```bash
terraform output app_gateway_public_ip   # Public entry point
terraform output container_app_fqdn     # Internal ACA FQDN (not directly reachable)
terraform output log_analytics_workspace_id
```

Test the deployment:
```bash
curl http://$(terraform output -raw app_gateway_public_ip)/get
```

---

## Cost Estimate (West Europe, dev config)

| Resource | ~Monthly Cost |
|----------|--------------|
| App Gateway WAF_v2 (1 unit) | ~€180 |
| Container Apps (scale-to-zero) | ~€0–5 |
| Log Analytics (30-day retention) | ~€2–10 |
| Public IP | ~€3 |
| Storage (tfstate) | < €1 |
| **Total** | **~€185–200/month** |

> App Gateway WAF_v2 dominates cost. For dev, consider Azure Front Door Standard (~€35/month) as a cheaper WAF alternative.

---

## Author

Built by **Przemysław Grzenkowicz** / [Flow64](https://github.com/pgrzenko)  
Part of the **FLOWer Recruit** platform – ATS Match Engine & Infrastructure Engineering reference implementations.

LinkedIn: [linkedin.com/in/pgrzenkowicz](https://linkedin.com/in/pgrzenkowicz) | GitHub: [github.com/pgrzenko](https://github.com/pgrzenko)
