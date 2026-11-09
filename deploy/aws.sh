#!/usr/bin/env bash
# Deploy every AWS app in apps.yaml. Two ways to run it, same steps either way:
#
#  1. Automatically: the "deployer" Lambda in the AWS account (set up once with
#     bootstrap/aws-autodeploy.sh) checks every 10 minutes whether `main` changed, downloads that exact
#     commit and runs this script from it with AWS_DEPLOY_SRC set. GitHub never signs in to AWS.
#  2. By hand, in AWS CloudShell (already signed in), the fallback that always works:
#       curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/deploy/aws.sh | bash
#
# Why not GitHub Actions: this account's project guardrails block GitHub's keyless sign-in, and the
# Free plan is kept so the account can never bill a card. Everything runs on its credits.
#
# Steps: install Terraform and crane if needed → get the latest infra code (CloudShell) or use the commit
# the deployer fetched (AWS_DEPLOY_SRC) → create the image repositories and database → copy each app
# image from GitHub's registry into ECR → apply the rest → check each app's health endpoint.
# Safe to rerun; it only changes what's different.
#
# Environment (all optional; the deployer sets them, CloudShell needs none):
#   AWS_DEPLOY_SRC         a checked-out copy of this repo to deploy instead of cloning main
#   AWS_TARGET_REGION      region, default us-east-2 (the only one the guardrails allow)
#   DEPLOY_LOCK_HELD=1     the caller already holds the /30apps/deployer/lock lock in Parameter Store
#   HEALTH_WAIT_SECONDS    keep re-checking an unhealthy app for this long (default 0: check once)
#   DEPLOY_STRICT_HEALTH=1 exit 3 if an app is still unhealthy after that (the deployer sets this)
#   DEPLOY_REFUSE_DESTROY=1 exit 4 instead of applying a plan that deletes or replaces anything (the deployer
#                          sets this; DEPLOY_ALLOW_DESTROY=1 overrides it for one run). A by-hand run in CloudShell
#                          is not restricted: it prints the plan's deletions, then applies.
set -euo pipefail

REGION="${AWS_TARGET_REGION:-us-east-2}"  # not AWS_REGION: CloudShell sets that to whatever region the console shows
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

# Tool versions are pinned and checksummed, and downloads must stay on https. Terraform's version is the same one
# the deployer image uses (CI checks they match): one version everywhere means the same plan and the same
# state format whichever runner applies, instead of whatever "latest" is on the day.
CURL=(curl --proto "=https" --proto-redir "=https" -fsSL)
TERRAFORM_VERSION="1.17.1"
YQ_VERSION="v4.44.3"
CRANE_VERSION="v0.20.3"
case "$TF_ARCH" in
  amd64) YQ_SHA256="a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7"; CRANE_SHA256="36c67a932f489b3f2724b64af90b599a8ef2aa7b004872597373c0ad694dc059" ;;
  arm64) YQ_SHA256="0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156"; CRANE_SHA256="d2235f7779cd39c6e40f43701d2512c997409f629fb53e621ede0d57d3f995e2" ;;
esac

if ! command -v terraform >/dev/null 2>&1; then
  echo "==> Installing Terraform ${TERRAFORM_VERSION}"
  zip="terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip"
  "${CURL[@]}" -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${zip}"
  want="$("${CURL[@]}" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" | grep " ${zip}\$" | cut -d' ' -f1)"
  echo "${want}  /tmp/terraform.zip" | sha256sum -c - >/dev/null
  unzip -o -q /tmp/terraform.zip terraform -d "$BIN"
  rm -f /tmp/terraform.zip
fi

# mikefarah yq under its own path: a different tool called "yq" (a Python jq wrapper) may already be installed.
# (The deployer image ships it as yq-go too.)
YQ="$BIN/yq-go"
if command -v yq-go >/dev/null 2>&1; then
  YQ="$(command -v yq-go)"
elif [ ! -x "$YQ" ]; then
  echo "==> Installing yq ${YQ_VERSION} (reads apps.yaml)"
  "${CURL[@]}" -o "$YQ.part" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TF_ARCH}"
  echo "${YQ_SHA256}  ${YQ}.part" | sha256sum -c - >/dev/null
  chmod +x "$YQ.part" && mv "$YQ.part" "$YQ"
fi

if ! command -v crane >/dev/null 2>&1; then
  echo "==> Installing crane ${CRANE_VERSION} (copies container images between registries)"
  "${CURL[@]}" -o /tmp/crane.tgz "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz"
  echo "${CRANE_SHA256}  /tmp/crane.tgz" | sha256sum -c - >/dev/null
  tar -xz -C "$BIN" -f /tmp/crane.tgz crane
  rm -f /tmp/crane.tgz
