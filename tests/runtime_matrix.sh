#!/usr/bin/env bash
# End-to-end validation for the supported Docker/Sysbox runtime matrix.
#
# This harness is deliberately separate from tests/run.sh: it needs a real Docker daemon and
# Sysbox, while the source test suite must remain runnable on an ordinary development host. The
# caller supplies a freshly-created AGENTBOX_RUNTIME_TEST_ROOT; this file never removes that root
# because result.toml is the durable audit record for the invocation.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RESULT_FILE=""
TEST_ROOT=""
PROJECT_DIR=""
MACHINE=""
CNAME=""
DVOL=""
JVOL=""
CONTAINER_ID=""
IMAGE_REFERENCE=""
CURRENT_ROW="setup"
CURRENT_DIAGNOSTIC=""
OVERALL_STATUS="fail"
CLEANUP_STATUS="not-run"
CLEANUP_DIAGNOSTIC=""
CLEANUP_ELIGIBLE=0
RESOURCES_CREATED=0
CONTAINER_CREATED_BY_RUN=0
NETWORKS_ACCOUNTED=0
NETWORK_INVENTORY_STATUS="not-recorded"
MUTATION_STARTED_EPOCH=""
FINALIZED=0
AB_ENV=()
ROW_TIMER_PID=""
WHOLE_TIMER_PID=""
PREREQUISITES_BLOCKED=0
CONTEXT_REVISION=""
CONTEXT_CHANGED=0
DOCKER_INFO_STATUS="unavailable"
OPERATION_ID=""
OPERATION_NEW_CONTAINER_ID=""

declare -a ROW_IDS=()
declare -a ROW_STATUSES=()
declare -a ROW_DIAGNOSTICS=()
declare -a RESOURCE_KINDS=()
declare -a RESOURCE_NAMES=()
declare -a RESOURCE_IDS=()
declare -a RESOURCE_OWNED=()
declare -a RESOURCE_CLEANUP=()
declare -a CONTEXT_FILES=(
  "bin/ab"
  "agentbox-entrypoint.sh"
  "Dockerfile"
  ".bashrc"
  ".dockerignore"
  "runtime/git-disabled"
  "sysbox.nix"
)
declare -A CONTEXT_HASHES=()
declare -A CONTEXT_METADATA=()
declare -A VOLUME_IDENTITIES=()
declare -A VOLUME_CREATED_BY_RUN=()
declare -A NETWORK_IDENTITIES=()
PRECHECK_COMPLETE=0

LAST_OUTPUT=""
ROW_FAILURE=0
ROW_DIAGNOSTIC=""

# Every direct Docker CLI operation in this harness is bounded independently of the 180-second
# row timer. The production launcher is invoked as a separate process and keeps its own timeout.
DOCKER_BIN="$(type -P docker 2>/dev/null || true)"
docker() {
  timeout 30 "$DOCKER_BIN" "$@"
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf '%s' "$value"
}

record_row() {
  ROW_IDS+=("$1")
  ROW_STATUSES+=("$2")
  ROW_DIAGNOSTICS+=("${3:-none}")
}

record_resource() {
  RESOURCE_KINDS+=("$1")
  RESOURCE_NAMES+=("$2")
  RESOURCE_IDS+=("${3:-unknown}")
  RESOURCE_OWNED+=("${4:-false}")
  RESOURCE_CLEANUP+=("${5:-not-attempted}")
}

write_result() {
  local now i volume_ownership
  [ -n "$RESULT_FILE" ] || return 0
  volume_ownership=false=false
  if [ -n "$DVOL" ] && [ -n "$JVOL" ]; then
    volume_ownership="$([ "${VOLUME_CREATED_BY_RUN[$DVOL]:-0}" -eq 1 ] && printf true || printf false)=$([ "${VOLUME_CREATED_BY_RUN[$JVOL]:-0}" -eq 1 ] && printf true || printf false)"
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$RESULT_FILE")"
  {
    printf 'schema = 1\n'
    printf 'status = "%s"\n' "$(toml_escape "$OVERALL_STATUS")"
    printf 'started_at = "%s"\n' "$(toml_escape "${STARTED_AT:-unknown}")"
    printf 'finished_at = "%s"\n' "$(toml_escape "$now")"
    printf 'invocation_script = "%s"\n' "$(toml_escape "$SCRIPT_DIR/runtime_matrix.sh")"
    printf 'repository_context = "%s"\n' "$(toml_escape "$REPO_ROOT")"
    printf 'context_revision = "%s"\n' "$(toml_escape "$CONTEXT_REVISION")"
    printf 'context_changed = %s\n' "$([ "$CONTEXT_CHANGED" -eq 0 ] && printf false || printf true)"
    printf 'runtime_test_root = "%s"\n' "$(toml_escape "$TEST_ROOT")"
    printf 'project_directory = "%s"\n' "$(toml_escape "$PROJECT_DIR")"
    printf 'machine = "%s"\n' "$(toml_escape "$MACHINE")"
    printf 'container_name = "%s"\n' "$(toml_escape "$CNAME")"
    printf 'inner_docker_volume = "%s"\n' "$(toml_escape "$DVOL")"
    printf 'jj_volume = "%s"\n' "$(toml_escape "$JVOL")"
    printf 'prerequisites_blocked = %s\n' "$([ "$PREREQUISITES_BLOCKED" -eq 1 ] && printf true || printf false)"
    printf 'cleanup_status = "%s"\n' "$(toml_escape "$CLEANUP_STATUS")"
    printf 'cleanup_diagnostic = "%s"\n' "$(toml_escape "$CLEANUP_DIAGNOSTIC")"
    printf 'cleanup_eligible = %s\n' "$([ "$CLEANUP_ELIGIBLE" -eq 1 ] && printf true || printf false)"
    printf 'ownership_container_event = %s\n' "$([ "$CONTAINER_CREATED_BY_RUN" -eq 1 ] && printf true || printf false)"
    printf 'ownership_volume_events = "%s"\n' "$(toml_escape "$volume_ownership")"
    printf 'networks_accounted = %s\n' "$([ "$NETWORKS_ACCOUNTED" -eq 1 ] && printf true || printf false)"
    printf 'network_inventory = "%s"\n' "$(toml_escape "$NETWORK_INVENTORY_STATUS")"
    printf 'docker_info = "%s"\n' "$(toml_escape "$DOCKER_INFO_STATUS")"
    printf 'current_row = "%s"\n' "$(toml_escape "$CURRENT_ROW")"
    printf 'current_diagnostic = "%s"\n' "$(toml_escape "$CURRENT_DIAGNOSTIC")"
    printf '\n[versions]\n'
    printf 'docker_client = "%s"\n' "$(toml_escape "${DOCKER_CLIENT_VERSION:-unavailable}")"
    printf 'docker_server = "%s"\n' "$(toml_escape "${DOCKER_SERVER_VERSION:-unavailable}")"
    printf 'sysbox = "%s"\n' "$(toml_escape "${SYSBOX_VERSION:-unavailable}")"
    printf 'sysbox_runtime_path = "%s"\n' "$(toml_escape "${SYSBOX_RUNTIME_PATH:-unavailable}")"
    printf 'runtimes = "%s"\n' "$(toml_escape "${DOCKER_RUNTIMES:-unavailable}")"
    printf 'nested_hello_world = "%s"\n' "$(toml_escape "${NESTED_HELLO_WORLD:-not-run}")"
    printf '\n[invocation]\n'
    printf 'home = "%s"\n' "$(toml_escape "${HOME:-unset}")"
    printf 'xdg_config_home = "%s"\n' "$(toml_escape "${XDG_CONFIG_HOME:-unset}")"
    printf 'xdg_state_home = "%s"\n' "$(toml_escape "${XDG_STATE_HOME:-unset}")"
    printf 'xdg_cache_home = "%s"\n' "$(toml_escape "${XDG_CACHE_HOME:-unset}")"
    printf 'xdg_runtime_dir = "%s"\n' "$(toml_escape "${XDG_RUNTIME_DIR:-unset}")"
    printf 'agentbox_dir = "%s"\n' "$(toml_escape "${AGENTBOX_DIR:-unset}")"
    printf 'agentbox_machine = "%s"\n' "$(toml_escape "${AGENTBOX_MACHINE:-unset}")"
    printf '\n'
    for i in "${!ROW_IDS[@]}"; do
      printf '[[rows]]\n'
      printf 'id = "%s"\n' "$(toml_escape "${ROW_IDS[$i]}")"
      printf 'status = "%s"\n' "$(toml_escape "${ROW_STATUSES[$i]}")"
      printf 'diagnostic = "%s"\n\n' "$(toml_escape "${ROW_DIAGNOSTICS[$i]}")"
    done
    for i in "${!RESOURCE_KINDS[@]}"; do
      printf '[[resources]]\n'
      printf 'kind = "%s"\n' "$(toml_escape "${RESOURCE_KINDS[$i]}")"
      printf 'name = "%s"\n' "$(toml_escape "${RESOURCE_NAMES[$i]}")"
      printf 'id = "%s"\n' "$(toml_escape "${RESOURCE_IDS[$i]}")"
      printf 'owned = %s\n' "${RESOURCE_OWNED[$i]}"
      printf 'cleanup = "%s"\n\n' "$(toml_escape "${RESOURCE_CLEANUP[$i]}")"
    done
  } >"$RESULT_FILE"
}

