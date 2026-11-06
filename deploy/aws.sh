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

# Gemini key, stored once with:
#   aws ssm put-parameter --name /30apps/gemini_api_key --type SecureString --value "<key>"
# Without it, apps that ask for Gemini run on demo answers.
TF_VAR_gemini_api_key="$(aws ssm get-parameter --name /30apps/gemini_api_key --with-decryption \
  --query Parameter.Value --output text 2>/dev/null || true)"
export TF_VAR_gemini_api_key
if [ -n "$TF_VAR_gemini_api_key" ]; then echo "==> Gemini key found"; else echo "==> No Gemini key in Parameter Store; AI runs in demo mode"; fi

# Cloudflare DNS. The API token (Zone:DNS:Edit on breakthruventures.ai only) is stored once with:
#   read -rsp "Token: " V && echo && aws ssm put-parameter --region us-east-2 --name /30apps/cloudflare/api_token \
#     --type SecureString --overwrite --value "$V" --query Version --output text; unset V
# With it, Terraform creates each app's DNS records (certificate validation and the app's CNAME) itself.
# Without it the manual two-phase flow is used. The zone ID (not secret) may be stored as a plain String at
# /30apps/cloudflare/zone_id; without it Terraform looks the zone up by name, which needs Zone:Read.
# The token is never printed; it only goes into the environment variable the Cloudflare provider reads.
CLOUDFLARE_API_TOKEN="$(aws ssm get-parameter --name /30apps/cloudflare/api_token --with-decryption \
  --query Parameter.Value --output text 2>/dev/null || true)"
if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
  export CLOUDFLARE_API_TOKEN
  export TF_VAR_manage_dns=true
  TF_VAR_cloudflare_zone_id="$(aws ssm get-parameter --name /30apps/cloudflare/zone_id \
    --query Parameter.Value --output text 2>/dev/null || true)"
  export TF_VAR_cloudflare_zone_id
  echo "==> Cloudflare token found; DNS records are created automatically"
else
  unset CLOUDFLARE_API_TOKEN
  export TF_VAR_manage_dns=false
  echo "==> No Cloudflare token in Parameter Store; DNS records are added by hand (see the README)"
fi

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

# mikefarah yq under its own path: a different tool called "yq" (a Python jq wrapper) may already be installed.
YQ="$BIN/yq-go"
if [ ! -x "$YQ" ]; then
  echo "==> Installing yq (reads apps.yaml)"
  curl -fsSL -o "$YQ" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TF_ARCH}"
  chmod +x "$YQ"
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

# Per-app secrets. apps.yaml lists the env var NAMES an app needs (`secrets: [INGEST_TOKEN]`); the values
# live in Parameter Store as SecureStrings, stored once by Michael with:
#   read -rsp "Value: " V && echo && aws ssm put-parameter --region us-east-2 --name /30apps/<app>/<VAR> \
#     --type SecureString --overwrite --value "$V" --query Version --output text; unset V
# This reads them (10 per call), and exports the JSON map {"<app>": {"<VAR>": "<value>"}} as
# TF_VAR_app_secrets. A parameter that isn't there is skipped with a warning naming it. Values are never
# printed: they only pass through files in a private temp folder (removed on exit) and the environment.
collect_app_secrets() {
  local names tmp n=0 found missing
  names="$(jq -r '.[] | .name as $n | (.secrets // [])[] | "/30apps/\($n)/\(.)"' <<<"$AWS_APPS")"
  export TF_VAR_app_secrets="{}"
  if [ -z "$names" ]; then return 0; fi
  tmp="$(umask 077 && mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT
  while [ -n "$names" ]; do
    n=$((n + 1))
    # shellcheck disable=SC2046  # the names are plain /30apps/<app>/<VAR> words
    if ! aws ssm get-parameters --with-decryption --output json </dev/null \
      --names $(head -n 10 <<<"$names") >"$tmp/batch-$n.json"; then
      echo "==> WARNING: could not read a batch of app secrets from Parameter Store; skipping it"
      rm -f "$tmp/batch-$n.json"
    fi
    names="$(tail -n +11 <<<"$names")"
  done
  if ! ls "$tmp"/batch-*.json >/dev/null 2>&1; then echo '{"Parameters":[]}' >"$tmp/batch-0.json"; fi
  TF_VAR_app_secrets="$(jq -s -c 'reduce (.[].Parameters[]) as $p ({};
    ($p.Name | ltrimstr("/30apps/") | split("/")) as [$a, $v] | .[$a][$v] = $p.Value)' "$tmp"/batch-*.json)"
  export TF_VAR_app_secrets
  found="$(jq -r 'to_entries[] | .key as $a | .value | keys[] | "/30apps/\($a)/\(.)"' <<<"$TF_VAR_app_secrets")"
  missing="$(jq -r '.[] | .name as $n | (.secrets // [])[] | "/30apps/\($n)/\(.)"' <<<"$AWS_APPS" | grep -vxF -f <(printf '%s\n' "$found") || true)"
  if [ -n "$missing" ]; then
    while read -r m; do echo "==> WARNING: no app secret at ${m}; skipping it"; done <<<"$missing"
  fi
  echo "==> App secrets: $(jq '[.[] | length] | add // 0' <<<"$TF_VAR_app_secrets") value(s) found"
}

