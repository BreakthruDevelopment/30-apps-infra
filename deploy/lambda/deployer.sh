#!/usr/bin/env bash
# The deployer's own logic: what ONE invocation does. Sourced by the runtime (deploy/lambda/bootstrap).
#
# This file is baked into the deployer image, so it stays small and stable. The real deploy logic is
# deploy/aws.sh from the commit being deployed; fixes to it reach AWS without rebuilding the image.
#
# One invocation:
#   1. take the lock (Parameter Store: only one deploy at a time, even if the account can't reserve concurrency)
#   2. find the commit SHA of `main` and compare it with /30apps/deployer/last_sha; stop if unchanged
#   3. give up on a commit after 3 failed attempts (so a broken commit can't burn the free compute tier)
#   4. download that exact commit's tarball (pinned to the SHA, never a branch name) and run its deploy/aws.sh
#   5. on success write last_sha; either way write last_result (JSON: sha, ok, time, message)
#
# Parameter Store (standard parameters, free), all under /30apps/deployer/:
#   last_sha     the commit that was last deployed successfully
#   last_result  {"sha","ok","time","message","run_id","trigger","seconds"}  (ok is null while running)
#   attempts     "<sha> <count> <epoch of the last attempt>"
#   lock         {"holder","expires"}  deploy/aws.sh takes the same lock when run by hand in CloudShell
#
# Event: {} from the schedule; {"force":true,"run_id":"..."} from bootstrap/aws-autodeploy.sh (deploy even if
# main is unchanged, and ignore the attempt limit). Nothing here ever prints a secret: aws.sh reads secrets
# into environment variables only, and Terraform masks sensitive values.

DEPLOYER_REPO="${DEPLOYER_REPO:-BreakthruDevelopment/30-apps-infra}"
DEADLINE_MS="${DEADLINE_MS:-0}"
P="/30apps/deployer"
WORK="/tmp/deployer"
MAX_ATTEMPTS=3
RETRY_GAP_SECONDS=1500 # at least 25 minutes between attempts at the same commit

# JSON log line on stderr: log <level> <message> [--arg key value ...]
log() {
  local level="$1" msg="$2"
  shift 2
  jq -nc --arg level "$level" --arg msg "$msg" "$@" \
    '{ts: (now | todate), level: $level, msg: $msg} + ($ARGS.named | del(.level, .msg))' >&2
}

param_get() { aws ssm get-parameter --name "$1" --query Parameter.Value --output text 2>/dev/null || true; }
param_put() { aws ssm put-parameter --name "$1" --type String --overwrite --value "$2" >/dev/null; }
param_del() { aws ssm delete-parameter --name "$1" >/dev/null 2>&1 || true; }

# The commit `main` points at. The GitHub API answers an unauthenticated call with just the SHA; AWS's shared
# egress addresses can hit its rate limit, so fall back to the git protocol's ref advertisement (not rate limited).
main_sha() {
  local sha
  sha="$(curl -fsS -m 20 -H 'Accept: application/vnd.github.sha' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: 30apps-deployer' "https://api.github.com/repos/${DEPLOYER_REPO}/commits/main" 2>/dev/null || true)"
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    sha="$(curl -fsS -m 30 -H 'User-Agent: 30apps-deployer' "https://github.com/${DEPLOYER_REPO}.git/info/refs?service=git-upload-pack" 2>/dev/null |
      grep -a -o '[0-9a-f]\{40\} refs/heads/main$' | head -n 1 | cut -d' ' -f1 || true)"
  fi
  if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then printf '%s' "$sha"; fi
}