context_snapshot() {
  local file path
  CONTEXT_REVISION="$(jj --repository "$REPO_ROOT" --ignore-working-copy log -r @ --no-graph -T 'commit_id' 2>/dev/null)" || return 1
  [ -n "$CONTEXT_REVISION" ] || return 1
  for file in "${CONTEXT_FILES[@]}"; do
    path="$REPO_ROOT/$file"
    [ -f "$path" ] || return 1
    CONTEXT_HASHES["$file"]="$(sha256sum "$path" | cut -d' ' -f1)"
    CONTEXT_METADATA["$file"]="$(stat -c '%s:%Y:%a' "$path")"
  done
}

context_verify_unchanged() {
  local file path hash metadata revision
  revision="$(jj --repository "$REPO_ROOT" --ignore-working-copy log -r @ --no-graph -T 'commit_id' 2>/dev/null || true)"
  if [ "$revision" != "$CONTEXT_REVISION" ]; then
    CONTEXT_CHANGED=1
    return 1
  fi
  for file in "${CONTEXT_FILES[@]}"; do
    path="$REPO_ROOT/$file"
    hash="$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1 || true)"
    metadata="$(stat -c '%s:%Y:%a' "$path" 2>/dev/null || true)"
    if [ "$hash" != "${CONTEXT_HASHES[$file]:-}" ] ||
       [ "$metadata" != "${CONTEXT_METADATA[$file]:-}" ]; then
      CONTEXT_CHANGED=1
      return 1
    fi
  done
}

path_below_root() {
  local path="$1" resolved root
  root="$(realpath -e "$TEST_ROOT" 2>/dev/null)" || return 1
  resolved="$(realpath -m "$path" 2>/dev/null)" || return 1
  [ "$resolved" != "$root" ] && [[ "$resolved" == "$root"/* ]]
}

validate_invocation() {
  local context resolved expected
  : "${AGENTBOX_RUNTIME_TEST_ROOT:?AGENTBOX_RUNTIME_TEST_ROOT is required}"
  : "${AGENTBOX_CONTEXT:?AGENTBOX_CONTEXT is required}"
  : "${AGENTBOX_DIR:?AGENTBOX_DIR is required}"
  : "${AGENTBOX_MACHINE:?AGENTBOX_MACHINE is required}"
  TEST_ROOT="$AGENTBOX_RUNTIME_TEST_ROOT"
  RESULT_FILE="$TEST_ROOT/result.toml"
  PROJECT_DIR="$AGENTBOX_DIR"
  MACHINE="$AGENTBOX_MACHINE"
  [[ "$TEST_ROOT" = /* ]] || { CURRENT_DIAGNOSTIC="test root is not absolute"; return 1; }
  [ -d "$TEST_ROOT" ] || { CURRENT_DIAGNOSTIC="test root is not a directory"; return 1; }
  [ -f "$TEST_ROOT/.agentbox-task13-root" ] || {
    CURRENT_DIAGNOSTIC="test root marker is missing"
    return 1
  }
  resolved="$(realpath -e "$TEST_ROOT")" || return 1
  case "$resolved" in /|/tmp|/var|/home|"$HOME")
    CURRENT_DIAGNOSTIC="test root is too broad: $resolved"
    return 1
    ;;
  esac
  [ -r "$TEST_ROOT/.agentbox-task13-root" ] || return 1
  while IFS= read -r expected; do
    case "$(basename "$expected")" in
      home|xdg-config|state|cache|project|.agentbox-task13-root) ;;
      *)
        CURRENT_DIAGNOSTIC="test root is not fresh: unexpected entry $(basename "$expected")"
        return 1
        ;;
    esac
  done < <(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -print)
  mkdir -p "$TEST_ROOT/runtime"
  chmod 700 "$TEST_ROOT/runtime"
  XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
  export XDG_RUNTIME_DIR
  for expected in "$HOME" "${XDG_CONFIG_HOME:-}" "${XDG_STATE_HOME:-}" \
                  "${XDG_CACHE_HOME:-}" "$XDG_RUNTIME_DIR" "$PROJECT_DIR"; do
    [ -n "$expected" ] || { CURRENT_DIAGNOSTIC="required isolated path is unset"; return 1; }
    path_below_root "$expected" || {
      CURRENT_DIAGNOSTIC="path is outside test root: $expected"
      return 1
    }
  done
  context="$(realpath -e "$AGENTBOX_CONTEXT" 2>/dev/null || true)"
  [ "$context" = "$REPO_ROOT" ] || {
    CURRENT_DIAGNOSTIC="AGENTBOX_CONTEXT is not the checkout root"
    return 1
  }
  [ -d "$PROJECT_DIR" ] || { CURRENT_DIAGNOSTIC="isolated project is missing"; return 1; }
  mkdir -p "$TEST_ROOT/rows" "$TEST_ROOT/fixtures" "$TEST_ROOT/records"
}

compute_names() {
  local dir="$1" slug hash
  slug="$(printf '%s' "$dir" | tr -cs '[:alnum:]' '-' | sed 's/^-*//')"
  slug="${slug:0:80}"
  hash="$(printf '%s' "$dir" | sha256sum | cut -c1-16)"
  CNAME="agentbox-${slug}-${hash}"
  DVOL="agentbox-docker-${slug}-${hash}"
  JVOL="agentbox-jj-${slug}-${hash}"
}

run_ab() {
  local log_name rc
  log_name="${CURRENT_ROW}-$(date +%s%N).log"
  if LAST_OUTPUT="$(
    cd "$PROJECT_DIR"
    env "${AB_ENV[@]}" AGENTBOX_REPORT=1 AGENTBOX_CONTEXT="$REPO_ROOT" \
      AGENTBOX_DIR="$PROJECT_DIR" AGENTBOX_MACHINE="$MACHINE" \
      timeout 180 bash "$REPO_ROOT/bin/ab" "$@" 2>&1
  )"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$LAST_OUTPUT" >"$TEST_ROOT/rows/$log_name"
  return "$rc"
}

docker_mount_present() {
  local destination="$1"
  [ -n "$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{println .Destination}}{{end}}{{end}}" "$CNAME" 2>/dev/null || true)" ]
}

docker_mount_rw() {
  local destination="$1"
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.RW}}{{end}}{{end}}" \
    "$CNAME" 2>/dev/null || true
}

docker_label() {
  local label="$1"
  docker inspect -f "{{index .Config.Labels \"$label\"}}" "$CNAME" 2>/dev/null || true
}

volume_identity() {
  local volume="$1"
  docker volume inspect -f '{{.Name}}|{{.Mountpoint}}|{{.CreatedAt}}' "$volume" 2>/dev/null || true
}

volume_test_owner() {
  local volume="$1"
  docker volume inspect -f '{{index .Labels "org.agentbox.runtime_test_root"}}' \
    "$volume" 2>/dev/null || true
}

prepare_owned_volume() {
  local volume="$1" owner
  docker volume create --label "org.agentbox.runtime_test_root=$TEST_ROOT" "$volume" >/dev/null || {
    ROW_DIAGNOSTIC="could not reserve test volume: $volume"
    return 1
  }
  owner="$(docker volume inspect -f '{{index .Labels "org.agentbox.runtime_test_root"}}' \
    "$volume" 2>/dev/null || true)"
  [ "$owner" = "$TEST_ROOT" ] || {
    ROW_DIAGNOSTIC="test volume ownership label was not retained: $volume"
    return 1
  }
  VOLUME_CREATED_BY_RUN["$volume"]=1
  VOLUME_IDENTITIES["$volume"]="$(volume_identity "$volume")"
  CLEANUP_ELIGIBLE=1
  record_resource volume "$volume" "${VOLUME_IDENTITIES[$volume]}" true harness-reserved
}

