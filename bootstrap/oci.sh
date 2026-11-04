#!/usr/bin/env bash
# One-time Oracle Cloud setup for the 30 apps portfolio. Run in OCI Cloud Shell, already signed in:
#   curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/oci.sh | bash
#
# Oracle has no keyless sign-in for GitHub Actions like the other three clouds, so this creates a
# dedicated, narrowly scoped user whose API key goes into a GitHub *environment* secret that only
# the main branch can read.
#
# Creates:
#   - compartment "30-apps" (everything for this project lives here)
#   - group 30apps-deployers + user github-30apps-deploy, allowed to manage only that compartment
#   - an API signing key for that user
#   - a private Object Storage bucket for Terraform state
# Safe to run again (an extra API key is added only if the user has none).
set -euo pipefail

TENANCY="${OCI_TENANCY:?Run this in OCI Cloud Shell}"
REGION="${OCI_REGION:?Run this in OCI Cloud Shell}"
COMPARTMENT_NAME="30-apps"
GROUP="30apps-deployers"
USER_NAME="github-30apps-deploy"
BUCKET="tfstate-30apps"
KEY_DIR="$HOME/.oci-30apps"
# Identity domains require an email per user; a plus-address lands in the dev@ inbox.
DEPLOY_EMAIL="${OCI_DEPLOY_EMAIL:-dev+github-30apps@breakthruventures.ai}"

HOME_REGION="$(oci iam region-subscription list --query "data[?\"is-home-region\"].\"region-name\" | [0]" --raw-output)"
if [ "$REGION" != "$HOME_REGION" ]; then
  echo "Cloud Shell is in ${REGION} but your home region is ${HOME_REGION}."
  echo "Always Free resources exist only in the home region. Switch the console region to ${HOME_REGION} and rerun."
  exit 1
fi
echo "Tenancy ${TENANCY}, home region ${REGION}"

first() { oci "$@" --all --query 'data[0].id' --raw-output 2>/dev/null || true; }

# --- Compartment --------------------------------------------------------------
COMPARTMENT="$(first iam compartment list --compartment-id "$TENANCY" --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE)"
if [ -z "$COMPARTMENT" ] || [ "$COMPARTMENT" = "null" ]; then
  COMPARTMENT="$(oci iam compartment create --compartment-id "$TENANCY" --name "$COMPARTMENT_NAME" \
    --description "30 apps in 30 days portfolio" --wait-for-state ACTIVE --query 'data.id' --raw-output)"
  echo "Created compartment ${COMPARTMENT_NAME}"
fi

# --- Group, user, policy ------------------------------------------------------
GROUP_ID="$(first iam group list --compartment-id "$TENANCY" --name "$GROUP")"
if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" = "null" ]; then
  GROUP_ID="$(oci iam group create --compartment-id "$TENANCY" --name "$GROUP" \
    --description "GitHub Actions deployers for the 30 apps portfolio" --query 'data.id' --raw-output)"
fi
USER_ID="$(first iam user list --compartment-id "$TENANCY" --name "$USER_NAME")"
if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
  USER_ID="$(oci iam user create --compartment-id "$TENANCY" --name "$USER_NAME" \
    --description "Used only by GitHub Actions in BreakthruDevelopment/30-apps-infra" \
    --email "$DEPLOY_EMAIL" --query 'data.id' --raw-output)"
  oci iam group add-user --group-id "$GROUP_ID" --user-id "$USER_ID" >/dev/null
  echo "Created user ${USER_NAME}"
fi

POLICY_NAME="30apps-deployers-policy"
POLICY_ID="$(first iam policy list --compartment-id "$TENANCY" --name "$POLICY_NAME")"
STATEMENTS="[
  \"Allow group 'Default'/'${GROUP}' to manage all-resources in compartment ${COMPARTMENT_NAME}\",
  \"Allow group 'Default'/'${GROUP}' to inspect compartments in tenancy\",
  \"Allow group 'Default'/'${GROUP}' to read objectstorage-namespaces in tenancy\"
]"
if [ -z "$POLICY_ID" ] || [ "$POLICY_ID" = "null" ]; then
  oci iam policy create --compartment-id "$TENANCY" --name "$POLICY_NAME" \
    --description "Scope the 30 apps deployer to its compartment" --statements "$STATEMENTS" >/dev/null
  echo "Created policy"
fi

# --- API signing key ----------------------------------------------------------
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
# The CLI prints nothing (not an empty list) when the user has no keys, so check for a fingerprint instead.
EXISTING_FINGERPRINT="$(oci iam user api-key list --user-id "$USER_ID" --query 'data[0].fingerprint' --raw-output 2>/dev/null || true)"
if [ -z "$EXISTING_FINGERPRINT" ] || [ "$EXISTING_FINGERPRINT" = "null" ]; then
  openssl genrsa -out "$KEY_DIR/key.pem" 2048 2>/dev/null
  chmod 600 "$KEY_DIR/key.pem"
  openssl rsa -pubout -in "$KEY_DIR/key.pem" -out "$KEY_DIR/key_public.pem" 2>/dev/null
  FINGERPRINT="$(oci iam user api-key upload --user-id "$USER_ID" --key-file "$KEY_DIR/key_public.pem" \
    --query 'data.fingerprint' --raw-output)"
  NEW_KEY=1
else
  FINGERPRINT="$EXISTING_FINGERPRINT"
  NEW_KEY=0
fi

# --- Terraform state bucket ---------------------------------------------------
NAMESPACE="$(oci os ns get --query data --raw-output)"
oci os bucket get --bucket-name "$BUCKET" --namespace "$NAMESPACE" >/dev/null 2>&1 || \
  oci os bucket create --name "$BUCKET" --compartment-id "$COMPARTMENT" --namespace "$NAMESPACE" \
    --public-access-type NoPublicAccess --versioning Enabled >/dev/null

cat <<EOF

============================================================
Oracle Cloud is ready.

1) Add these as GitHub repository VARIABLES (not secrets) in
   BreakthruDevelopment/30-apps-infra → Settings → Secrets and variables → Actions → Variables:

  OCI_TENANCY_OCID       ${TENANCY}
  OCI_USER_OCID          ${USER_ID}
  OCI_FINGERPRINT        ${FINGERPRINT}
  OCI_REGION             ${REGION}
  OCI_COMPARTMENT_OCID   ${COMPARTMENT}
  OCI_NAMESPACE          ${NAMESPACE}
  OCI_STATE_BUCKET       ${BUCKET}
EOF

if [ "$NEW_KEY" = "1" ]; then
cat <<EOF

2) This one IS a secret. Add it under Settings → Environments → production → Environment secrets,
   named OCI_PRIVATE_KEY. Copy everything between the lines, including BEGIN and END:
------------------------------------------------------------
$(cat "$KEY_DIR/key.pem")
------------------------------------------------------------
   Don't paste it anywhere else (including AI chats). After saving it in GitHub, delete the local copy:
     rm -rf ${KEY_DIR}
============================================================
EOF
else
  echo
  echo "2) The deploy user already has an API key, so no new key was made. If OCI_PRIVATE_KEY isn't in"
  echo "   GitHub yet, delete the key in the console (Identity → Users → ${USER_NAME}) and rerun."
  echo "============================================================"
fi
