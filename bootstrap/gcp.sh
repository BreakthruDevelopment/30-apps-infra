#!/usr/bin/env bash
# One-time Google Cloud setup for the 30 apps portfolio. Run in Google Cloud Shell, already signed in:
#   curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/gcp.sh | bash -s -- YOUR_PROJECT_ID
#
# Creates, in that project:
#   - the APIs the apps use
#   - a private, versioned bucket for Terraform state (us-central1)
#   - Workload Identity Federation for GitHub, accepting ONLY BreakthruDevelopment/30-apps-infra
#   - two service accounts GitHub Actions acts as, with no keys:
#       gh-30apps-deploy  (Editor + Cloud Run admin; only the "production" environment, limited to main)
#       gh-30apps-plan    (Viewer; pull requests, for terraform plan)
# Safe to run again.
set -euo pipefail

ORG="BreakthruDevelopment"
REPO="30-apps-infra"
REGION="us-central1"   # one of the always-free regions
PROJECT="${1:-$(gcloud config get-value project 2>/dev/null || true)}"

# GitHub orgs using immutable subject claims send "repo:ORG@<owner id>/REPO@<repo id>:...".
# Trust both that form and the plain one, so either setting works.
GH_IDS="$(curl -fsSL "https://api.github.com/repos/${ORG}/${REPO}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["owner"]["id"], d["id"])')"
OWNER_ID="${GH_IDS% *}"
REPO_ID="${GH_IDS#* }"
ID_PREFIX="repo:${ORG}@${OWNER_ID}/${REPO}@${REPO_ID}"

if [ -z "$PROJECT" ]; then
  echo "Pass your project ID: ... | bash -s -- YOUR_PROJECT_ID"
  echo "Your projects:"; gcloud projects list --format='table(projectId,name)'
  exit 1
fi
gcloud config set project "$PROJECT" >/dev/null
NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
BUCKET="${PROJECT}-tfstate"
POOL="github"
PROVIDER="github-30-apps-infra"
PRINCIPAL="principal://iam.googleapis.com/projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/subject"
echo "Project ${PROJECT} (${NUMBER}), region ${REGION}"

gcloud services enable run.googleapis.com artifactregistry.googleapis.com compute.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com
echo "APIs enabled"

# --- Terraform state ----------------------------------------------------------
if ! gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${BUCKET}" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
  echo "Created state bucket gs://${BUCKET}"
fi
gcloud storage buckets update "gs://${BUCKET}" --versioning >/dev/null

# --- Workload Identity Federation ----------------------------------------------
gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$POOL" --location=global --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global \
  --workload-identity-pool="$POOL" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" --display-name="30-apps-infra" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository=='${ORG}/${REPO}'"

# --- Service accounts ---------------------------------------------------------
ensure_sa() {
  gcloud iam service-accounts describe "$1@${PROJECT}.iam.gserviceaccount.com" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$1" --display-name="$2"
}
ensure_sa gh-30apps-deploy "GitHub Actions deploy (30-apps-infra, production)"
ensure_sa gh-30apps-plan "GitHub Actions plan (30-apps-infra, pull requests)"
DEPLOY_SA="gh-30apps-deploy@${PROJECT}.iam.gserviceaccount.com"
PLAN_SA="gh-30apps-plan@${PROJECT}.iam.gserviceaccount.com"

grant() {  # retries: brand-new service accounts take a few seconds to be visible to IAM
  for _ in 1 2 3 4 5 6; do
    gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$1" --role="$2" \
      --condition=None >/dev/null 2>&1 && return 0
    sleep 10
  done
  gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$1" --role="$2" --condition=None >/dev/null
}
for r in roles/editor roles/run.admin roles/iam.serviceAccountUser roles/secretmanager.admin; do grant "$DEPLOY_SA" "$r"; done
for r in roles/viewer roles/secretmanager.secretAccessor; do grant "$PLAN_SA" "$r"; done
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --member="serviceAccount:${PLAN_SA}" \
  --role=roles/storage.objectViewer >/dev/null

gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" --role=roles/iam.workloadIdentityUser \
  --member="${PRINCIPAL}/repo:${ORG}/${REPO}:environment:production" >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$PLAN_SA" --role=roles/iam.workloadIdentityUser \
  --member="${PRINCIPAL}/repo:${ORG}/${REPO}:pull_request" >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" --role=roles/iam.workloadIdentityUser \
  --member="${PRINCIPAL}/${ID_PREFIX}:environment:production" >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$PLAN_SA" --role=roles/iam.workloadIdentityUser \
  --member="${PRINCIPAL}/${ID_PREFIX}:pull_request" >/dev/null
echo "GitHub trust configured for ${ID_PREFIX} and repo:${ORG}/${REPO}"
echo "Service accounts and bindings ready"

cat <<EOF

============================================================
Google Cloud is ready. Add these as GitHub repository VARIABLES (not secrets) in
BreakthruDevelopment/30-apps-infra → Settings → Secrets and variables → Actions → Variables:

  GCP_PROJECT_ID       ${PROJECT}
  GCP_PROJECT_NUMBER   ${NUMBER}
  GCP_REGION           ${REGION}
  GCP_STATE_BUCKET     ${BUCKET}
  GCP_WIF_PROVIDER     projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}
  GCP_DEPLOY_SA        ${DEPLOY_SA}
  GCP_PLAN_SA          ${PLAN_SA}

None of these are secret. No service account keys were created.
============================================================
EOF