refresh_identity() {
  local id volume_id network network_id volume owned networks
  id="$(docker inspect -f '{{.Id}}' "$CNAME" 2>/dev/null || true)"
  [ -n "$id" ] || return 1
  if [ "$id" != "$CONTAINER_ID" ]; then
    CONTAINER_ID="$id"
    RESOURCES_CREATED=1
    owned=false
    [ "$CONTAINER_CREATED_BY_RUN" -eq 1 ] && owned=true
    record_resource container "$CNAME" "$id" "$owned" observed
  fi
  IMAGE_REFERENCE="$(docker inspect -f '{{.Config.Image}}' "$CNAME" 2>/dev/null || true)"
  for volume in "$DVOL" "$JVOL"; do
    volume_id="$(volume_identity "$volume")"
    [ -n "$volume_id" ] || return 1
    if [ -n "${VOLUME_IDENTITIES[$volume]:-}" ] &&
       [ "${VOLUME_IDENTITIES[$volume]}" != "$volume_id" ]; then
      return 1
    fi
    VOLUME_IDENTITIES["$volume"]="$volume_id"
    owned=false
    [ "${VOLUME_CREATED_BY_RUN[$volume]:-0}" -eq 1 ] && owned=true
    record_resource volume "$volume" "$volume_id" "$owned" observed
  done
  networks="$(docker inspect -f '{{range $name, $network := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
    "$CNAME" 2>/dev/null)" || {
    ROW_DIAGNOSTIC="container network inventory could not be inspected"
    NETWORKS_ACCOUNTED=0
    return 1
  }
  NETWORKS_ACCOUNTED=0
  while IFS= read -r network; do
    [ -n "$network" ] || continue
    network_id="$(docker network inspect -f '{{.Id}}' "$network" 2>/dev/null)" || {
      ROW_DIAGNOSTIC="network inspection failed: $network"
      return 1
    }
    [ -n "$network_id" ] || {
      ROW_DIAGNOSTIC="network identity was empty: $network"
      return 1
    }
    if [ -n "${NETWORK_IDENTITIES[$network]:-}" ] &&
       [ "${NETWORK_IDENTITIES[$network]}" != "$network_id" ]; then
      ROW_DIAGNOSTIC="network identity changed: $network"
      return 1
    fi
    NETWORK_IDENTITIES["$network"]="$network_id"
    record_resource network "$network" "$network_id" false preserved
  done <<<"$networks"
  NETWORKS_ACCOUNTED=1
  NETWORK_INVENTORY_STATUS=recorded
}

assert_runtime_identity() {
  local volume volume_id
  assert_equal "outer container identity is stable" "$CONTAINER_ID" \
    "$(docker inspect -f '{{.Id}}' "$CNAME" 2>/dev/null || true)" || return 1
  for volume in "$DVOL" "$JVOL"; do
    volume_id="$(volume_identity "$volume")"
    assert_equal "volume identity is stable: $volume" "${VOLUME_IDENTITIES[$volume]:-}" \
      "$volume_id" || return 1
  done
}

isolated_state_fingerprint() {
  local root
  {
    for root in "$HOME" "${XDG_CONFIG_HOME:-}" "${XDG_STATE_HOME:-}" \
      "${XDG_CACHE_HOME:-}" "${XDG_RUNTIME_DIR:-}" "${AGENTBOX_DIR:-}"; do
      [ -n "$root" ] && [ -e "$root" ] || continue
      printf 'root=%s\n' "$root"
      # Lock mtimes change when a read-only command enters the project critical section. They
      # serialize access but are not logical report state, so exclude only this exact lock tree.
      find "$root" -xdev -path "$XDG_RUNTIME_DIR/agentbox/locks" -prune -o \
        -printf '%y:%P:%s:%T@:%m\n' 2>/dev/null | sort
      find "$root" -xdev -path "$XDG_RUNTIME_DIR/agentbox/locks" -prune -o \
        -type f -exec sha256sum {} + 2>/dev/null | sort
    done
  } | sha256sum | cut -d' ' -f1
}

assert_equal() {
  if [ "$2" != "$3" ]; then
    ROW_FAILURE=1
    ROW_DIAGNOSTIC="$1"
    return 1
  fi
}

assert_contains() {
  if [[ "$2" != *"$3"* ]]; then
    ROW_FAILURE=1
    ROW_DIAGNOSTIC="$1"
    return 1
  fi
}

assert_true() {
  if ! "$@"; then
    ROW_FAILURE=1
    ROW_DIAGNOSTIC="${ROW_DIAGNOSTIC:-assertion failed: $1}"
    return 1
  fi
}

assert_report() {
  assert_contains "${1:-report is missing result}" "${2:-$LAST_OUTPUT}" "result=" || return 1
  assert_contains "${1:-report is missing reason}" "${2:-$LAST_OUTPUT}" "reason=" || return 1
}

assert_report_fields() {
  local output="$1" field
  for field in result= reason= phase= container_name= operation_status= task_status= \
    agent_execution= mutation_allowed=; do
    assert_contains "report is missing $field" "$output" "$field" || return 1
  done
}

assert_complete_ready() {
  local output="$1"
  assert_contains "complete report missing success" "$output" "result=success" || return 1
  assert_contains "complete report missing operation reason" "$output" "reason=operation-complete" || return 1
  assert_contains "operation did not complete" "$output" "task_status=pass" || return 1
  assert_contains "operation status was not complete" "$output" "operation_status=complete" || return 1
  assert_contains "readiness was not ready" "$output" "readiness=ready" || return 1
}

policy_digest() {
  local git_enabled="$1" github="$2" ssh="$3"
  printf 'schema_version=1\ngit_enabled=%s\ngithub_grant=%s\nssh_grant_all=%s\n' \
    "$git_enabled" "$github" "$ssh" | sha256sum | cut -d' ' -f1
}

assert_policy() {
  local git_enabled="$1" github="$2" ssh="$3" digest
  digest="sha256:$(policy_digest "$git_enabled" "$github" "$ssh")"
  assert_equal "policy git label" "$git_enabled" "$(docker_label org.agentbox.policy.git_enabled)" || return 1
  assert_equal "policy GitHub label" "$github" "$(docker_label org.agentbox.policy.github_grant)" || return 1
  assert_equal "policy SSH label" "$ssh" "$(docker_label org.agentbox.policy.ssh_grant_all)" || return 1
  assert_equal "policy digest label" "$digest" "$(docker_label org.agentbox.policy.digest)" || return 1
  assert_equal "policy version label" 1 "$(docker_label org.agentbox.policy.version)" || return 1
}

assert_required_mounts() {
  assert_true docker_mount_present /workspace || return 1
  assert_equal "workspace source" "$PROJECT_DIR" \
    "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$CNAME")" || return 1
  assert_equal "workspace writable" true "$(docker_mount_rw /workspace)" || return 1
  assert_equal "inner Docker volume" "$DVOL" \
    "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}' "$CNAME")" || return 1
  assert_equal "jj volume" "$JVOL" \
    "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/agentbox/.config/jj"}}{{.Name}}{{end}}{{end}}' "$CNAME")" || return 1
  assert_equal "inner Docker writable" true "$(docker_mount_rw /var/lib/docker)" || return 1
  assert_equal "jj volume writable" true "$(docker_mount_rw /home/agentbox/.config/jj)" || return 1
}

mount_destination_match_count() {
  local destination="$1" destinations="$2" line count=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$destination" ]; then
      count=$((count + 1))
    fi
  done <<<"$destinations"
  printf '%s' "$count"
}

assert_duplicate_detector_fixture() {
  local matches=$'/workspace\n/workspace\n'
  assert_equal "duplicate detector counts two destinations" 2 \
    "$(mount_destination_match_count /workspace "$matches")" || return 1
  [ "$(mount_destination_match_count /workspace "$matches")" -gt 1 ] || {
    ROW_DIAGNOSTIC="duplicate detector accepted a synthetic duplicate"
    return 1
  }
}

assert_no_duplicate_protected_mounts() {
  local destination count destinations
  destinations="$(docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$CNAME")"
  for destination in /workspace /var/lib/docker /home/agentbox/.config/jj \
    /usr/bin/git /home/agentbox/.gitconfig /home/agentbox/.config/git/config \
    /home/agentbox/.config/gh /home/agentbox/.ssh /home/agentbox/.ssh/known_hosts; do
    count="$(mount_destination_match_count "$destination" "$destinations")"
    [ "$count" -le 1 ] || {
      ROW_FAILURE=1
      ROW_DIAGNOSTIC="duplicate protected mount at $destination"
      return 1
    }
  done
}

