#!/usr/bin/env bash
# Build the Terraform `app_secrets` variable for one cloud from GitHub environment secrets.
#
#   SECRETS_JSON='<toJSON(secrets)>' deploy/gh-app-secrets.sh <azure|gcp> <output-file>
#
# GitHub can't list secrets by pattern, so the workflow hands over the whole `secrets` context
# (masked) and this picks out, for every app that runs on <cloud> and declares `secrets:` in
# apps.yaml, the secret named <APP>_<VAR> (app name upper-cased, '-' -> '_'; build-tracker +
# INGEST_TOKEN -> BUILD_TRACKER_INGEST_TOKEN). The result is a tfvars JSON file (mode 600):
#   {"app_secrets": {"<app>": {"<VAR>": "<value>"}}}
# Missing or empty secrets are skipped with a warning that names the secret, never a value.
# Values only travel through the environment, stdin and the output file; nothing is printed.
set -euo pipefail

cloud="${1:?usage: gh-app-secrets.sh <cloud> <output-file>}"
out="${2:?usage: gh-app-secrets.sh <cloud> <output-file>}"
apps_yaml="${APPS_YAML:-$(dirname "$0")/../apps.yaml}"
: "${SECRETS_JSON:?SECRETS_JSON is not set}"
export SECRETS_JSON

# One entry per (app, var) wanted on this cloud: {"app": "build-tracker", "var": "INGEST_TOKEN", "key": "BUILD_TRACKER_INGEST_TOKEN"}
wanted="$(CLOUD="$cloud" yq -o=json '[.apps[] | select(.clouds | contains([strenv(CLOUD)])) | select(.secrets) | {"name": .name, "secrets": .secrets}]' "$apps_yaml" \
  | jq -c '[.[] | .name as $n | ($n | ascii_upcase | gsub("-"; "_")) as $p | .secrets[] | {app: $n, var: ., key: ($p + "_" + .)}]')"

umask 077
jq -r '(env.SECRETS_JSON | fromjson) as $s | .[] | select(($s[.key] // "") == "") | "::warning::Secret \(.key) is not set (app \(.app)); skipping \(.var)"' <<<"$wanted"
jq '(env.SECRETS_JSON | fromjson) as $s
    | {app_secrets: (reduce (.[] | select(($s[.key] // "") != "")) as $w ({}; .[$w.app][$w.var] = $s[$w.key]))}' <<<"$wanted" >"$out"

echo "Per-app secrets for ${cloud}: $(jq '[.app_secrets[] | length] | add // 0' "$out") value(s) for $(jq '.app_secrets | length' "$out") app(s)"
