#!/usr/bin/env bash
# One-time setup of AUTOMATIC AWS deploys. Run in AWS CloudShell (already signed in):
#   curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/aws-autodeploy.sh | bash
#
# What it sets up: a "deployer" Lambda function inside this AWS account, woken every 10 minutes by EventBridge
# Scheduler. It asks GitHub (read-only, no sign-in) whether `main` changed; if so it downloads that exact
# commit and runs its deploy/aws.sh, the same script you run by hand in CloudShell. GitHub never signs in
# to AWS and no access keys exist anywhere. See the README, "AWS: automatic deploys".
#
# Other commands (give them after `bash -s --`):
#   ... | bash -s -- pause     stop the schedule (the CloudShell one-liner keeps working)
#   ... | bash -s -- resume    start it again
#   ... | bash -s -- deploy    deploy now, even if main is unchanged, and print the result
#   ... | bash -s -- deploy --allow-destroy   same, but let this run apply a plan that deletes or replaces
#                              resources (automatic runs refuse such a plan; review it first)
#   ... | bash -s -- status    show the schedule, the last deploy and whether main has moved
#   ... | bash -s -- remove    delete everything this script created (apps and their state are not touched)
# Rerun with no argument to update the deployer image (after the "AWS deployer image" workflow pushed a new
# one) or to repair anything. Safe to run again: existing resources are reused.
#
# Creates (all free, none of them can bill): IAM roles apps30-deployer and apps30-deployer-scheduler, ECR
# repository apps30/deployer, Lambda function apps30-deployer, a log group (14 days), schedule apps30-deployer.
# If this account's guardrails refuse any step the script says which one and stops; nothing else is changed
# and the CloudShell one-liner (deploy/aws.sh) keeps working.
#
# Safety checks before it installs, resumes or deploys anything: `main` of this repository must be protected on
# GitHub (a ruleset or classic branch protection that requires a pull request), because whatever lands on main is
# run inside this account; and the deployer image must carry a valid Sigstore signature from this repo's
# "AWS deployer image" workflow on main, and is copied into ECR by that verified digest.
#
# Environment: DEPLOYER_MEMORY (MB, default 2048), DEPLOYER_BROAD=1 (also attach the AWS-managed
# PowerUserAccess policy, if the scoped policy turns out to miss something; the same access the old GitHub
# deploy role had), DEPLOYER_IMAGE (source image, default the public GitHub one).
set -euo pipefail

COMMAND="${1:-install}"
ALLOW_DESTROY=false
if [ "${2:-}" = "--allow-destroy" ]; then ALLOW_DESTROY=true; fi
REGION="${AWS_TARGET_REGION:-us-east-2}" # the only region the account's guardrails allow
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

FN="apps30-deployer" # not under 30apps-*: the deployer's own policy must not be able to touch itself
ROLE="apps30-deployer"
SCHED_ROLE="apps30-deployer-scheduler"
SCHEDULE="apps30-deployer"
ECR_REPO="apps30/deployer"
LOG_GROUP="/aws/lambda/${FN}"
SRC_IMAGE="${DEPLOYER_IMAGE:-ghcr.io/breakthrudevelopment/30apps-deployer:latest}"
MEMORY="${DEPLOYER_MEMORY:-2048}"
P="/30apps/deployer"
BIN="$HOME/.local/bin"
GH_REPO="BreakthruDevelopment/30-apps-infra"
CURL=(curl --proto "=https" --proto-redir "=https" -fsSL)
# Pinned tools, each with its SHA-256 (from the upstream release): crane copies the image, cosign verifies it.
CRANE_VERSION="v0.20.3"
CRANE_SHA256_X86_64="36c67a932f489b3f2724b64af90b599a8ef2aa7b004872597373c0ad694dc059"
CRANE_SHA256_ARM64="d2235f7779cd39c6e40f43701d2512c997409f629fb53e621ede0d57d3f995e2"
COSIGN_VERSION="v2.6.5" # keep equal to COSIGN_VERSION in .github/workflows/aws-deployer-image.yml
COSIGN_SHA256_AMD64="c3b4f5410e608af03a5eb0aaac84a4313d8da131248e08ff1759ac70c79d1644"
COSIGN_SHA256_ARM64="426193b4c5da4d4d643e822f48fe0cc8a476ca1782a272704831f5a0cef716d7"
SIGNER_IDENTITY="https://github.com/${GH_REPO}/.github/workflows/aws-deployer-image.yml@refs/heads/main"
OIDC_ISSUER="https://token.actions.githubusercontent.com"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="breakthru-30apps-tfstate-${ACCOUNT}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
FN_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"
SCHED_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${SCHED_ROLE}"
TMP="$(umask 077 && mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DENIED_RE='AccessDenied|not authorized to perform|explicit deny|service control polic|UnauthorizedOperation|Forbidden|is not permitted'

