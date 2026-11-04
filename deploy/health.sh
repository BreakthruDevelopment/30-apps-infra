#!/usr/bin/env bash
# Usage: deploy/health.sh '<terraform output -json urls>'
# Waits up to ~5 minutes per app for /api/health to answer 200 (new apps may still be
# starting or migrating), then prints each app's status. Fails only if an app never answers.
set -uo pipefail

urls_json="${1:-}"
[ -z "$urls_json" ] && urls_json="{}"
failed=0
while read -r name url; do
  [ -z "$name" ] && continue
  status=000
  for _ in $(seq 1 30); do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${url}/api/health")"
    [ "$status" = "200" ] && break
    sleep 10
  done
  echo "${name}: ${url} -> HTTP ${status}"
  echo "- **${name}**: ${url} (health: HTTP ${status})" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  [ "$status" = "000" ] && failed=1
done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$urls_json")
exit "$failed"