LOCK_MINE=0
# Atomic: put-parameter without --overwrite fails if the parameter exists. The value carries an expiry (this
# invocation's deadline plus a minute), so a run that died without cleaning up only blocks others until then.
lock_acquire() {
  local now expires value out cur
  now="$(date +%s)"
  expires=$((DEADLINE_MS / 1000 + 60))
  value="$(jq -nc --arg h lambda --argjson e "$expires" '{holder: $h, expires: $e}')"
  if out="$(aws ssm put-parameter --name "$P/lock" --type String --value "$value" 2>&1)"; then
    LOCK_MINE=1
    return 0
  fi
  if ! grep -q ParameterAlreadyExists <<<"$out"; then
    log error "could not take the lock" --arg error "$(head -c 300 <<<"$out")"
    return 2
  fi
  cur="$(param_get "$P/lock" | jq -r '.expires // 0' 2>/dev/null || echo 0)"
  if [[ "$cur" =~ ^[0-9]+$ ]] && [ "$now" -gt "$cur" ]; then
    log warn "taking over an expired lock"
    param_put "$P/lock" "$value"
    LOCK_MINE=1
    return 0
  fi
  return 1
}

cleanup() {
  if [ "$LOCK_MINE" = 1 ]; then param_del "$P/lock"; fi
  rm -rf "$WORK" /tmp/home /tmp/30apps-terraform /tmp/30apps-terraform.init.log
}

# write_result <sha> <ok: true|false|null> <message> — never holds secrets, message is cut to 300 characters.
write_result() {
  local json
  json="$(jq -nc --arg sha "$1" --argjson ok "$2" --arg message "${3:0:300}" --arg run_id "$RUN_ID" \
    --arg trigger "$TRIGGER" --argjson seconds "$((SECONDS - START))" \
    '{sha: $sha, ok: $ok, time: (now | todate), message: $message, run_id: $run_id, trigger: $trigger, seconds: $seconds}')"
  param_put "$P/last_result" "$json" || log error "could not write last_result"
}

# A short, readable reason from the deploy log: the script's own ERROR line, else Terraform's first Error.
failure_summary() {
  local log_file="$1" msg
  msg="$(grep -a -m1 '^==> ERROR' "$log_file" || true)"
  if [ -z "$msg" ]; then
    msg="$(grep -a -m1 -A1 -E '^(│ )?Error:' "$log_file" | tr '\n' ' ' | sed 's/│//g' | tr -s ' ' || true)"
  fi
  if [ -z "$msg" ]; then msg="$(grep -a -v '^[[:space:]]*$' "$log_file" | tail -n 2 | tr '\n' ' ' || true)"; fi
  printf '%s' "$msg" | tr -cd '[:print:]' | head -c 300
}

run_deploy() {
  local sha="$1" budget rc
  budget=$(((DEADLINE_MS - $(date +%s%3N)) / 1000 - 75))
  if [ "$budget" -lt 120 ]; then
    echo "not enough time left in this invocation (${budget}s)" >"$WORK/deploy.log"
    return 124
  fi
  # INT first: Terraform stops gracefully and releases its state lock; KILL 30 seconds later if it hasn't.
  AWS_DEPLOY_SRC="$WORK/src" DEPLOY_LOCK_HELD=1 DEPLOY_STRICT_HEALTH=1 HEALTH_WAIT_SECONDS=150 \
    timeout --signal=INT --kill-after=30 "$budget" bash "$WORK/src/deploy/aws.sh" 2>&1 |
    sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' | tee "$WORK/deploy.log" |
    jq -R -c --unbuffered --arg sha "$sha" '{ts: (now | todate), level: "info", src: "aws.sh", sha: $sha, msg: .}' >&2
  rc="${PIPESTATUS[0]}"
  return "$rc"
}

# One invocation. Prints a one-line JSON response on stdout.
handler() {
  local event="$1" out
  # A subshell so the EXIT trap always releases the lock and wipes /tmp (it is reused between invocations).
  out="$(
    trap cleanup EXIT
    handle_event "$event"
  )"
  printf '%s\n' "$out"
}