# ---- helpers ------------------------------------------------------------------------------------

# A step failed. Say which one, and whether it looks like a guardrail/permission block. Stops cleanly:
# everything created so far is harmless and rerunnable; the CloudShell flow is unaffected.
fail_step() { # $1 description, $2 the error output
  echo
  if grep -qiE "$DENIED_RE" <<<"$2"; then
    echo "==> STOPPED: this account's permissions or guardrails refused a step: $1"
  else
    echo "==> STOPPED: a step failed: $1"
  fi
  echo "    AWS said: $(head -c 600 <<<"$2")"
  echo
  echo "    Nothing else was changed. The CloudShell deploy (deploy/aws.sh) works exactly as before."
  echo "    Rerun this script after fixing the cause, or '... | bash -s -- remove' to delete what it created."
  exit 2
}

OUT=""
try() { # try "description" command...: run it; stop with a clear message if it fails
  local desc="$1"
  shift
  if ! OUT="$("$@" 2>&1)"; then fail_step "$desc" "$OUT"; fi
}

say() { echo "==> $*"; }

ensure_tools() {
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  if ! command -v jq >/dev/null 2>&1; then
    say "jq is missing; it ships with CloudShell. Install it and rerun."
    exit 1
  fi
  local arch crane_sha
  case "$(uname -m)" in
    x86_64) arch=x86_64 crane_sha="$CRANE_SHA256_X86_64" ;;
    aarch64 | arm64) arch=arm64 crane_sha="$CRANE_SHA256_ARM64" ;;
    *) echo "Unsupported CPU: $(uname -m)" && exit 1 ;;
  esac
  if ! command -v crane >/dev/null 2>&1; then
    say "Installing crane ${CRANE_VERSION} (copies container images between registries)"
    "${CURL[@]}" -o "$TMP/crane.tgz" "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_${arch}.tar.gz"
    echo "${crane_sha}  $TMP/crane.tgz" | sha256sum -c - >/dev/null || fail_step "verify the crane download" "checksum mismatch"
    tar -xz -C "$BIN" -f "$TMP/crane.tgz" crane
  fi
}

# cosign, pinned and checksummed, into the private temp folder (removed when the script ends).
install_cosign() {
  local file sha
  case "$(uname -m)" in
    x86_64) file=cosign-linux-amd64 sha="$COSIGN_SHA256_AMD64" ;;
    *) file=cosign-linux-arm64 sha="$COSIGN_SHA256_ARM64" ;;
  esac
  say "Installing cosign ${COSIGN_VERSION} (verifies the image's signature)"
  "${CURL[@]}" -o "$TMP/cosign" "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/${file}" ||
    fail_step "download cosign" "download failed"
  echo "${sha}  $TMP/cosign" | sha256sum -c - >/dev/null || fail_step "verify the cosign download" "checksum mismatch"
  chmod +x "$TMP/cosign"
}