fi

# One deploy at a time. The deployer Lambda holds /30apps/deployer/lock while it runs (and tells this script
# so with DEPLOY_LOCK_HELD). A manual run takes the same lock, so it can't collide with an automatic one.
# create-without-overwrite is atomic: only one caller can create the parameter. The value is JSON with a random
# holder id and an expiry, so a run that died without cleaning up blocks others only until then, and a caller only
# ever deletes a lock that still carries its own id. Only "already exists" means someone else holds it: any other
# error (AccessDenied, throttling) stops the run rather than being mistaken for a busy lock.
LOCK_NAME="/30apps/deployer/lock"
LOCK_ID="$(cat /proc/sys/kernel/random/uuid)"
LOCK_MINE=0
TFPLAN="${TF_DATA_DIR}.plan"
lock_holder_id() { aws ssm get-parameter --name "$LOCK_NAME" --query Parameter.Value --output text 2>/dev/null | jq -r '.id // ""' 2>/dev/null || true; }
release_lock() {
  if [ "$LOCK_MINE" = 1 ] && [ "$(lock_holder_id)" = "$LOCK_ID" ]; then aws ssm delete-parameter --name "$LOCK_NAME" >/dev/null 2>&1 || true; fi
}
cleanup() { rm -f "$TFPLAN"; release_lock; }
take_lock() {
  local value now current expires holder out
  now="$(date +%s)"
  value="$(jq -nc --arg h cloudshell --arg id "$LOCK_ID" --argjson e "$((now + 5400))" '{holder:$h,id:$id,expires:$e}')"
  if out="$(aws ssm put-parameter --name "$LOCK_NAME" --type String --value "$value" 2>&1)"; then LOCK_MINE=1; return 0; fi
  if ! grep -q ParameterAlreadyExists <<<"$out"; then
    echo "==> ERROR: cannot use the deploy lock ${LOCK_NAME}: $(head -c 300 <<<"$out")"
    return 1
  fi
  if ! current="$(aws ssm get-parameter --name "$LOCK_NAME" --query Parameter.Value --output text 2>&1)"; then
    echo "==> ERROR: cannot read the deploy lock ${LOCK_NAME}: $(head -c 300 <<<"$current")"
    return 1
  fi
  expires="$(jq -r '.expires // 0' <<<"$current" 2>/dev/null || echo 0)"
  holder="$(jq -r '.holder // "another deploy"' <<<"$current" 2>/dev/null || echo "another deploy")"
  if [[ "$expires" =~ ^[0-9]+$ ]] && [ "$now" -gt "$expires" ]; then
    echo "==> Found an expired deploy lock; taking it over"
    aws ssm put-parameter --name "$LOCK_NAME" --type String --overwrite --value "$value" >/dev/null
    sleep 2 # two takers may both overwrite; the one whose id survives wins
    if [ "$(lock_holder_id)" = "$LOCK_ID" ]; then LOCK_MINE=1; return 0; fi
  fi
  echo "==> ERROR: ${holder} is deploying right now (lock ${LOCK_NAME}). Wait a few minutes and rerun."
  echo "    If you are sure nothing is running: aws ssm delete-parameter --name ${LOCK_NAME}"
  return 1
}
trap cleanup EXIT
if [ "${DEPLOY_LOCK_HELD:-}" != "1" ]; then
  take_lock
fi

# Plan, check, apply. The plan's JSON is only ever filtered down to resource addresses (it holds sensitive
# values, so it is never printed or kept; the plan file is private and removed on exit). Automatic runs
# (DEPLOY_REFUSE_DESTROY=1) stop with exit 4 if the plan deletes or replaces anything.
guarded_apply() { # extra `terraform plan` arguments, e.g. -target=...
  local addrs
  (umask 077 && terraform plan -input=false -out="$TFPLAN" "$@")
  addrs="$(terraform show -json "$TFPLAN" | jq -r '.resource_changes[]? | select(.change.actions | index("delete")) | "\(.address) (\(.change.actions | join(" then ")))"')"
  if [ -n "$addrs" ]; then
    if [ "${DEPLOY_REFUSE_DESTROY:-}" = "1" ] && [ "${DEPLOY_ALLOW_DESTROY:-}" != "1" ]; then
      echo "==> ERROR: refusing to apply a plan that deletes or replaces resources (automatic runs never do):"
      printf '    %s\n' "${addrs//$'\n'/$'\n    '}"
      echo "    If that is intended, review it and deploy with: ... bootstrap/aws-autodeploy.sh | bash -s -- deploy --allow-destroy"
      exit 4
    fi
    echo "==> Destroy allowed: this plan deletes or replaces:"
    printf '    %s\n' "${addrs//$'\n'/$'\n    '}"
  fi
  terraform apply -input=false "$TFPLAN"
  rm -f "$TFPLAN"
}