# The AWS apps, read straight from apps.yaml. (Asking Terraform instead fails the first time a new app
# appears, because its locals refer to resources that don't exist yet.)
AWS_APPS="$("$YQ" -o=json '[.apps[] | select(.clouds | contains(["aws"]))]' ../../apps.yaml)"

collect_app_secrets

# Custom domains. Terraform creates each app's certificate. With the Cloudflare token it also creates the
# validation and app records and waits for the certificate (one pass). Without it, the API Gateway domain
# mapping waits until ACM reports the certificate ISSUED (after the validation CNAME is added by hand),
# so ask ACM now and hand Terraform the issued names: a JSON list of strings. Unused when DNS is automatic.
issued_domains() {
  aws acm list-certificates --certificate-statuses ISSUED --region "$REGION" --output json \
    | jq -c '[.CertificateSummaryList[]?.DomainName]'
}

# Prints the DNS records, from `terraform output -json dns_records`. Values are not secrets.
# Automatic: already created in Cloudflare by this run. Manual: pending = certificate validation (add
# first); final = the app's own name -> API Gateway target (printed once the certificate is issued and
# this script has been rerun).
print_dns_records() {
  local records="$1"
  if [ "$(jq 'length' <<<"$records")" = "0" ]; then return 0; fi
  echo
  if [ "$(jq 'map(select(.automatic)) | length' <<<"$records")" != "0" ]; then
    echo "==> DNS records (created automatically in Cloudflare; nothing to add by hand)"
    jq -r '
      to_entries[] | select(.value.automatic) | .key as $app | .value as $r |
      "    \($app)  (\($r.domain))",
      "      validation  host: \($r.validation.host)  type: \($r.validation.type)  value: \($r.validation.value)",
      "      app         host: \($r.final.host)  type: \($r.final.type)  value: \($r.final.value)"
    ' <<<"$records"
  fi
  if [ "$(jq 'map(select(.automatic | not)) | length' <<<"$records")" != "0" ]; then
    echo "==> DNS records to add by hand in Cloudflare (DNS -> Records -> Add record, Proxy status: DNS only)"
    jq -r '
      to_entries[] | select(.value.automatic | not) | .key as $app | .value as $r |
      "    \($app)  (\($r.domain))",
      (if $r.final != null then
         "      FINAL    host: \($r.final.host)  type: \($r.final.type)  value: \($r.final.value)",
         "      (validation record \($r.validation.host) can stay; it keeps the certificate renewing)"
       else
         "      PENDING  host: \($r.validation.host)  type: \($r.validation.type)  value: \($r.validation.value)",
         "               (full name: \($r.validation.name); this proves ownership to AWS. Add it, wait for the",
         "                certificate to show Issued, rerun this script, then add the app record it prints.)"
       end)
    ' <<<"$records"
  fi
}

TF_VAR_issued_domains="$(issued_domains)"
export TF_VAR_issued_domains
echo "==> Issued certificates: $(jq -r 'join(", ") | if . == "" then "none" else . end' <<<"$TF_VAR_issued_domains")"

echo "==> Creating image repositories and the database (a new database takes ~10 minutes)"
terraform apply -input=false -auto-approve \
  -target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.app -target=aws_db_instance.main

echo "==> Copying app images into ECR (ARM builds, which Lambda runs on)"
aws ecr get-login-password | crane auth login --username AWS --password-stdin "$REGISTRY" >/dev/null
jq -r '.[] | "\(.image):\(.tag) 30apps/\(.name):\(.tag)"' <<<"$AWS_APPS" | while read -r src dst; do
  echo "    ${src} -> ${REGISTRY}/${dst}"
  crane copy --platform linux/arm64 "$src" "${REGISTRY}/${dst}"
done

echo "==> Deploying the apps (with automatic DNS, a new custom domain waits up to 15 minutes for its certificate)"
terraform apply -input=false -auto-approve

echo "==> Checking each app"
terraform output -json urls | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r name url; do
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${url}/api/health" || true)"
  echo "    ${name}: ${url}  (health: HTTP ${status})"
done
print_dns_records "$(terraform output -json dns_records)"
echo "==> Done. A 503 right after the first deploy usually means the app is still migrating; check again in a minute."