# `main` must be protected before anything here installs or deploys: the deployer runs whatever is on main with
# this account's permissions. A repository ruleset reports through /rules/branches/main (a non-empty list that
# includes a pull_request rule); classic branch protection reports .protected on /branches/main. Fail closed.
require_main_protected() {
  local rules branch
  if rules="$("${CURL[@]}" -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${GH_REPO}/rules/branches/main" 2>/dev/null)" &&
    jq -e 'type == "array" and (map(select(.type == "pull_request")) | length) > 0' <<<"$rules" >/dev/null 2>&1; then
    say "Branch protection: a ruleset on main requires pull requests"
    return 0
  fi
  if branch="$("${CURL[@]}" -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${GH_REPO}/branches/main" 2>/dev/null)" &&
    jq -e '.protected == true' <<<"$branch" >/dev/null 2>&1; then
    say "Branch protection: classic protection is on for main"
    return 0
  fi
  echo
  echo "==> STOPPED: 'main' of ${GH_REPO} is not protected (or GitHub could not be asked)."
  echo "    The deployer runs whatever is merged to main inside this AWS account, so main must require a pull request first."
  echo "    Add the ruleset described in the README, 'AWS: automatic deploys', 'Protect main first':"
  echo "    https://github.com/${GH_REPO}#protect-main-first"
  echo "    Nothing was created or changed. The CloudShell deploy (deploy/aws.sh) works as before."
  exit 3
}

ensure_role() { # $1 name, $2 trust policy JSON
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    try "update the trust policy of role $1" aws iam update-assume-role-policy --role-name "$1" --policy-document "$2"
    say "Role $1 exists"
  else
    try "create role $1" aws iam create-role --role-name "$1" --assume-role-policy-document "$2" \
      --description "30 apps: AWS auto-deploy ($1)" --tags Key=project,Value=30-apps-30-days
    say "Created role $1"
    sleep 10 # new IAM roles take a few seconds to become usable
  fi
}

