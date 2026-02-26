#!/usr/bin/env bash
###############################################################################
# bootstrap.sh – Create Terraform remote state backend (run once per env)
#
# Why a separate script and not Terraform?
#   Terraform needs a backend to store its state, but the backend itself
#   can't be managed by Terraform (chicken-and-egg problem). This script
#   creates the Azure Storage Account that Terraform will use as its backend.
#   Run it once per environment before the first `terraform init`.
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh dev westeurope
#
# Requires: az CLI logged in with Contributor rights on the target subscription
###############################################################################

# Exit immediately on any error (-e), treat unset variables as errors (-u),
# and fail pipelines if any command in a pipe fails (-o pipefail).
# This prevents the script from silently continuing after a failure.
set -euo pipefail

ENV="${1:-dev}"
LOCATION="${2:-westeurope}"
RG_NAME="rg-tfstate-${ENV}"
# Storage account names must be globally unique across all of Azure (3-24 chars,
# lowercase alphanumeric only). Appending a random 6-char suffix avoids
# collisions without requiring manual coordination.
SA_NAME="sttfstate${ENV}$(head /dev/urandom | tr -dc 'a-z0-9' | head -c6)"
CONTAINER="tfstate"

echo "=== Terraform Backend Bootstrap ==="
echo "Environment : $ENV"
echo "Location    : $LOCATION"
echo "RG          : $RG_NAME"
echo "Storage     : $SA_NAME"

# Create a dedicated resource group for the state backend.
# Keeping tfstate in its own RG (separate from workload resources) means
# `terraform destroy` on the workload won't accidentally delete the state file.
# Tags identify this as a bootstrap-managed resource, not a Terraform-managed one.
az group create \
  --name "$RG_NAME" \
  --location "$LOCATION" \
  --tags managed_by=bootstrap env="$ENV" > /dev/null

# Create the storage account with security-hardened settings:
#
# --sku Standard_ZRS (Zone-Redundant Storage):
#   Replicates data across 3 availability zones in the same region. If one zone
#   goes down, the state file remains accessible. LRS would be cheaper but
#   losing state in a zone failure would be catastrophic (manual state recovery).
#
# --kind StorageV2:
#   General-purpose v2 — supports blob versioning and soft-delete, which are
#   critical for state file recovery. V1 does not support these features.
#
# --min-tls-version TLS1_2:
#   Rejects connections using TLS 1.0/1.1 (deprecated, known vulnerabilities).
#   Azure defaults vary; setting this explicitly ensures compliance.
#
# --allow-blob-public-access false:
#   Prevents any container or blob from being made publicly accessible, even
#   if someone misconfigures a container's access level. State files contain
#   sensitive resource IDs and configuration — they must never be public.
#
# --https-only true:
#   Blocks plain HTTP access to the storage account. All API calls (including
#   Terraform's) must use HTTPS, preventing state data from being intercepted.
az storage account create \
  --name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION" \
  --sku Standard_ZRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --https-only true \
  --tags managed_by=bootstrap env="$ENV" > /dev/null

# Enable blob versioning and soft-delete for state file protection:
#
# --enable-versioning true:
#   Every overwrite of the state file creates a new version. If a bad apply
#   corrupts the state, you can restore a previous version from the Azure portal
#   or az CLI without needing a separate backup mechanism.
#
# --enable-delete-retention true / --delete-retention-days 30:
#   Deleted blobs are retained for 30 days before permanent removal. If someone
#   accidentally deletes the state file, it can be recovered within that window.
#   30 days is long enough to catch mistakes without accumulating excessive
#   storage costs (state files are typically < 100 KB).
az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 > /dev/null

# Create the blob container that Terraform will write state files to.
# --auth-mode login: uses the current az CLI session's Azure AD credentials
# instead of storage account keys. This is more secure because it doesn't
# require generating or storing access keys — access is controlled via RBAC.
az storage container create \
  --name "$CONTAINER" \
  --account-name "$SA_NAME" \
  --auth-mode login > /dev/null

echo ""
echo "Backend ready. Add these to ADO Variable Group 'vg-terraform-${ENV}':"
echo "   TF_BACKEND_RG        = $RG_NAME"
echo "   TF_BACKEND_SA        = $SA_NAME"
echo "   TF_BACKEND_CONTAINER = $CONTAINER"
