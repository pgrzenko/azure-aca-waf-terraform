# Architecture Decision Record

This document explains the architectural decisions behind this infrastructure. Each section answers the "why" — the reasoning an interviewer would probe during a technical review.

---

## Why Azure Container Apps over AKS

Azure Container Apps (ACA) was chosen over Azure Kubernetes Service (AKS) for several reasons specific to this use case:

**Operational overhead.** AKS requires managing the control plane upgrades, node pool scaling, RBAC configuration, and networking plugins (kubenet vs Azure CNI). ACA abstracts all of this — Microsoft manages the underlying Kubernetes cluster. For a single-service API workload, the full power of AKS is unnecessary.

**Scale-to-zero.** ACA natively supports scaling to zero replicas when idle. AKS requires KEDA installed and configured separately, and you still pay for at least one node even with zero pods. In dev, scale-to-zero reduces the ACA cost to near zero when the service isn't receiving traffic.

**Cost.** An AKS cluster requires at minimum one VM (Standard_B2s at ~€30/month) plus the optional uptime SLA (€60/month for production). ACA bills per-second on consumed vCPU and memory — for a demo workload with intermittent traffic, the difference is significant.

**When AKS would be the better choice:** multiple tightly-coupled microservices, custom networking requirements (service mesh, network policies), workloads needing GPU nodes, or teams that already operate Kubernetes and need fine-grained control.

---

## Why Application Gateway WAF_v2 over Azure Front Door