capture_creation_events() {
  local until container_events volume_events volume container_id event_id event_name current_volume
  local recorded_owner
  until="$(date +%s)"
  container_events="$(docker events --since "$MUTATION_STARTED_EPOCH" --until "$until" \
    --filter type=container --filter event=create \
    --format '{{.Actor.ID}}|{{.Actor.Attributes.name}}' 2>/dev/null || true)"
  container_id="$(docker inspect -f '{{.Id}}' "$CNAME" 2>/dev/null || true)"
  if [ -z "$OPERATION_ID" ] || [ -z "$OPERATION_NEW_CONTAINER_ID" ] ||
     [ -z "$container_id" ] || [ "$OPERATION_NEW_CONTAINER_ID" != "$container_id" ]; then
    ROW_DIAGNOSTIC="container creation was not tied to the completed operation"
    return 1
  fi
  while IFS='|' read -r event_id event_name; do
    if [ "$event_id" = "$container_id" ] && [ "$event_name" = "$CNAME" ]; then
      break
    fi
  done <<<"$container_events"
  if [ "$event_id" != "$container_id" ] || [ "$event_name" != "$CNAME" ]; then
    ROW_DIAGNOSTIC="container creation event did not match the exact operation identity"
    return 1
  fi
  CONTAINER_CREATED_BY_RUN=1
  CLEANUP_ELIGIBLE=1
  record_resource container "$CNAME" "" true creation-event
  volume_events="$(docker events --since "$MUTATION_STARTED_EPOCH" --until "$until" \
    --filter type=volume --filter event=create \
    --format '{{.Actor.ID}}|{{.Actor.Attributes.name}}' 2>/dev/null || true)"
  for volume in "$DVOL" "$JVOL"; do
    if [ "${VOLUME_CREATED_BY_RUN[$volume]:-0}" -eq 1 ]; then
      current_volume="$(volume_identity "$volume")"
      recorded_owner="$(volume_test_owner "$volume")"
      if [ "${current_volume%%|*}" = "$volume" ] && [ "$recorded_owner" = "$TEST_ROOT" ]; then
        continue
      fi
      ROW_DIAGNOSTIC="reserved volume identity or ownership changed: $volume"
      return 1
    fi
    event_id=""
    event_name=""
    while IFS='|' read -r event_id event_name; do
      if [ "$event_id" = "$volume" ]; then
        break
      fi
    done <<<"$volume_events"
    current_volume="$(volume_identity "$volume")"
    if [ "$event_id" = "$volume" ] && [ "${current_volume%%|*}" = "$volume" ]; then
      VOLUME_CREATED_BY_RUN["$volume"]=1
      VOLUME_IDENTITIES["$volume"]="$current_volume"
      record_resource volume "$volume" "" true creation-event
    else
      VOLUME_CREATED_BY_RUN["$volume"]=0
      ROW_DIAGNOSTIC="volume creation was not causally tied to operation: $volume"
      return 1
    fi
  done
}

fixture_setup() {
  local gh_dir="$HOME/.config/gh" ssh_dir="$HOME/.ssh"
  mkdir -p "$gh_dir" "$ssh_dir"
  chmod 700 "$gh_dir" "$ssh_dir"
  printf '%s\n' 'host: github.example.invalid' >"$gh_dir/hosts.yml"
  printf '%s\n' 'github.example.invalid ssh-ed25519 AAAA-task13-fixture' >"$ssh_dir/known_hosts"
  chmod 600 "$ssh_dir/known_hosts"
}

row_baseline() {
  local marker run_rc capture_rc
  AB_ENV=()
  MUTATION_STARTED_EPOCH="$(( $(date +%s) - 1 ))"
  RESOURCES_CREATED=1
  prepare_owned_volume "$DVOL" || return 1
  prepare_owned_volume "$JVOL" || return 1
  run_rc=0
  run_ab start || run_rc=$?
  OPERATION_ID="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^operation_id=//p' | sed -n '1p')"
  OPERATION_NEW_CONTAINER_ID="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^new_container_id=//p' | sed -n '1p')"
  capture_rc=0
  capture_creation_events || capture_rc=$?
  [ "$run_rc" -eq 0 ] || { ROW_DIAGNOSTIC="baseline start failed"; return 1; }
  [ "$capture_rc" -eq 0 ] || return 1
  assert_complete_ready "$LAST_OUTPUT" || return 1
  refresh_identity || { ROW_DIAGNOSTIC="created resources could not be inspected"; return 1; }
  assert_required_mounts || return 1
  assert_no_duplicate_protected_mounts || return 1
  assert_policy true false false || return 1
  assert_equal "workspace contains collocated .git" 0 \
    "$(docker exec --user agentbox "$CNAME" test -e /workspace/.git; echo $?)" || return 1
  assert_equal "container jj root" /workspace \
    "$(docker exec --user agentbox "$CNAME" jj root 2>/dev/null)" || return 1
  docker exec --user agentbox "$CNAME" sh -c \
    'printf task13-baseline > /workspace/.task13-baseline' >/dev/null || {
    ROW_DIAGNOSTIC="could not write baseline marker"
    return 1
  }
  docker exec --user agentbox "$CNAME" sh -c \
    'printf task13-jj-state > /home/agentbox/.config/jj/.task13-jj-state' >/dev/null || {
    ROW_DIAGNOSTIC="could not write jj volume marker"
    return 1
  }
  docker exec --user root "$CNAME" sh -c \
    'printf task13-docker-state > /var/lib/docker/.task13-docker-state' >/dev/null || {
    ROW_DIAGNOSTIC="could not write inner Docker volume marker"
    return 1
  }
  marker="$(docker exec --user agentbox "$CNAME" cat /workspace/.task13-baseline)"
  assert_equal "baseline marker" task13-baseline "$marker" || return 1
  docker stop "$CONTAINER_ID" >/dev/null || { ROW_DIAGNOSTIC="baseline stop failed"; return 1; }
  run_ab start || { ROW_DIAGNOSTIC="baseline restart failed"; return 1; }
  refresh_identity || return 1
  assert_equal "baseline marker survives restart" task13-baseline \
    "$(docker exec --user agentbox "$CNAME" cat /workspace/.task13-baseline)" || return 1
  assert_equal "jj marker survives restart" task13-jj-state \
    "$(docker exec --user agentbox "$CNAME" cat /home/agentbox/.config/jj/.task13-jj-state)" || return 1
  assert_equal "inner Docker marker survives restart" task13-docker-state \
    "$(docker exec --user root "$CNAME" cat /var/lib/docker/.task13-docker-state)" || return 1
}

row_no_git() {
  local first_line
  AB_ENV=(AGENTBOX_NO_GIT=1)
  run_ab start --apply || { ROW_DIAGNOSTIC="no-Git apply failed"; return 1; }
  refresh_identity || return 1
  assert_policy false false false || return 1
  if run_ab exec git --version; then
    ROW_DIAGNOSTIC="git unexpectedly succeeded with no-Git policy"
    return 1
  fi
  first_line="$(printf '%s\n' "$LAST_OUTPUT" | sed -n '1p')"
  assert_equal "exact Git blocker" 'agentbox: Git is disabled in this agentbox.' "$first_line" || return 1
  run_ab exec jj root || { ROW_DIAGNOSTIC="jj failed with no-Git policy"; return 1; }
  assert_equal "jj root remains workspace" /workspace \
    "$(printf '%s\n' "$LAST_OUTPUT" | sed -n '1p')" || return 1
  run_ab exec gh --version || { ROW_DIAGNOSTIC="gh --version failed with no-Git policy"; return 1; }
  AB_ENV=(AGENTBOX_NO_GIT=1)
  if run_ab exec env GH_TOKEN=invalid gh repo create --source /workspace --private --remote origin; then
    AB_ENV=(AGENTBOX_NO_GIT=1)
    ROW_DIAGNOSTIC="Git-dependent gh operation unexpectedly succeeded"
    return 1
  fi
  AB_ENV=(AGENTBOX_NO_GIT=1)
  assert_contains "Git-dependent gh did not use blocker" "$LAST_OUTPUT" \
    'agentbox: Git is disabled in this agentbox.' || return 1
  assert_equal "Git config mount absent" false "$(docker_mount_present /home/agentbox/.gitconfig && echo true || echo false)" || return 1
  assert_equal "Git config directory mount absent" false \
    "$(docker_mount_present /home/agentbox/.config/git/config && echo true || echo false)" || return 1
}