# The deployer's permissions: what the CloudShell user needs for stacks/aws, scoped to this stack's names.
# Resources are limited to the 30apps-* / apps30-postgres names the stack uses; IAM is limited to the single
# role the stack creates, and may only attach the basic Lambda logging policy to it. It cannot touch its own
# role, its own function or other IAM. (EC2 security-group edits and RDS subnet/parameter-group reads can't
# be narrowed further by resource name without guessing, so those are account-wide within us-east-2.)
# The Deny statements at the end always apply, even with DEPLOYER_BROAD=1: the deployer can never change its own
# function, role, image repository, schedule or log group, or write Parameter Store outside /30apps/deployer/.
write_policy() {
  cat >"$TMP/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"TerraformStateList","Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],
  "Resource":"arn:aws:s3:::${BUCKET}"},
 {"Sid":"TerraformStateObjects","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],
  "Resource":"arn:aws:s3:::${BUCKET}/aws/*"},
 {"Sid":"ParameterStoreRead","Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath"],
  "Resource":"arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/30apps/*"},
 {"Sid":"ParameterStoreDeployerState","Effect":"Allow","Action":["ssm:PutParameter","ssm:DeleteParameter"],
  "Resource":"arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/30apps/deployer/*"},
 {"Sid":"DecryptSecureStrings","Effect":"Allow","Action":"kms:Decrypt",
  "Resource":"arn:aws:kms:${REGION}:${ACCOUNT}:key/*",
  "Condition":{"StringEquals":{"kms:ViaService":"ssm.${REGION}.amazonaws.com"}}},
 {"Sid":"EcrToken","Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Sid":"EcrAppRepositories","Effect":"Allow","Action":"ecr:*",
  "Resource":"arn:aws:ecr:${REGION}:${ACCOUNT}:repository/30apps/*"},
 {"Sid":"LambdaApps","Effect":"Allow","Action":"lambda:*",
  "Resource":["arn:aws:lambda:${REGION}:${ACCOUNT}:function:30apps-*","arn:aws:lambda:${REGION}:${ACCOUNT}:function:30apps-*:*"]},
 {"Sid":"ApiGateway","Effect":"Allow","Action":["apigateway:GET","apigateway:POST","apigateway:PUT","apigateway:PATCH","apigateway:DELETE",
            "apigateway:TagResource","apigateway:UntagResource"],
  "Resource":["arn:aws:apigateway:${REGION}::/apis","arn:aws:apigateway:${REGION}::/apis/*",
              "arn:aws:apigateway:${REGION}::/domainnames","arn:aws:apigateway:${REGION}::/domainnames/*",
              "arn:aws:apigateway:${REGION}::/tags/*"]},
 {"Sid":"RdsRead","Effect":"Allow","Action":["rds:Describe*","rds:ListTagsForResource"],"Resource":"*"},
 {"Sid":"RdsDatabase","Effect":"Allow","Action":"rds:*",
  "Resource":["arn:aws:rds:${REGION}:${ACCOUNT}:db:apps30-postgres","arn:aws:rds:${REGION}:${ACCOUNT}:subgrp:*",
              "arn:aws:rds:${REGION}:${ACCOUNT}:pg:*","arn:aws:rds:${REGION}:${ACCOUNT}:og:*"]},
 {"Sid":"Ec2Read","Effect":"Allow","Action":"ec2:Describe*","Resource":"*"},
 {"Sid":"Ec2SecurityGroups","Effect":"Allow",
  "Action":["ec2:CreateSecurityGroup","ec2:DeleteSecurityGroup","ec2:AuthorizeSecurityGroupIngress","ec2:AuthorizeSecurityGroupEgress",
            "ec2:RevokeSecurityGroupIngress","ec2:RevokeSecurityGroupEgress","ec2:ModifySecurityGroupRules",
            "ec2:UpdateSecurityGroupRuleDescriptionsIngress","ec2:UpdateSecurityGroupRuleDescriptionsEgress",
            "ec2:CreateTags","ec2:DeleteTags"],
  "Resource":["arn:aws:ec2:${REGION}:${ACCOUNT}:security-group/*","arn:aws:ec2:${REGION}:${ACCOUNT}:security-group-rule/*",
              "arn:aws:ec2:${REGION}:${ACCOUNT}:vpc/*"]},
 {"Sid":"AppExecutionRole","Effect":"Allow",
  "Action":["iam:CreateRole","iam:DeleteRole","iam:GetRole","iam:UpdateAssumeRolePolicy","iam:TagRole","iam:UntagRole",
            "iam:ListRolePolicies","iam:ListAttachedRolePolicies","iam:ListInstanceProfilesForRole","iam:ListRoleTags"],
  "Resource":"arn:aws:iam::${ACCOUNT}:role/30apps-lambda"},
 {"Sid":"AppExecutionRoleLogsPolicyOnly","Effect":"Allow","Action":["iam:AttachRolePolicy","iam:DetachRolePolicy"],
  "Resource":"arn:aws:iam::${ACCOUNT}:role/30apps-lambda",
  "Condition":{"ArnEquals":{"iam:PolicyARN":"arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"}}},
 {"Sid":"PassAppExecutionRole","Effect":"Allow","Action":"iam:PassRole",
  "Resource":"arn:aws:iam::${ACCOUNT}:role/30apps-lambda",
  "Condition":{"StringEquals":{"iam:PassedToService":"lambda.amazonaws.com"}}},
 {"Sid":"Certificates","Effect":"Allow",
  "Action":["acm:RequestCertificate","acm:DescribeCertificate","acm:DeleteCertificate","acm:ListCertificates",
            "acm:GetCertificate","acm:ListTagsForCertificate","acm:AddTagsToCertificate","acm:RemoveTagsFromCertificate"],
  "Resource":"*","Condition":{"StringEquals":{"aws:RequestedRegion":"${REGION}"}}},
 {"Sid":"AppLogGroups","Effect":"Allow",
  "Action":["logs:CreateLogGroup","logs:DeleteLogGroup","logs:PutRetentionPolicy","logs:DeleteRetentionPolicy",
            "logs:TagResource","logs:UntagResource","logs:TagLogGroup","logs:UntagLogGroup","logs:ListTagsForResource","logs:ListTagsLogGroup"],
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/aws/lambda/30apps-*","arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/aws/lambda/30apps-*:*"]},
 {"Sid":"LogGroupsRead","Effect":"Allow","Action":"logs:DescribeLogGroups","Resource":"*"},
 {"Sid":"OwnLogs","Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"},
 {"Sid":"DenyChangingTheDeployerFunction","Effect":"Deny","Action":"lambda:*",
  "Resource":["arn:aws:lambda:${REGION}:${ACCOUNT}:function:apps30-deployer*","arn:aws:lambda:${REGION}:${ACCOUNT}:function:apps30-deployer*:*"]},
 {"Sid":"DenyDeployerImageRepository","Effect":"Deny","Action":"ecr:*",
  "Resource":"arn:aws:ecr:${REGION}:${ACCOUNT}:repository/apps30/*"},
 {"Sid":"DenyScheduler","Effect":"Deny","Action":"scheduler:*","Resource":"*"},
 {"Sid":"DenyDeployerRoles","Effect":"Deny","Action":"iam:*","Resource":"arn:aws:iam::${ACCOUNT}:role/apps30-*"},
 {"Sid":"DenyChangingTheDeployerLogGroup","Effect":"Deny","Action":["logs:DeleteLogGroup","logs:PutRetentionPolicy"],
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}","arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"]},
 {"Sid":"DenyParameterWritesOutsideDeployerState","Effect":"Deny","Action":["ssm:PutParameter","ssm:DeleteParameter"],
  "NotResource":"arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/30apps/deployer/*"}
]}
JSON
}

