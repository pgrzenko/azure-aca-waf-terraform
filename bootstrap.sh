#!/usr/bin/env bash
###############################################################################
# bootstrap.sh – Create Terraform remote state backend (run once per sub)
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh dev westeurope
#
# Requires: az CLI logged in with Contributor rights
###############################################################################

set -euo pipefail

ENV="${1:-dev}"
LOCATION="${2:-westeurope}"
RG_NAME="rg-tfstate-${ENV}"
SA_NAME="sttfstate${ENV}$(head /dev/urandom | tr -dc 'a-z0-9' | head -c6)"
CONTAINER="tfstate"

echo "=== Terraform Backend Bootstrap ==="
echo "Environment : $ENV"
echo "Location    : $LOCATION"
echo "RG          : $RG_NAME"
echo "Storage     : $SA_NAME"

# Create Resource Group
az group create \
  --name "$RG_NAME" \
  --location "$LOCATION" \
  --tags managed_by=bootstrap env="$ENV" > /dev/null

# Create Storage Account (ZRS for redundancy)
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

# Enable blob soft-delete (30 days) + versioning
az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 > /dev/null

# Create container
az storage container create \
  --name "$CONTAINER" \
  --account-name "$SA_NAME" \
  --auth-mode login > /dev/null

echo ""
echo "✅ Backend ready. Add these to ADO Variable Group 'vg-terraform-${ENV}':"
echo "   TF_BACKEND_RG        = $RG_NAME"
echo "   TF_BACKEND_SA        = $SA_NAME"
echo "   TF_BACKEND_CONTAINER = $CONTAINER"
