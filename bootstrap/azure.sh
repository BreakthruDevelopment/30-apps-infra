#!/usr/bin/env bash
# One-time Azure setup for the 30 apps portfolio. Run in Azure Cloud Shell (Bash), already signed in:
#   curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/azure.sh | bash
#
# Creates:
#   - resource group rg-30apps-shared with a storage account for Terraform state
#   - two app registrations GitHub Actions signs in as, with no secrets (federated credentials),
#     usable ONLY by BreakthruDevelopment/30-apps-infra:
#       github-30apps-deploy  (Contributor; only the "production" environment, which is limited to main)
#       github-30apps-plan    (Reader; pull requests, for terraform plan)
#   - registers the resource providers the apps need
# Safe to run again.
set -euo pipefail

ORG="BreakthruDevelopment"
REPO="30-apps-infra"
LOCATION="eastus"
RG="rg-30apps-shared"

# GitHub orgs using immutable subject claims send "repo:ORG@<owner id>/REPO@<repo id>:...".
# Trust both that form and the plain one, so either setting works.
GH_IDS="$(curl -fsSL "https://api.github.com/repos/${ORG}/${REPO}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["owner"]["id"], d["id"])')"
OWNER_ID="${GH_IDS% *}"
REPO_ID="${GH_IDS#* }"
ID_PREFIX="repo:${ORG}@${OWNER_ID}/${REPO}@${REPO_ID}"

SUB="$(az account show --query id -o tsv)"
TENANT="$(az account show --query tenantId -o tsv)"
SA="tf30apps$(echo "$SUB" | tr -d '-' | cut -c1-12)"
echo "Subscription ${SUB}, tenant ${TENANT}"

for p in Microsoft.App Microsoft.OperationalInsights Microsoft.DBforPostgreSQL Microsoft.Storage; do
  az provider register --namespace "$p" >/dev/null
done
echo "Resource providers registering (this finishes in the background)"

# --- Terraform state ----------------------------------------------------------
az group create -n "$RG" -l "$LOCATION" -o none
if ! az storage account show -n "$SA" -g "$RG" -o none 2>/dev/null; then
  az storage account create -n "$SA" -g "$RG" -l "$LOCATION" --sku Standard_LRS \
    --min-tls-version TLS1_2 --allow-blob-public-access false -o none
  echo "Created state storage account $SA"
fi
az storage account blob-service-properties update -n "$SA" -g "$RG" --enable-versioning true -o none
KEY="$(az storage account keys list -n "$SA" -g "$RG" --query '[0].value' -o tsv)"
az storage container create -n tfstate --account-name "$SA" --account-key "$KEY" -o none
SA_ID="$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)"

# --- App registrations with federated credentials ----------------------------
ensure_app() {  # $1 display name, $2 credential name, $3 subject → prints appId
  local app
  app="$(az ad app list --display-name "$1" --query '[0].appId' -o tsv)"
  if [ -z "$app" ]; then
    app="$(az ad app create --display-name "$1" --query appId -o tsv)"
  fi
  az ad sp show --id "$app" -o none 2>/dev/null || az ad sp create --id "$app" -o none
  add_cred "$app" "$2" "$3"
  echo "$app"
}

add_cred() {  # $1 appId, $2 credential name, $3 subject
  if ! az ad app federated-credential list --id "$1" --query "[?name=='$2'].name" -o tsv | grep -q .; then
    az ad app federated-credential create --id "$1" -o none --parameters "{
      \"name\": \"$2\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$3\",
      \"audiences\": [\"api://AzureADTokenExchange\"]}"
  fi
}

assign() {  # $1 appId, $2 role, $3 scope
  local sp
  sp="$(az ad sp show --id "$1" --query id -o tsv)"
  az role assignment create --assignee-object-id "$sp" --assignee-principal-type ServicePrincipal \
    --role "$2" --scope "$3" -o none 2>/dev/null || true
}

DEPLOY_APP="$(ensure_app github-30apps-deploy production "repo:${ORG}/${REPO}:environment:production")"
PLAN_APP="$(ensure_app github-30apps-plan pull-request "repo:${ORG}/${REPO}:pull_request")"
add_cred "$DEPLOY_APP" production-ids "${ID_PREFIX}:environment:production"
add_cred "$PLAN_APP" pull-request-ids "${ID_PREFIX}:pull_request"
echo "GitHub trust configured for ${ID_PREFIX} and repo:${ORG}/${REPO}"

# New service principals take a few seconds to appear for role assignment.
sleep 20
assign "$DEPLOY_APP" Contributor "/subscriptions/${SUB}"
assign "$DEPLOY_APP" "Storage Blob Data Contributor" "$SA_ID"
assign "$PLAN_APP" Reader "/subscriptions/${SUB}"
assign "$PLAN_APP" "Storage Blob Data Reader" "$SA_ID"
echo "Roles assigned"

cat <<EOF

============================================================
Azure is ready. Add these as GitHub repository VARIABLES (not secrets) in
BreakthruDevelopment/30-apps-infra → Settings → Secrets and variables → Actions → Variables:

  AZURE_TENANT_ID          ${TENANT}
  AZURE_SUBSCRIPTION_ID    ${SUB}
  AZURE_LOCATION           ${LOCATION}
  AZURE_STATE_RG           ${RG}
  AZURE_STATE_ACCOUNT      ${SA}
  AZURE_DEPLOY_CLIENT_ID   ${DEPLOY_APP}
  AZURE_PLAN_CLIENT_ID     ${PLAN_APP}

None of these are secret. No client secrets were created.
============================================================
EOF