put_schedule() { # $1 ENABLED|DISABLED
  local verb=create-schedule i
  aws scheduler get-schedule --name "$SCHEDULE" >/dev/null 2>&1 && verb=update-schedule
  jq -nc --arg arn "$FN_ARN" --arg role "$SCHED_ROLE_ARN" \
    '{Arn:$arn, RoleArn:$role, Input:"{}", RetryPolicy:{MaximumRetryAttempts:0, MaximumEventAgeInSeconds:60}}' >"$TMP/target.json"
  for i in 1 2 3 4 5 6; do
    if OUT="$(aws scheduler "$verb" --name "$SCHEDULE" --state "$1" --schedule-expression "rate(10 minutes)" \
      --flexible-time-window '{"Mode":"OFF"}' --target "file://$TMP/target.json" \
      --description "30 apps: check main every 10 minutes and deploy the AWS stack when it changed" 2>&1)"; then
      return 0
    fi
    if grep -qiE 'must allow|cannot be assumed|assume' <<<"$OUT" && [ "$i" -lt 6 ]; then sleep 10; else fail_step "$verb (EventBridge Scheduler)" "$OUT"; fi
  done
}

show_status() {
  local state last result lock attempts sha
  state="$(aws scheduler get-schedule --name "$SCHEDULE" --query '[State,ScheduleExpression]' --output text 2>/dev/null || echo "not created")"
  last="$(aws ssm get-parameter --name "$P/last_sha" --query Parameter.Value --output text 2>/dev/null || echo "none yet")"
  result="$(aws ssm get-parameter --name "$P/last_result" --query Parameter.Value --output text 2>/dev/null || echo "none yet")"
  lock="$(aws ssm get-parameter --name "$P/lock" --query Parameter.Value --output text 2>/dev/null || echo "free")"
  attempts="$(aws ssm get-parameter --name "$P/attempts" --query Parameter.Value --output text 2>/dev/null || echo "none")"
  sha="$("${CURL[@]}" -m 20 "https://api.github.com/repos/${GH_REPO}/git/ref/heads/main" 2>/dev/null | jq -r '.object.sha // "unknown"' 2>/dev/null || echo "unknown")"
  echo "    schedule:         ${state}"
  echo "    main is at:       ${sha}"
  echo "    last deployed:    ${last}"
  echo "    last result:      ${result}"
  echo "    failed attempts:  ${attempts}   (sha count epoch; the deployer gives up on a commit after 3)"
  echo "    lock:             ${lock}"
}