start_policy() {
  local github="$1" ssh="$2"
  AB_ENV=(AGENTBOX_NO_GIT=0 AGENTBOX_GRANT_GH=0 AGENTBOX_GRANT_ALL_OF_DOT_SSH=0)
  local -a options=(start --apply)
  [ "$github" = true ] && options+=(--grant-gh)
  [ "$ssh" = true ] && options+=(--grant-all-of-dot-ssh)
  run_ab "${options[@]}" || return 1
  refresh_identity || return 1
  assert_policy true "$([ "$github" = true ] && echo true || echo false)" \
    "$([ "$ssh" = true ] && echo true || echo false)" || return 1
  if [ "$github" = true ]; then
    assert_true docker_mount_present /home/agentbox/.config/gh || return 1
    assert_equal "GitHub config writable" true "$(docker_mount_rw /home/agentbox/.config/gh)" || return 1
  else
    assert_equal "GitHub config absent" false \
      "$(docker_mount_present /home/agentbox/.config/gh && echo true || echo false)" || return 1
  fi
  if [ "$ssh" = true ]; then
    assert_equal "SSH directory readonly" false "$(docker_mount_rw /home/agentbox/.ssh)" || return 1
    assert_equal "known_hosts writable" true "$(docker_mount_rw /home/agentbox/.ssh/known_hosts)" || return 1
  else
    assert_equal "SSH directory absent" false \
      "$(docker_mount_present /home/agentbox/.ssh && echo true || echo false)" || return 1
    assert_equal "known_hosts absent" false \
      "$(docker_mount_present /home/agentbox/.ssh/known_hosts && echo true || echo false)" || return 1
  fi
}

row_credentials() {
  local gh_dir="$HOME/.config/gh" saved_gh saved_known before_id
  fixture_setup
  start_policy false false || { ROW_DIAGNOSTIC="grant-off transition failed"; return 1; }
  start_policy true false || { ROW_DIAGNOSTIC="GitHub-only transition failed"; return 1; }
  start_policy false true || { ROW_DIAGNOSTIC="SSH-only transition failed"; return 1; }
  start_policy true true || { ROW_DIAGNOSTIC="both-grants transition failed"; return 1; }
  before_id="$CONTAINER_ID"
  saved_gh="$TEST_ROOT/fixtures/gh-directory"
  mv "$gh_dir" "$saved_gh"
  if run_ab start --apply --grant-gh; then
    mv "$saved_gh" "$gh_dir"
    ROW_DIAGNOSTIC="missing GitHub source was accepted"
    return 1
  fi
  mv "$saved_gh" "$gh_dir"
  mv "$gh_dir" "$saved_gh"
  ln -s "$saved_gh" "$gh_dir"
  if run_ab start --apply --grant-gh; then
    rm -f "$gh_dir"
    mv "$saved_gh" "$gh_dir"
    ROW_DIAGNOSTIC="symlinked GitHub source was accepted"
    return 1
  fi
  rm -f "$gh_dir"
  mv "$saved_gh" "$gh_dir"
  saved_known="$TEST_ROOT/fixtures/known-hosts"
  mv "$HOME/.ssh/known_hosts" "$saved_known"
  ln -s "$saved_known" "$HOME/.ssh/known_hosts"
  if run_ab start --apply --grant-all-of-dot-ssh; then
    rm -f "$HOME/.ssh/known_hosts"
    mv "$saved_known" "$HOME/.ssh/known_hosts"
    ROW_DIAGNOSTIC="symlinked known_hosts source was accepted"
    return 1
  fi
  rm -f "$HOME/.ssh/known_hosts"
  mv "$saved_known" "$HOME/.ssh/known_hosts"
  refresh_identity || return 1
  assert_equal "invalid grant leaves container unchanged" "$before_id" "$CONTAINER_ID" || return 1
}

row_policy_transitions() {
  local before_id before_image after_image
  AB_ENV=(AGENTBOX_NO_GIT=1 AGENTBOX_GRANT_GH=0 AGENTBOX_GRANT_ALL_OF_DOT_SSH=0)
  before_id="$CONTAINER_ID"
  if run_ab start; then
    ROW_DIAGNOSTIC="normal policy mismatch was accepted"
    return 1
  fi
  refresh_identity || return 1
  assert_equal "refused mismatch preserves container" "$before_id" "$CONTAINER_ID" || return 1
  before_image="$(docker inspect -f '{{.Config.Image}}' "$CNAME" 2>/dev/null || true)"
  run_ab start --apply || { ROW_DIAGNOSTIC="explicit no-Git apply failed"; return 1; }
  refresh_identity || return 1
  assert_policy false false false || return 1
  after_image="$IMAGE_REFERENCE"
  assert_equal "policy apply reuses image" "$before_image" "$after_image" || return 1
  [[ "$LAST_OUTPUT" != *"building "* ]] || {
    ROW_DIAGNOSTIC="policy-only start --apply unexpectedly built an image"
    return 1
  }
  docker stop "$CONTAINER_ID" >/dev/null || { ROW_DIAGNOSTIC="transition stop failed"; return 1; }
  before_id="$CONTAINER_ID"
  AB_ENV=(AGENTBOX_NO_GIT=0 AGENTBOX_GRANT_GH=0 AGENTBOX_GRANT_ALL_OF_DOT_SSH=0)
  run_ab start || { ROW_DIAGNOSTIC="stopped policy reconciliation failed"; return 1; }
  refresh_identity || return 1
  [ "$before_id" != "$CONTAINER_ID" ] || {
    ROW_DIAGNOSTIC="stopped policy reconciliation reused the old container"
    return 1
  }
  assert_policy true false false || return 1
  assert_equal "stopped reconciliation preserves inner Docker volume" "$DVOL" \
    "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}' "$CNAME")" || return 1
  assert_equal "stopped reconciliation preserves jj volume" "$JVOL" \
    "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/agentbox/.config/jj"}}{{.Name}}{{end}}{{end}}' "$CNAME")" || return 1
  run_ab rebuild || { ROW_DIAGNOSTIC="explicit rebuild failed"; return 1; }
  assert_contains "rebuild reports image build" "$LAST_OUTPUT" "building " || return 1
  refresh_identity || return 1
  assert_policy true false false || return 1
  assert_required_mounts || return 1
  assert_equal "rebuild preserves logical name" "$CNAME" \
    "$(docker inspect -f '{{.Name}}' "$CNAME" | sed 's#^/##')" || return 1
  assert_equal "rebuild preserves inner Docker volume" "$DVOL" \
    "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}' "$CNAME")" || return 1
  assert_equal "rebuild preserves jj volume" "$JVOL" \
    "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/agentbox/.config/jj"}}{{.Name}}{{end}}{{end}}' "$CNAME")" || return 1
  [ -n "$before_image" ] && [ -n "$IMAGE_REFERENCE" ] && [ -n "$after_image" ] || {
    ROW_DIAGNOSTIC="image identity was not recorded"
    return 1
  }
}

row_recovery_reports() {
  local marker before_id before_state
  marker="$(docker exec --user agentbox "$CNAME" cat /workspace/.task13-baseline)"
  docker stop "$CONTAINER_ID" >/dev/null || { ROW_DIAGNOSTIC="recovery stop failed"; return 1; }
  AB_ENV=(AGENTBOX_NO_UPDATE_CHECK=1)
  before_id="$CONTAINER_ID"
  before_state="$(isolated_state_fingerprint)"
  run_ab config || true
  assert_report "config report missing" "$LAST_OUTPUT" || return 1
  assert_report_fields "$LAST_OUTPUT" || return 1
  assert_runtime_identity || return 1
  assert_equal "config is read-only" "$before_state" "$(isolated_state_fingerprint)" || return 1
  run_ab status || true
  assert_report "status report missing" "$LAST_OUTPUT" || return 1
  assert_report_fields "$LAST_OUTPUT" || return 1
  assert_runtime_identity || return 1
  assert_equal "status is read-only" "$before_state" "$(isolated_state_fingerprint)" || return 1
  run_ab logs || true
  assert_report "logs report missing" "$LAST_OUTPUT" || return 1
  assert_report_fields "$LAST_OUTPUT" || return 1
  assert_runtime_identity || return 1
  assert_equal "logs is read-only" "$before_state" "$(isolated_state_fingerprint)" || return 1
  run_ab stop || true
  assert_report "stop report missing" "$LAST_OUTPUT" || return 1
  assert_report_fields "$LAST_OUTPUT" || return 1
  assert_runtime_identity || return 1
  assert_equal "stop is idempotent here" "$before_id" "$CONTAINER_ID" || return 1
  assert_equal "stop report path is read-only" "$before_state" "$(isolated_state_fingerprint)" || return 1
  run_ab start || { ROW_DIAGNOSTIC="explicit recovery start failed"; return 1; }
  refresh_identity || return 1
  assert_equal "recovery preserves workspace" "$marker" \
    "$(docker exec --user agentbox "$CNAME" cat /workspace/.task13-baseline)" || return 1
}