if [ -n "${AWS_DEPLOY_SRC:-}" ]; then
  echo "==> Using the infra code in ${AWS_DEPLOY_SRC}"
  cd "$AWS_DEPLOY_SRC/stacks/aws"
else
  echo "==> Getting the latest infra code"
  if [ -d "$WORKDIR/.git" ]; then
    git -C "$WORKDIR" fetch -q --depth 1 origin main
    git -C "$WORKDIR" reset -q --hard origin/main
  else
    git clone -q --depth 1 "$REPO_URL" "$WORKDIR"
  fi
  cd "$WORKDIR/stacks/aws"
fi
rm -rf .terraform  # left over from older runs that used the home folder

# Quiet on success; on failure show why (a bare `>/dev/null` used to hide it).
if ! terraform init -input=false -reconfigure \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=aws/terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="use_lockfile=true" >"${TF_DATA_DIR}.init.log" 2>&1; then
  tail -n 40 "${TF_DATA_DIR}.init.log"
  echo "==> ERROR: terraform init failed"
  exit 1
fi
echo "==> Terraform initialized"

# Once Terraform has created DNS records in Cloudflare, a run without the token would plan to delete them
# (and fail half-way). Stop before that happens.
if [ "$TF_VAR_manage_dns" = false ] && terraform state list 2>/dev/null | grep -q '^cloudflare_dns_record\.'; then
  echo "==> ERROR: Terraform manages DNS records in Cloudflare, but no token was found at"
  echo "    /30apps/cloudflare/api_token. Restore the token and rerun; nothing was changed."
  exit 1
fi

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
  trap "rm -rf '$tmp'; cleanup" EXIT  # replaces the trap above, so it also releases the lock
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
  missing="$(jq -r '.[] | .name as $n | (.secrets // [])[] | "/30apps/\($n)/\(.)"' <<<"$AWS_APPS" | FOUND="$found" awk 'BEGIN { n = split(ENVIRON["FOUND"], f, "\n"); for (i = 1; i <= n; i++) if (f[i] != "") seen[f[i]] = 1 } !($0 in seen)' || true)"
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
guarded_apply -target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.app -target=aws_db_instance.main

echo "==> Copying app images into ECR (ARM builds, which Lambda runs on)"
aws ecr get-login-password | crane auth login --username AWS --password-stdin "$REGISTRY" >/dev/null
jq -r '.[] | "\(.image):\(.tag) 30apps/\(.name):\(.tag)"' <<<"$AWS_APPS" | while read -r src dst; do
  echo "    ${src} -> ${REGISTRY}/${dst}"
  crane copy --platform linux/arm64 "$src" "${REGISTRY}/${dst}"
done

echo "==> Deploying the apps (with automatic DNS, a new custom domain waits up to 15 minutes for its certificate)"
guarded_apply

echo "==> Checking each app"
# Read the outputs first: failures inside a process substitution or an argument would be silently ignored.
# No process substitution (<(...)) anywhere in this script: Lambda has no /dev/fd, so the deployer can't run it.
urls_json="$(terraform output -json urls)"
dns_json="$(terraform output -json dns_records)"
unhealthy=""
health_deadline=$((SECONDS + ${HEALTH_WAIT_SECONDS:-0}))
while read -r name url; do
  [ -n "$name" ] || continue  # an empty here-string still yields one empty line
  while :; do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${url}/api/health" || true)"
    if [ "$status" = "200" ] || [ "$SECONDS" -ge "$health_deadline" ]; then break; fi
    sleep 10
  done
  echo "    ${name}: ${url}  (health: HTTP ${status})"
  if [ "$status" != "200" ]; then unhealthy="${unhealthy}${unhealthy:+, }${name} (HTTP ${status})"; fi
done <<<"$(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$urls_json")"
print_dns_records "$dns_json"
if [ -n "$unhealthy" ] && [ "${DEPLOY_STRICT_HEALTH:-}" = "1" ]; then
  echo "==> ERROR: unhealthy after the deploy: ${unhealthy}"
  exit 3
fi
echo "==> Done. A 503 right after the first deploy usually means the app is still migrating; check again in a minute."