# Invoke the deployer now (asynchronously) and wait for its result in Parameter Store.
run_once() {
  local run_id start i res ok
  run_id="bootstrap-$(date +%s)"
  start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  try "invoke the deployer" aws lambda invoke --function-name "$FN" --invocation-type Event \
    --cli-binary-format raw-in-base64-out --payload "$(jq -nc --arg r "$run_id" --argjson d "$ALLOW_DESTROY" '{force:true, run_id:$r, allow_destroy:$d}')" "$TMP/invoke.out"
  if [ "$ALLOW_DESTROY" = true ]; then say "This run MAY delete or replace resources (--allow-destroy)"; fi
  say "Deploying now (a no-change run takes a few minutes; a first run or a new app can take up to 15). Waiting for the result..."
  for i in $(seq 1 68); do
    sleep 15
    res="$(aws ssm get-parameter --name "$P/last_result" --query Parameter.Value --output text 2>/dev/null || true)"
    if [ -n "$res" ] && jq -e --arg r "$run_id" --arg s "$start" '(.run_id == $r or .time >= $s) and .ok != null' <<<"$res" >/dev/null 2>&1; then
      ok="$(jq -r '.ok' <<<"$res")"
      echo
      echo "    result: $(jq -c . <<<"$res")"
      if [ "$ok" = true ]; then
        say "The deploy worked. From now on a merge to main deploys to AWS within about 10 minutes."
        return 0
      fi
      echo
      say "The deploy did not succeed. Last lines of its log:"
      aws logs tail "$LOG_GROUP" --since 30m --format short 2>/dev/null | tail -n 40 | cut -d' ' -f2- |
        jq -R -r 'fromjson? | "    \(.level // "") \(.msg)"' 2>/dev/null | cut -c1-300 || true
      echo
      echo "    The CloudShell one-liner still works. A permission error above means the deployer's policy needs"
      echo "    another action: tell the person who set this up, or rerun with DEPLOYER_BROAD=1."
      return 1
    fi
    printf '.'
  done
  echo
  say "No result after 17 minutes. Check later with: ... | bash -s -- status   (logs: ${LOG_GROUP})"
  return 1
}

remove_all() {
  say "Removing the automatic deploy (apps, their state and the CloudShell flow are not touched)"
  if aws scheduler delete-schedule --name "$SCHEDULE" >/dev/null 2>&1; then say "Deleted schedule"; fi
  if aws lambda delete-function --function-name "$FN" >/dev/null 2>&1; then say "Deleted function"; fi
  if aws logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1; then say "Deleted log group"; fi
  if aws ecr delete-repository --repository-name "$ECR_REPO" --force >/dev/null 2>&1; then say "Deleted ECR repository"; fi
  for r in "$ROLE" "$SCHED_ROLE"; do
    for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
      aws iam delete-role-policy --role-name "$r" --policy-name "$p" >/dev/null 2>&1 || true
    done
    for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "$r" --policy-arn "$p" >/dev/null 2>&1 || true
    done
    if aws iam delete-role --role-name "$r" >/dev/null 2>&1; then say "Deleted role $r"; fi
  done
  for p in last_sha last_result attempts lock; do aws ssm delete-parameter --name "$P/$p" >/dev/null 2>&1 || true; done
  say "Done."
}

# ---- commands that need no setup -------------------------------------------------------------------

case "$COMMAND" in
  status)
    say "Account ${ACCOUNT}, region ${REGION}"
    show_status
    exit 0
    ;;
  remove)
    remove_all
    exit 0
    ;;
  pause | install) ;;
  resume | deploy) ;;
  *)
    echo "Unknown command '${COMMAND}'. Use: install (default), pause, resume, deploy, status or remove."
    exit 1
    ;;
esac

say "Account ${ACCOUNT}, region ${REGION}"

if [ "$COMMAND" = resume ] || [ "$COMMAND" = deploy ]; then require_main_protected; fi

if [ "$COMMAND" = pause ] || [ "$COMMAND" = resume ]; then
  aws lambda get-function --function-name "$FN" >/dev/null 2>&1 || { say "The deployer isn't set up yet. Run this script with no argument first."; exit 1; }
  if [ "$COMMAND" = pause ]; then
    put_schedule DISABLED
    say "Paused. Nothing deploys automatically until you run '... | bash -s -- resume'. The CloudShell one-liner still works."
  else
    put_schedule ENABLED
    say "Resumed: main is checked every 10 minutes."
  fi
  exit 0
fi

if [ "$COMMAND" = deploy ]; then
  aws lambda get-function --function-name "$FN" >/dev/null 2>&1 || { say "The deployer isn't set up yet. Run this script with no argument first."; exit 1; }
  run_once
  exit $?
fi

# ---- install / update ------------------------------------------------------------------------------

require_main_protected
ensure_tools

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  say "The Terraform state bucket ${BUCKET} doesn't exist. Run bootstrap/aws.sh and the CloudShell deploy first."
  exit 1
fi