**Network topology simplicity.** Application Gateway deploys inside the VNet, giving it direct L7 access to the ACA internal load balancer. No Private Link or public exposure of the backend is needed. Front Door operates at the edge (Microsoft's global PoP network) and requires either a public backend or a Private Link origin — both of which add complexity for a single-region deployment.

**Same WAF capabilities.** Both App Gateway WAF and Front Door WAF support OWASP Core Rule Sets and the Microsoft Bot Manager. The rule engine is identical; the difference is where inspection happens (regional VNet vs global edge).

**Cost for single-region.** App Gateway WAF_v2 with autoscale (1-5 units) costs ~€180/month. Front Door Premium (required for Private Link origins) starts at ~€275/month. Front Door Standard is cheaper (~€35/month) but lacks WAF rule customization and doesn't support Private Link to ACA.

**When Front Door would be the better choice:** multi-region deployments needing global load balancing, anycast routing, and edge caching. If this workload expanded to multiple regions, the architecture should migrate from App Gateway to Front Door.

---

## Networking Topology

```
Internet
    │
    ▼
┌──────────────────────────────────────────────┐
│  VNet: 10.0.0.0/16                           │
│                                              │
│  ┌─────────────────────┐                     │
│  │ snet-agw: 10.0.1.0/24                    │
│  │ (App Gateway subnet — dedicated)          │
│  │ App Gateway WAF_v2                        │
│  │   ← Public IP (Standard, Static)         │
│  └───────────┬─────────┘                     │
│              │ Routes to ACA internal FQDN   │
│  ┌───────────▼─────────┐                     │
│  │ snet-aca: 10.0.2.0/23                    │
│  │ (Delegated to Microsoft.App/environments) │
│  │ Container Apps Environment (internal LB)  │
│  │   Container App: httpbin                  │
│  └─────────────────────┘                     │
└──────────────────────────────────────────────┘
```

**Why the Container App has no public ingress:**
- `internal_load_balancer_enabled = true` on the ACA Environment means Azure assigns only a private IP. There is no public DNS record, no public IP, no way to reach the container from the internet directly.
- `external_enabled = false` on the Container App's ingress limits it to VNet-internal traffic only.
- All inbound traffic must pass through the Application Gateway, which enforces WAF inspection. There is no bypass path.

**Subnet sizing:**
- App Gateway subnet: /24 (256 addresses). App Gateway requires a dedicated subnet and can consume multiple IPs during autoscaling (one per instance).
- ACA subnet: /23 (512 addresses). Azure Container Apps requires a minimum /23 when VNet-integrated. The platform reserves IPs for the internal load balancer, Envoy sidecars, and KEDA components.

**Why a /16 VNet:** over-provisioned intentionally. Future additions (Private Endpoints for Key Vault or Storage, Bastion host, VPN Gateway) need their own subnets. Re-addressing a VNet in production is disruptive.

---

## Security Decisions

### WAF in Prevention Mode (not Detection)

Detection mode logs attacks but lets them through — useful during initial rollout to identify false positives. This deployment starts in Prevention mode because:
- The backend (httpbin) is a well-known service with predictable traffic patterns.
- Starting strict and relaxing rules is safer than starting permissive and tightening later.
- In a recruitment demo, Prevention mode demonstrates a security-first posture.

In production, the recommended approach is: deploy in Detection mode for 1-2 weeks, review the WAF logs for false positives, add exclusions for legitimate patterns, then switch to Prevention.

### OWASP 3.2

Version 3.2 is the latest OWASP Core Rule Set supported by Azure Application Gateway WAF. It covers the OWASP Top 10: SQL injection, XSS, local/remote file inclusion, command injection, and protocol violations. Earlier versions (3.1, 3.0) have known bypass techniques that 3.2 addresses.

### Bot Manager 1.0

The Microsoft Bot Manager rule set classifies traffic into good bots (Googlebot, Bingbot), bad bots (known scrapers, vulnerability scanners), and unknown. In Prevention mode, bad bots are blocked automatically. This adds a layer of protection against automated reconnaissance without requiring IP-based allow/deny lists.

### Rate Limiting (300 req/min per client IP)

A custom WAF rule blocks any single client IP exceeding 300 requests per minute. This is a baseline defence against:
- Application-layer DDoS
- Credential stuffing
- API abuse and scraping

The threshold is intentionally conservative. Production tuning would raise or lower it based on observed traffic patterns and add exclusions for monitoring systems and health checks.

---

## Scaling Strategy

| Setting | Dev | Prod | Why |
|---------|-----|------|-----|
| `aca_min_replicas` | 0 | 2 | Dev scales to zero when idle (saves cost). Prod keeps 2 replicas always running to avoid cold-start latency (5-10 seconds) that would cause health probe failures and user-visible timeouts. |
| `aca_max_replicas` | 3 | 10 | Dev caps at 3 to limit cost. Prod allows 10 to handle traffic spikes. |
| Scale trigger | HTTP concurrent requests > 50 | Same | KEDA HTTP scaler. When any replica has more than 50 concurrent requests, ACA adds another replica. HTTP-based scaling is more responsive than CPU-based for I/O-bound web APIs. |
| App Gateway autoscale | 1–5 capacity units | Same | Each unit handles ~10 Mbps / ~6,000 connections. Min=1 keeps dev cost at one unit. Max=5 handles moderate production traffic. |

---

## Remote State Design

### Why Azure Storage (not Terraform Cloud, not local state)

- **Azure Storage** integrates natively with the `azurerm` backend — no additional SaaS accounts or API keys needed. The ADO Service Principal that deploys infrastructure can also read/write state using the same RBAC.
- **Terraform Cloud** adds a dependency on an external SaaS. For a single-team, single-repo project, the overhead of a remote execution environment isn't justified.
- **Local state** is not an option for CI/CD — each pipeline run executes on a fresh agent with no filesystem persistence.

### Backend Hardening (bootstrap.sh)

| Setting | Why |
|---------|-----|
| ZRS (Zone-Redundant Storage) | State file survives a full availability zone failure. LRS would risk data loss. |
| Blob versioning | Every `terraform apply` overwrites the state file. Versioning preserves all previous versions, enabling rollback if state corruption occurs. |
| Soft-delete (30 days) | Protects against accidental deletion. A deleted state file can be recovered within 30 days. |
| TLS 1.2 minimum | Blocks connections using deprecated TLS 1.0/1.1 (known vulnerabilities). |
| No public blob access | Even if someone misconfigures the container access level, the storage account-level setting prevents public exposure of state files (which contain resource IDs and configuration). |
| HTTPS only | Prevents state data from being transmitted in plaintext over the network. |
| `--auth-mode login` | Uses Azure AD RBAC instead of storage account keys. Keys are shared secrets that grant full access; RBAC allows scoped, auditable, revocable access per identity. |

### State Isolation

Each environment (dev, staging, prod) gets its own state file key (`aca-waf/dev/terraform.tfstate`, `aca-waf/prod/terraform.tfstate`). This prevents a dev `terraform destroy` from reading prod state and vice versa. Variable Groups in ADO enforce this isolation at the pipeline level.

---

## Cost Breakdown

### Dev Environment (West Europe)

| Resource | Monthly Estimate | Notes |
|----------|-----------------|-------|
| Application Gateway WAF_v2 | ~€180 | Fixed cost for the gateway + WAF processing. Dominates the bill. |
| Container Apps | €0–5 | Scale-to-zero when idle. Billed per-second on active vCPU/memory. |
| Log Analytics (30-day retention) | €2–10 | Depends on log volume. WAF logs can be verbose under attack. |
| Public IP (Standard) | ~€3 | Fixed monthly cost for a static public IP. |
| Storage Account (tfstate) | < €1 | State files are typically < 100 KB. |
| **Total** | **~€185–200/month** | |

### Cost Trade-offs

- **App Gateway is the cost driver.** For dev/testing, Azure Front Door Standard (~€35/month) would be significantly cheaper, but it can't route to an internal ACA environment without Private Link (which adds its own cost and complexity).
- **Scale-to-zero saves minimal money** in this architecture because the App Gateway fixed cost dwarfs the ACA compute cost. The savings are ~€5/month, but scale-to-zero remains valuable as a pattern that transfers to production workloads behind shared gateways.
- **Production cost multiplier:** prod runs `min_replicas=2` and `max_replicas=10`, adding ~€20-50/month in ACA compute depending on load. The App Gateway cost stays roughly the same (autoscale adjusts within the same pricing tier).

---

## Production Hardening — Next Steps

These are the changes needed to take this from a recruitment demo to production-ready infrastructure:

1. **HTTPS termination.** Replace the HTTP listener with HTTPS + an SSL certificate from Azure Key Vault. Add an HTTP→HTTPS redirect rule. This is the single most important security gap in the current configuration.

2. **Secrets management.** Add `azurerm_key_vault` to store application secrets (API keys, database connection strings). Container App environment variables should reference Key Vault secrets, not plaintext values.

3. **Custom domain + DNS.** Create an `azurerm_dns_zone` and an A record pointing to the App Gateway public IP. Configure the certificate for the custom domain.

4. **Monitoring and alerting.** Add `azurerm_monitor_metric_alert` rules for:
   - WAF block rate spikes (potential attack or false-positive storm)
   - ACA 5xx error rate (application failures)
   - App Gateway backend health (ACA unreachable)
   - Log Analytics ingestion anomalies

5. **Image pinning.** Replace `kennethreitz/httpbin:latest` with a pinned digest or semver tag. `:latest` in production leads to unpredictable deployments when the upstream image changes.

6. **Private Link for state backend.** The Storage Account holding Terraform state is currently accessible over the public internet (with authentication). Adding a Private Endpoint restricts access to the VNet, reducing the attack surface.

7. **Defender for Containers.** Enable Microsoft Defender for the ACA environment to get vulnerability scanning on container images and runtime threat detection.

8. **Network Security Groups.** Add NSGs to both subnets with explicit allow/deny rules. Currently, subnet isolation relies on Azure's default deny between subnets. Explicit NSGs provide defense in depth and audit visibility.

9. **Terraform state locking.** The azurerm backend supports state locking via blob leases. This is enabled by default but should be verified — concurrent applies without locking can corrupt state.

10. **Multi-environment pipeline validation.** Add a pipeline stage that runs `terraform plan` against prod after applying to dev, catching configuration drift before it reaches production.