inner_process_identity() {
  local pid="$1"
  docker exec --user root "$CNAME" sh -c '
    pid="$1"
    expected_pid="$(cat /var/run/docker.pid 2>/dev/null || true)"
    [ "$pid" = "$expected_pid" ] || exit 1
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed "s/[[:space:]]//g")"
    start="$(ps -o lstart= -p "$pid" 2>/dev/null)"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    [ "$comm" = dockerd ] && [ "${exe##*/}" = dockerd ] && [ -n "$start" ] || exit 1
    printf "%s|%s|%s" "$pid" "$start" "$exe"
  ' sh "$pid"
}

terminate_recorded_inner_daemon() {
  local pid="$1" expected_start="$2"
  docker exec --user root "$CNAME" sh -c '
    pid="$1"
    expected_start="$2"
    expected_pid="$(cat /var/run/docker.pid 2>/dev/null || true)"
    [ "$pid" = "$expected_pid" ] || exit 1
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed "s/[[:space:]]//g")"
    start="$(ps -o lstart= -p "$pid" 2>/dev/null)"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    [ "$comm" = dockerd ] && [ "${exe##*/}" = dockerd ] &&
      [ "$start" = "$expected_start" ] || exit 1
    kill -TERM "$pid"
  ' sh "$pid" "$expected_start"
}

row_nested_readiness() {
  local inner_pid new_inner_pid inner_evidence new_inner_evidence inner_start new_inner_start
  local before_state
  inner_pid="$(docker exec --user root "$CNAME" cat /var/run/docker.pid 2>/dev/null || true)"
  [[ "$inner_pid" =~ ^[1-9][0-9]*$ ]] || { ROW_DIAGNOSTIC="inner Docker PID was not recorded"; return 1; }
  inner_evidence="$(inner_process_identity "$inner_pid" 2>/dev/null || true)"
  [ -n "$inner_evidence" ] || { ROW_DIAGNOSTIC="inner Docker PID is not dockerd"; return 1; }
  inner_start="${inner_evidence#*|}"
  inner_start="${inner_start%%|*}"
  terminate_recorded_inner_daemon "$inner_pid" "$inner_start" || {
    ROW_DIAGNOSTIC="recorded inner Docker PID could not be terminated"
    return 1
  }
  if docker exec --user agentbox "$CNAME" docker info >/dev/null 2>&1; then
    ROW_DIAGNOSTIC="inner Docker remained ready after exact daemon termination"
    return 1
  fi
  assert_equal "outer container remains running" true \
    "$(docker inspect -f '{{.State.Running}}' "$CNAME")" || return 1
  before_state="$(isolated_state_fingerprint)"
  run_ab status || true
  assert_report "nested status report missing" "$LAST_OUTPUT" || return 1
  assert_report_fields "$LAST_OUTPUT" || return 1
  assert_runtime_identity || return 1
  assert_equal "nested status is read-only" "$before_state" "$(isolated_state_fingerprint)" || return 1
  run_ab logs || true
  assert_report "nested logs report missing" "$LAST_OUTPUT" || return 1
  assert_report_fields "$LAST_OUTPUT" || return 1
  assert_runtime_identity || return 1
  assert_equal "nested logs is read-only" "$before_state" "$(isolated_state_fingerprint)" || return 1
  run_ab config || true
  assert_report "nested config report missing" "$LAST_OUTPUT" || return 1
  assert_report_fields "$LAST_OUTPUT" || return 1
  assert_runtime_identity || return 1
  assert_equal "nested config is read-only" "$before_state" "$(isolated_state_fingerprint)" || return 1
  docker stop "$CONTAINER_ID" >/dev/null || { ROW_DIAGNOSTIC="outer recovery stop failed"; return 1; }
  AB_ENV=()
  run_ab start --apply || { ROW_DIAGNOSTIC="outer recovery start failed"; return 1; }
  refresh_identity || return 1
  new_inner_pid="$(docker exec --user root "$CNAME" cat /var/run/docker.pid 2>/dev/null || true)"
  [[ "$new_inner_pid" =~ ^[1-9][0-9]*$ ]] || { ROW_DIAGNOSTIC="replacement inner PID was not recorded"; return 1; }
  new_inner_evidence="$(inner_process_identity "$new_inner_pid" 2>/dev/null || true)"
  [ -n "$new_inner_evidence" ] || { ROW_DIAGNOSTIC="replacement PID is not dockerd"; return 1; }
  new_inner_start="${new_inner_evidence#*|}"
  new_inner_start="${new_inner_start%%|*}"
  [ "$new_inner_start" != "$inner_start" ] || {
    ROW_DIAGNOSTIC="readiness recovery did not establish a new daemon identity"
    return 1
  }
  assert_equal "readiness bound is recorded" 30 \
    "$(docker exec --user agentbox "$CNAME" sed -n 's/^wait_bound_seconds=//p' /var/run/agentbox/nested-docker-state 2>/dev/null)" || return 1
  case "$(docker exec --user agentbox "$CNAME" sed -n 's/^replacement_attempted=//p' /var/run/agentbox/nested-docker-state 2>/dev/null)" in
    0|1) ;;
    *)
      ROW_DIAGNOSTIC="readiness replacement count exceeded one"
      return 1
      ;;
  esac
}

row_retry_cleanup() {
  local first_operation second_operation
  docker stop "$CONTAINER_ID" >/dev/null || { ROW_DIAGNOSTIC="retry stop failed"; return 1; }
  AB_ENV=()
  run_ab start --apply || { ROW_DIAGNOSTIC="first retry start failed"; return 1; }
  first_operation="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^operation_id=//p' | sed -n '1p')"
  [ -n "$first_operation" ] || { ROW_DIAGNOSTIC="first operation id missing"; return 1; }
  refresh_identity || return 1
  docker stop "$CONTAINER_ID" >/dev/null || { ROW_DIAGNOSTIC="second retry stop failed"; return 1; }
  run_ab start --apply || { ROW_DIAGNOSTIC="second retry start failed"; return 1; }
  second_operation="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^operation_id=//p' | sed -n '1p')"
  [ -n "$second_operation" ] || { ROW_DIAGNOSTIC="second operation id missing"; return 1; }
  assert_complete_ready "$LAST_OUTPUT" || return 1
  CLEANUP_ELIGIBLE=1
  [ "$first_operation" != "$second_operation" ] || {
    ROW_DIAGNOSTIC="retry operation ids were reused"
    return 1
  }
  refresh_identity || return 1
  [ -n "$IMAGE_REFERENCE" ] || { ROW_DIAGNOSTIC="retry image identity missing"; return 1; }
  [ -n "$(docker volume inspect "$DVOL" 2>/dev/null)" ] || {
    ROW_DIAGNOSTIC="inner Docker volume disappeared during retry"
    return 1
  }
  [ -n "$(docker volume inspect "$JVOL" 2>/dev/null)" ] || {
    ROW_DIAGNOSTIC="jj volume disappeared during retry"
    return 1
  }
}

run_row() {
  local id="$1" function_name="$2" rc
  CURRENT_ROW="$id"
  ROW_DIAGNOSTIC=""
  ROW_FAILURE=0
  (
    sleep 180
    kill -TERM "$PPID" 2>/dev/null || true
  ) &
  ROW_TIMER_PID=$!
  if "$function_name"; then
    rc=0
  else
    rc=$?
  fi
  kill "$ROW_TIMER_PID" 2>/dev/null || true
  wait "$ROW_TIMER_PID" 2>/dev/null || true
  ROW_TIMER_PID=""
  if [ "$rc" -eq 0 ] && [ "$ROW_FAILURE" -eq 0 ]; then
    CURRENT_DIAGNOSTIC=""
    record_row "$id" pass none
    return 0
  fi
  CURRENT_DIAGNOSTIC="${ROW_DIAGNOSTIC:-row assertion failed}"
  record_row "$id" fail "${ROW_DIAGNOSTIC:-row assertion failed}"
  return 1
}

mark_remaining_blocked() {
  local id
  for id in P13-02 P13-03 P13-04 P13-05 P13-06 P13-07 P13-08; do
    if [[ " ${ROW_IDS[*]} " != *" $id "* ]]; then
      record_row "$id" blocked "prerequisite row P13-01 was blocked"
    fi
  done
}