# 1. The image: public on GHCR, signed by this repo's workflow on main, identified by its digest.
install_cosign
SRC_REPO="${SRC_IMAGE%:*}"
if ! OUT="$(crane digest "$SRC_IMAGE" 2>&1)"; then
  say "Cannot pull ${SRC_IMAGE} without signing in."
  echo "    Either the 'AWS deployer image' workflow hasn't run on main yet (GitHub, Actions), or the package is private."
  echo "    Make it public: github.com/orgs/BreakthruDevelopment/packages/container/30apps-deployer/settings"
  echo "    (Danger Zone, Change visibility, Public), then rerun this script."
  echo "    crane said: $(head -c 300 <<<"$OUT")"
  exit 1
fi
SRC_DIGEST="$OUT"
[[ "$SRC_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail_step "resolve the image digest" "unexpected digest: ${SRC_DIGEST:0:100}"
if ! OUT="$("$TMP/cosign" verify --certificate-identity "$SIGNER_IDENTITY" --certificate-oidc-issuer "$OIDC_ISSUER" \
  "${SRC_REPO}@${SRC_DIGEST}" 2>&1 >/dev/null)"; then
  echo
  echo "==> STOPPED: the signature of ${SRC_REPO}@${SRC_DIGEST} did not verify."
  echo "    Expected a Sigstore signature from: ${SIGNER_IDENTITY}"
  echo "    cosign said: $(head -c 500 <<<"$OUT")"
  echo "    The image was not copied and nothing was changed. If the workflow only just finished, wait a minute and rerun."
  exit 3
fi
say "Image signature verified (${SRC_DIGEST}), signed by the AWS deployer image workflow on main"

# 2. IAM. First because it is the step most likely to be blocked by guardrails.
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
SCHED_TRUST="$(jq -nc --arg a "$ACCOUNT" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"scheduler.amazonaws.com"},Action:"sts:AssumeRole",Condition:{StringEquals:{"aws:SourceAccount":$a}}}]}')"
ensure_role "$ROLE" "$LAMBDA_TRUST"
write_policy
try "attach the deployer's permissions to role ${ROLE}" aws iam put-role-policy --role-name "$ROLE" \
  --policy-name deploy-30apps-aws --policy-document "file://$TMP/policy.json"
say "Deployer permissions set (scoped to the stack's resources)"
if [ "${DEPLOYER_BROAD:-}" = 1 ]; then
  try "attach PowerUserAccess" aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
  say "DEPLOYER_BROAD=1: PowerUserAccess is attached as well (the explicit Deny statements still apply)"
else
  # A rerun without the flag takes the broad policy away again.
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/PowerUserAccess >/dev/null 2>&1 || true
fi
ensure_role "$SCHED_ROLE" "$SCHED_TRUST"
jq -nc --arg arn "$FN_ARN" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"lambda:InvokeFunction",Resource:[$arn,($arn+":*")]}]}' >"$TMP/sched-policy.json"
try "let the scheduler invoke the deployer" aws iam put-role-policy --role-name "$SCHED_ROLE" \
  --policy-name invoke-deployer --policy-document "file://$TMP/sched-policy.json"

# 3. ECR repository for the deployer image (Lambda can only run images from ECR), then copy the image in.
if ! aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
  try "create the ECR repository ${ECR_REPO}" aws ecr create-repository --repository-name "$ECR_REPO" \
    --tags Key=project,Value=30-apps-30-days
  say "Created ECR repository ${ECR_REPO}"
fi
try "set the ECR lifecycle policy" aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"Keep the two newest images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":2},"action":{"type":"expire"}}]}'
jq -nc --arg src "arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}" \
  '{Version:"2012-10-17",Statement:[{Sid:"LambdaECRImageRetrievalPolicy",Effect:"Allow",Principal:{Service:"lambda.amazonaws.com"},Action:["ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],Condition:{StringLike:{"aws:sourceArn":$src}}}]}' >"$TMP/ecr-policy.json"
if ! aws ecr set-repository-policy --repository-name "$ECR_REPO" --policy-text "file://$TMP/ecr-policy.json" >/dev/null 2>&1; then
  say "Could not set the repository policy (Lambda usually adds it itself); continuing"
