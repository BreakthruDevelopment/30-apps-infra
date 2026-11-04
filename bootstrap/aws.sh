#!/usr/bin/env bash
# One-time AWS setup for the 30 apps portfolio. Run in AWS CloudShell (already signed in):
#   curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/aws.sh | bash
#
# Creates:
#   - a private, versioned S3 bucket for Terraform state
#   - GitHub's OIDC identity provider, so Actions can sign in without stored keys
#   - two roles, usable ONLY by BreakthruDevelopment/30-apps-infra:
#       github-30apps-deploy  (PowerUser; only the "production" environment, which is limited to main)
#       github-30apps-plan    (ReadOnly; pull requests, for terraform plan)
#   - a shared Lambda execution role the apps run as
# Safe to run again: existing resources are reused.
set -euo pipefail

ORG="BreakthruDevelopment"
REPO="30-apps-infra"
REGION="us-east-1"   # CloudFront certificates must live in us-east-1, so everything does.
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="breakthru-30apps-tfstate-${ACCOUNT}"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
echo "Account ${ACCOUNT}, region ${REGION}"

# --- Terraform state bucket -------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "State bucket exists: $BUCKET"
else
  aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  echo "Created state bucket: $BUCKET"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# --- GitHub OIDC provider -----------------------------------------------------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "GitHub OIDC provider exists"
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com >/dev/null
  echo "Created GitHub OIDC provider"
fi

trust_policy() {  # $1 = the GitHub token subject allowed to assume the role
  cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"${OIDC_ARN}"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{
   "token.actions.githubusercontent.com:aud":"sts.amazonaws.com",
   "token.actions.githubusercontent.com:sub":"$1"}}}]}
JSON
}

ensure_role() {  # $1 name, $2 trust policy JSON
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "$2"
    echo "Updated role $1"
  else
    aws iam create-role --role-name "$1" --assume-role-policy-document "$2" >/dev/null
    echo "Created role $1"
  fi
}

# --- Shared Lambda execution role --------------------------------------------
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ensure_role 30apps-lambda-exec "$LAMBDA_TRUST"
aws iam attach-role-policy --role-name 30apps-lambda-exec \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/30apps-lambda-exec"

# --- Deploy role: production environment only (limited to main in GitHub) -----
ensure_role github-30apps-deploy "$(trust_policy "repo:${ORG}/${REPO}:environment:production")"
aws iam attach-role-policy --role-name github-30apps-deploy --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam put-role-policy --role-name github-30apps-deploy --policy-name pass-lambda-role --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["iam:PassRole","iam:GetRole"],"Resource":"${LAMBDA_ROLE_ARN}"}]}
JSON
)"

# --- Plan role: pull requests, read-only --------------------------------------
ensure_role github-30apps-plan "$(trust_policy "repo:${ORG}/${REPO}:pull_request")"
aws iam attach-role-policy --role-name github-30apps-plan --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

cat <<EOF

============================================================
AWS is ready. Add these as GitHub repository VARIABLES (not secrets) in
BreakthruDevelopment/30-apps-infra → Settings → Secrets and variables → Actions → Variables:

  AWS_ACCOUNT_ID         ${ACCOUNT}
  AWS_REGION             ${REGION}
  AWS_STATE_BUCKET       ${BUCKET}
  AWS_DEPLOY_ROLE_ARN    arn:aws:iam::${ACCOUNT}:role/github-30apps-deploy
  AWS_PLAN_ROLE_ARN      arn:aws:iam::${ACCOUNT}:role/github-30apps-plan
  AWS_LAMBDA_ROLE_ARN    ${LAMBDA_ROLE_ARN}

None of these are secret. No keys were created.
============================================================
EOF