resource_confirm_absent() {
  local kind="$1" name="$2" output rc
  if [ "$kind" = container ]; then
    if output="$(docker inspect "$name" 2>&1)"; then
      CURRENT_DIAGNOSTIC="expected container already exists: $name"
      return 1
    else
      rc=$?
    fi
  else
    if output="$(docker volume inspect "$name" 2>&1)"; then
      CURRENT_DIAGNOSTIC="expected volume already exists: $name"
      return 1
    else
      rc=$?
    fi
  fi
  [ "$rc" -ne 0 ] || return 1
  case "$output" in
    *"No such object"*|*"no such object"*|*"No such volume"*|*"no such volume"*|*"not found"*) return 0 ;;
    *)
      CURRENT_DIAGNOSTIC="$kind preflight inspection failed for $name"
      return 2
      ;;
  esac
}

assert_expected_resources_absent() {
  local kind name rc
  compute_names "$PROJECT_DIR"
  for kind in container volume volume; do
    case "$kind" in
      container) name="$CNAME" ;;
      volume) [ "$name" = "$CNAME" ] && name="$DVOL" || name="$JVOL" ;;
    esac
    resource_confirm_absent "$kind" "$name" || {
      rc=$?
      [ "$rc" -eq 1 ] || CURRENT_DIAGNOSTIC="preflight inspection failed for $name"
      return 1
    }
    record_resource "$kind" "$name" "" false preflight-absent
  done
  PRECHECK_COMPLETE=1
}

cleanup_exact() {
  local actual_id actual_name volume_id expected_id
  CLEANUP_STATUS=pass
  if [ "$RESOURCES_CREATED" -eq 0 ]; then
    CLEANUP_DIAGNOSTIC="no owned runtime resources were created"
    return 0
  fi
  if [ "$CLEANUP_ELIGIBLE" -ne 1 ] || [ "$PRECHECK_COMPLETE" -ne 1 ]; then
    CLEANUP_STATUS=deferred
    CLEANUP_DIAGNOSTIC="cleanup deferred because exact ownership evidence is unavailable"
    return 0
  fi
  if [ "$CONTAINER_CREATED_BY_RUN" -eq 1 ] && [ -n "$CONTAINER_ID" ]; then
    actual_id="$(docker inspect -f '{{.Id}}' "$CNAME" 2>/dev/null || true)"
    actual_name="$(docker inspect -f '{{.Name}}' "$CNAME" 2>/dev/null || true)"
    if [ -z "$actual_id" ]; then
      resource_confirm_absent container "$CNAME" || {
        CLEANUP_STATUS=fail
        CLEANUP_DIAGNOSTIC="container inspection failed during cleanup"
      }
    elif [ "$actual_id" = "$CONTAINER_ID" ] && [ "$actual_name" = "/$CNAME" ]; then
      if docker rm -f "$CNAME" >/dev/null 2>&1; then
        record_resource container "$CNAME" "$CONTAINER_ID" true removed
      else
        CLEANUP_STATUS=fail
        CLEANUP_DIAGNOSTIC="exact container removal failed"
      fi
    else
      CLEANUP_STATUS=fail
      CLEANUP_DIAGNOSTIC="container identity changed; refused removal"
    fi
    if ! resource_confirm_absent container "$CNAME"; then
      CLEANUP_STATUS=fail
      CLEANUP_DIAGNOSTIC="owned container remains after cleanup"
    fi
  fi
  for volume in "$DVOL" "$JVOL"; do
    [ -n "$volume" ] || continue
    [ "${VOLUME_CREATED_BY_RUN[$volume]:-0}" -eq 1 ] || continue
    expected_id="${VOLUME_IDENTITIES[$volume]:-}"
    volume_id="$(volume_identity "$volume")"
    if [ -z "$volume_id" ]; then
      resource_confirm_absent volume "$volume" || {
        CLEANUP_STATUS=fail
        CLEANUP_DIAGNOSTIC="volume inspection failed during cleanup: $volume"
      }
      continue
    fi
    if [ -z "$expected_id" ] || [ "$volume_id" != "$expected_id" ]; then
      CLEANUP_STATUS=fail
      CLEANUP_DIAGNOSTIC="volume identity changed; refused removal: $volume"
      continue
    fi
    if docker volume rm "$volume" >/dev/null 2>&1; then
      record_resource volume "$volume" "$volume_id" true removed
    else
      CLEANUP_STATUS=fail
      CLEANUP_DIAGNOSTIC="exact volume removal failed: $volume"
    fi
    if ! resource_confirm_absent volume "$volume"; then
      CLEANUP_STATUS=fail
      CLEANUP_DIAGNOSTIC="owned volume remains after cleanup: $volume"
    fi
  done
}

verify_final_inventory() {
  local volume network network_id
  [ "$RESOURCES_CREATED" -eq 1 ] || return 0
  [ "$CLEANUP_ELIGIBLE" -eq 1 ] || return 0
  [ "$CLEANUP_STATUS" = pass ] || return 1
  if [ "$NETWORKS_ACCOUNTED" -eq 1 ]; then
    for network in "${!NETWORK_IDENTITIES[@]}"; do
      network_id="$(docker network inspect -f '{{.Id}}' "$network" 2>/dev/null)" || return 1
      [ "$network_id" = "${NETWORK_IDENTITIES[$network]}" ] || return 1
    done
  fi
  if [ "$CONTAINER_CREATED_BY_RUN" -eq 1 ]; then
    resource_confirm_absent container "$CNAME" || return 1
  fi
  for volume in "$DVOL" "$JVOL"; do
    if [ "${VOLUME_CREATED_BY_RUN[$volume]:-0}" -eq 1 ]; then
      resource_confirm_absent volume "$volume" || return 1
    fi
  done
  if [ "$NETWORKS_ACCOUNTED" -eq 1 ]; then
    NETWORK_INVENTORY_STATUS=verified
  fi
}

