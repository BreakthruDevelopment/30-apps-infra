#!/usr/bin/env bash
# Deploy every AWS app in apps.yaml. Run in AWS CloudShell (already signed in):
#   curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/deploy/aws.sh | bash
#
# Why CloudShell: this account's project guardrails block GitHub's keyless sign-in, and the
# Free plan is kept so the account can never bill a card. Everything runs on its credits.
#
# Steps: install Terraform and crane if needed → get the latest infra code → create the image
# repositories and database → copy each app image from GitHub's registry into ECR → apply the
# rest → check each app's health endpoint. Safe to rerun; it only changes what's different.
set -euo pipefail

REGION="us-east-2"
REPO_URL="https://github.com/BreakthruDevelopment/30-apps-infra"
WORKDIR="$HOME/30-apps-infra"
BIN="$HOME/.local/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH" AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
# CloudShell's home folder is capped at 1 GB and the AWS provider plugin is larger, so
# Terraform's working files live in /tmp (rebuilt automatically on the next run).
export TF_DATA_DIR="/tmp/30apps-terraform"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="breakthru-30apps-tfstate-${ACCOUNT}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
echo "==> Account ${ACCOUNT}, region ${REGION}"

case "$(uname -m)" in
  x86_64) TF_ARCH=amd64; CRANE_ARCH=x86_64 ;;
  aarch64 | arm64) TF_ARCH=arm64; CRANE_ARCH=arm64 ;;
  *) echo "Unsupported CPU: $(uname -m)"; exit 1 ;;
esac

if ! command -v terraform >/dev/null 2>&1; then
  TF_VERSION="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)"
  echo "==> Installing Terraform ${TF_VERSION}"
  curl -fsSL -o /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${TF_ARCH}.zip"
  unzip -o -q /tmp/terraform.zip terraform -d "$BIN"
  rm -f /tmp/terraform.zip
fi

if ! command -v crane >/dev/null 2>&1; then
  echo "==> Installing crane (copies container images between registries)"
  curl -fsSL "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz" \
    | tar -xz -C "$BIN" crane
fi

echo "==> Getting the latest infra code"
if [ -d "$WORKDIR/.git" ]; then
  git -C "$WORKDIR" fetch -q --depth 1 origin main
  git -C "$WORKDIR" reset -q --hard origin/main
else
  git clone -q --depth 1 "$REPO_URL" "$WORKDIR"
fi
cd "$WORKDIR/stacks/aws"
rm -rf .terraform  # left over from older runs that used the home folder

terraform init -input=false -reconfigure \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=aws/terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="use_lockfile=true" >/dev/null
echo "==> Terraform initialized"

echo "==> Creating image repositories and the database (a new database takes ~10 minutes)"
terraform apply -input=false -auto-approve \
  -target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.app -target=aws_db_instance.main

echo "==> Copying app images into ECR (ARM builds, which Lambda runs on)"
aws ecr get-login-password | crane auth login --username AWS --password-stdin "$REGISTRY" >/dev/null
MIRRORS="$(terraform console <<'EOF'
jsonencode({ for n, a in local.apps : "${a.image}:${a.tag}" => "30apps/${n}:${a.tag}" })
EOF
)"
echo "$MIRRORS" | jq -r '. | fromjson | to_entries[] | "\(.key) \(.value)"' | while read -r src dst; do
  echo "    ${src} -> ${REGISTRY}/${dst}"
  crane copy --platform linux/arm64 "$src" "${REGISTRY}/${dst}"
done

echo "==> Deploying the apps"
terraform apply -input=false -auto-approve

echo "==> Checking each app"
terraform output -json urls | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r name url; do
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${url}/api/health" || true)"
  echo "    ${name}: ${url}  (health: HTTP ${status})"
done
echo "==> Done. A 503 right after the first deploy usually means the app is still migrating; check again in a minute."