fi
aws ecr get-login-password | crane auth login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1 ||
  fail_step "sign crane in to ECR" "aws ecr get-login-password failed"
say "Copying ${SRC_REPO}@${SRC_DIGEST} into ECR (by the verified digest, never a tag)"
try "copy the deployer image into ECR" crane copy "${SRC_REPO}@${SRC_DIGEST}" "${REGISTRY}/${ECR_REPO}:latest"
try "read the digest of the copied image" crane digest "${REGISTRY}/${ECR_REPO}:latest"
DIGEST="$OUT"
if [ "$DIGEST" != "$SRC_DIGEST" ]; then fail_step "check the copied image" "ECR has ${DIGEST}, expected the verified ${SRC_DIGEST}"; fi
IMAGE_URI="${REGISTRY}/${ECR_REPO}@${DIGEST}"
say "Image in ECR: ${DIGEST}"

# 4. Log group with short retention (the function would otherwise create one that never expires).
if ! aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[].logGroupName' --output text 2>/dev/null | grep -qw "$LOG_GROUP"; then
  try "create the log group" aws logs create-log-group --log-group-name "$LOG_GROUP"
fi
try "set log retention" aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 14

# 5. The function.
if aws lambda get-function --function-name "$FN" >/dev/null 2>&1; then
  try "update the function code" aws lambda update-function-code --function-name "$FN" --image-uri "$IMAGE_URI" --query FunctionArn --output text
  try "wait for the new code to be ready" aws lambda wait function-updated-v2 --function-name "$FN"
  try "update the function configuration" aws lambda update-function-configuration --function-name "$FN" \
    --role "$ROLE_ARN" --memory-size "$MEMORY" --timeout 900 --ephemeral-storage Size=512 --query FunctionArn --output text
  say "Updated function ${FN}"
else
  for i in 1 2 3 4 5 6; do
    if OUT="$(aws lambda create-function --function-name "$FN" --package-type Image --code "ImageUri=${IMAGE_URI}" \
      --role "$ROLE_ARN" --architectures arm64 --memory-size "$MEMORY" --timeout 900 --ephemeral-storage Size=512 \
      --description "Deploys the AWS stack of 30-apps-infra when main changes (pull model)" \
      --tags project=30-apps-30-days --query FunctionArn --output text 2>&1)"; then
      break
    fi
    if grep -qi 'cannot be assumed' <<<"$OUT" && [ "$i" -lt 6 ]; then sleep 10; else fail_step "create the Lambda function (container image from ECR)" "$OUT"; fi
  done
  say "Created function ${FN}"
fi
try "wait for the function to be active" aws lambda wait function-active-v2 --function-name "$FN"
try "wait for the function update to finish" aws lambda wait function-updated-v2 --function-name "$FN"

# One run at a time and no automatic retries (a failed deploy is recorded and retried by the schedule, with a limit).
try "turn off asynchronous retries" aws lambda put-function-event-invoke-config --function-name "$FN" \
  --maximum-retry-attempts 0 --maximum-event-age-in-seconds 60
if OUT="$(aws lambda put-function-concurrency --function-name "$FN" --reserved-concurrent-executions 1 2>&1)"; then
  say "Reserved concurrency 1 set"
else
  say "Could not reserve concurrency (small accounts must keep unreserved capacity); the Parameter Store lock still allows one deploy at a time"
fi

# 6. The schedule.
put_schedule ENABLED
say "Schedule ${SCHEDULE}: every 10 minutes"

cat <<EOF

============================================================
Automatic AWS deploys are set up.
  function   ${FN} (arm64 container image, ${MEMORY} MB, 15 min max)
  schedule   every 10 minutes (EventBridge Scheduler); pause with:  ... | bash -s -- pause
  role       ${ROLE} (scoped to this stack; no access keys; GitHub never signs in to AWS)
  logs       CloudWatch ${LOG_GROUP} (JSON lines, 14 days)
  results    Parameter Store ${P}/last_result and ${P}/last_sha
Free tier: ~4,300 invocations a month (1,000,000 free), a no-change check uses a few GB-seconds, a deploy a few
hundred (400,000 free). The deployer retries a failing commit at most 3 times.
============================================================

EOF
run_once