verify_result_record() {
  local row_count expected row_block result_status current_row current_diagnostic blocked_rows
  [ -s "$RESULT_FILE" ] || return 1
  grep -qx 'schema = 1' "$RESULT_FILE" || return 1
  grep -q '^status = "' "$RESULT_FILE" || return 1
  grep -q '^cleanup_status = "' "$RESULT_FILE" || return 1
  grep -q '^networks_accounted = \(true\|false\)$' "$RESULT_FILE" || return 1
  grep -q '^network_inventory = "' "$RESULT_FILE" || return 1
  row_count="$(grep -c '^\[\[rows\]\]$' "$RESULT_FILE" || true)"
  [ "$row_count" -eq 8 ] || return 1
  for expected in P13-01 P13-02 P13-03 P13-04 P13-05 P13-06 P13-07 P13-08; do
    [ "$(grep -c "^id = \"$expected\"$" "$RESULT_FILE" || true)" -eq 1 ] || return 1
  done
  result_status="$(sed -n 's/^status = "\([^"]*\)"$/\1/p' "$RESULT_FILE" | sed -n '1p')"
  for expected in P13-01 P13-02 P13-03 P13-04 P13-05 P13-06 P13-07 P13-08; do
    row_block="$(sed -n "/^id = \"$expected\"$/,/^diagnostic =/p" "$RESULT_FILE")"
    case "$result_status" in
      pass) printf '%s\n' "$row_block" | grep -qx 'status = "pass"' || return 1 ;;
      blocked) printf '%s\n' "$row_block" | grep -qx 'status = "blocked"' || return 1 ;;
      fail) : ;;
      *) return 1 ;;
    esac
  done
  if [ "$result_status" = fail ]; then
    current_row="$(sed -n 's/^current_row = "\([^"]*\)"$/\1/p' "$RESULT_FILE" | sed -n '1p')"
    current_diagnostic="$(sed -n 's/^current_diagnostic = "\([^"]*\)"$/\1/p' "$RESULT_FILE" | sed -n '1p')"
    if [ "$current_row" = setup ]; then
      [ -n "$current_diagnostic" ] || return 1
      blocked_rows="$(sed -n '/^id = /,/^diagnostic =/p' "$RESULT_FILE" | grep -c '^status = "blocked"$' || true)"
      [ "$blocked_rows" -eq 8 ] || return 1
    else
      grep -q '^status = "fail"$' "$RESULT_FILE" || return 1
      sed -n '/^id = /,/^diagnostic =/p' "$RESULT_FILE" | grep -q '^status = "fail"$' || return 1
    fi
  fi
  if [ "$CLEANUP_ELIGIBLE" -eq 1 ]; then
    grep -q '^cleanup_status = "pass"$' "$RESULT_FILE" || return 1
  fi
}

ensure_all_rows_recorded() {
  local expected
  for expected in P13-01 P13-02 P13-03 P13-04 P13-05 P13-06 P13-07 P13-08; do
    if ! printf '%s\n' "${ROW_IDS[@]}" | grep -Fxq "$expected"; then
      record_row "$expected" blocked "not run because $CURRENT_ROW failed"
    fi
  done
}

finish() {
  local rc="$1"
  [ "$FINALIZED" -eq 0 ] || return 0
  FINALIZED=1
  if [ "$rc" -eq 124 ] && [ "$CURRENT_ROW" != setup ]; then
    record_row "$CURRENT_ROW" fail "${CURRENT_DIAGNOSTIC:-timeout}"
  fi
  ensure_all_rows_recorded
  if [ -n "$WHOLE_TIMER_PID" ]; then
    kill "$WHOLE_TIMER_PID" 2>/dev/null || true
    wait "$WHOLE_TIMER_PID" 2>/dev/null || true
    WHOLE_TIMER_PID=""
  fi
  if [ "$rc" -eq 0 ] && [ "$CONTEXT_CHANGED" -eq 0 ]; then
    cleanup_exact
    [ "$CLEANUP_STATUS" = pass ] || OVERALL_STATUS=fail
  else
    cleanup_exact
  fi
  if ! verify_final_inventory; then
    OVERALL_STATUS=fail
    CLEANUP_STATUS=fail
    CLEANUP_DIAGNOSTIC="final owned-resource inventory verification failed"
  fi
  context_verify_unchanged || OVERALL_STATUS=fail
  if [ "$PREREQUISITES_BLOCKED" -eq 1 ]; then
    OVERALL_STATUS=blocked
  elif [ "$OVERALL_STATUS" != pass ] || [ "$CLEANUP_STATUS" != pass ]; then
    OVERALL_STATUS=fail
  fi
  write_result
  if ! verify_result_record; then
    OVERALL_STATUS=fail
    CLEANUP_STATUS=fail
    CLEANUP_DIAGNOSTIC="final result record verification failed"
    write_result
  fi
}

on_term() {
  CURRENT_DIAGNOSTIC="whole-run or row timeout"
  OVERALL_STATUS=fail
  exit 124
}

discover_sysbox_version() {
  local candidate runtime_entry docker_info version
  SYSBOX_VERSION=""
  SYSBOX_RUNTIME_PATH=""
  for candidate in "$(command -v sysbox-runc 2>/dev/null || true)" \
    /usr/bin/sysbox-runc /usr/local/bin/sysbox-runc /usr/local/sbin/sysbox-runc; do
    [ -x "$candidate" ] || continue
    version="$($candidate --version 2>/dev/null | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | sed -n '1p')"
    if [ -n "$version" ]; then
      SYSBOX_VERSION="$version"
      SYSBOX_RUNTIME_PATH="$candidate"
      return 0
    fi
  done
  runtime_entry="$(docker info --format '{{index .Runtimes "sysbox-runc"}}' 2>/dev/null || true)"
  while IFS= read -r candidate; do
    candidate="${candidate#\{\{}"
    candidate="${candidate%\}\}}"
    candidate="${candidate//\"/}"
    candidate="${candidate//[/}"
    candidate="${candidate//]/}"
    candidate="${candidate%% *}"
    case "$candidate" in
      */sysbox-runc|*/sysbox-runc-*)
        [ -x "$candidate" ] || continue
        version="$($candidate --version 2>/dev/null | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | sed -n '1p')"
        if [ -n "$version" ]; then
          SYSBOX_VERSION="$version"
          SYSBOX_RUNTIME_PATH="$candidate"
          return 0
        fi
        ;;
    esac
  done < <(printf '%s\n' "$runtime_entry" | tr '[],"' '\n')
  docker_info="$(docker info 2>/dev/null || true)"
  SYSBOX_VERSION="$(printf '%s\n' "$docker_info" \
    | sed -nE 's/.*[Ss]ysbox[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' \
    | sed -n '1p')"
}

main() {
  local rc
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  trap 'finish "$?"' EXIT
  trap on_term TERM INT
  (
    sleep 900
    kill -TERM "$PPID" 2>/dev/null || true
  ) &
  WHOLE_TIMER_PID=$!
  if ! validate_invocation; then
    OVERALL_STATUS=fail
    CURRENT_ROW=setup
    CURRENT_DIAGNOSTIC="${CURRENT_DIAGNOSTIC:-invalid invocation}"
    return 1
  fi
  if ! context_snapshot; then
    OVERALL_STATUS=fail
    CURRENT_ROW=setup
    CURRENT_DIAGNOSTIC="repository context could not be snapshotted"
    return 1
  fi
  if ! assert_duplicate_detector_fixture; then
    OVERALL_STATUS=fail
    CURRENT_ROW=setup
    CURRENT_DIAGNOSTIC="${ROW_DIAGNOSTIC:-duplicate detector self-test failed}"
    return 1
  fi
  CURRENT_ROW=P13-01
  if [ -z "$DOCKER_BIN" ] || ! command -v jj >/dev/null || ! command -v timeout >/dev/null; then
    PREREQUISITES_BLOCKED=1
    CURRENT_DIAGNOSTIC="external docker, jj, and timeout are required"
    record_row P13-01 blocked "external docker, jj, and timeout are required"
    mark_remaining_blocked
    return 3
  fi
  if ! docker info >/dev/null 2>&1; then
    PREREQUISITES_BLOCKED=1
    CURRENT_DIAGNOSTIC="plain docker info failed"
    DOCKER_INFO_STATUS=failed
    record_row P13-01 blocked "plain docker info failed"
    mark_remaining_blocked
    return 3
  fi
  DOCKER_INFO_STATUS=ok
  DOCKER_CLIENT_VERSION="$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)"
  DOCKER_SERVER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  DOCKER_RUNTIMES="$(docker info --format '{{json .Runtimes}}' 2>/dev/null || true)"
  discover_sysbox_version
  if [ -z "$DOCKER_CLIENT_VERSION" ] || [ -z "$DOCKER_SERVER_VERSION" ] ||
     [[ "$DOCKER_RUNTIMES" != *'sysbox-runc'* ]]; then
    PREREQUISITES_BLOCKED=1
    CURRENT_DIAGNOSTIC="Docker daemon or sysbox-runc runtime is unavailable"
    record_row P13-01 blocked "Docker daemon or sysbox-runc runtime is unavailable"
    mark_remaining_blocked
    return 3
  fi
  if ! docker run --rm --runtime=sysbox-runc hello-world >/dev/null 2>&1; then
    PREREQUISITES_BLOCKED=1
    NESTED_HELLO_WORLD=failed
    CURRENT_DIAGNOSTIC="sysbox-runc nested runtime smoke test failed"
    record_row P13-01 blocked "sysbox-runc nested runtime smoke test failed"
    mark_remaining_blocked
    return 3
  fi
  NESTED_HELLO_WORLD=pass
  if [ "$DOCKER_CLIENT_VERSION" != 29.7.2 ] || [ "$DOCKER_SERVER_VERSION" != 29.7.2 ] ||
     [[ "$SYSBOX_VERSION" != *0.7.0* ]]; then
    PREREQUISITES_BLOCKED=1
    CURRENT_DIAGNOSTIC="runtime versions are outside the validated Docker 29.7.2/Sysbox 0.7.0 baseline"
    record_row P13-01 blocked "runtime versions are outside the validated Docker 29.7.2/Sysbox 0.7.0 baseline"
    mark_remaining_blocked
    return 3
  fi
  record_row P13-01 pass none
  if ! jj git init --colocate "$PROJECT_DIR" >/dev/null 2>&1; then
    OVERALL_STATUS=fail
    record_row P13-02 fail "could not initialize isolated jj project"
    return 1
  fi
  compute_names "$PROJECT_DIR"
  if ! assert_expected_resources_absent; then
    OVERALL_STATUS=fail
    record_row P13-02 fail "$CURRENT_DIAGNOSTIC"
    return 1
  fi
  if ! run_row P13-02 row_baseline; then OVERALL_STATUS=fail; return 1; fi
  if ! run_row P13-03 row_no_git; then OVERALL_STATUS=fail; return 1; fi
  if ! run_row P13-04 row_credentials; then OVERALL_STATUS=fail; return 1; fi
  if ! run_row P13-05 row_policy_transitions; then OVERALL_STATUS=fail; return 1; fi
  if ! run_row P13-06 row_recovery_reports; then OVERALL_STATUS=fail; return 1; fi
  if ! run_row P13-07 row_nested_readiness; then OVERALL_STATUS=fail; return 1; fi
  if ! run_row P13-08 row_retry_cleanup; then OVERALL_STATUS=fail; return 1; fi
  context_verify_unchanged || { OVERALL_STATUS=fail; return 1; }
  OVERALL_STATUS=pass
  rc=0
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