handle_event() {
  local event="$1" sha last now n a_sha a_n a_t force rc
  SECONDS=0
  START=0
  force="$(jq -r '.force // false' <<<"$event" 2>/dev/null || echo false)"
  RUN_ID="$(jq -r '.run_id // ""' <<<"$event" 2>/dev/null || true)"
  TRIGGER="schedule"
  if [ "$force" = true ]; then TRIGGER="manual"; fi

  rm -rf "$WORK"
  mkdir -p "$WORK/src" /tmp/home
  export HOME=/tmp/home TF_DATA_DIR=/tmp/30apps-terraform

  if [ "${AWS_REGION:-}" != "${AWS_TARGET_REGION:-us-east-2}" ]; then
    log error "wrong region; refusing to run" --arg region "${AWS_REGION:-unset}"
    echo '{"status":"error","reason":"wrong region"}'
    return 0
  fi

  lock_acquire
  rc=$?
  if [ "$rc" = 1 ]; then
    log info "another deploy holds the lock; nothing to do"
    echo '{"status":"busy"}'
    return 0
  elif [ "$rc" != 0 ]; then
    echo '{"status":"error","reason":"lock"}'
    return 0
  fi

  sha="$(main_sha)"
  if [ -z "$sha" ]; then
    log error "could not read the commit of main from GitHub"
    echo '{"status":"error","reason":"github unreachable"}'
    return 0
  fi

  last="$(param_get "$P/last_sha")"
  if [ "$sha" = "$last" ] && [ "$force" != true ]; then
    log info "up to date" --arg sha "$sha"
    echo '{"status":"up-to-date"}'
    return 0
  fi

  # Attempt limit per commit, so a broken commit is retried a few times, not every 10 minutes forever.
  now="$(date +%s)"
  read -r a_sha a_n a_t <<<"$(param_get "$P/attempts")"
  n=0
  if [ "${a_sha:-}" = "$sha" ] && [[ "${a_n:-}" =~ ^[0-9]+$ ]]; then n="$a_n"; fi
  if [ "$force" != true ]; then
    if [ "$n" -ge "$MAX_ATTEMPTS" ]; then
      log warn "giving up on this commit after repeated failures; push a fix or force a run" --arg sha "$sha" --argjson attempts "$n"
      echo '{"status":"gave-up"}'
      return 0
    fi
    if [ "$n" -gt 0 ] && [[ "${a_t:-}" =~ ^[0-9]+$ ]] && [ $((now - a_t)) -lt "$RETRY_GAP_SECONDS" ]; then
      log info "waiting before retrying this commit" --arg sha "$sha" --argjson attempts "$n"
      echo '{"status":"waiting"}'
      return 0
    fi
  fi
  param_put "$P/attempts" "$sha $((n + 1)) $now"
  write_result "$sha" null "deploy started"
  log info "deploying" --arg sha "$sha" --arg trigger "$TRIGGER" --argjson attempt "$((n + 1))"

  if ! curl -fsSL -m 120 -H 'User-Agent: 30apps-deployer' "https://codeload.github.com/${DEPLOYER_REPO}/tar.gz/${sha}" |
    tar -xz -C "$WORK/src" --strip-components=1 || [ ! -f "$WORK/src/deploy/aws.sh" ]; then
    log error "could not download the commit" --arg sha "$sha"
    write_result "$sha" false "could not download commit ${sha:0:7} from GitHub"
    echo '{"status":"failed","reason":"download"}'
    return 0
  fi

  run_deploy "$sha"
  rc=$?
  if [ "$rc" = 0 ]; then
    param_put "$P/last_sha" "$sha"
    param_del "$P/attempts"
    write_result "$sha" true "deployed ${sha:0:7}: $(grep -a 'Apply complete!' "$WORK/deploy.log" | tail -n 1 || true)"
    log info "deploy succeeded" --arg sha "$sha" --argjson seconds "$SECONDS"
    echo '{"status":"deployed"}'
  else
    write_result "$sha" false "failed (exit ${rc}): $(failure_summary "$WORK/deploy.log")"
    log error "deploy failed" --arg sha "$sha" --argjson exit_code "$rc" --argjson seconds "$SECONDS"
    echo '{"status":"failed"}'
  fi
  return 0
}
