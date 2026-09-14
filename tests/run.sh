#!/usr/bin/env bash
# shellcheck disable=SC2119,SC2120,SC2218,SC2032,SC2100,SC2317,SC2329 # tests use intentional forwarding wrappers and indirect mocks
# SC2034 stays scoped to the sourced-mock seams below.
# Unit tests for agentbox host-side logic:
#   - bin/ab                :: compute_names, ab_config_candidates, ab_config_file,
#                              ab_config_container_path, ab_parse_mounts_line, ab_mount_dest_owner,
#                              ab_parse_network_line, ab_dockerfile_has_content, cmd_config_init
#   - agentbox-entrypoint.sh :: ab_parse_port_line, ab_port_bindable, ab_setup_fail, ab_step_fail
#   - tests/smoke.sh         :: ab_parse_env_line  (sourced for this one function; see below)
#
# Zero dependencies — plain bash. Run: bash tests/run.sh
#
# Both scripts are written to be source-safe: their executable bodies are guarded by a
# `[[ ${BASH_SOURCE[0]} == ${0} ]]` check, so sourcing them defines the functions WITHOUT
# running docker / dockerd / chown. This file sources them and pokes the pure functions.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1";
         [ -n "${2:-}" ] && printf '       expected: %s\n' "$2";
         [ -n "${3:-}" ] && printf '       actual:   %s\n' "$3";
         FAIL=$((FAIL+1)); }
# assert_eq <desc> <expected> <actual>
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "$2" "$3"; fi; }

# --- source the code under test, then relax errexit/nounset (all three scripts set them) ---
# shellcheck source=../bin/ab
# shellcheck disable=SC1091
source "$REPO/bin/ab"
# shellcheck source=../agentbox-entrypoint.sh
# shellcheck disable=SC1091
source "$REPO/agentbox-entrypoint.sh"
# shellcheck source=../tests/smoke.sh
# shellcheck disable=SC1091
source "$REPO/tests/smoke.sh"   # source-safe: its ab_parse_env_line() is unit-tested below
set +e +u

# The sourced launcher owns these globals; declare the cross-file test contract so ShellCheck
# can distinguish dynamically exchanged test state from genuinely missing variables.
declare slug nocache operation_readiness_handoff_state operation_state_readiness_daemon_evidence
declare operation_state_readiness_retryable operation_state_readiness_diagnostic
declare operation_state_named_volumes operation_state_old_container_id operation_state_container_id
declare operation_state_cleanup_allowed operation_state_retry_command operation_state_diagnostic
declare policy_retry_reconcile policy_git_source command_report_result command_report_exit_status
declare -a policy_snapshot_paths protected_mount_destinations
declare -A grant_source_snapshot policy_tier_git_enabled policy_tier_grant_all_of_dot_ssh
declare -A policy_tier_updates_check policy_resolved_source policy_resolved_labels
declare -A mount_spec_state mount_spec_source mount_spec_destination policy_input
# The report tests opt in explicitly; normal launcher use keeps reports disabled by default.
AGENTBOX_REPORT=1

# Expected hash for a project dir, computed the same way compute_names does (sha256[:16]).
hex16() { printf '%s' "$1" | sha256sum | cut -c1-16; }

echo "compute_names (bin/ab)"

# The sourced mount array is for the actual checkout, so capture its jj state volume before the
# name-focused cases below deliberately recompute names for other project paths.
_initial_jvol="$jvol"
assert_eq "jj state volume mount" "$_initial_jvol:/home/agentbox/.config/jj" \
  "$(ab_mount_dest_owner /home/agentbox/.config/jj)"

# Exact name for a real project. (This also pins the format against drift.)
compute_names "/home/alice/stay"
assert_eq "stay slug"  "home-alice-stay"                                "$slug"
assert_eq "stay cname" "agentbox-home-alice-stay-$(hex16 /home/alice/stay)" "$cname"
assert_eq "stay dvol"  "agentbox-docker-home-alice-stay-$(hex16 /home/alice/stay)" "$dvol"
assert_eq "stay jvol"  "agentbox-jj-home-alice-stay-$(hex16 /home/alice/stay)"     "$jvol"

# Determinism: same dir twice -> identical names.
compute_names "/workspace"; a="$cname"
compute_names "/workspace"; b="$cname"
assert_eq "deterministic" "$a" "$b"

# The hash disambiguates paths that collapse to the SAME slug: '/' and '-' both fold to '-',
# so /home/alice/stay and /home-alice-stay share a slug but MUST get distinct containers.
compute_names "/home/alice/stay";  sa="$slug"; ca="$cname"
compute_names "/home-alice-stay";  sb="$slug"; cb="$cname"
assert_eq "same slug collapses"  "$sa" "$sb"
assert_eq "but cname differs"    "different" "$([ "$ca" = "$cb" ] && echo same || echo different)"

# Slug is truncated to 80 chars; the full hash still disambiguates deep/truncated paths.
long="/mnt/$(printf 'a%.0s' {1..200})/proj"
compute_names "$long"
assert_eq "slug truncated to 80" "80" "${#slug}"

echo
echo "Task 3 canonical identity and mount safety (bin/ab)"
for _machine_case in A a1 a-1 a_1 a.1 "$(printf 'a%.0s' {1..64})"; do
  assert_eq "valid machine $_machine_case" "$_machine_case" "$(canonical_machine_name "$_machine_case")"
done
for _machine_case in '' a- a_ a. a/b 'a b' "$(printf 'a%.0s' {1..65})"; do
  assert_eq "invalid machine $_machine_case" "1" "$(canonical_machine_name "$_machine_case" >/dev/null 2>&1; echo $?)"
done
_identity_root="$(mktemp -d)"
mkdir -p "$_identity_root/real/space/é/proj"
ln -s "$_identity_root/real" "$_identity_root/link"
assert_eq "physical project path" "$_identity_root/real/space/é/proj" \
  "$(canonical_project_path "$_identity_root/link/space/./é/../é/proj")"
assert_eq "missing project rejected" "1" \
  "$(canonical_project_path "$_identity_root/missing" >/dev/null 2>&1; echo $?)"
assert_eq "mount repeated separators" "/home/agentbox/.ssh" \
  "$(canonical_mount_destination '//home///agentbox/./.ssh')"
assert_eq "mount dots and parent" "/home/agentbox/.ssh/known_hosts" \
  "$(canonical_mount_destination '/home/agentbox/.config/../.ssh/known_hosts')"
assert_eq "mount relative rejected" "1" \
  "$(canonical_mount_destination 'home/agentbox/.ssh' >/dev/null 2>&1; echo $?)"
assert_eq "mount root escape rejected" "1" \
  "$(canonical_mount_destination '/../etc' >/dev/null 2>&1; echo $?)"
assert_eq "similar protected path allowed" "" \
  "$(mount_destination_obscures_protected /home/agentbox/.ssh2 || true)"
assert_eq "protected parent conflict" "/home/agentbox/.gitconfig" \
  "$(mount_destination_obscures_protected /home/agentbox)"
assert_eq "workspace protected" "/workspace" \
  "$(mount_destination_obscures_protected /workspace)"
assert_eq "collocated git metadata protected" "/workspace/.git" \
  "$(mount_destination_obscures_protected /workspace/.git)"
assert_eq "workspace parent conflict" "/workspace" \
  "$(mount_destination_obscures_protected /)"
assert_eq "workspace nested path allowed" "" \
  "$(mount_destination_obscures_protected /workspace/project-file || true)"
assert_eq "jj state protected" "/home/agentbox/.config/jj" \
  "$(mount_destination_obscures_protected /home/agentbox/.config/jj)"
assert_eq "jj state nested path allowed" "" \
  "$(mount_destination_obscures_protected /home/agentbox/.config/jj/repo || true)"
assert_eq "jj legacy config protected" "/home/agentbox/.jjconfig.toml" \
  "$(mount_destination_obscures_protected /home/agentbox/.jjconfig.toml)"
assert_eq "jj host config protected" "/home/agentbox/.config/jj-host-config.toml" \
  "$(mount_destination_obscures_protected /home/agentbox/.config/jj-host-config.toml)"
assert_eq "jj host conf.d protected" "/home/agentbox/.config/jj-host-conf.d" \
  "$(mount_destination_obscures_protected /home/agentbox/.config/jj-host-conf.d)"
for _safe_mount_case in /workspace2 /workspace/project2 /home/agentbox/.config/jj2 \
                         /home/agentbox/.config/jj-host-config.toml.bak; do
  assert_eq "safe similar destination $_safe_mount_case" "" \
    "$(mount_destination_obscures_protected "$_safe_mount_case" || true)"
done
_protected_mount_file="$(mktemp)"
_saved_protected_mount_cfg="$cfg_mounts"
for _protected_mount_case in / /workspace /workspace/.git /home/agentbox/.config/jj \
                              /home/agentbox/.jjconfig.toml \
                              /home/agentbox/.config/jj-host-config.toml \
                              /home/agentbox/.config/jj-host-conf.d; do
  printf '%s\n' "/tmp/source $_protected_mount_case" >"$_protected_mount_file"
  cfg_mounts="$_protected_mount_file"
  assert_eq "validate protected destination $_protected_mount_case" 1 \
    "$(validate_custom_mounts >/dev/null 2>&1; echo $?)"
done
cfg_mounts="$_saved_protected_mount_cfg"
rm -f "$_protected_mount_file"
_lock_home="$(mktemp -d)"
_saved_project_for_lock="$PROJECT_DIR"; _saved_machine_for_lock="$MACHINE"; _saved_home_for_lock="$HOME"
_saved_runtime_for_lock="${XDG_RUNTIME_DIR-}"; _saved_cache_for_lock="${XDG_CACHE_HOME-}"
PROJECT_DIR="$_lock_home"; MACHINE=lockhost; HOME="$_lock_home/home"
XDG_RUNTIME_DIR="$_lock_home/runtime"; XDG_CACHE_HOME="$_lock_home/cache"
mkdir -p "$HOME"
compute_names "$PROJECT_DIR"
agentbox_lock_fd=""
policy_lock_acquire >/dev/null 2>&1; _lock_rc=$?
assert_eq "lock acquired" "0" "$_lock_rc"
assert_eq "lock result" acquired "$lock_result"
assert_eq "lock directory mode" 700 "$(stat -c '%a' "$(dirname "$lock_path")")"
assert_eq "lock file mode" 600 "$(stat -c '%a' "$lock_path")"
_lock_fd_before="$agentbox_lock_fd"; policy_lock_acquire >/dev/null 2>&1
assert_eq "reentrant lock reuses handle" "$_lock_fd_before" "$agentbox_lock_fd"
exec {agentbox_lock_fd}>&-; agentbox_lock_fd=""
_bad_runtime="$_lock_home/runtime-file"; _bad_cache="$_lock_home/cache-file"; _fallback_cache="$_lock_home/cache-fallback"
: >"$_bad_runtime"; : >"$_bad_cache"; mkdir -p "$_fallback_cache"
XDG_RUNTIME_DIR="$_bad_runtime"; XDG_CACHE_HOME="$_fallback_cache"
policy_lock_acquire >/dev/null 2>&1; _lock_rc=$?
assert_eq "lock cache fallback" 0 "$_lock_rc"
assert_eq "lock fallback path" "$_fallback_cache/agentbox/locks" "$(dirname "$lock_path")"
exec {agentbox_lock_fd}>&-; agentbox_lock_fd=""
XDG_RUNTIME_DIR="$_lock_home/runtime"; XDG_CACHE_HOME="$_lock_home/cache"
policy_lock_acquire >/dev/null 2>&1
exec {agentbox_lock_fd}>&-; agentbox_lock_fd=""; lock_timeout_seconds=0
flock() { return 1; }
policy_lock_acquire >/dev/null 2>&1; _lock_rc=$?
assert_eq "busy lock outcome" 1 "$_lock_rc"
assert_eq "busy lock result" busy "$lock_result"
unset -f flock
lock_timeout_seconds=30
_bad_home="$_lock_home/home-file"; : >"$_bad_home"; HOME="$_bad_home"
XDG_RUNTIME_DIR="$_bad_runtime"; XDG_CACHE_HOME="$_bad_cache"; agentbox_lock_fd=""
policy_lock_acquire >/dev/null 2>&1; _lock_rc=$?
assert_eq "lock failure outcome" 1 "$_lock_rc"
assert_eq "lock failure result" failed "$lock_result"
PROJECT_DIR="$_saved_project_for_lock"; MACHINE="$_saved_machine_for_lock"; HOME="$_saved_home_for_lock"
if [ -n "$_saved_runtime_for_lock" ]; then XDG_RUNTIME_DIR="$_saved_runtime_for_lock"; else unset XDG_RUNTIME_DIR; fi
if [ -n "$_saved_cache_for_lock" ]; then XDG_CACHE_HOME="$_saved_cache_for_lock"; else unset XDG_CACHE_HOME; fi
rm -rf "$_lock_home"

_source_home="$(mktemp -d)"
_saved_home_for_sources="$HOME"; HOME="$_source_home"
mkdir -p "$HOME/.config/gh" "$HOME/.ssh"
: >"$HOME/.ssh/known_hosts"; chmod 600 "$HOME/.ssh/known_hosts"
policy_grant_gh=1; policy_grant_all_of_dot_ssh=1
grant_sources_snapshot >/dev/null 2>&1; _grant_rc=$?
assert_eq "grant sources snapshot" 0 "$_grant_rc"
assert_eq "grant directory identity" directory "${grant_source_snapshot[gh]%%|*}"
mv "$HOME/.config/gh" "$HOME/.config/gh-old"; mkdir "$HOME/.config/gh"
grant_sources_recheck >/dev/null 2>&1; _grant_rc=$?
assert_eq "grant directory replacement detected" 1 "$_grant_rc"
rm "$HOME/.ssh/known_hosts"; ln -s "$HOME/.ssh/missing" "$HOME/.ssh/known_hosts"
grant_sources_snapshot >/dev/null 2>&1; _grant_rc=$?
assert_eq "known_hosts symlink rejected" 1 "$_grant_rc"
policy_grant_gh=0; policy_grant_all_of_dot_ssh=0
assert_eq "no-grants source recheck accepted" 0 "$(grant_sources_recheck >/dev/null 2>&1; echo $?)"
HOME="$_saved_home_for_sources"; rm -rf "$_source_home"

_snapshot_root="$(mktemp -d)"; mkdir -p "$_snapshot_root/machines" "$_snapshot_root/projects"
_saved_policy_root_for_snapshot="$AB_CFG_ROOT"; _saved_project_for_snapshot="$PROJECT_DIR"; _saved_machine_for_snapshot="$MACHINE"
AB_CFG_ROOT="$_snapshot_root"; PROJECT_DIR="$_snapshot_root"; MACHINE=snapshot
printf '%s\n' '[git]' 'enabled = true' >"$_snapshot_root/agentbox.toml"
unset AGENTBOX_NO_GIT AGENTBOX_GRANT_GH AGENTBOX_GRANT_ALL_OF_DOT_SSH AGENTBOX_NO_UPDATE_CHECK
policy_input_reset; policy_load_host >/dev/null 2>&1
assert_eq "four policy sources snapshotted" 4 "${#policy_snapshot_paths[@]}"
printf '%s\n' '[git]' 'enabled = false' >"$_snapshot_root/agentbox.toml"
assert_eq "policy replacement detected" 1 "$(policy_snapshot_recheck >/dev/null 2>&1; echo $?)"
rm -f "$_snapshot_root/agentbox.toml"
policy_input_reset; policy_load_host >/dev/null 2>&1
assert_eq "unchanged absent policy snapshot accepted" 0 "$(policy_snapshot_recheck >/dev/null 2>&1; echo $?)"
mkdir "$_snapshot_root/outside"; rm -rf "$_snapshot_root/machines"; ln -s "$_snapshot_root/outside" "$_snapshot_root/machines"
assert_eq "symlinked policy tier rejected" 1 "$(policy_load_host >/dev/null 2>&1; echo $?)"
_snapshot_symlink_target="$(mktemp -d)"; _snapshot_symlink_parent="$(mktemp -d)"
mkdir -p "$_snapshot_symlink_target/machines" "$_snapshot_symlink_target/projects" \
  "$_snapshot_symlink_target/project"
ln -s "$_snapshot_symlink_target" "$_snapshot_symlink_parent/agentbox"
AB_CFG_ROOT="$_snapshot_symlink_parent/agentbox"; PROJECT_DIR="$_snapshot_symlink_target/project"
policy_input_reset
assert_eq "symlinked policy root allows absent defaults" 0 "$(policy_load_host >/dev/null 2>&1; echo $?)"
_snapshot_symlink_retarget="$(mktemp -d)"
mkdir -p "$_snapshot_symlink_retarget/machines" "$_snapshot_symlink_retarget/projects"
rm -f "$_snapshot_symlink_parent/agentbox"
ln -s "$_snapshot_symlink_retarget" "$_snapshot_symlink_parent/agentbox"
assert_eq "retargeted policy root rejected" 1 \
  "$(policy_snapshot_recheck >/dev/null 2>&1; echo $?)"
rm -rf "$_snapshot_symlink_parent" "$_snapshot_symlink_target" "$_snapshot_symlink_retarget"
AB_CFG_ROOT="$_saved_policy_root_for_snapshot"; PROJECT_DIR="$_saved_project_for_snapshot"; MACHINE="$_saved_machine_for_snapshot"
rm -rf "$_snapshot_root"

_mount_test_file="$(mktemp)"; printf '%s\n' '/tmp/source /home/agentbox/.ssh' >"$_mount_test_file"
_saved_mount_list="$cfg_mounts"; cfg_mounts="$_mount_test_file"
_saved_policy_load_fn="$(declare -f policy_load_host)"; _saved_policy_inspect_fn="$(declare -f policy_inspect_recorded)"
_saved_lock_fn="$(declare -f policy_lock_acquire)"; _saved_exists_fn="$(declare -f exists)"; _saved_validate_blocker_fn="$(declare -f validate_git_blocker)"
policy_load_host() { policy_git_enabled=1; policy_grant_gh=0; policy_grant_all_of_dot_ssh=0; policy_git_source=default; policy_grant_gh_source=default; policy_grant_all_of_dot_ssh_source=default; return 0; }
policy_inspect_recorded() { policy_recorded_status=none; return 0; }
policy_lock_acquire() { lock_result=acquired; return 0; }
exists() { return 1; }
validate_git_blocker() { return 0; }
policy_operation_requested=1
assert_eq "custom protected mount rejected in preflight" 1 "$(policy_preflight start >/dev/null 2>&1; echo $?)"
policy_operation_requested=0
unset -f policy_load_host policy_inspect_recorded policy_lock_acquire exists validate_git_blocker
eval "$_saved_policy_load_fn"; eval "$_saved_policy_inspect_fn"; eval "$_saved_lock_fn"; eval "$_saved_exists_fn"; eval "$_saved_validate_blocker_fn"
cfg_mounts="$_saved_mount_list"; rm -f "$_mount_test_file"

_saved_snapshot_recheck_fn="$(declare -f policy_snapshot_recheck)"; _saved_grant_recheck_fn="$(declare -f grant_sources_recheck)"; _saved_grant_validate_fn="$(declare -f grant_sources_validate_snapshot)"; _saved_preflight_fn="$(declare -f policy_preflight)"
recheck_calls=0
policy_snapshot_recheck() { recheck_calls=$((recheck_calls + 1)); [ "$recheck_calls" -gt 1 ]; }
grant_sources_recheck() { return 0; }
grant_sources_validate_snapshot() { return 0; }
policy_preflight() {
  # A start retry must preserve the recorded grant, while rebuild semantics revoke omitted grants.
  if [ "$1" = start ]; then
    policy_grant_gh=1; policy_grant_gh_source=recorded
  else
    policy_grant_gh=0; policy_grant_gh_source=rebuild-default
  fi
  return 0
}
policy_grant_gh=0; policy_grant_all_of_dot_ssh=0
policy_resolution_recheck start >/dev/null 2>&1; _retry_rc=$?
assert_eq "policy retry succeeds after one change" 0 "$_retry_rc"
assert_eq "start retry preserves recorded grant" 1 "$policy_grant_gh"
recheck_calls=0
policy_snapshot_recheck() { recheck_calls=$((recheck_calls + 1)); return 1; }
policy_resolution_recheck start >/dev/null 2>&1; _retry_rc=$?
assert_eq "second policy change fails" 1 "$_retry_rc"
unset -f policy_snapshot_recheck grant_sources_recheck grant_sources_validate_snapshot policy_preflight
eval "$_saved_snapshot_recheck_fn"; eval "$_saved_grant_recheck_fn"; eval "$_saved_grant_validate_fn"; eval "$_saved_preflight_fn"

# The final build guard must sit immediately before Docker's mutating build call. This mocked
# boundary test makes a policy change refusal observable: image inspection may happen, but no
# `docker build` is allowed after the guard rejects the operation.
_saved_final_guard_fn="$(declare -f policy_final_mutation_guard)"
_saved_docker_fn="$(declare -f docker 2>/dev/null || true)"
_saved_cfg_dockerfile="$cfg_dockerfile"
policy_operation_requested=1
cfg_dockerfile=""
mock_docker_builds=0
build_guard_mode=""
policy_final_mutation_guard() { build_guard_mode="$1"; return 1; }
docker() {
  if [ "$1" = build ]; then mock_docker_builds=$((mock_docker_builds + 1)); fi
  [ "$1" != image ]
}
build_image force "" start >/dev/null 2>&1; _build_guard_rc=$?
assert_eq "build mutation guard stops docker build" 1 "$_build_guard_rc"
assert_eq "no docker build after guard refusal" 0 "$mock_docker_builds"
assert_eq "start mode reaches image build guard" start "$build_guard_mode"
cfg_dockerfile="$_saved_cfg_dockerfile"
unset -f policy_final_mutation_guard docker
eval "$_saved_final_guard_fn"
[ -n "$_saved_docker_fn" ] && eval "$_saved_docker_fn"
policy_operation_requested=0

# Exercise the real start call path as well as the helper: cmd_start must pass `start` through to
# build_image, otherwise a retry from the build boundary would still use rebuild grant semantics.
_saved_start_require_fn="$(declare -f require_sysbox 2>/dev/null || true)"
_saved_start_prepare_fn="$(declare -f prepare_host_state 2>/dev/null || true)"
_saved_start_policy_mounts_fn="$(declare -f add_policy_mounts 2>/dev/null || true)"
_saved_start_jj_fn="$(declare -f require_jj_state_mount 2>/dev/null || true)"
_saved_start_warn_fn="$(declare -f warn_legacy_files 2>/dev/null || true)"
_saved_start_running_fn="$(declare -f is_running 2>/dev/null || true)"
_saved_start_exists_fn="$(declare -f exists 2>/dev/null || true)"
_saved_start_build_fn="$(declare -f build_image 2>/dev/null || true)"
_saved_start_user_mounts_fn="$(declare -f build_user_mounts 2>/dev/null || true)"
_saved_start_wait_fn="$(declare -f wait_jj_state 2>/dev/null || true)"
_saved_start_connect_fn="$(declare -f connect_networks 2>/dev/null || true)"
_saved_start_docker_fn="$(declare -f docker 2>/dev/null || true)"
_saved_start_operation_requested="$policy_operation_requested"
_start_mode_file="$(mktemp)"
require_sysbox() { :; }
prepare_host_state() { :; }
add_policy_mounts() { :; }
require_jj_state_mount() { :; }
warn_legacy_files() { :; }
is_running() { return 1; }
exists() { return 1; }
build_image() { printf '%s' start >"$_start_mode_file"; printf '%s' agentbox:test-image; }
build_user_mounts() { :; }
wait_jj_state() { :; }
connect_networks() { :; }
docker() { :; }
policy_operation_requested=0; policy_needs_recreate=0
cmd_start >/dev/null 2>&1
assert_eq "cmd_start propagates start build mode" start "$(cat "$_start_mode_file")"
unset -f require_sysbox prepare_host_state add_policy_mounts require_jj_state_mount warn_legacy_files
unset -f is_running exists build_image build_user_mounts wait_jj_state connect_networks docker
eval "$_saved_start_require_fn"; eval "$_saved_start_prepare_fn"; eval "$_saved_start_policy_mounts_fn"
eval "$_saved_start_jj_fn"; eval "$_saved_start_warn_fn"; eval "$_saved_start_running_fn"
eval "$_saved_start_exists_fn"; eval "$_saved_start_build_fn"; eval "$_saved_start_user_mounts_fn"
eval "$_saved_start_wait_fn"; eval "$_saved_start_connect_fn"
[ -n "$_saved_start_docker_fn" ] && eval "$_saved_start_docker_fn"
policy_operation_requested="$_saved_start_operation_requested"
rm -f "$_start_mode_file"

# A mounts file replacement between preflight and final construction must stop before any custom
# mount is appended. In particular, a newly injected /usr/bin/git destination must not shadow the
# policy mount (or its absence) at the eventual docker run boundary.
_mount_race_file="$(mktemp)"; _mount_race_src="$(mktemp)"
_saved_mount_race_cfg="$cfg_mounts"; _saved_mount_race_mounts=("${mounts[@]}")
cfg_mounts="$_mount_race_file"; mounts=()
printf '%s\n' "$_mount_race_src /home/agentbox/safe" >"$_mount_race_file"
custom_mounts_snapshot_take >/dev/null 2>&1
printf '%s\n' "$_mount_race_src /usr/bin/git" >"$_mount_race_file"
build_user_mounts >/dev/null 2>&1; _mount_race_rc=$?
assert_eq "changed mounts file rejected before construction" 1 "$_mount_race_rc"
assert_eq "changed protected mount is not appended" "" "$(ab_mount_dest_owner /usr/bin/git)"
cfg_mounts="$_saved_mount_race_cfg"; mounts=("${_saved_mount_race_mounts[@]}")
custom_mounts_snapshot_reset
rm -f "$_mount_race_file" "$_mount_race_src"

# The final mount guard must reject a source change after mount construction instead of accepting
# a new snapshot that would leave the already-built mount array out of sync with policy.
_saved_final_mount_snapshot_fn="$(declare -f policy_snapshot_recheck)"
_saved_final_mount_validate_fn="$(declare -f grant_sources_validate_snapshot)"
_saved_final_mount_grant_fn="$(declare -f grant_sources_recheck)"
_saved_final_mount_operation_requested="$policy_operation_requested"
policy_snapshot_recheck() { return 0; }
grant_sources_validate_snapshot() { return 0; }
grant_sources_recheck() { return 0; }
policy_operation_requested=1
_mount_final_file="$(mktemp)"; _mount_final_src="$(mktemp)"
_saved_mount_final_cfg="$cfg_mounts"
cfg_mounts="$_mount_final_file"
printf '%s\n' "$_mount_final_src /home/agentbox/safe" >"$_mount_final_file"
custom_mounts_snapshot_take >/dev/null 2>&1
printf '%s\n' "$_mount_final_src /home/agentbox/also-safe" >"$_mount_final_file"
assert_eq "final mount guard rejects changed source" 1 "$(policy_final_mount_guard >/dev/null 2>&1; echo $?)"
cfg_mounts="$_saved_mount_final_cfg"
custom_mounts_snapshot_reset
rm -f "$_mount_final_file" "$_mount_final_src"
policy_operation_requested="$_saved_final_mount_operation_requested"
unset -f policy_snapshot_recheck grant_sources_validate_snapshot grant_sources_recheck
eval "$_saved_final_mount_snapshot_fn"; eval "$_saved_final_mount_validate_fn"; eval "$_saved_final_mount_grant_fn"
rm -rf "$_identity_root"

echo
echo "ab_config_candidates (bin/ab)"
# Four tiers, most specific first, with `machines/` and `projects/` reserved at the root so a
# machine named e.g. `home` can never be read as the first segment of /home/alice/myproj. Pure —
# no filesystem involved — so this pins the ORDER and the layout against drift.
_want="$(printf '%s\n' \
  /cfg/machines/myhost/projects/home/alice/myproj/env \
  /cfg/machines/myhost/env \
  /cfg/projects/home/alice/myproj/env \
  /cfg/env)"
assert_eq "four candidates, in order" "$_want" "$(ab_config_candidates /cfg myhost /home/alice/myproj env)"
assert_eq "exactly four"              "4"      "$(ab_config_candidates /cfg m /p x | wc -l)"
# The name is per-file: the same search runs separately for each of the four config files.
assert_eq "name is substituted"       "/cfg/machines/m/projects/p/setup.sh" \
                                      "$(ab_config_candidates /cfg m /p setup.sh | head -1)"
# Leading slash dropped exactly once (the project component is a relative path under projects/).
assert_eq "no double slash"           "0"      "$(ab_config_candidates /cfg m /home/alice env | grep -c '//')"

echo
echo "ab_config_file (bin/ab)"
# First match wins, tier by tier. Built up in a tmpdir from least to most specific: each new
# file must take over from the one below it.
_cfg="$(mktemp -d)"
_mk() { mkdir -p "$(dirname "$1")"; : >"$1"; }
_r()  { ab_config_file "$_cfg" myhost /home/alice/myproj "$1"; }

assert_eq "nothing -> empty"       ""                "$(_r env)"
_mk "$_cfg/env"
assert_eq "tier 4 (global)"        "$_cfg/env"       "$(_r env)"
_mk "$_cfg/projects/home/alice/myproj/env"
assert_eq "tier 3 beats 4"         "$_cfg/projects/home/alice/myproj/env" "$(_r env)"
_mk "$_cfg/machines/myhost/env"
assert_eq "tier 2 beats 3"         "$_cfg/machines/myhost/env"      "$(_r env)"
_mk "$_cfg/machines/myhost/projects/home/alice/myproj/env"
assert_eq "tier 1 beats 2"         "$_cfg/machines/myhost/projects/home/alice/myproj/env" "$(_r env)"

# Each of the four names resolves INDEPENDENTLY — a per-project `env` must not drag `ports`
# along with it (the whole point of the issue: separate resolution per file).
assert_eq "ports unaffected by env" ""               "$(_r ports)"
_mk "$_cfg/ports"
assert_eq "ports resolves alone"   "$_cfg/ports"     "$(_r ports)"

# Another machine's / another project's files are not ours.
_mk "$_cfg/machines/othermachine/mounts"
_mk "$_cfg/projects/home/alice/other/mounts"
assert_eq "other machine ignored"  ""                "$(_r mounts)"

# A DIRECTORY at a candidate path is not a match — the search must fall through to the next tier
# (mkdir -p of a deep candidate creates exactly this shape for the shallower ones).
mkdir -p "$_cfg/machines/myhost/setup.sh"
_mk "$_cfg/setup.sh"
assert_eq "directory is not a match" "$_cfg/setup.sh" "$(_r setup.sh)"
assert_eq "always returns 0"       "0"               "$(_r nosuchname >/dev/null; echo $?)"
# A user-side Dockerfile (child image, FROM agentbox:latest) resolves the same four-tier way,
# independently of the other names — same property the ports case above pins.
_mk "$_cfg/machines/myhost/projects/home/alice/myproj/Dockerfile"
assert_eq "Dockerfile resolves (tier 1)" "$_cfg/machines/myhost/projects/home/alice/myproj/Dockerfile" "$(_r Dockerfile)"
rm -rf "$_cfg"

echo
echo "agentbox.toml policy resolution (bin/ab)"
_policy_root="$(mktemp -d)"
mkdir -p "$_policy_root/machines/myhost" "$_policy_root/projects/home/alice/myproj" \
  "$_policy_root/machines/myhost/projects/home/alice/myproj"
printf '%s\n' '[git]' 'enabled = false' '[github]' 'grant = true' >"$_policy_root/agentbox.toml"
printf '%s\n' '[git]' 'enabled = true' >"$_policy_root/machines/myhost/agentbox.toml"
printf '%s\n' '[ssh]' 'grant_all = true' >"$_policy_root/projects/home/alice/myproj/agentbox.toml"
printf '%s\n' '[git]' 'enabled = false' >"$_policy_root/machines/myhost/projects/home/alice/myproj/agentbox.toml"
_saved_policy_root="$AB_CFG_ROOT"
_saved_machine="$MACHINE"
_saved_project="$PROJECT_DIR"
_saved_cli_git="$policy_cli_git_enabled"
_saved_cli_gh="$policy_cli_grant_gh"
_saved_cli_ssh="$policy_cli_grant_all_of_dot_ssh"
AB_CFG_ROOT="$_policy_root"
MACHINE=myhost
PROJECT_DIR=/home/alice/myproj
policy_cli_git_enabled=""
policy_cli_grant_gh=""
policy_cli_grant_all_of_dot_ssh=""
unset AGENTBOX_NO_GIT AGENTBOX_GRANT_GH AGENTBOX_GRANT_ALL_OF_DOT_SSH AGENTBOX_NO_UPDATE_CHECK
policy_input_reset
policy_load_host
assert_eq "policy field inheritance" "0" "$policy_git_enabled"
assert_eq "policy machine/project override" "1" "$policy_grant_gh"
assert_eq "policy project field" "1" "$policy_grant_all_of_dot_ssh"
assert_eq "global tier Git value" false "${policy_tier_git_enabled[global]}"
assert_eq "machine tier Git value" true "${policy_tier_git_enabled[machine]}"
assert_eq "project tier SSH value" true "${policy_tier_grant_all_of_dot_ssh[project]}"
assert_eq "machine/project tier Git value" false "${policy_tier_git_enabled[machine_project]}"
assert_eq "omitted tier field is unset" unset "${policy_tier_updates_check[machine]}"
assert_eq "resolved policy effective Git" false "${policy_resolved_effective[git_enabled]}"
assert_eq "resolved policy source tier" machine_project "${policy_resolved_source[git_enabled]}"
assert_eq "resolved policy label count" 5 "${#policy_resolved_labels[@]}"
assert_eq "resolved policy has all top-level sections" 1 "$(
  _record="$(policy_resolved_record)"
  for _section in effective global machine project machine_project label_values recorded_state; do
    printf '%s\n' "$_record" | grep -q "^${_section}\." || exit 1
  done
  echo 1
)"
_policy_expected_hash="$(printf 'schema_version=1\ngit_enabled=false\ngithub_grant=true\nssh_grant_all=true\n' | sha256sum | cut -d' ' -f1)"
assert_eq "canonical digest expected bytes" "sha256:$_policy_expected_hash" "${policy_resolved_effective[digest]}"
assert_eq "updates excluded from digest" "$(policy_digest_for 0 1 1)" "$(policy_digest_for 0 1 1)"
printf '%s\r\n' '[git]' 'enabled = true # CRLF' >"$_policy_root/agentbox.toml"
policy_load_host
assert_eq "CRLF policy accepted" true "${policy_tier_git_enabled[global]}"
printf '%s\n' '[git]' 'enabled = true' '[git]' 'enabled = false' >"$_policy_root/agentbox.toml"
_policy_parse_error="$(policy_load_host 2>&1 >/dev/null)"
assert_eq "duplicate error has exact line" 1 "$(printf '%s' "$_policy_parse_error" | grep -c "$_policy_root/agentbox.toml:4:")"
assert_eq "duplicate error has reason" 1 "$(printf '%s' "$_policy_parse_error" | grep -c 'duplicate key git.enabled')"
printf '%s\n' '[git]' 'enabled = true' >"$_policy_root/agentbox.toml"
AGENTBOX_NO_GIT=0
export AGENTBOX_NO_GIT
policy_input_reset
policy_load_host
assert_eq "explicit Git env re-enable" "1" "$policy_git_enabled"
AGENTBOX_NO_GIT=maybe
policy_input_reset
assert_eq "invalid policy env rejected" "1" "$(policy_load_host >/dev/null 2>&1; echo $?)"
unset AGENTBOX_NO_GIT
printf '%s\n' 'AGENTBOX_GRANT_GH=invalid' >"$_policy_root/env"
AGENTBOX_GRANT_GH=0
export AGENTBOX_GRANT_GH
policy_input_reset
policy_load_host >/dev/null 2>&1; _policy_env_rc=$?
assert_eq "container env file is not policy input" "0" "$_policy_env_rc"
assert_eq "host policy wins over container env file" "0" "$policy_grant_gh"
rm -f "$_policy_root/env"
unset AGENTBOX_GRANT_GH
printf '%s\n' '[unknown]' 'value = true' >"$_policy_root/agentbox.toml"
policy_input_reset
assert_eq "unknown policy table rejected" "1" "$(policy_load_host >/dev/null 2>&1; echo $?)"
assert_eq "canonical policy digest stable" "$(policy_digest_for 1 0 0)" "$(policy_digest_for 1 0 0)"
assert_eq "Git blocker mode" "755" "$(stat -c '%a' "$GIT_BLOCKER")"
assert_eq "Git blocker validates" "0" "$(validate_git_blocker >/dev/null 2>&1; echo $?)"
AB_CFG_ROOT="$_saved_policy_root"
MACHINE="$_saved_machine"
PROJECT_DIR="$_saved_project"
policy_cli_git_enabled="$_saved_cli_git"
policy_cli_grant_gh="$_saved_cli_gh"
policy_cli_grant_all_of_dot_ssh="$_saved_cli_ssh"
rm -rf "$_policy_root"

echo
echo "recorded policy inspection and lifecycle preflight (bin/ab)"
# Inspect legacy state without Docker by replacing only the read-only inspect helpers. In
# particular, a /usr/bin/git mount from an unknown source is ambiguous and must not be silently
# migrated as Git-enabled. Old grant labels are authoritative; mounts contradicting them are
# invalid rather than an implicit credential grant.
_saved_exists_fn="$(declare -f exists 2>/dev/null || true)"
_saved_running_fn="$(declare -f is_running 2>/dev/null || true)"
_saved_policy_label_fn="$(declare -f policy_snapshot_label 2>/dev/null || true)"
_saved_namespace_labels_fn="$(declare -f policy_snapshot_namespace_labels 2>/dev/null || true)"
_saved_mount_dest_fn="$(declare -f policy_snapshot_has_mount_destination 2>/dev/null || true)"
_saved_git_source_fn="$(declare -f policy_snapshot_git_mount_source 2>/dev/null || true)"
_saved_container_snapshot_fn="$(declare -f policy_container_snapshot 2>/dev/null || true)"
mock_version=""; mock_git=""; mock_gh=""; mock_ssh=""; mock_digest=""
mock_git_mount=0; mock_git_source=""; mock_gitconfig_mount=0; mock_xdg_gitconfig_mount=0
mock_gh_mount=0; mock_ssh_mount=0; mock_known_hosts_mount=0
mock_container_exists=1; mock_container_running=1; mock_snapshot_calls=0
exists() { return 0; }
is_running() { return 0; }
policy_container_snapshot() {
  mock_snapshot_calls=$((mock_snapshot_calls + 1))
  policy_container_snapshot_reset
  [ "$mock_container_exists" = 1 ] || return 1
  if [ "$mock_container_running" = 1 ]; then policy_container_snapshot_lifecycle=running; else policy_container_snapshot_lifecycle=stopped; fi
  [ -n "$mock_version" ] && policy_container_snapshot_labels["org.agentbox.policy.version"]="$mock_version"
  [ -n "$mock_git" ] && policy_container_snapshot_labels["org.agentbox.policy.git_enabled"]="$mock_git"
  [ -n "$mock_gh" ] && policy_container_snapshot_labels["org.agentbox.policy.github_grant"]="$mock_gh"
  [ -n "$mock_ssh" ] && policy_container_snapshot_labels["org.agentbox.policy.ssh_grant_all"]="$mock_ssh"
  [ -n "$mock_digest" ] && policy_container_snapshot_labels["org.agentbox.policy.digest"]="$mock_digest"
  [ -n "${mock_old_gh-}" ] && policy_container_snapshot_labels["agentbox.grant-gh"]="$mock_old_gh"
  [ -n "${mock_old_ssh-}" ] && policy_container_snapshot_labels["agentbox.grant-all-of-dot-ssh"]="$mock_old_ssh"
  [ "$mock_git_mount" = 1 ] && policy_container_snapshot_mount_sources[/usr/bin/git]="$mock_git_source"
  [ "$mock_gitconfig_mount" = 1 ] && policy_container_snapshot_mount_sources[/home/agentbox/.gitconfig]=legacy
  [ "$mock_xdg_gitconfig_mount" = 1 ] && policy_container_snapshot_mount_sources[/home/agentbox/.config/git/config]=legacy
  [ "$mock_gh_mount" = 1 ] && policy_container_snapshot_mount_sources[/home/agentbox/.config/gh]=legacy
  [ "$mock_ssh_mount" = 1 ] && policy_container_snapshot_mount_sources[/home/agentbox/.ssh]=legacy
  [ "$mock_known_hosts_mount" = 1 ] && policy_container_snapshot_mount_sources[/home/agentbox/.ssh/known_hosts]=legacy
  policy_container_snapshot_ready=1
}
policy_snapshot_namespace_labels() { :; }
policy_snapshot_label() {
  case "$1" in
    org.agentbox.policy.version) printf '%s' "$mock_version" ;;
    org.agentbox.policy.git_enabled) printf '%s' "$mock_git" ;;
    org.agentbox.policy.github_grant) printf '%s' "$mock_gh" ;;
    org.agentbox.policy.ssh_grant_all) printf '%s' "$mock_ssh" ;;
    org.agentbox.policy.digest) printf '%s' "$mock_digest" ;;
    agentbox.grant-gh) printf '%s' "${mock_old_gh-}" ;;
    agentbox.grant-all-of-dot-ssh) printf '%s' "${mock_old_ssh-}" ;;
  esac
}
policy_snapshot_has_mount_destination() {
  case "$1" in
    /usr/bin/git) [ "$mock_git_mount" = 1 ] ;;
    /home/agentbox/.gitconfig) [ "$mock_gitconfig_mount" = 1 ] ;;
    /home/agentbox/.config/git/config) [ "$mock_xdg_gitconfig_mount" = 1 ] ;;
    /home/agentbox/.config/gh) [ "$mock_gh_mount" = 1 ] ;;
    /home/agentbox/.ssh) [ "$mock_ssh_mount" = 1 ] ;;
    /home/agentbox/.ssh/known_hosts) [ "$mock_known_hosts_mount" = 1 ] ;;
    *) return 1 ;;
  esac
}
policy_snapshot_git_mount_source() { printf '%s' "$mock_git_source"; }
mock_old_gh=""; mock_old_ssh=""
policy_inspect_recorded
assert_eq "plain legacy defaults Git on" "legacy" "$policy_recorded_status"
assert_eq "legacy classification" "legacy" "$policy_recorded_classification"
assert_eq "existing container lifecycle" "running" "$policy_recorded_lifecycle_state"
assert_eq "plain legacy records Git enabled" "1" "$policy_recorded_git_enabled"
assert_eq "absent old GH label means false" "0" "$policy_recorded_grant_gh"
mock_git_mount=1; mock_git_source="$GIT_BLOCKER"
policy_inspect_recorded
assert_eq "recognized blocker migrates Git off" "0" "$policy_recorded_git_enabled"
assert_eq "recognized blocker is legacy" "legacy" "$policy_recorded_status"
mock_git_source=/tmp/unrelated-git
policy_inspect_recorded
assert_eq "unknown blocker is invalid" "invalid" "$policy_recorded_status"
assert_eq "unknown blocker explains state" "1" "$(printf '%s' "$policy_recorded_detail" | grep -c 'unrecognized')"
mock_git_mount=0; mock_git_source=""; mock_gh_mount=1
policy_inspect_recorded
assert_eq "unlabelled GH mount is not inferred" "0" "$policy_recorded_grant_gh"
assert_eq "unlabelled GH mount is invalid" "invalid" "$policy_recorded_status"
mock_gh_mount=0
policy_inspect_recorded
assert_eq "repeated plain legacy inspection resets detail" "legacy" "$policy_recorded_status"
assert_eq "repeated plain legacy detail is current" "1" "$(printf '%s' "$policy_recorded_detail" | grep -c 'no versioned policy labels')"
mock_gh_mount=0; mock_old_gh=0; mock_gh_mount=1
policy_inspect_recorded
assert_eq "zero GH label with mount is invalid" "invalid" "$policy_recorded_status"
mock_old_gh=1; mock_gh_mount=0
policy_inspect_recorded
assert_eq "one GH label without mount is invalid" "invalid" "$policy_recorded_status"
mock_old_gh=bad; mock_gh_mount=0
policy_inspect_recorded
assert_eq "malformed old GH label is invalid" "invalid" "$policy_recorded_status"
mock_container_exists=0
policy_inspect_recorded
assert_eq "absent container classification" "absent" "$policy_recorded_classification"
assert_eq "absent container lifecycle" "absent" "$policy_recorded_lifecycle_state"
mock_container_exists=1
mock_old_gh=""; mock_old_ssh=""; mock_git_mount=0; mock_git_source=""
mock_container_running=0
is_running() { return 1; }
mock_version=1; mock_git=true; mock_gh=false; mock_ssh=false
mock_digest="sha256:$(policy_digest_for 1 0 0)"
policy_inspect_recorded
assert_eq "complete labels are valid" "valid" "$policy_recorded_classification"
assert_eq "stopped container lifecycle" "stopped" "$policy_recorded_lifecycle_state"
assert_eq "complete labels mount state inspected" "matching" "$policy_recorded_mount_consistency"
mock_git_mount=1; mock_git_source=/tmp/unrelated-git
policy_inspect_recorded
assert_eq "versioned labels with contradictory Git mount are stale" "stale" "$policy_recorded_classification"
assert_eq "versioned mount contradiction is explained" 1 \
  "$(printf '%s' "$policy_recorded_detail" | grep -c 'Git-enabled label contradicts')"
mock_git_mount=0; mock_git_source=""; mock_gh_mount=1
policy_inspect_recorded
assert_eq "versioned false GitHub grant with mount is stale" "stale" "$policy_recorded_classification"
assert_eq "versioned GitHub contradiction is explained" 1 \
  "$(printf '%s' "$policy_recorded_detail" | grep -c 'GitHub-grant label is false')"
mock_gh_mount=0; mock_ssh_mount=0; mock_known_hosts_mount=1
policy_inspect_recorded
assert_eq "versioned false SSH grant with known_hosts is stale" "stale" "$policy_recorded_classification"
assert_eq "versioned SSH contradiction is explained" 1 \
  "$(printf '%s' "$policy_recorded_detail" | grep -c 'SSH-grant label is false')"
mock_known_hosts_mount=0
mock_version=1; mock_git=false; mock_gh=false; mock_ssh=false
mock_digest="sha256:$(policy_digest_for 0 0 0)"; mock_git_mount=1; mock_git_source="$GIT_BLOCKER"; mock_gitconfig_mount=1
policy_inspect_recorded
assert_eq "versioned no-Git config mount is stale" "stale" "$policy_recorded_classification"
assert_eq "versioned no-Git config contradiction is explained" 1 \
  "$(printf '%s' "$policy_recorded_detail" | grep -c 'Git-disabled label contradicts')"
mock_git=false; mock_digest="sha256:$(policy_digest_for 0 0 0)"; mock_gitconfig_mount=0
policy_inspect_recorded
assert_eq "versioned no-Git matching mounts are valid" "valid" "$policy_recorded_classification"

# The production seam must not combine observations from separate Docker calls. Simulate a
# replacement immediately after the first snapshot: the replacement adds a contradictory Git
# mount, but classification must still use the captured state and must make exactly one snapshot.
mock_version=1; mock_git=true; mock_gh=false; mock_ssh=false
mock_digest="sha256:$(policy_digest_for 1 0 0)"; mock_git_mount=0; mock_git_source=""
mock_snapshot_calls=0
policy_container_snapshot() {
  policy_container_snapshot_fixture
  if [ "$mock_snapshot_calls" = 1 ]; then
    mock_git_mount=1
    mock_git_source=/tmp/replacement-git
  fi
}
# Human-authorized exception: this mock exports snapshot globals to sourced bin/ab code.
# shellcheck disable=SC2034
policy_container_snapshot_fixture() {
  mock_snapshot_calls=$((mock_snapshot_calls + 1))
  policy_container_snapshot_reset
  [ "$mock_container_exists" = 1 ] || return 1
  if [ "$mock_container_running" = 1 ]; then policy_container_snapshot_lifecycle=running; else policy_container_snapshot_lifecycle=stopped; fi
  [ -n "$mock_version" ] && policy_container_snapshot_labels["org.agentbox.policy.version"]="$mock_version"
  [ -n "$mock_git" ] && policy_container_snapshot_labels["org.agentbox.policy.git_enabled"]="$mock_git"
  [ -n "$mock_gh" ] && policy_container_snapshot_labels["org.agentbox.policy.github_grant"]="$mock_gh"
  [ -n "$mock_ssh" ] && policy_container_snapshot_labels["org.agentbox.policy.ssh_grant_all"]="$mock_ssh"
  [ -n "$mock_digest" ] && policy_container_snapshot_labels["org.agentbox.policy.digest"]="$mock_digest"
  [ "$mock_git_mount" = 1 ] && policy_container_snapshot_mount_sources[/usr/bin/git]="$mock_git_source"
  policy_container_snapshot_ready=1
}
unset -f policy_snapshot_label policy_snapshot_namespace_labels policy_snapshot_has_mount_destination policy_snapshot_git_mount_source
eval "$_saved_policy_label_fn"
eval "$_saved_namespace_labels_fn"
eval "$_saved_mount_dest_fn"
eval "$_saved_git_source_fn"
policy_inspect_recorded
assert_eq "replacement after snapshot does not mix state" "valid" "$policy_recorded_classification"
assert_eq "recorded inspection uses one Docker snapshot" 1 "$mock_snapshot_calls"
policy_container_snapshot() { policy_container_snapshot_fixture; }
mock_git=true; mock_digest="sha256:$(policy_digest_for 1 0 0)"; mock_git_mount=0; mock_git_source=""
policy_snapshot_namespace_labels() {
  printf '%s\n' \
    'org.agentbox.policy.version = 1' \
    'org.agentbox.policy.git_enabled = true' \
    'org.agentbox.policy.github_grant = false' \
    'org.agentbox.policy.ssh_grant_all = false' \
    'org.agentbox.policy.digest = placeholder'
}
policy_inspect_recorded
assert_eq "known enumerated labels remain valid" "valid" "$policy_recorded_classification"
mock_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
policy_inspect_recorded
assert_eq "digest mismatch is stale" "stale" "$policy_recorded_classification"
mock_version=2; mock_digest=""; mock_git=""; mock_gh=""; mock_ssh=""
policy_inspect_recorded
assert_eq "higher version is unsupported" "unsupported-version" "$policy_recorded_classification"
mock_version=1; mock_git=true; mock_gh=""; mock_ssh=false; mock_digest=""
policy_inspect_recorded
assert_eq "partial labels are invalid" "invalid" "$policy_recorded_classification"
mock_gh=false; mock_digest="sha256:$(policy_digest_for 1 0 0)"
policy_inspect_recorded contradictory
assert_eq "supplied contradictory mounts are stale" "stale" "$policy_recorded_classification"
assert_eq "supplied mount state is retained" "contradictory" "$policy_recorded_mount_consistency"
mock_version=""; mock_git=""; mock_gh=""; mock_ssh=""; mock_digest=""
policy_inspect_recorded contradictory
assert_eq "legacy contradictory mounts are invalid" "invalid" "$policy_recorded_classification"
assert_eq "legacy contradiction is not migratable" "invalid" "$policy_recorded_status"
assert_eq "legacy contradiction is explained" 1 "$(printf '%s' "$policy_recorded_detail" | grep -c 'mount consistency is contradictory')"
policy_snapshot_namespace_labels() { printf '%s\n' 'org.agentbox.policy.extra=value'; }
policy_inspect_recorded
assert_eq "extra policy label is invalid" "invalid" "$policy_recorded_classification"
assert_eq "extra policy label is explained" 1 "$(printf '%s' "$policy_recorded_detail" | grep -c 'unsupported recorded policy label')"
unset -f exists policy_snapshot_label policy_snapshot_has_mount_destination policy_snapshot_git_mount_source policy_container_snapshot
eval "$_saved_exists_fn"
eval "$_saved_running_fn"
eval "$_saved_policy_label_fn"
eval "$_saved_namespace_labels_fn"
eval "$_saved_mount_dest_fn"
eval "$_saved_git_source_fn"
eval "$_saved_container_snapshot_fn"

# The state matrix exercises the lifecycle gate without requiring a Docker daemon: mismatches on
# running containers refuse normally, explicit apply permits them, and stopped containers are
# marked for same-name recreation. This is the host-side equivalent of the Docker-mocked flow.
_saved_load_host_fn="$(declare -f policy_load_host 2>/dev/null || true)"
_saved_inspect_fn="$(declare -f policy_inspect_recorded 2>/dev/null || true)"
_saved_exists_fn="$(declare -f exists 2>/dev/null || true)"
_saved_running_fn="$(declare -f is_running 2>/dev/null || true)"
_saved_blocker_fn="$(declare -f validate_git_blocker 2>/dev/null || true)"
mock_running=1
policy_load_host() {
  policy_git_enabled=1; policy_grant_gh=0; policy_grant_all_of_dot_ssh=0
  policy_git_source=default; policy_grant_gh_source=default
  policy_grant_all_of_dot_ssh_source=default; policy_updates_check=1; policy_updates_source=default
  return 0
}
policy_inspect_recorded() {
  policy_recorded_status=valid; policy_recorded_git_enabled=0; policy_recorded_grant_gh=1
  policy_recorded_grant_all_of_dot_ssh=0; policy_recorded_digest="sha256:old"
}
exists() { return 0; }
is_running() { [ "$mock_running" = 1 ]; }
validate_git_blocker() { return 0; }
policy_apply=0
assert_eq "running mismatch refuses" "1" "$(policy_preflight start >/dev/null 2>&1; echo $?)"
policy_apply=1
policy_preflight start >/dev/null 2>&1; _preflight_rc=$?
assert_eq "running mismatch apply permits" "0" "$_preflight_rc"
assert_eq "start record adopts recorded Git" false "${policy_resolved_effective[git_enabled]}"
assert_eq "start effective grant is adopted" 1 "$policy_grant_gh"
assert_eq "start record adopts recorded grant" true "${policy_resolved_effective[github_grant]}"
mock_running=0; policy_apply=0
policy_preflight start >/dev/null 2>&1
assert_eq "stopped mismatch requests recreate" "1" "$policy_needs_recreate"
policy_preflight rebuild >/dev/null 2>&1
assert_eq "rebuild record preserves recorded Git" false "${policy_resolved_effective[git_enabled]}"
assert_eq "rebuild record resets omitted grant" false "${policy_resolved_effective[github_grant]}"
unset -f policy_load_host policy_inspect_recorded exists is_running validate_git_blocker
eval "$_saved_load_host_fn"
eval "$_saved_inspect_fn"
eval "$_saved_exists_fn"
eval "$_saved_running_fn"
eval "$_saved_blocker_fn"

# A running --apply must reuse the image recorded by Docker. The mocked command below fails the
# test if build_image is called, and records the image passed to docker run.
_saved_require_sysbox_fn="$(declare -f require_sysbox 2>/dev/null || true)"
_saved_prepare_fn="$(declare -f prepare_host_state 2>/dev/null || true)"
_saved_add_policy_fn="$(declare -f add_policy_mounts 2>/dev/null || true)"
_saved_jj_mount_fn="$(declare -f require_jj_state_mount 2>/dev/null || true)"
_saved_warn_fn="$(declare -f warn_legacy_files 2>/dev/null || true)"
_saved_start_running_fn="$(declare -f is_running 2>/dev/null || true)"
_saved_start_exists_fn="$(declare -f exists 2>/dev/null || true)"
_saved_build_fn="$(declare -f build_image 2>/dev/null || true)"
_saved_wait_fn="$(declare -f wait_jj_state 2>/dev/null || true)"
_saved_connect_fn="$(declare -f connect_networks 2>/dev/null || true)"
_saved_user_mounts_fn="$(declare -f build_user_mounts 2>/dev/null || true)"
_saved_docker_fn="$(declare -f docker 2>/dev/null || true)"
mock_run_image=""; mock_build_called=0
require_sysbox() { :; }
prepare_host_state() { :; }
add_policy_mounts() { :; }
require_jj_state_mount() { :; }
warn_legacy_files() { :; }
is_running() { return 0; }
exists() { return 1; }
build_image() { mock_build_called=1; return 1; }
wait_jj_state() { :; }
connect_networks() { :; }
build_user_mounts() { :; }
docker() {
  case "$1" in
    inspect) printf '%s\n' 'agentbox:test-image' ;;
    rm) : ;;
    run) mock_run_image="${*: -1}" ;;
    *) : ;;
  esac
}
_saved_start_mounts=("${mounts[@]}"); _saved_start_args=("${run_args[@]}"); _saved_start_labels=("${grant_labels[@]}")
policy_needs_recreate=1; policy_apply=1; mounts=(); run_args=(); grant_labels=()
cmd_start >/dev/null 2>&1
assert_eq "policy apply skips image build" "0" "$mock_build_called"
assert_eq "policy apply reuses existing image" "agentbox:test-image" "$mock_run_image"
# A stopped policy mismatch follows the same image-reuse rule. It must inspect the stopped
# container's image and must not refresh the base/child image before replacing the container.
mock_run_image=""; mock_build_called=0
is_running() { return 1; }
exists() { return 0; }
policy_needs_recreate=1; policy_apply=1; policy_operation_requested=0
cmd_start >/dev/null 2>&1
assert_eq "stopped policy apply skips image build" "0" "$mock_build_called"
assert_eq "stopped policy apply reuses existing image" "agentbox:test-image" "$mock_run_image"
mounts=("${_saved_start_mounts[@]}"); run_args=("${_saved_start_args[@]}"); grant_labels=("${_saved_start_labels[@]}")
unset -f require_sysbox prepare_host_state add_policy_mounts require_jj_state_mount warn_legacy_files
unset -f is_running exists build_image wait_jj_state connect_networks build_user_mounts docker
eval "$_saved_require_sysbox_fn"
eval "$_saved_prepare_fn"
eval "$_saved_add_policy_fn"
eval "$_saved_jj_mount_fn"
eval "$_saved_warn_fn"
eval "$_saved_start_running_fn"
eval "$_saved_start_exists_fn"
eval "$_saved_build_fn"
eval "$_saved_wait_fn"
eval "$_saved_connect_fn"
eval "$_saved_user_mounts_fn"
[ -n "$_saved_docker_fn" ] && eval "$_saved_docker_fn"

echo
echo "ab_config_container_path (bin/ab)"
# The config root is bind-mounted ro at /home/agentbox/.config/agentbox, so a resolved host path
# maps into the container by swapping that prefix — this is what ab hands the entrypoint in
# AGENTBOX_PORTS_FILE / AGENTBOX_SETUP_FILE.
_saved_root="$AB_CFG_ROOT"
AB_CFG_ROOT=/home/alice/.config/agentbox
assert_eq "nested path mapped" "/home/agentbox/.config/agentbox/machines/m/projects/p/ports" \
  "$(ab_config_container_path /home/alice/.config/agentbox/machines/m/projects/p/ports)"
assert_eq "top-level mapped"   "/home/agentbox/.config/agentbox/env" \
  "$(ab_config_container_path /home/alice/.config/agentbox/env)"
assert_eq "empty in, empty out" "" "$(ab_config_container_path '')"
AB_CFG_ROOT="$_saved_root"

echo
echo "ab_append_current_env (bin/ab)"
# Per-exec forwarding is restricted to names declared by the resolved env file. Values come from
# the invoking shell, not from literal KEY=VALUE text in that file, so session-specific variables
# such as STAY_SESSION_NAME follow the shell that launched ab.
_env_file="$(mktemp)"
cat >"$_env_file" <<'EOF'
# comments and blank lines are ignored
MAC_DIR=/file-value-is-not-forwarded
STAY_SESSION_NAME
NOT_A_SHELL_VARIABLE=ignored
BAD-NAME=ignored
EOF
_saved_cfg_env="$cfg_env"
cfg_env="$_env_file"
MAC_DIR=/current-value
STAY_SESSION_NAME=session-b
export MAC_DIR STAY_SESSION_NAME
unset NOT_A_SHELL_VARIABLE
_env_args=()
ab_append_current_env _env_args
assert_eq "forwards only declared current values" \
  $'--env\nMAC_DIR=/current-value\n--env\nSTAY_SESSION_NAME=session-b' \
  "$(printf '%s\n' "${_env_args[@]}")"

cat >"$_env_file" <<'EOF'
CURRENT_VALUE
UNSET_FINAL_VALUE
EOF
CURRENT_VALUE=forwarded
export CURRENT_VALUE
unset UNSET_FINAL_VALUE
_env_args=()
_env_rc=0
ab_append_current_env _env_args || _env_rc=$?
assert_eq "unset final declaration is skipped successfully" "0" "$_env_rc"
assert_eq "unset final declaration is not forwarded" \
  $'--env\nCURRENT_VALUE=forwarded' \
  "$(printf '%s\n' "${_env_args[@]}")"
cfg_env="$_saved_cfg_env"
rm -f "$_env_file"

echo
echo "ab_parse_port_line (agentbox-entrypoint.sh)"
assert_eq "plain port"          "2222"  "$(ab_parse_port_line 2222)"
assert_eq "trailing comment"    "2222"  "$(ab_parse_port_line '2222 # ssh to mac')"
assert_eq "leading comment drop" ""     "$(ab_parse_port_line '# a comment')"
assert_eq "blank line drop"     ""      "$(ab_parse_port_line '')"
assert_eq "whitespace drop"     ""      "$(ab_parse_port_line '   ')"
assert_eq "non-numeric drop"    ""      "$(ab_parse_port_line ssh)"
assert_eq "map syntax rejected" ""      "$(ab_parse_port_line '2222:2222')"
assert_eq "surrounding spaces"  "8080"  "$(ab_parse_port_line '  8080  ')"
assert_eq "high port"           "65535" "$(ab_parse_port_line 65535)"

echo
echo "ab_port_bindable (agentbox-entrypoint.sh)"
# socat binds as the unprivileged agentbox user, so a forwardable port is 1024-65535. Returns
# 0 (bindable) / 1 (not); 10# forces decimal (no octal for a leading zero) and the digit-count
# bound short-circuits before the arithmetic so an absurdly long number can't wrap into a pass.
b() { ab_port_bindable "$1" >/dev/null 2>&1; echo $?; }
assert_eq "valid 1024 (lowest)"    "0" "$(b 1024)"
assert_eq "valid 2222"             "0" "$(b 2222)"
assert_eq "valid 65535 (highest)"  "0" "$(b 65535)"
assert_eq "reject 1023 privileged" "1" "$(b 1023)"
assert_eq "reject 80 privileged"   "1" "$(b 80)"
assert_eq "reject 0"               "1" "$(b 0)"
assert_eq "reject 65536 (too big)" "1" "$(b 65536)"
assert_eq "reject non-numeric"     "1" "$(b ssh)"
assert_eq "reject huge number"     "1" "$(b 99999999999999999999)"

echo
echo "nested Docker readiness recovery (agentbox-entrypoint.sh)"
_saved_task11_ps_fn="$(declare -f ps 2>/dev/null || true)"
_saved_task11_kill_fn="$(declare -f kill 2>/dev/null || true)"
_saved_task11_docker_fn="$(declare -f docker 2>/dev/null || true)"
_saved_task11_daemon_alive_fn="$(declare -f docker_daemon_alive)"
_saved_task11_launch_alive_fn="$(declare -f docker_readiness_launched_process_alive)"
_saved_task11_launch_exited_fn="$(declare -f docker_readiness_launched_process_exited)"
_saved_task11_wait_fn="$(declare -f wait_for_dockerd)"
_saved_task11_start_fn="$(declare -f start_dockerd_once)"
_saved_task11_socket_fn="$(declare -f docker_socket_ready)"
_saved_task11_sleep_fn="$(declare -f readiness_sleep)"
_saved_task11_sock="$DOCKER_SOCK"; _saved_task11_pid_file="$DOCKER_PID_FILE"
_saved_task11_state_file="$DOCKER_READINESS_STATE_FILE"
_saved_task11_operation_id="$docker_readiness_operation_id"
_saved_task11_attempts="$DOCKER_READINESS_ATTEMPTS"
_saved_task11_interval="$DOCKER_READINESS_INTERVAL"
_saved_task11_state="$docker_readiness_state"
_saved_task11_retryable="$docker_readiness_retryable"
_saved_task11_replacement="$docker_readiness_replacement_attempted"
_saved_task11_evidence="$docker_readiness_daemon_evidence"
_saved_task11_wait_attempts="$docker_readiness_wait_attempts"
_saved_task11_diagnostic="$docker_readiness_diagnostic"
_saved_task11_terminal="$docker_readiness_terminal_failure"
_saved_task11_transitions="$docker_readiness_transition_log"
_saved_task11_launch_observed="$docker_readiness_launch_observed"
_saved_task11_launch_pid="$docker_readiness_launch_pid"
_task11_root="$(mktemp -d)"
DOCKER_SOCK="$_task11_root/docker.sock"; DOCKER_PID_FILE="$_task11_root/docker.pid"
DOCKER_READINESS_STATE_FILE="$_task11_root/nested-docker-state"
docker_readiness_operation_id=task11-test
DOCKER_READINESS_ATTEMPTS=3; DOCKER_READINESS_INTERVAL=0
_task11_ps_mode='pid-valid'
printf '4242\n' >"$DOCKER_PID_FILE"
ps() {
  case "$*" in
    '-o comm= -p 4242')
      case "$_task11_ps_mode" in
        pid-valid|pid-zombie) printf 'dockerd\n' ;;
        *) printf 'containerd\n' ;;
      esac
      ;;
    '-o stat= -p 4242')
      [ "$_task11_ps_mode" = pid-zombie ] && printf 'Z\n' || printf 'S\n'
      ;;
    '-eo pid=,comm=,stat=')
      [ "$_task11_ps_mode" = process-fallback ] && printf '4242 dockerd S\n'
      [ "$_task11_ps_mode" = process-zombie ] && printf '4242 dockerd Z\n'
      ;;
  esac
}
kill() { return 0; }
assert_eq "valid PID identifies live dockerd" 0 "$(docker_daemon_pid_alive; echo $?)"
_task11_ps_mode='pid-mismatch'
assert_eq "mismatched PID is not trusted" 1 "$(docker_daemon_pid_alive; echo $?)"
_task11_ps_mode='pid-zombie'
assert_eq "zombie PID is not trusted" 1 "$(docker_daemon_pid_alive; echo $?)"
_task11_ps_mode='process-fallback'
assert_eq "process table finds live dockerd without usable PID" 0 "$(docker_daemon_process_alive; echo $?)"
_task11_ps_mode='process-zombie'
assert_eq "process table ignores zombie dockerd" 1 "$(docker_daemon_process_alive; echo $?)"

# The wait loop is bounded and injectable: this fixture becomes API-ready on its third poll
# without sleeping, proving the production 30-second loop has a deterministic test seam.
_task11_ready_calls=0
docker_socket_ready() {
  _task11_ready_calls=$((_task11_ready_calls + 1))
  [ "$_task11_ready_calls" -ge 3 ]
}
docker() { [ "$1" = info ] && return 0; return 0; }
readiness_sleep() { :; }
wait_for_dockerd >/dev/null 2>&1; _task11_wait_rc=$?
assert_eq "readiness wait reaches API" 0 "$_task11_wait_rc"
assert_eq "readiness wait is bounded and counted" 3 "$docker_readiness_wait_attempts"

# A launched daemon that exits on the second poll leaves one poll in the shared budget. The
# replacement succeeds on that final poll; a separate per-attempt budget would incorrectly give
# the replacement a fresh three-poll window.
DOCKER_READINESS_ATTEMPTS=60; docker_readiness_wait_attempts=0; docker_readiness_launch_observed=1
docker_socket_ready() { [ "$docker_readiness_wait_attempts" -ge 60 ]; }
docker() {
  if [ "$1" = info ] && [ "$docker_readiness_wait_attempts" -ge 60 ]; then return 0; fi
  return 1
}
docker_readiness_launched_process_exited() { [ "$docker_readiness_wait_attempts" -ge 59 ]; }
readiness_sleep() { :; }
wait_for_dockerd >/dev/null 2>&1; _task11_first_wait_rc=$?
assert_eq "exited daemon returns before shared deadline" 2 "$_task11_first_wait_rc"
assert_eq "first wait consumes most shared budget" 59 "$docker_readiness_wait_attempts"
wait_for_dockerd >/dev/null 2>&1; _task11_second_wait_rc=$?
assert_eq "replacement uses remaining shared budget" 0 "$_task11_second_wait_rc"
assert_eq "replacement total stays within bound" 60 "$docker_readiness_wait_attempts"

# The remaining cases exercise ensure_dockerd's state machine. Docker API, process liveness,
# launch, socket readiness, and sleep are all seams so no real daemon, socket, or 30-second wait
# is needed. Marker files are private fixtures, allowing cleanup assertions without /var/run.
unset -f docker_socket_ready docker readiness_sleep
eval "$_saved_task11_socket_fn"; eval "$_saved_task11_docker_fn"; eval "$_saved_task11_sleep_fn"
_task11_info_rc=1; _task11_alive_results=(); _task11_start_results=()
_task11_alive_calls=0; _task11_start_calls=0
docker() { [ "$1" = info ] && return "$_task11_info_rc"; return 0; }
docker_daemon_alive() {
  _task11_alive_calls=$((_task11_alive_calls + 1))
  local result="${_task11_alive_results[0]:-false}"
  _task11_alive_results=("${_task11_alive_results[@]:1}")
  [ "$result" = true ]
}
wait_for_dockerd() { return "${_task11_wait_result:-1}"; }
start_dockerd_once() {
  _task11_start_calls=$((_task11_start_calls + 1))
  local result="${_task11_start_results[0]:-1}"
  _task11_start_results=("${_task11_start_results[@]:1}")
  return "$result"
}
readiness_sleep() { :; }
docker_socket_ready() { return 1; }

touch "$DOCKER_SOCK" "$DOCKER_PID_FILE"
_task11_alive_results=(true); _task11_wait_result=0
ensure_dockerd >/dev/null 2>&1; _task11_rc=$?
assert_eq "live daemon with valid evidence becomes ready" 0 "$_task11_rc"
assert_eq "live daemon is not restarted" 0 "$_task11_start_calls"
assert_eq "live daemon state is ready" ready "$docker_readiness_state"
assert_eq "live daemon transition" "starting ready" "$docker_readiness_transition_log"
assert_eq "live daemon markers are preserved" 2 "$(find "$DOCKER_SOCK" "$DOCKER_PID_FILE" -maxdepth 0 -type f 2>/dev/null | wc -l)"

_task11_alive_results=(true true); _task11_wait_result=1; _task11_start_calls=0
ensure_dockerd >/dev/null 2>&1; _task11_rc=$?
assert_eq "persistent live daemon returns failure" 1 "$_task11_rc"
assert_eq "persistent live daemon is not restarted" 0 "$_task11_start_calls"
assert_eq "persistent live daemon is failed-but-running" failed-but-running "$docker_readiness_state"
assert_eq "persistent live daemon is retryable" 1 "$docker_readiness_retryable"
assert_eq "persistent live daemon markers are preserved" 2 "$(find "$DOCKER_SOCK" "$DOCKER_PID_FILE" -maxdepth 0 -type f 2>/dev/null | wc -l)"

_task11_alive_results=(false); _task11_start_results=(0); _task11_start_calls=0
ensure_dockerd >/dev/null 2>&1; _task11_rc=$?
assert_eq "stale markers with no daemon start once" 0 "$_task11_rc"
assert_eq "stale markers are cleaned before start" 0 "$(find "$DOCKER_SOCK" "$DOCKER_PID_FILE" -maxdepth 0 -type f 2>/dev/null | wc -l)"
assert_eq "stale marker recovery is ready" ready "$docker_readiness_state"

touch "$DOCKER_SOCK" "$DOCKER_PID_FILE"
_task11_alive_results=(false false); _task11_start_results=(2 0); _task11_start_calls=0
ensure_dockerd >/dev/null 2>&1; _task11_rc=$?
assert_eq "exited daemon gets one replacement" 0 "$_task11_rc"
assert_eq "replacement starts exactly once" 2 "$_task11_start_calls"
assert_eq "replacement state returns ready" ready "$docker_readiness_state"
assert_eq "replacement transition is explicit" \
  "starting failed-and-exited replacement-attempted ready" "$docker_readiness_transition_log"
assert_eq "replacement attempt is recorded" 1 "$docker_readiness_replacement_attempted"
assert_eq "readiness handoff records operation" 1 \
  "$(grep -c '^operation_id=task11-test$' "$DOCKER_READINESS_STATE_FILE" || true)"
assert_eq "readiness handoff records state" 1 \
  "$(grep -c '^state=ready$' "$DOCKER_READINESS_STATE_FILE" || true)"
assert_eq "readiness handoff records retryability" 1 \
  "$(grep -c '^retryable=0$' "$DOCKER_READINESS_STATE_FILE" || true)"
assert_eq "readiness handoff records wait bound" 1 \
  "$(grep -c '^wait_attempts=' "$DOCKER_READINESS_STATE_FILE" || true)"

_task11_alive_results=(false false false); _task11_start_results=(2 2); _task11_start_calls=0
ensure_dockerd >/dev/null 2>&1; _task11_rc=$?
assert_eq "failed replacement returns failure" 1 "$_task11_rc"
assert_eq "failed replacement is attempted once" 2 "$_task11_start_calls"
assert_eq "failed replacement is terminal" failed-and-exited "$docker_readiness_state"
assert_eq "failed replacement is terminally remembered" 1 "$docker_readiness_terminal_failure"
ensure_dockerd >/dev/null 2>&1; _task11_rc=$?
assert_eq "terminal replacement does not retry" 1 "$_task11_rc"
assert_eq "terminal replacement keeps one attempt" 2 "$_task11_start_calls"

# Restore the real launch/wait path for the delayed-process-appearance regression below.
unset -f docker docker_daemon_alive wait_for_dockerd start_dockerd_once
[ -n "$_saved_task11_docker_fn" ] && eval "$_saved_task11_docker_fn"
eval "$_saved_task11_daemon_alive_fn"; eval "$_saved_task11_wait_fn"; eval "$_saved_task11_start_fn"

# A background dockerd can be launched before it is visible through the process-table seam. The
# launched PID is still considered alive, so the bounded wait must report a running failure and
# retain the newly written markers rather than authorizing cleanup and a replacement launch.
_saved_task11_docker_fn="$(declare -f docker)"
_saved_task11_socket_fn="$(declare -f docker_socket_ready)"
_saved_task11_sleep_fn="$(declare -f readiness_sleep)"
_saved_task11_launch_alive_fn="$(declare -f docker_readiness_launched_process_alive)"
_saved_task11_launch_exited_fn="$(declare -f docker_readiness_launched_process_exited)"
_saved_task11_launch_pid="$docker_readiness_launch_pid"
_saved_task11_log="$DOCKERD_LOG"
_task11_launch_count_file="$_task11_root/launch-count"
printf '0\n' >"$_task11_launch_count_file"
docker() { [ "$1" = info ] && return 1; return 0; }
docker_socket_ready() { return 1; }
readiness_sleep() { :; }
dockerd() {
  local count
  count=$(<"$_task11_launch_count_file")
  printf '%s\n' "$((count + 1))" >"$_task11_launch_count_file"
  touch "$DOCKER_SOCK" "$DOCKER_PID_FILE"
}
docker_readiness_launched_process_alive() { return 0; }
docker_readiness_launched_process_exited() { return 1; }
DOCKER_READINESS_ATTEMPTS=3; DOCKER_READINESS_INTERVAL=0
docker_readiness_wait_attempts=0; docker_readiness_launch_pid=""
docker_readiness_terminal_failure=0
DOCKERD_LOG="$_task11_root/dockerd.log"
ensure_dockerd >/dev/null 2>&1; _task11_delayed_process_rc=$?
assert_eq "delayed process appearance remains running" 1 "$_task11_delayed_process_rc"
assert_eq "delayed process appearance launches once" 1 "$(<"$_task11_launch_count_file")"
assert_eq "delayed process appearance keeps socket marker" 1 \
  "$(find "$DOCKER_SOCK" -maxdepth 0 -type f 2>/dev/null | wc -l)"
assert_eq "delayed process appearance keeps PID marker" 1 \
  "$(find "$DOCKER_PID_FILE" -maxdepth 0 -type f 2>/dev/null | wc -l)"
unset -f docker dockerd docker_socket_ready readiness_sleep
eval "$_saved_task11_docker_fn"; eval "$_saved_task11_socket_fn"; eval "$_saved_task11_sleep_fn"
eval "$_saved_task11_launch_alive_fn"; eval "$_saved_task11_launch_exited_fn"
docker_readiness_launch_pid="$_saved_task11_launch_pid"; DOCKERD_LOG="$_saved_task11_log"

unset -f ps kill docker docker_daemon_alive docker_readiness_launched_process_alive
unset -f docker_readiness_launched_process_exited wait_for_dockerd start_dockerd_once
unset -f docker_socket_ready readiness_sleep
[ -n "$_saved_task11_ps_fn" ] && eval "$_saved_task11_ps_fn"
[ -n "$_saved_task11_kill_fn" ] && eval "$_saved_task11_kill_fn"
eval "$_saved_task11_docker_fn"; eval "$_saved_task11_daemon_alive_fn"
eval "$_saved_task11_launch_alive_fn"; eval "$_saved_task11_launch_exited_fn"
eval "$_saved_task11_wait_fn"; eval "$_saved_task11_start_fn"
eval "$_saved_task11_socket_fn"; eval "$_saved_task11_sleep_fn"
rm -rf "$_task11_root"
DOCKER_SOCK="$_saved_task11_sock"; DOCKER_PID_FILE="$_saved_task11_pid_file"
DOCKER_READINESS_STATE_FILE="$_saved_task11_state_file"
docker_readiness_operation_id="$_saved_task11_operation_id"
DOCKER_READINESS_ATTEMPTS="$_saved_task11_attempts"; DOCKER_READINESS_INTERVAL="$_saved_task11_interval"
docker_readiness_state="$_saved_task11_state"; docker_readiness_retryable="$_saved_task11_retryable"
docker_readiness_replacement_attempted="$_saved_task11_replacement"
docker_readiness_daemon_evidence="$_saved_task11_evidence"
docker_readiness_wait_attempts="$_saved_task11_wait_attempts"
docker_readiness_diagnostic="$_saved_task11_diagnostic"
docker_readiness_terminal_failure="$_saved_task11_terminal"
docker_readiness_transition_log="$_saved_task11_transitions"
docker_readiness_launch_observed="$_saved_task11_launch_observed"
docker_readiness_launch_pid="$_saved_task11_launch_pid"

echo
echo "ab_parse_mounts_line (bin/ab)"
# Grammar: `src [dst] [ro|rw]`, mode defaulting to ro. ab_parse_mounts_line leaves a leading ~
# literal (build_user_mounts expands it later, differently per side), so the expected strings are
# built from t='~' rather than a literal ~ in quotes.
t='~'
assert_eq "src only -> dst=src, ro"  "${t}/.ssh/id_ed25519"$'\t'"${t}/.ssh/id_ed25519"$'\tro' "$(ab_parse_mounts_line "${t}/.ssh/id_ed25519")"
assert_eq "src + dst (two tokens)"   $'/home/alice/k\t/home/agentbox/k\tro'  "$(ab_parse_mounts_line '/home/alice/k /home/agentbox/k')"
# The two-token ambiguity: a trailing ro/rw is the MODE, anything else is a destination.
assert_eq "src + rw (two tokens)"    $'/srv/data\t/srv/data\trw'            "$(ab_parse_mounts_line '/srv/data rw')"
assert_eq "src + ro (two tokens)"    $'/srv/data\t/srv/data\tro'            "$(ab_parse_mounts_line '/srv/data ro')"
assert_eq "src + dst + rw"           $'/srv/data\t/home/agentbox/d\trw'     "$(ab_parse_mounts_line '/srv/data /home/agentbox/d rw')"
assert_eq "src + dst + ro"           $'/srv/data\t/home/agentbox/d\tro'     "$(ab_parse_mounts_line '/srv/data /home/agentbox/d ro')"
assert_eq "comment dropped"          ""                                     "$(ab_parse_mounts_line '# a comment')"
assert_eq "blank dropped"            ""                                     "$(ab_parse_mounts_line '')"
assert_eq "whitespace dropped"       ""                                     "$(ab_parse_mounts_line '   ')"
assert_eq "trailing comment"         "${t}/.ssh/k"$'\t'"${t}/.ssh/k"$'\tro' "$(ab_parse_mounts_line "${t}/.ssh/k # my mac key")"
assert_eq "trailing comment + mode"  $'/srv/d\t/srv/d\trw'                  "$(ab_parse_mounts_line '/srv/d rw # writable')"
assert_eq "extra spaces collapsed"   $'a\tb\tro'                            "$(ab_parse_mounts_line '  a   b  ')"
# Malformed: a third token that isn't a mode, 4+ tokens, or a bare mode with no path.
assert_eq "3rd token not a mode"     ""                                     "$(ab_parse_mounts_line '/a /b /c')"
assert_eq "four tokens rejected"     ""                                     "$(ab_parse_mounts_line '/a /b rw extra')"
assert_eq "bare mode rejected"       ""                                     "$(ab_parse_mounts_line 'rw')"
assert_eq "returns 0 always"         "0"                                    "$(ab_parse_mounts_line '/a /b /c /d'; echo $?)"

echo
echo "ab_parse_network_line (bin/ab)"
# One docker network name per line; # comments (full-line and trailing) and blanks yield nothing.
# Names are [a-zA-Z0-9_.-]+, and a leading '-' is rejected (docker network connect would read it as
# a flag). Same always-returns-0 contract as ab_parse_mounts_line — connect_networks distinguishes
# blank/comment from a typo'd line.
assert_eq "plain name"            "lab"     "$(ab_parse_network_line 'lab')"
assert_eq "surrounding spaces"    "lab"     "$(ab_parse_network_line '  lab  ')"
assert_eq "name with dots"        "db.jl"   "$(ab_parse_network_line 'db.jl')"
assert_eq "name with dash"        "my-net"  "$(ab_parse_network_line 'my-net')"
assert_eq "name with underscore"  "lab_net" "$(ab_parse_network_line 'lab_net')"
assert_eq "trailing comment"      "lab"     "$(ab_parse_network_line 'lab # the lab network')"
assert_eq "full-line comment"     ""        "$(ab_parse_network_line '# a comment')"
assert_eq "blank line"            ""        "$(ab_parse_network_line '')"
assert_eq "whitespace only"       ""        "$(ab_parse_network_line '   ')"
assert_eq "two tokens rejected"   ""        "$(ab_parse_network_line 'lab extra')"
assert_eq "leading dash rejected" ""        "$(ab_parse_network_line '-lab')"
assert_eq "invalid char rejected" ""        "$(ab_parse_network_line 'lab!net')"
assert_eq "returns 0 always"      "0"       "$(ab_parse_network_line 'bad net'; echo $?)"

echo
echo "ab_dockerfile_has_content (bin/ab)"
# A resolved Dockerfile with no instruction lines (only comments/blanks) is "empty" -> treated
# as ABSENT (no child image; the base runs), so absent == empty (same property the other files
# already have). Anything with a real instruction line has content. Real tmpfiles.
_df="$(mktemp)"
printf '' >"$_df";                        assert_eq "empty file -> no content"            "1" "$(ab_dockerfile_has_content "$_df"; echo $?)"
printf '\n\n  \n' >"$_df";                assert_eq "only blanks -> no content"           "1" "$(ab_dockerfile_has_content "$_df"; echo $?)"
printf '# comment\n#another\n' >"$_df";   assert_eq "only comments -> no content"         "1" "$(ab_dockerfile_has_content "$_df"; echo $?)"
printf '# c\nFROM agentbox:latest\n' >"$_df"; assert_eq "comment + FROM -> content"       "0" "$(ab_dockerfile_has_content "$_df"; echo $?)"
printf 'RUN echo hi\n' >"$_df";           assert_eq "instruction -> content"              "0" "$(ab_dockerfile_has_content "$_df"; echo $?)"
printf '  RUN echo # inline\n' >"$_df";   assert_eq "indented instr, inline # -> content" "0" "$(ab_dockerfile_has_content "$_df"; echo $?)"
assert_eq "absent file -> no content"     "1" "$(ab_dockerfile_has_content "$_df.missing"; echo $?)"
rm -f "$_df"

echo
echo "ab_mount_dest_owner (bin/ab)"
# A user mount onto a destination ab already uses would make `docker run` fail with "Duplicate
# mount point", so build_user_mounts drops that line. Both spec forms in the array are matched.
assert_eq "agentbox README is mounted ro" "$CONTEXT/README.md:/home/agentbox/README.md:ro" \
  "$(ab_mount_dest_owner /home/agentbox/README.md)"
_saved_mounts=("${mounts[@]}")
mounts=(-v "/proj:/workspace" -v "/etc/localtime:/etc/localtime:ro" --mount "type=bind,src=/srv/d,dst=/home/agentbox/d,readonly")
assert_eq "-v dst matched"          "/proj:/workspace"          "$(ab_mount_dest_owner /workspace)"
assert_eq "-v dst with :ro matched" "/etc/localtime:/etc/localtime:ro" "$(ab_mount_dest_owner /etc/localtime)"
assert_eq "--mount dst matched"     "type=bind,src=/srv/d,dst=/home/agentbox/d,readonly" "$(ab_mount_dest_owner /home/agentbox/d)"
assert_eq "unclaimed dst -> empty"  ""                          "$(ab_mount_dest_owner /home/agentbox/other)"
assert_eq "source is not a dst"     ""                          "$(ab_mount_dest_owner /proj)"
mounts=("${_saved_mounts[@]}")

echo
echo "prepare_host_state (bin/ab)"
# Host config files are mirrored read-only, while jj's secure repo/workspace state is kept in the
# separate writable jvol mounted at jj's standard container path. JJ_CONFIG points only at the
# read-only user config files, even when the host uses a custom XDG_CONFIG_HOME.
_cfg_home="$(mktemp -d)"
_saved_home="$HOME"
_saved_xdg="${XDG_CONFIG_HOME-}"
_saved_mounts=("${mounts[@]}")
HOME="$_cfg_home"
XDG_CONFIG_HOME="$_cfg_home/custom-config"
mkdir -p "$HOME/.config/jj" "$XDG_CONFIG_HOME/jj/conf.d"
: >"$HOME/.gitconfig"
: >"$HOME/.jjconfig.toml"
: >"$XDG_CONFIG_HOME/jj/config.toml"
: >"$XDG_CONFIG_HOME/jj/conf.d/10-work.toml"
mounts=()
jj_config_paths=()
add_host_config_mounts
policy_git_enabled=1
policy_grant_gh=0
policy_grant_all_of_dot_ssh=0
add_policy_mounts
assert_eq "mounts git config" "$HOME/.gitconfig:/home/agentbox/.gitconfig:ro" \
  "$(ab_mount_dest_owner /home/agentbox/.gitconfig)"
assert_eq "mounts jj legacy config" "$HOME/.jjconfig.toml:/home/agentbox/.jjconfig.toml:ro" \
  "$(ab_mount_dest_owner /home/agentbox/.jjconfig.toml)"
assert_eq "mounts jj XDG config" "$XDG_CONFIG_HOME/jj/config.toml:/home/agentbox/.config/jj-host-config.toml:ro" \
  "$(ab_mount_dest_owner /home/agentbox/.config/jj-host-config.toml)"
assert_eq "mounts jj conf.d" "$XDG_CONFIG_HOME/jj/conf.d:/home/agentbox/.config/jj-host-conf.d:ro" \
  "$(ab_mount_dest_owner /home/agentbox/.config/jj-host-conf.d)"
assert_eq "JJ_CONFIG paths" \
  "JJ_CONFIG=/home/agentbox/.jjconfig.toml:/home/agentbox/.config/jj-host-config.toml:/home/agentbox/.config/jj-host-conf.d" \
  "$(jj_config_env_arg)"
assert_eq "JJ_CONFIG path count" 3 "${#jj_config_paths[@]}"
assert_eq "jj state mount is not host config" "" \
  "$(ab_mount_dest_owner /home/agentbox/.config/jj)"
HOME="$_saved_home"
if [ -n "$_saved_xdg" ]; then XDG_CONFIG_HOME="$_saved_xdg"; else unset XDG_CONFIG_HOME; fi
mounts=("${_saved_mounts[@]}")
rm -rf "$_cfg_home"

# A clean host has no tool state directories. Preparation must create only the launcher-owned
# state directories as the invoking user; a granted GitHub source must already exist.
_state_home="$(mktemp -d)"
_saved_home="$HOME"
_saved_mounts=("${mounts[@]}")
HOME="$_state_home"
mounts=()
grant_gh=0
grant_all_of_dot_ssh=0
policy_git_enabled=1
policy_grant_gh=0
policy_grant_all_of_dot_ssh=0
prepare_host_state
assert_eq "creates Claude state dir" "1" "$([ -d "$HOME/.claude" ] && echo 1 || echo 0)"
assert_eq "creates Codex state dir"  "1" "$([ -d "$HOME/.codex" ] && echo 1 || echo 0)"
assert_eq "does not create gh state dir by default" "0" "$([ -d "$HOME/.config/gh" ] && echo 1 || echo 0)"
grant_gh=1
policy_grant_gh=1
prepare_host_state >/dev/null 2>&1
_missing_gh_rc=$?
assert_eq "missing gh source rejects grant" 1 "$_missing_gh_rc"
assert_eq "missing gh source is not created" "0" "$([ -d "$HOME/.config/gh" ] && echo 1 || echo 0)"
assert_eq "missing gh source is not mounted" "" "$(ab_mount_dest_owner /home/agentbox/.config/gh)"
mkdir -p "$HOME/.config/gh"
prepare_host_state
assert_eq "creates gh state dir with grant" "1" "$([ -d "$HOME/.config/gh" ] && echo 1 || echo 0)"
assert_eq "mounts gh state dir with grant" "$HOME/.config/gh:/home/agentbox/.config/gh" \
  "$(ab_mount_dest_owner /home/agentbox/.config/gh)"
mkdir -p "$HOME/.ssh"
: >"$HOME/.ssh/known_hosts"
grant_all_of_dot_ssh=1
policy_grant_all_of_dot_ssh=1
prepare_host_state
assert_eq "mounts all of ssh read-only with grant" "$HOME/.ssh:/home/agentbox/.ssh:ro" \
  "$(ab_mount_dest_owner /home/agentbox/.ssh)"
assert_eq "mounts known_hosts read-write with grant" "$HOME/.ssh/known_hosts:/home/agentbox/.ssh/known_hosts" \
  "$(ab_mount_dest_owner /home/agentbox/.ssh/known_hosts)"
assert_eq "gh grant label enabled" "--label agentbox.grant-gh=1" "${grant_labels[*]:0:2}"
HOME="$_saved_home"
mounts=("${_saved_mounts[@]}")
rm -rf "$_state_home"

echo
echo "Task 4 mount specification (bin/ab)"
_mount_spec_home="$(mktemp -d)"
_mount_spec_blocker="$(mktemp)"
_mount_spec_cfg="$(mktemp)"
_saved_mount_spec_home="$HOME"
_saved_mount_spec_git_blocker="$GIT_BLOCKER"
_saved_mount_spec_cfg_mounts="$cfg_mounts"
_saved_mount_spec_git="$policy_git_enabled"
_saved_mount_spec_gh="$policy_grant_gh"
_saved_mount_spec_ssh="$policy_grant_all_of_dot_ssh"
HOME="$_mount_spec_home"
GIT_BLOCKER="$_mount_spec_blocker"
cfg_mounts=""
mkdir -p "$HOME/.config/git" "$HOME/.config/gh" "$HOME/.ssh"
: >"$HOME/.gitconfig"
: >"$HOME/.config/git/config"
: >"$HOME/.ssh/known_hosts"
printf '#!/usr/bin/env bash\nexit 1\n' >"$GIT_BLOCKER"
chmod 755 "$GIT_BLOCKER"

_mount_spec_lines="$(mount_spec_record)"
assert_eq "mount spec has six fixed entries" "6" "$(printf '%s\n' "$_mount_spec_lines" | wc -l)"
assert_eq "mount spec key order" \
  "git_blocker git_config github_config ssh_dir known_hosts custom_conflicts" \
  "$(printf '%s\n' "$_mount_spec_lines" | cut -f1 | paste -sd' ' -)"

for _git_enabled in 0 1; do
  for _grant_gh in 0 1; do
    for _grant_ssh in 0 1; do
      policy_git_enabled="$_git_enabled"
      policy_grant_gh="$_grant_gh"
      policy_grant_all_of_dot_ssh="$_grant_ssh"
      mount_spec_build >/dev/null 2>&1
      _mount_spec_rc=$?
      assert_eq "mount matrix $_git_enabled/$_grant_gh/$_grant_ssh builds" 0 "$_mount_spec_rc"
      _git_state="${mount_spec_state[git_blocker]}"
      _git_config_state="${mount_spec_state[git_config]}"
      _gh_state="${mount_spec_state[github_config]}"
      _ssh_state="${mount_spec_state[ssh_dir]}"
      _known_state="${mount_spec_state[known_hosts]}"
      assert_eq "matrix blocker state $_git_enabled/$_grant_gh/$_grant_ssh" \
        "$([ "$_git_enabled" = 0 ] && echo ro || echo absent)" "$_git_state"
      assert_eq "matrix git config state $_git_enabled/$_grant_gh/$_grant_ssh" \
        "$([ "$_git_enabled" = 1 ] && echo ro || echo absent)" "$_git_config_state"
      assert_eq "matrix GitHub state $_git_enabled/$_grant_gh/$_grant_ssh" \
        "$([ "$_grant_gh" = 1 ] && echo rw || echo absent)" "$_gh_state"
      assert_eq "matrix SSH state $_git_enabled/$_grant_gh/$_grant_ssh" \
        "$([ "$_grant_ssh" = 1 ] && echo ro || echo absent)" "$_ssh_state"
      assert_eq "matrix known_hosts state $_git_enabled/$_grant_gh/$_grant_ssh" \
        "$([ "$_grant_ssh" = 1 ] && echo rw || echo absent)" "$_known_state"
    done
  done
done

rm -f "$HOME/.ssh/known_hosts"
policy_git_enabled=1
policy_grant_gh=0
policy_grant_all_of_dot_ssh=1
mount_spec_build >/dev/null 2>&1
assert_eq "missing known_hosts stays absent" absent "${mount_spec_state[known_hosts]}"
assert_eq "SSH dir remains read-only without known_hosts" ro "${mount_spec_state[ssh_dir]}"

_saved_mount_spec_mounts=("${mounts[@]-}")
mounts=()
policy_grant_all_of_dot_ssh=0
policy_grant_gh=0
policy_git_enabled=1
add_policy_mounts
assert_eq "Git-enabled config argument" "$HOME/.gitconfig:/home/agentbox/.gitconfig:ro" \
  "$(ab_mount_dest_owner /home/agentbox/.gitconfig)"
assert_eq "Git-enabled has no blocker argument" "" "$(ab_mount_dest_owner /usr/bin/git)"
mounts=()
policy_git_enabled=0
add_policy_mounts
assert_eq "no-Git blocker argument" \
  "type=bind,src=$GIT_BLOCKER,dst=/usr/bin/git,readonly" "$(ab_mount_dest_owner /usr/bin/git)"
assert_eq "no-Git omits gitconfig argument" "" "$(ab_mount_dest_owner /home/agentbox/.gitconfig)"
assert_eq "no-Git omits XDG gitconfig argument" "" "$(ab_mount_dest_owner /home/agentbox/.config/git/config)"
mounts=("${_saved_mount_spec_mounts[@]}")

rm -f "$HOME/.gitconfig"
policy_git_enabled=1
mount_spec_build >/dev/null 2>&1
assert_eq "Git config falls back to XDG source" "$HOME/.config/git/config" "${mount_spec_source[git_config]}"
assert_eq "Git config falls back to XDG destination" /home/agentbox/.config/git/config "${mount_spec_destination[git_config]}"
: >"$HOME/.gitconfig"

_mount_spec_protected=0
for _protected_destination in "${protected_mount_destinations[@]}"; do
  printf '%s\n' "$_mount_spec_blocker $_protected_destination" >"$_mount_spec_cfg"
  cfg_mounts="$_mount_spec_cfg"
  assert_eq "custom conflict $_protected_destination" 1 \
    "$(mount_spec_validate >/dev/null 2>&1; echo $?)"
  _mount_spec_protected=$((_mount_spec_protected + 1))
done
assert_eq "all protected destinations covered" "${#protected_mount_destinations[@]}" "$_mount_spec_protected"
cfg_mounts="$_mount_spec_cfg"
printf '%s\n' "$_mount_spec_blocker /workspace2" >"$_mount_spec_cfg"
assert_eq "similar custom destination remains valid" 0 \
  "$(mount_spec_validate >/dev/null 2>&1; echo $?)"

for _blocker_case in missing unreadable nonexec symlink world-writable wrong-mode; do
  rm -f "$GIT_BLOCKER"
  case "$_blocker_case" in
    missing) : ;;
    unreadable) printf '#!/usr/bin/env bash\nexit 1\n' >"$GIT_BLOCKER"; chmod 000 "$GIT_BLOCKER" ;;
    nonexec) printf '#!/usr/bin/env bash\nexit 1\n' >"$GIT_BLOCKER"; chmod 644 "$GIT_BLOCKER" ;;
    symlink) printf '#!/usr/bin/env bash\nexit 1\n' >"$_mount_spec_home/real-blocker"; chmod 755 "$_mount_spec_home/real-blocker"; ln -s "$_mount_spec_home/real-blocker" "$GIT_BLOCKER" ;;
    world-writable) printf '#!/usr/bin/env bash\nexit 1\n' >"$GIT_BLOCKER"; chmod 757 "$GIT_BLOCKER" ;;
    wrong-mode) printf '#!/usr/bin/env bash\nexit 1\n' >"$GIT_BLOCKER"; chmod 754 "$GIT_BLOCKER" ;;
  esac
  policy_git_enabled=0
  policy_grant_gh=0
  policy_grant_all_of_dot_ssh=0
  assert_eq "blocker $_blocker_case rejected" 1 "$(mount_spec_build >/dev/null 2>&1; echo $?)"
done

rm -f "$GIT_BLOCKER" "$_mount_spec_home/real-blocker" "$_mount_spec_cfg" 2>/dev/null || true
HOME="$_saved_mount_spec_home"
GIT_BLOCKER="$_saved_mount_spec_git_blocker"
cfg_mounts="$_saved_mount_spec_cfg_mounts"
policy_git_enabled="$_saved_mount_spec_git"
policy_grant_gh="$_saved_mount_spec_gh"
policy_grant_all_of_dot_ssh="$_saved_mount_spec_ssh"
rm -rf "$_mount_spec_home"
rm -f "$_mount_spec_blocker" "$_mount_spec_cfg"

echo
echo "raw policy input capture (bin/ab)"
unset AGENTBOX_NO_GIT AGENTBOX_GRANT_GH AGENTBOX_GRANT_ALL_OF_DOT_SSH
policy_input_reset
_raw_unset="$(printf '%s\n' \
  cli_git_enabled=unset cli_grant_gh=unset cli_grant_ssh=unset \
  env_git_enabled=unset env_grant_gh=unset env_grant_ssh=unset)"
assert_eq "raw record has six unset fields" "$_raw_unset" "$(policy_input_record)"

for value in 1 true yes on TRUE YES ON; do
  AGENTBOX_NO_GIT="$value"; export AGENTBOX_NO_GIT
  policy_input_reset; policy_input_capture_env
  assert_eq "no-git true spelling $value" false "${policy_input[env_git_enabled]}"
done
for value in 0 false no off FALSE NO OFF; do
  AGENTBOX_NO_GIT="$value"; export AGENTBOX_NO_GIT
  policy_input_reset; policy_input_capture_env
  assert_eq "no-git false spelling $value" true "${policy_input[env_git_enabled]}"
done
for value in 1 true yes on TRUE YES ON; do
  AGENTBOX_GRANT_GH="$value"; export AGENTBOX_GRANT_GH
  policy_input_reset; policy_input_capture_env
  assert_eq "grant-gh true spelling $value" true "${policy_input[env_grant_gh]}"
done
for value in 0 false no off FALSE NO OFF; do
  AGENTBOX_GRANT_GH="$value"; export AGENTBOX_GRANT_GH
  policy_input_reset; policy_input_capture_env
  assert_eq "grant-gh false spelling $value" false "${policy_input[env_grant_gh]}"
done
for value in 1 true yes on TRUE YES ON; do
  AGENTBOX_GRANT_ALL_OF_DOT_SSH="$value"; export AGENTBOX_GRANT_ALL_OF_DOT_SSH
  policy_input_reset; policy_input_capture_env
  assert_eq "grant-ssh true spelling $value" true "${policy_input[env_grant_ssh]}"
done
for value in 0 false no off FALSE NO OFF; do
  AGENTBOX_GRANT_ALL_OF_DOT_SSH="$value"; export AGENTBOX_GRANT_ALL_OF_DOT_SSH
  policy_input_reset; policy_input_capture_env
  assert_eq "grant-ssh false spelling $value" false "${policy_input[env_grant_ssh]}"
done
unset AGENTBOX_NO_GIT AGENTBOX_GRANT_GH AGENTBOX_GRANT_ALL_OF_DOT_SSH
policy_input_reset
parse_runtime_options start --no-git --grant-gh --grant-all-of-dot-ssh --no-git
assert_eq "start captures CLI Git false" false "${policy_input[cli_git_enabled]}"
assert_eq "start captures CLI GitHub true" true "${policy_input[cli_grant_gh]}"
assert_eq "start captures CLI SSH true" true "${policy_input[cli_grant_ssh]}"
parse_runtime_options rebuild --no-cache --grant-gh
assert_eq "rebuild captures CLI Git unset" unset "${policy_input[cli_git_enabled]}"
assert_eq "rebuild captures CLI GitHub true" true "${policy_input[cli_grant_gh]}"
assert_eq "rebuild captures CLI SSH unset" unset "${policy_input[cli_grant_ssh]}"
parse_exec_options exec --no-git --grant-gh echo hello
assert_eq "exec captures policy prefix" "false true unset" \
  "${policy_input[cli_git_enabled]} ${policy_input[cli_grant_gh]} ${policy_input[cli_grant_ssh]}"
assert_eq "explicit exec records command authority" 1 "$policy_explicit_exec_command"
assert_eq "exec preserves command arguments" "echo hello" "${policy_command_args[*]}"
parse_convenience_options claude --grant-gh --no-git --resume
assert_eq "claude captures policy flags" "true false unset" \
  "${policy_input[cli_grant_gh]} ${policy_input[cli_git_enabled]} ${policy_input[cli_grant_ssh]}"
assert_eq "convenience execution is not explicit exec" 0 "$policy_explicit_exec_command"
assert_eq "claude preserves command arguments" "claude --resume" "${policy_command_args[*]}"
parse_convenience_options codex --grant-all-of-dot-ssh --model o3
assert_eq "codex captures SSH grant" true "${policy_input[cli_grant_ssh]}"
assert_eq "codex preserves command arguments" "codex --model o3" "${policy_command_args[*]}"
parse_convenience_options bash -- --no-git
assert_eq "bash delimiter preserves command argument" "bash --no-git" "${policy_command_args[*]}"

_saved_docker_fn="$(declare -f docker 2>/dev/null || true)"
_saved_update_fn="$(declare -f check_for_update 2>/dev/null || true)"
policy_test_docker_calls=0
policy_test_update_calls=0
docker() { policy_test_docker_calls=$((policy_test_docker_calls + 1)); return 1; }
check_for_update() { policy_test_update_calls=$((policy_test_update_calls + 1)); return 0; }
AGENTBOX_GRANT_GH=invalid; export AGENTBOX_GRANT_GH
policy_input_reset
assert_eq "invalid policy fails preflight" "1" "$(policy_preflight start >/dev/null 2>&1; echo $?)"
assert_eq "invalid policy skips Docker" "0" "$policy_test_docker_calls"
assert_eq "invalid policy skips update check" "0" "$policy_test_update_calls"
unset AGENTBOX_GRANT_GH
unset -f docker check_for_update
[ -n "$_saved_docker_fn" ] && eval "$_saved_docker_fn"
[ -n "$_saved_update_fn" ] && eval "$_saved_update_fn"

echo
echo "runtime grant options (bin/ab)"
grant_gh=0; grant_all_of_dot_ssh=0
parse_runtime_options start --grant-gh --grant-all-of-dot-ssh
assert_eq "--grant-gh parsed" "1" "$grant_gh"
assert_eq "--grant-all-of-dot-ssh parsed" "1" "$grant_all_of_dot_ssh"
parse_runtime_options rebuild --no-cache --grant-gh
assert_eq "--no-cache parsed" "--no-cache" "$nocache"
assert_eq "unknown option rejected" "1" "$(parse_runtime_options start --no-such-option >/dev/null 2>&1; echo $?)"

echo
echo "adopt_existing_grants (bin/ab)"
# Convenience commands auto-start a stopped container. Persisted labels restore the grants
# before cmd_start rebuilds its mount list; ambiguous legacy mount state is handled by policy
# preflight instead of being inferred here.
_saved_exists_fn="$(declare -f exists 2>/dev/null || true)"
_saved_mount_owner_fn="$(declare -f container_has_mount_destination 2>/dev/null || true)"
_mock_bin="$(mktemp -d)"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in' \
  "  *agentbox.grant-gh*) printf '1\\n' ;;" \
  "  *agentbox.grant-all-of-dot-ssh*) printf '0\\n' ;;" \
  "  *) printf '<no value>\\n' ;;" \
  'esac' >"$_mock_bin/docker"
chmod 0755 "$_mock_bin/docker"
_saved_path="$PATH"
PATH="$_mock_bin:$PATH"
exists() { return 0; }
container_has_mount_destination() { [ "$1" = /home/agentbox/.config/gh ]; }
grant_gh=0; grant_all_of_dot_ssh=0
adopt_existing_grants
assert_eq "adopts persisted gh grant" "1" "$grant_gh"
assert_eq "does not invent ssh grant" "0" "$grant_all_of_dot_ssh"
PATH="$_saved_path"
rm -rf "$_mock_bin"
unset -f exists container_has_mount_destination
eval "$_saved_exists_fn"
eval "$_saved_mount_owner_fn"

echo
echo "require_jj_state_mount (bin/ab)"
# Existing containers from before jj support have no jj state-volume mount. They must fail fast
# with the migration command instead of entering the readiness timeout; current containers pass.
_saved_exists_fn="$(declare -f exists 2>/dev/null || true)"
_saved_mount_owner_fn="$(declare -f container_has_mount_destination 2>/dev/null || true)"
exists() { return 0; }
container_has_mount_destination() { [ "$1" = "$JJ_STATE_CONTAINER" ]; }
assert_eq "current container accepted" "0" "$(require_jj_state_mount >/dev/null 2>&1; echo $?)"
container_has_mount_destination() { return 1; }
_legacy_jj_msg="$(require_jj_state_mount 2>&1)"
assert_eq "legacy container rejected" "1" "$(require_jj_state_mount >/dev/null 2>&1; echo $?)"
assert_eq "legacy migration hint" "1" "$(printf '%s\n' "$_legacy_jj_msg" | grep -c "ab rebuild")"
unset -f exists container_has_mount_destination
eval "$_saved_exists_fn"
eval "$_saved_mount_owner_fn"

echo
echo "ab_setup_fail (agentbox-entrypoint.sh)"
# A setup.sh failure must surface — to stderr, so `ab logs` shows it — the exit code, the tail
# of the setup log (the actual cause), where to read the full log, and that it auto-retries.
_ab_setup_tmp="$(mktemp)"
printf 'downloading tool...\ncurl: (6) Could not resolve host: github.com\n' >"$_ab_setup_tmp"
_saved_setup_log="$SETUP_LOG"
SETUP_LOG="$_ab_setup_tmp"
_ab_fail_msg="$(ab_setup_fail 7 2>&1)"
SETUP_LOG="$_saved_setup_log"
rm -f "$_ab_setup_tmp"
assert_eq "setup log restored" "$_saved_setup_log" "$SETUP_LOG"
assert_eq "reports exit code"    "1" "$(printf '%s\n' "$_ab_fail_msg" | grep -c 'exited 7')"
assert_eq "includes log tail"    "1" "$(printf '%s\n' "$_ab_fail_msg" | grep -c 'Could not resolve host')"
assert_eq "full-log hint shown"  "1" "$(printf '%s\n' "$_ab_fail_msg" | grep -c 'ab exec cat')"
assert_eq "retry how-to shown"   "1" "$(printf '%s\n' "$_ab_fail_msg" | grep -c 'ab stop && ab start')"
assert_eq "stays-up reassurance" "1" "$(printf '%s\n' "$_ab_fail_msg" | grep -c 'stays up')"

echo
echo "ab_step_fail (agentbox-entrypoint.sh)"
# A daemon-step failure must name the step and point at its log so `ab logs` shows *what*
# failed, reassure that the container stays up, and show how to retry — non-fatal by construction.
_ab_step_msg="$(ab_step_fail "port forwarding" "/var/log/agentbox-forward.log" 2>&1)"
assert_eq "names the step"        "1" "$(printf '%s\n' "$_ab_step_msg" | grep -c 'port forwarding')"
assert_eq "points at the log"     "1" "$(printf '%s\n' "$_ab_step_msg" | grep -c 'agentbox-forward.log')"
assert_eq "shows the cat hint"    "1" "$(printf '%s\n' "$_ab_step_msg" | grep -c 'ab exec cat')"
assert_eq "retry how-to shown"    "1" "$(printf '%s\n' "$_ab_step_msg" | grep -c 'ab stop && ab start')"
assert_eq "stays-up reassurance"  "1" "$(printf '%s\n' "$_ab_step_msg" | grep -c 'stays up')"
assert_eq "returns 0 (non-fatal)" "0" "$(ab_step_fail "port forwarding" "/var/log/agentbox-forward.log" >/dev/null 2>&1; echo $?)"

echo
echo "ab_parse_env_line (tests/smoke.sh)"
# docker --env-file semantics: full-line '#' comments and blanks yield nothing; an inline '#'
# and spaces are part of the value; the value is everything after the FIRST '='; quotes are
# literal (docker does not strip them). The helper always returns 0 so callers under `set -e`
# don't die on a non-assignment line — same contract as ab_parse_port_line.
assert_eq "plain KEY=VALUE"        $'MAC_HOST\t1.2.3.4'   "$(ab_parse_env_line 'MAC_HOST=1.2.3.4')"
assert_eq "value with spaces"      $'K\ta b c'            "$(ab_parse_env_line 'K=a b c')"
assert_eq "inline # kept in value" $'K\ta#b'              "$(ab_parse_env_line 'K=a#b')"
assert_eq "value with ="           $'URL\thttp://x/?a=1'  "$(ab_parse_env_line 'URL=http://x/?a=1')"
assert_eq "empty value"            $'EMPTY\t'             "$(ab_parse_env_line 'EMPTY=')"
assert_eq "full-line comment"      ""                     "$(ab_parse_env_line '# a comment')"
assert_eq "indented comment"       ""                     "$(ab_parse_env_line '   # comment')"
assert_eq "blank line"             ""                     "$(ab_parse_env_line '')"
assert_eq "whitespace only"        ""                     "$(ab_parse_env_line '   ')"
assert_eq "no = dropped"           ""                     "$(ab_parse_env_line 'NOTHING')"
assert_eq "returns 0 always"       "0"                    "$(ab_parse_env_line 'bad'; echo $?)"

echo
echo "cmd_config_init (bin/ab)"
# Isolate from the real ~/.config/agentbox and from this test run's own machine/project.
_saved_cfg_root="$AB_CFG_ROOT" _saved_machine="$MACHINE" _saved_project="$PROJECT_DIR"
# $_icfg itself must NOT already exist (unlike a bare `mktemp -d`) — the global tier's target
# dir IS $AB_CFG_ROOT, so asserting it exists afterward would otherwise be true regardless of
# whether cmd_config_init did anything.
_icfg="$(mktemp -d)/agentbox-cfg"
AB_CFG_ROOT="$_icfg" MACHINE=myhost PROJECT_DIR=/home/alice/myproj

# No flags -> the plain top-level (global) tier; no file args -> directory only, plus a hint.
assert_eq "global tier dir absent beforehand" "0" "$([ -d "$_icfg" ] && echo 1 || echo 0)"
_out="$(cmd_config_init 2>&1)"
assert_eq "global tier dir created" "1" "$([ -d "$_icfg" ] && echo 1 || echo 0)"
assert_eq "hint shown when no files given" "1" "$(printf '%s' "$_out" | grep -c 'pass file names')"

# --machine -> machines/<machine>/, and the copied file is the real example template, not empty.
cmd_config_init --machine ports >/dev/null
assert_eq "machine tier dir created" "1" "$([ -d "$_icfg/machines/myhost" ] && echo 1 || echo 0)"
assert_eq "machine tier file copied" "0" \
  "$(diff -q "$_icfg/machines/myhost/ports" "$REPO/examples/agentbox-config/ports" >/dev/null; echo $?)"

# --project -> projects/<project-path>/ (leading slash dropped, same as ab_config_candidates).
cmd_config_init --project env >/dev/null
assert_eq "project tier dir created" "1" \
  "$([ -d "$_icfg/projects/home/alice/myproj" ] && echo 1 || echo 0)"
assert_eq "project tier file copied" "1" "$([ -f "$_icfg/projects/home/alice/myproj/env" ] && echo 1 || echo 0)"

# --machine --project -> the most-specific tier (both segments).
cmd_config_init --machine --project setup.sh >/dev/null
assert_eq "machine+project tier dir created" "1" \
  "$([ -d "$_icfg/machines/myhost/projects/home/alice/myproj" ] && echo 1 || echo 0)"
assert_eq "machine+project tier file copied" "1" \
  "$([ -f "$_icfg/machines/myhost/projects/home/alice/myproj/setup.sh" ] && echo 1 || echo 0)"

# Re-running with a file that already exists must not clobber a user's edits.
printf 'MY_CUSTOM_VALUE=1\n' >"$_icfg/projects/home/alice/myproj/env"
_out="$(cmd_config_init --project env 2>&1)"
assert_eq "existing file not overwritten" "MY_CUSTOM_VALUE=1" \
  "$(cat "$_icfg/projects/home/alice/myproj/env")"
assert_eq "existing file reported, not silently skipped" "1" \
  "$(printf '%s' "$_out" | grep -c 'already exists')"

# The "$copied/$#" summary line must count only genuine copies, not every name requested — a
# mixed batch of one fresh file, one that already exists (from the "existing file" case just
# above), and one unknown name should still report exactly 1 copy out of 3 requested.
_out="$(cmd_config_init --project mounts env notreal 2>&1)"
assert_eq "mixed batch: fresh file copied" "1" \
  "$([ -f "$_icfg/projects/home/alice/myproj/mounts" ] && echo 1 || echo 0)"
assert_eq "mixed batch: existing file still untouched" "MY_CUSTOM_VALUE=1" \
  "$(cat "$_icfg/projects/home/alice/myproj/env")"
assert_eq "mixed batch: summary counts only real copies" "1" \
  "$(printf '%s' "$_out" | grep -c '1/3 template(s) written')"

# Unknown flag / unknown file name are rejected, not silently accepted. A bad flag is fatal
# (exit 1, not return) so it must be run in its own subshell — $? is read from OUTSIDE that
# subshell, since `exit` would otherwise abort this test script before "echo $?" ever ran.
( cmd_config_init --bogus >/dev/null 2>&1 )
_init_bad_flag_rc=$?
assert_eq "unknown flag exits non-zero" "1" "$_init_bad_flag_rc"
_out="$(cmd_config_init --project bogusfile 2>&1)"
assert_eq "unknown file name reported"  "1" "$(printf '%s' "$_out" | grep -c 'unknown file')"
assert_eq "unknown file name not created" "0" \
  "$([ -e "$_icfg/projects/home/alice/myproj/bogusfile" ] && echo 1 || echo 0)"

rm -rf "$(dirname "$_icfg")"
AB_CFG_ROOT="$_saved_cfg_root" MACHINE="$_saved_machine" PROJECT_DIR="$_saved_project"

echo
echo "Task 6 policy decisions (bin/ab)"
# The decision layer is pure: fixtures below set the Task 5 recorded-state handoff and the
# Task 7 overlay directly, then inspect its fixed output without invoking Docker or lifecycle
# helpers. This keeps every matrix/overlay assertion independent of the host daemon.
decision_fixture() {
  policy_operation_status=none
  policy_readiness_result=not-applicable
  policy_apply=0
  policy_git_source=default
  policy_git_enabled=1
  policy_grant_gh=0
  policy_grant_all_of_dot_ssh=0
  policy_recorded_status=none
  policy_recorded_classification=absent
  policy_recorded_lifecycle_state=absent
  policy_recorded_git_enabled=""
  policy_recorded_grant_gh=""
  policy_recorded_grant_all_of_dot_ssh=""
  policy_recorded_digest=""
}
decision_fixture
policy_decide start
assert_eq "absent creates" create "$policy_decision_kind"
assert_eq "absent permits mutation" 1 "$policy_decision_mutation_allowed"
assert_eq "absent permits execution" 1 "$policy_decision_execution_allowed"

decision_fixture
policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=stopped
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
policy_decide start
assert_eq "stopped matching starts in place" start-in-place "$policy_decision_kind"
assert_eq "stopped matching may mutate" 1 "$policy_decision_mutation_allowed"

policy_grant_gh=1
policy_decide start
assert_eq "stopped difference reconciles" reconcile-stopped "$policy_decision_kind"
assert_eq "stopped difference needs no apply" 0 "$policy_decision_explicit_apply_required"

decision_fixture
policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"; policy_grant_gh=1
policy_decide exec
assert_eq "running mismatch refuses" refuse "$policy_decision_kind"
assert_eq "running mismatch cannot mutate" 0 "$policy_decision_mutation_allowed"
assert_eq "running mismatch requires apply" 1 "$policy_decision_explicit_apply_required"

policy_apply=1
policy_decide start
assert_eq "running apply reconciles" reconcile-running "$policy_decision_kind"
assert_eq "running apply mutates" 1 "$policy_decision_mutation_allowed"

decision_fixture
policy_recorded_status=legacy; policy_recorded_classification=legacy; policy_recorded_lifecycle_state=running
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_decide exec
assert_eq "running matching legacy proceeds" start-in-place "$policy_decision_kind"
assert_eq "running matching legacy does not recreate" 0 "$policy_decision_mutation_allowed"

decision_fixture
policy_recorded_status=stale; policy_recorded_classification=stale; policy_recorded_lifecycle_state=stopped
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_decide rebuild
assert_eq "stale rebuild requires Git input" refuse "$policy_decision_kind"
assert_eq "stale rebuild requires reconciliation" 1 "$policy_decision_explicit_apply_required"
policy_git_source=cli
policy_decide rebuild
assert_eq "explicit Git input rebuilds" build-recreate "$policy_decision_kind"
assert_eq "explicit Git input permits mutation" 1 "$policy_decision_mutation_allowed"
policy_decision build
assert_eq "build alias uses shared decision" build-recreate "$policy_decision_kind"

decision_fixture
policy_recorded_status=invalid; policy_recorded_classification=invalid; policy_recorded_lifecycle_state=stopped
policy_decide config
assert_eq "invalid config reports only" report-only "$policy_decision_kind"
assert_eq "invalid config blocks update" 0 "$policy_decision_update_allowed"

# Every command family consumes the same base decision, and every non-ready operation overlay
# must suppress mutation/update consistently. Keep this matrix explicit so a new command cannot
# accidentally bypass the shared gate while tests cover only `exec`.
for _mode in start exec rebuild; do
  decision_fixture
  policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
  policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
  policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
  policy_decide "$_mode"
  if [ "$_mode" = rebuild ]; then _expected_kind=build-recreate; else _expected_kind=start-in-place; fi
  assert_eq "$_mode complete-ready base decision" "$_expected_kind" "$policy_decision_kind"
  assert_eq "$_mode complete-ready allows execution or build" 1 "$([ "$_mode" = rebuild ] && echo "$policy_decision_mutation_allowed" || echo "$policy_decision_execution_allowed")"
done
decision_fixture
policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
policy_decide config
assert_eq "config complete-ready remains report-only" report-only "$policy_decision_kind"

for _overlay in in-progress removal-failed absent-after-failure network-degraded readiness-failed; do
  for _mode in start exec rebuild; do
    decision_fixture
    policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
    policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
    policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
    policy_operation_status="$_overlay"
    policy_decide "$_mode"
    assert_eq "$_overlay blocks $_mode" refuse "$policy_decision_kind"
    assert_eq "$_overlay blocks $_mode mutation" 0 "$policy_decision_mutation_allowed"
    assert_eq "$_overlay blocks $_mode update" 0 "$policy_decision_update_allowed"
  done
  decision_fixture
  policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
  policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
  policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
  policy_operation_status="$_overlay"
  policy_decide config
  assert_eq "$_overlay config remains report-only" report-only "$policy_decision_kind"
  assert_eq "$_overlay config blocks update" 0 "$policy_decision_update_allowed"
done

decision_fixture
policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
policy_decide exec
policy_operation_status=in-progress
policy_decide exec
assert_eq "in-progress overlay refuses" refuse "$policy_decision_kind"
assert_eq "in-progress blocks explicit exec" blocked "$policy_decision_explicit_exec_mode"
assert_eq "in-progress blocks update" 0 "$policy_decision_update_allowed"

for _operation_status in removal-failed absent-after-failure; do
  policy_operation_status="$_operation_status"
  policy_decide exec
  assert_eq "$_operation_status overlay refuses" refuse "$policy_decision_kind"
  assert_eq "$_operation_status blocks mutation" 0 "$policy_decision_mutation_allowed"
  assert_eq "$_operation_status blocks update" 0 "$policy_decision_update_allowed"
done

policy_operation_status=complete; policy_readiness_result=ready
policy_decide exec
assert_eq "complete ready overlay uses base decision" start-in-place "$policy_decision_kind"
assert_eq "complete ready overlay permits exec" allowed "$policy_decision_explicit_exec_mode"

decision_fixture
policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"; policy_operation_status=network-degraded
policy_decide exec
assert_eq "degraded overlay refuses ordinary exec" refuse "$policy_decision_kind"
assert_eq "degraded overlay permits diagnostics" diagnostic-only "$policy_decision_explicit_exec_mode"

policy_recorded_lifecycle_state=stopped; policy_readiness_result=failed-but-running
policy_decide exec
assert_eq "failed readiness blocks stopped diagnostics" blocked "$policy_decision_explicit_exec_mode"
assert_eq "failed readiness blocks mutation" 0 "$policy_decision_mutation_allowed"

# Exercise the complete base-state matrix, including both lifecycle states and the explicit
# start-apply column. These cases intentionally call only the shared decision function: Docker,
# update, network, and execution helpers are not available to this layer.
decision_matrix_case() {
  local name="$1" classification="$2" lifecycle="$3" mode="$4" apply="$5" expected="$6"
  decision_fixture
  policy_recorded_classification="$classification"
  policy_recorded_status="$classification"
  policy_recorded_lifecycle_state="$lifecycle"
  policy_apply="$apply"
  if [ "$classification" = valid ] || [ "$classification" = legacy ]; then
    policy_recorded_git_enabled=1
    policy_recorded_grant_gh=0
    policy_recorded_grant_all_of_dot_ssh=0
    policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
  fi
  if [[ "$name" = *mismatch* ]]; then
    policy_grant_gh=1
    if [ "$classification" = valid ]; then
      policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
    fi
  fi
  policy_decide "$mode"
  assert_eq "$name apply state" "$apply" "$policy_apply"
  assert_eq "$name" "$expected" "$policy_decision_kind"
}

for _state in absent legacy valid stale invalid; do
  case "$_state" in
    absent) _lifecycle=absent ;;
    legacy|valid) _lifecycle=stopped ;;
    stale|invalid) _lifecycle=stopped ;;
  esac
  if [ "$_state" = absent ]; then
    decision_matrix_case "$_state start" "$_state" "$_lifecycle" start 0 create
    decision_matrix_case "$_state exec" "$_state" "$_lifecycle" exec 0 create
    decision_matrix_case "$_state rebuild" "$_state" "$_lifecycle" rebuild 0 build-recreate
  elif [ "$_state" = stale ] || [ "$_state" = invalid ]; then
    decision_matrix_case "$_state start refuses" "$_state" "$_lifecycle" start 0 refuse
    decision_matrix_case "$_state exec refuses" "$_state" "$_lifecycle" exec 0 refuse
    decision_matrix_case "$_state rebuild requires Git input" "$_state" "$_lifecycle" rebuild 0 refuse
  else
    if [ "$_state" = legacy ]; then
      decision_matrix_case "$_state stopped start" "$_state" "$_lifecycle" start 0 reconcile-stopped
      decision_matrix_case "$_state stopped exec" "$_state" "$_lifecycle" exec 0 reconcile-stopped
    else
      decision_matrix_case "$_state stopped start" "$_state" "$_lifecycle" start 0 start-in-place
      decision_matrix_case "$_state stopped exec" "$_state" "$_lifecycle" exec 0 start-in-place
    fi
    decision_matrix_case "$_state stopped rebuild" "$_state" "$_lifecycle" rebuild 0 build-recreate
  fi
  decision_matrix_case "$_state config" "$_state" "$_lifecycle" config 0 report-only
done
decision_matrix_case "valid stopped mismatch" valid stopped start 0 reconcile-stopped
decision_matrix_case "valid stopped mismatch apply" valid stopped start 1 reconcile-stopped
decision_matrix_case "valid running matching" valid running start 0 start-in-place
decision_matrix_case "valid running matching exec" valid running exec 0 start-in-place
decision_matrix_case "valid running mismatch refuses" valid running start 0 refuse
decision_matrix_case "valid running mismatch apply" valid running start 1 reconcile-running
decision_matrix_case "valid running mismatch exec refuses" valid running exec 0 refuse
decision_matrix_case "legacy running matching" legacy running exec 0 start-in-place
decision_matrix_case "legacy running mismatch refuses" legacy running start 0 refuse
decision_matrix_case "legacy running mismatch apply" legacy running start 1 reconcile-running

# Readiness is independently meaningful from the operation status. Pin both explicit-exec modes
# and the refusal reason for each failed readiness outcome, including a usable running outer
# container and an unavailable stopped one.
for _readiness in failed-but-running failed-and-exited; do
  decision_fixture
  policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
  policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
  policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
  policy_readiness_result="$_readiness"
  policy_decide exec
  assert_eq "$_readiness readiness refuses" refuse "$policy_decision_kind"
  assert_eq "$_readiness running diagnostics" diagnostic-only "$policy_decision_explicit_exec_mode"
  assert_eq "$_readiness reason" "readiness-$_readiness" "$policy_decision_reason_code"
  policy_recorded_lifecycle_state=stopped
  policy_decide exec
  assert_eq "$_readiness stopped diagnostics blocked" blocked "$policy_decision_explicit_exec_mode"
done

# An ordinary/convenience refusal must stop before the Docker mount check, lifecycle start, or
# final execution boundary. This is the command-side proof for the overlay gate, complementing
# the pure matrix above.
_saved_gate_mount_fn="$(declare -f require_jj_state_mount)"
_saved_gate_running_fn="$(declare -f is_running)"
_saved_gate_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_gate_grants_recheck_fn="$(declare -f grant_sources_recheck)"
_saved_gate_grants_validate_fn="$(declare -f grant_sources_validate_snapshot)"
# These helpers terminate the isolated command with a sentinel if the refusal gate is bypassed.
# The expected status remains policy refusal (1), so any attempted lifecycle or Docker boundary
# is an immediate test failure without relying on state mutated inside a command substitution.
require_jj_state_mount() { exit 77; }
is_running() { exit 77; }
policy_resolution_recheck() { return 0; }
grant_sources_recheck() { return 0; }
grant_sources_validate_snapshot() { return 0; }
policy_operation_requested=1; policy_explicit_exec_command=0
decision_fixture
policy_recorded_status=valid; policy_recorded_classification=valid; policy_recorded_lifecycle_state=running
policy_recorded_git_enabled=1; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
policy_operation_status=in-progress; policy_readiness_result=not-applicable
policy_decide exec
(_out="$(cmd_exec convenience 2>&1)"; _rc=$?; [ "$_rc" = 1 ])
assert_eq "refused convenience command exits" 0 "$?"
unset -f require_jj_state_mount is_running policy_resolution_recheck grant_sources_recheck grant_sources_validate_snapshot
eval "$_saved_gate_mount_fn"; eval "$_saved_gate_running_fn"; eval "$_saved_gate_recheck_fn"
eval "$_saved_gate_grants_recheck_fn"; eval "$_saved_gate_grants_validate_fn"
policy_operation_requested=0

# Explicit `ab exec` may reach Docker for diagnostics when the outer container is still running;
# convenience commands must not inherit that exception. Override only the final Docker call so
# this proves the command handoff without starting Docker or replacing the test process.
_saved_diag_docker_fn="$(declare -f docker)"
_saved_diag_require_fn="$(declare -f require_jj_state_mount)"
_saved_diag_running_fn="$(declare -f is_running)"
_saved_diag_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_diag_grants_recheck_fn="$(declare -f grant_sources_recheck)"
_saved_diag_grants_validate_fn="$(declare -f grant_sources_validate_snapshot)"
mock_exec_args=()
docker() { mock_exec_args=("$@"); return 0; }
require_jj_state_mount() { :; }
is_running() { return 0; }
policy_resolution_recheck() { return 0; }
grant_sources_recheck() { return 0; }
grant_sources_validate_snapshot() { return 0; }
policy_operation_requested=1
policy_explicit_exec_command=1
policy_operation_status=network-degraded
policy_readiness_result=not-applicable
policy_recorded_lifecycle_state=running
policy_decide exec
cmd_exec diagnostics >/dev/null 2>&1
assert_eq "diagnostic explicit exec reaches Docker boundary" exec "${mock_exec_args[0]}"
assert_eq "diagnostic explicit exec reaches requested command" 1 \
  "$(printf '%s\n' "${mock_exec_args[@]}" | grep -c 'diagnostics')"
policy_explicit_exec_command=0
(_out="$(cmd_exec blocked 2>&1)"; _rc=$?; [ "$_rc" = 1 ])
assert_eq "convenience path stays blocked during degradation" 0 "$?"
unset -f docker require_jj_state_mount is_running policy_resolution_recheck grant_sources_recheck grant_sources_validate_snapshot
eval "$_saved_diag_docker_fn"
eval "$_saved_diag_require_fn"
eval "$_saved_diag_running_fn"
eval "$_saved_diag_recheck_fn"
eval "$_saved_diag_grants_recheck_fn"
eval "$_saved_diag_grants_validate_fn"
policy_operation_requested=0

# Invoke every required launcher entry point through `main`, rather than only testing the shared
# decision function. The mocked preflight represents an in-progress Task 7 operation and refuses
# before any post-gate helper can run; the sentinel helpers make a bypass observable.
_saved_entry_parse_runtime_fn="$(declare -f parse_runtime_options)"
_saved_entry_parse_exec_fn="$(declare -f parse_exec_options)"
_saved_entry_parse_convenience_fn="$(declare -f parse_convenience_options)"
_saved_entry_operation_begin_fn="$(declare -f policy_operation_begin)"
_saved_entry_preflight_fn="$(declare -f policy_preflight)"
_saved_entry_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_entry_update_fn="$(declare -f check_for_update)"
_saved_entry_start_fn="$(declare -f cmd_start)"
_saved_entry_exec_fn="$(declare -f cmd_exec)"
_saved_entry_require_sysbox_fn="$(declare -f require_sysbox)"
_saved_entry_build_fn="$(declare -f build_image)"
_saved_entry_docker_fn="$(declare -f docker)"
_saved_entry_network_fn="$(declare -f connect_networks)"
_entry_log="$(mktemp)"
entry_overlay=in-progress
parse_runtime_options() { printf 'parse-runtime:%s\n' "$1" >>"$_entry_log"; }
parse_exec_options() {
  printf 'parse-exec\n' >>"$_entry_log"
  policy_explicit_exec_command=1
  policy_command_args=(diagnostics)
}
parse_convenience_options() {
  printf 'parse-convenience:%s\n' "$1" >>"$_entry_log"
  policy_explicit_exec_command=0
  policy_command_args=("$1")
}
policy_operation_begin() { printf 'operation-begin\n' >>"$_entry_log"; return 0; }
policy_preflight() {
  printf 'preflight:%s\n' "$1" >>"$_entry_log"
  policy_decision_update_allowed=0
  if [ "$entry_overlay" = network-degraded ] && [ "$policy_explicit_exec_command" = 1 ]; then
    policy_decision_kind=refuse
    policy_decision_explicit_exec_mode="diagnostic-only"
    return 0
  fi
  return 1
}
policy_resolution_recheck() { printf 'resolution-recheck:%s\n' "$1" >>"$_entry_log"; return 0; }
check_for_update() { printf 'update\n' >>"$_entry_log"; return 0; }
cmd_start() { printf 'post-start\n' >>"$_entry_log"; return 0; }
cmd_exec() { printf 'post-exec:%s\n' "$*" >>"$_entry_log"; return 0; }
require_sysbox() { printf 'post-sysbox\n' >>"$_entry_log"; return 0; }
build_image() { printf 'post-build\n' >>"$_entry_log"; return 1; }
docker() { printf 'post-docker:%s\n' "$*" >>"$_entry_log"; return 1; }
connect_networks() { printf 'post-network\n' >>"$_entry_log"; return 0; }

entry_run() {
  : >"$_entry_log"
  ( set -e; main "$@" ) >/dev/null 2>&1
}

for _entry_spec in "start:start" "build:rebuild" "rebuild:rebuild" \
                   "claude:exec" "codex:exec" "bash:exec" "exec:exec"; do
  IFS=: read -r _entry_command _entry_mode <<<"$_entry_spec"
  entry_overlay=in-progress
  entry_run "$_entry_command"
  _entry_rc=$?
  assert_eq "main $_entry_command refuses in-progress operation" 2 "$_entry_rc"
  assert_eq "main $_entry_command invokes $_entry_mode preflight" 1 \
    "$(grep -c "^preflight:$_entry_mode$" "$_entry_log")"
  assert_eq "main $_entry_command has no post-gate side effect" 0 \
    "$(grep -Ec '^post-|^update$' "$_entry_log")"
done

# The explicit `exec` entry point is the one permitted exception: a degraded running outer
# container reaches the diagnostic command boundary, while the ordinary matrix above remains
# refused. This also proves the main-dispatch path preserves explicit-exec authority.
entry_overlay=network-degraded
entry_run exec
_entry_rc=$?
assert_eq "main exec allows diagnostic overlay" 0 "$_entry_rc"
assert_eq "main exec diagnostic reaches command boundary" 1 \
  "$(grep -c '^post-exec:diagnostics$' "$_entry_log")"
assert_eq "main exec diagnostic skips update" 0 "$(grep -c '^update$' "$_entry_log")"

rm -f "$_entry_log"
unset -f parse_runtime_options parse_exec_options parse_convenience_options policy_operation_begin
unset -f policy_preflight policy_resolution_recheck check_for_update cmd_start cmd_exec
unset -f require_sysbox build_image docker connect_networks
eval "$_saved_entry_parse_runtime_fn"; eval "$_saved_entry_parse_exec_fn"
eval "$_saved_entry_parse_convenience_fn"; eval "$_saved_entry_operation_begin_fn"
eval "$_saved_entry_preflight_fn"; eval "$_saved_entry_recheck_fn"; eval "$_saved_entry_update_fn"
eval "$_saved_entry_start_fn"; eval "$_saved_entry_exec_fn"
eval "$_saved_entry_require_sysbox_fn"; eval "$_saved_entry_build_fn"
eval "$_saved_entry_docker_fn"; eval "$_saved_entry_network_fn"
policy_operation_requested=0

echo
echo "Task 7 durable operation records and lifecycle handoff (bin/ab)"
_task7_state="$(mktemp -d)"
_saved_task7_xdg="${XDG_STATE_HOME:-}"
_saved_task7_identity="${lock_identity:-}"
_saved_task7_cname="$cname"; _saved_task7_dvol="$dvol"; _saved_task7_jvol="$jvol"
XDG_STATE_HOME="$_task7_state"
lock_identity="$(printf task7 | sha256sum | cut -d' ' -f1)"
cname=agentbox-task7; dvol=agentbox-docker-task7; jvol=agentbox-jj-task7
policy_resolved_effective[digest]=sha256:task7digest
operation_record_begin
_task7_record="$operation_record_path"
assert_eq "record directory mode" 700 "$(stat -c '%a' "$(dirname "$_task7_record")")"
assert_eq "record file mode" 600 "$(stat -c '%a' "$_task7_record")"
assert_eq "record starts before lifecycle" in-progress "$(sed -n 's/^status = "\(.*\)"$/\1/p' "$_task7_record")"
assert_eq "record has no policy path or token" 0 "$(grep -Ec 'policy-file|credential|token|secret' "$_task7_record")"
assert_eq "record uses stable identity path" "$_task7_state/agentbox/operations/$lock_identity.toml" "$_task7_record"
operation_phase=removal
operation_old_container_id=old-id
operation_record_failure removal-failed "docker rm failed" >/dev/null 2>&1
if [ -f "$_task7_record" ]; then _task7_file_rc=0; else _task7_file_rc=1; fi
assert_eq "removal failure leaves record" 0 "$_task7_file_rc"
assert_eq "removal failure is terminal" removal-failed "$(sed -n 's/^status = "\(.*\)"$/\1/p' "$_task7_record")"
operation_record_load
assert_eq "failed record feeds decision overlay" removal-failed "$policy_operation_status"
operation_phase=completion; operation_readiness_result=ready
operation_record_terminal complete pass ""
if [ -f "$_task7_record" ]; then _task7_file_rc=0; else _task7_file_rc=1; fi
assert_eq "complete record is cleaned up" 1 "$_task7_file_rc"

# Existing operation records are trusted only when their grammar, required fields, and outcome
# contract are valid. A malformed or semantically corrupt record is an explicit blocking state;
# it must identify the record and point at the repair/retry path instead of being treated as absent.
printf 'status = "in-progress"\nnot-a-record =\n' >"$_task7_record"
operation_record_load
assert_eq "malformed record is invalid" invalid-record "$policy_operation_status"
assert_eq "malformed record names path" 1 "$(printf '%s' "$operation_diagnostic" | grep -c "$_task7_record")"
assert_eq "malformed record gives retry" 1 "$(printf '%s' "$operation_diagnostic" | grep -c 'ab start --apply')"
policy_recorded_classification=valid; policy_recorded_lifecycle_state=stopped
policy_decide start
assert_eq "invalid record refuses start" refuse "$policy_decision_kind"
assert_eq "invalid record blocks mutation" 0 "$policy_decision_mutation_allowed"
assert_eq "invalid record blocks execution" 0 "$policy_decision_execution_allowed"
assert_eq "invalid record blocks updates" 0 "$policy_decision_update_allowed"
assert_eq "invalid record requires explicit apply" 1 "$policy_decision_explicit_apply_required"
operation_record_begin
sed -i 's/readiness_result = "not-applicable"/readiness_result = "corrupt"/' "$_task7_record"
operation_record_load
assert_eq "invalid readiness is invalid record" invalid-record "$policy_operation_status"
assert_eq "invalid readiness names path" 1 "$(printf '%s' "$operation_diagnostic" | grep -c "$_task7_record")"
rm -f "$_task7_record"

operation_old_container_id=old-id; operation_new_container_id=new-id
assert_eq "result includes old container id" 1 "$(operation_result_record | grep -c '^old_container_id=old-id$')"
assert_eq "result includes new container id" 1 "$(operation_result_record | grep -c '^new_container_id=new-id$')"

# Pre-removal failures use only the contract's terminal statuses: removal-failed when the old
# container remains, absent-after-failure when no old container exists. All such failures block
# both execution authorities and forbid cleanup.
_saved_task7_failure_exists_fn="$(declare -f exists 2>/dev/null || true)"
task7_old_present=1
exists() { [ "$task7_old_present" = 1 ]; }
operation_record_begin
operation_phase=creation
operation_record_failure "$(operation_failure_status_before_removal)" "image build failed" >/dev/null 2>&1
assert_eq "old-container failure status" removal-failed "$(sed -n 's/^status = \"\(.*\)\"$/\1/p' "$_task7_record")"
assert_eq "old-container failure blocks agent" blocked "$(sed -n 's/^agent_execution = \"\(.*\)\"$/\1/p' "$_task7_record")"
assert_eq "old-container failure blocks explicit" blocked "$(sed -n 's/^explicit_exec = \"\(.*\)\"$/\1/p' "$_task7_record")"
assert_eq "old-container failure forbids cleanup" forbidden "$(sed -n 's/^record_cleanup = \"\(.*\)\"$/\1/p' "$_task7_record")"
task7_old_present=0
operation_record_begin
operation_phase=creation
operation_record_failure "$(operation_failure_status_before_removal)" "container creation failed" >/dev/null 2>&1
assert_eq "absent-container failure status" absent-after-failure "$(sed -n 's/^status = \"\(.*\)\"$/\1/p' "$_task7_record")"
assert_eq "absent-container failure blocks agent" blocked "$(sed -n 's/^agent_execution = \"\(.*\)\"$/\1/p' "$_task7_record")"
assert_eq "absent-container failure forbids cleanup" forbidden "$(sed -n 's/^record_cleanup = \"\(.*\)\"$/\1/p' "$_task7_record")"
unset -f exists
[ -n "$_saved_task7_failure_exists_fn" ] && eval "$_saved_task7_failure_exists_fn"
rm -f "$_task7_record"

# Post-create verification must validate the complete Task 4 specification and the three
# lifecycle-preserved mounts, not just policy labels. Exercise a valid snapshot, then force mode,
# project-source, and named-volume mismatches and confirm they cannot reach completion.
_saved_task7_inspect_fn="$(declare -f policy_inspect_recorded)"
_saved_task7_mount_source_decl="$(declare -p mount_spec_source)"
_saved_task7_mount_destination_decl="$(declare -p mount_spec_destination)"
_saved_task7_mount_state_decl="$(declare -p mount_spec_state)"
_saved_task7_git_enabled="$policy_git_enabled"
_saved_task7_grant_gh="$policy_grant_gh"
_saved_task7_grant_ssh="$policy_grant_all_of_dot_ssh"
_saved_task7_mount_consistency="$policy_mount_consistency"
_saved_task7_project="$PROJECT_DIR"
policy_git_enabled=0; policy_grant_gh=0; policy_grant_all_of_dot_ssh=0
mount_spec_reset
mount_spec_set git_blocker /tmp/git-disabled /usr/bin/git ro
task7_verify_blocker_mode=ro; task7_verify_project_source=/srv/project; task7_verify_jj_name="$jvol"
# Human-authorized exception: this mock exports mount arrays to sourced bin/ab code.
# shellcheck disable=SC2034
policy_inspect_recorded() {
  policy_container_snapshot_reset
  policy_container_snapshot_ready=1
  policy_recorded_status=valid; policy_recorded_classification=valid
  policy_recorded_lifecycle_state=running; policy_recorded_mount_consistency=matching
  policy_recorded_git_enabled=0; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
  policy_recorded_digest="sha256:$(policy_digest_for 0 0 0)"
  policy_container_snapshot_mount_sources[/usr/bin/git]=/tmp/git-disabled
  policy_container_snapshot_mount_modes[/usr/bin/git]="$task7_verify_blocker_mode"
  policy_container_snapshot_mount_types[/usr/bin/git]=bind
  policy_container_snapshot_mount_sources[/workspace]="$task7_verify_project_source"
  policy_container_snapshot_mount_modes[/workspace]=rw
  policy_container_snapshot_mount_types[/workspace]=bind
  policy_container_snapshot_mount_sources[/var/lib/docker]=/var/lib/docker/volumes/agentbox-docker-task7/_data
  policy_container_snapshot_mount_modes[/var/lib/docker]=rw
  policy_container_snapshot_mount_names[/var/lib/docker]="$dvol"
  policy_container_snapshot_mount_types[/var/lib/docker]=volume
  policy_container_snapshot_mount_sources[/home/agentbox/.config/jj]=/var/lib/docker/volumes/agentbox-jj-task7/_data
  policy_container_snapshot_mount_modes[/home/agentbox/.config/jj]=rw
  policy_container_snapshot_mount_names[/home/agentbox/.config/jj]="$task7_verify_jj_name"
  policy_container_snapshot_mount_types[/home/agentbox/.config/jj]=volume
}
PROJECT_DIR=/srv/project
policy_verify_applied_state >/dev/null 2>&1; _task7_verify_rc=$?
assert_eq "complete mount snapshot verifies" 0 "$_task7_verify_rc"
task7_verify_blocker_mode=rw
policy_verify_applied_state >/dev/null 2>&1; _task7_verify_rc=$?
assert_eq "mount mode mismatch rejects completion" 1 "$_task7_verify_rc"
task7_verify_blocker_mode=ro; task7_verify_project_source=/srv/other-project
policy_verify_applied_state >/dev/null 2>&1; _task7_verify_rc=$?
assert_eq "project source mismatch rejects completion" 1 "$_task7_verify_rc"
task7_verify_project_source=/srv/project; task7_verify_jj_name=wrong-jj-volume
operation_record_begin; operation_phase=completion
if policy_verify_applied_state >/dev/null 2>&1; then
  _task7_verify_rc=0
else
  operation_record_failure absent-after-failure "post-create mount verification failed" >/dev/null 2>&1
  _task7_verify_rc=1
fi
assert_eq "named-volume mismatch blocks completion" 1 "$_task7_verify_rc"
assert_eq "mount mismatch leaves terminal record" absent-after-failure "$(sed -n 's/^status = \"\(.*\)\"$/\1/p' "$_task7_record")"

# Use the production policy inspection and snapshot parser rather than the unit mock. The
# verifier must retain that one Docker snapshot long enough to compare mounts, then clear it.
eval "$_saved_task7_inspect_fn"
_saved_task7_verifier_docker_fn="$(declare -f docker 2>/dev/null || true)"
mount_spec_reset
mount_spec_set git_blocker "$GIT_BLOCKER" /usr/bin/git ro
docker() {
  case "$1" in
    inspect)
      printf 'lifecycle=running\n'
      printf 'label=org.agentbox.policy.version=1\n'
      printf 'label=org.agentbox.policy.git_enabled=false\n'
      printf 'label=org.agentbox.policy.github_grant=false\n'
      printf 'label=org.agentbox.policy.ssh_grant_all=false\n'
      printf 'label=org.agentbox.policy.digest=sha256:%s\n' "$(policy_digest_for 0 0 0)"
      printf 'mount=/usr/bin/git\t%s\t\tbind\tfalse\n' "$GIT_BLOCKER"
      printf 'mount=/workspace\t/srv/project\t\tbind\ttrue\n'
      printf 'mount=/var/lib/docker\t/var/lib/docker/volumes/%s/_data\t%s\tvolume\ttrue\n' "$dvol" "$dvol"
      printf 'mount=/home/agentbox/.config/jj\t/var/lib/docker/volumes/%s/_data\t%s\tvolume\ttrue\n' "$jvol" "$jvol"
      ;;
  esac
  return 0
}
policy_mount_consistency=unknown
policy_verify_applied_state >/dev/null 2>&1; _task7_verify_rc=$?
assert_eq "production snapshot reaches completion verification" 0 "$_task7_verify_rc"
assert_eq "production snapshot is cleared after verification" 0 "$policy_container_snapshot_ready"
unset -f docker
[ -n "$_saved_task7_verifier_docker_fn" ] && eval "$_saved_task7_verifier_docker_fn"
eval "$_saved_task7_inspect_fn"
eval "$_saved_task7_mount_source_decl"
eval "$_saved_task7_mount_destination_decl"
eval "$_saved_task7_mount_state_decl"
policy_git_enabled="$_saved_task7_git_enabled"; policy_grant_gh="$_saved_task7_grant_gh"
policy_grant_all_of_dot_ssh="$_saved_task7_grant_ssh"; policy_mount_consistency="$_saved_task7_mount_consistency"
PROJECT_DIR="$_saved_task7_project"
rm -f "$_task7_record"

_saved_task7_wait_ready_fn="$(declare -f wait_ready)"
_saved_task7_running_fn="$(declare -f is_running)"
_saved_task7_handoff_fn="$(declare -f readiness_handoff_read)"
wait_ready() { return 1; }
is_running() { return 0; }
readiness_handoff_read() { operation_readiness_diagnostic='handoff unavailable'; return 1; }
readiness_adapter >/dev/null 2>&1; _task7_ready_rc=$?
assert_eq "readiness reports running timeout" 1 "$_task7_ready_rc"
assert_eq "readiness running outcome" failed-but-running "$operation_readiness_result"
is_running() { return 1; }
readiness_adapter >/dev/null 2>&1; _task7_ready_rc=$?
assert_eq "readiness reports exited timeout" 2 "$_task7_ready_rc"
assert_eq "readiness exited outcome" failed-and-exited "$operation_readiness_result"
unset -f wait_ready is_running
unset -f readiness_handoff_read
eval "$_saved_task7_wait_ready_fn"; eval "$_saved_task7_running_fn"; eval "$_saved_task7_handoff_fn"

echo
echo "Task 11 readiness handoff and integrated recovery (bin/ab + entrypoint)"
# The entrypoint writes the nested-daemon handoff and the host adapter must consume it before
# recording a terminal result. Exercise valid, malformed, foreign-operation, and every public
# readiness state without a real Docker daemon, then run cmd_start twice with the real operation
# record and readiness adapter. The fixture keeps the named volumes and policy/credential mounts
# constant across both recovery cycles and records every Docker boundary for no-delete assertions.
_saved_task11_docker_fn="$(declare -f docker 2>/dev/null || true)"
_saved_task11_wait_ready_fn="$(declare -f wait_ready)"
_saved_task11_is_running_fn="$(declare -f is_running)"
_saved_task11_require_sysbox_fn="$(declare -f require_sysbox)"
_saved_task11_require_jj_fn="$(declare -f require_jj_state_mount)"
_saved_task11_warn_fn="$(declare -f warn_legacy_files)"
_saved_task11_exists_fn="$(declare -f exists)"
_saved_task11_build_fn="$(declare -f build_image)"
_saved_task11_prepare_fn="$(declare -f prepare_host_state)"
_saved_task11_policy_mount_fn="$(declare -f add_policy_mounts)"
_saved_task11_user_mount_fn="$(declare -f build_user_mounts)"
_saved_task11_wait_jj_fn="$(declare -f wait_jj_state)"
_saved_task11_verify_fn="$(declare -f policy_verify_applied_state)"
_saved_task11_connect_fn="$(declare -f connect_networks)"
_saved_task11_mutation_fn="$(declare -f operation_mutation_guard)"
_saved_task11_mount_guard_fn="$(declare -f operation_mount_guard)"
_saved_task11_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task11_grant_validate_fn="$(declare -f grant_sources_validate_snapshot)"
_saved_task11_grant_recheck_fn="$(declare -f grant_sources_recheck)"
_saved_task11_state="$(mktemp -d)"
_saved_task11_xdg="${XDG_STATE_HOME:-}"
_saved_task11_identity="${lock_identity:-}"
_saved_task11_cname="$cname"; _saved_task11_dvol="$dvol"; _saved_task11_jvol="$jvol"
_saved_task11_run_args_decl="$(declare -p run_args)"
_saved_task11_mounts_decl="$(declare -p mounts)"
_saved_task11_grant_labels_decl="$(declare -p grant_labels)"
XDG_STATE_HOME="$_saved_task11_state"
lock_identity="$(printf task11-host | sha256sum | cut -d' ' -f1)"
cname=agentbox-task11; dvol=agentbox-docker-task11; jvol=agentbox-jj-task11
operation_id=task11-host-operation
_task11_handoff_operation_id=task11-host-operation
_task11_handoff_state=ready
_task11_handoff_retryable=0
_task11_handoff_replacement=0
_task11_handoff_evidence=launched
_task11_handoff_wait_attempts=4
_task11_handoff_bound=30
_task11_handoff_diagnostic=
_task11_handoff_malformed=0
docker() {
  case "${1:-}" in
    exec)
      if [ "$_task11_handoff_malformed" = 1 ]; then
        printf 'not-a-key-value-line\n'
        return 0
      fi
      printf 'operation_id=%s\n' "$_task11_handoff_operation_id"
      printf 'state=%s\n' "$_task11_handoff_state"
      printf 'retryable=%s\n' "$_task11_handoff_retryable"
      printf 'replacement_attempted=%s\n' "$_task11_handoff_replacement"
      printf 'daemon_evidence=%s\n' "$_task11_handoff_evidence"
      printf 'wait_attempts=%s\n' "$_task11_handoff_wait_attempts"
      printf 'wait_bound_seconds=%s\n' "$_task11_handoff_bound"
      printf 'diagnostic=%s\n' "$_task11_handoff_diagnostic"
      ;;
    inspect)
      printf 'AGENTBOX_OPERATION_ID=task11-container-operation\n'
      ;;
    run) : ;;
  esac
  return 0
}
readiness_handoff_read
assert_eq "valid handoff operation id" task11-host-operation "$operation_readiness_operation_id"
assert_eq "valid handoff state" ready "$operation_readiness_handoff_state"
assert_eq "valid handoff daemon evidence" launched "$operation_readiness_daemon_evidence"
assert_eq "valid handoff wait bound" 30 "$operation_readiness_wait_bound_seconds"
wait_ready() { return 0; }
readiness_adapter >/dev/null 2>&1; _task11_adapter_rc=$?
assert_eq "valid handoff reaches ready" 0 "$_task11_adapter_rc"
assert_eq "adapter preserves ready state" ready "$operation_readiness_result"
eval "$_saved_task11_wait_ready_fn"

# API readiness can precede the atomic producer write. The host must reread the handoff and
# accept the same startup once the producer publishes ready, rather than recording a false
# failure from the transient starting snapshot.
_saved_task11_handoff_docker_fn="$(declare -f docker)"
_saved_task11_host_sleep_fn="$(declare -f readiness_host_sleep)"
_saved_task11_host_attempts="$READINESS_WAIT_ATTEMPTS"
_saved_task11_host_interval="$READINESS_WAIT_INTERVAL"
_task11_host_state_reads=0
_task11_host_state_reads_file="$_saved_task11_state/handoff-reads"
printf '0\n' >"$_task11_host_state_reads_file"
docker() {
  if [ "$1" = exec ] && [ "$2" = --user ]; then
    _task11_host_state_reads=$(<"$_task11_host_state_reads_file")
    _task11_host_state_reads=$((_task11_host_state_reads + 1))
    printf '%s\n' "$_task11_host_state_reads" >"$_task11_host_state_reads_file"
    if [ "$_task11_host_state_reads" -eq 1 ]; then
      printf 'operation_id=task11-host-operation\nstate=starting\nretryable=1\n'
      printf 'replacement_attempted=0\ndaemon_evidence=launched\nwait_attempts=4\n'
    else
      printf 'operation_id=task11-host-operation\nstate=ready\nretryable=0\n'
      printf 'replacement_attempted=0\ndaemon_evidence=launched\nwait_attempts=5\n'
    fi
    printf 'wait_bound_seconds=30\ndiagnostic=\n'
    return 0
  fi
  [ "$1" = exec ] && return 0
  return 1
}
readiness_host_sleep() { :; }
READINESS_WAIT_ATTEMPTS=3; READINESS_WAIT_INTERVAL=0
wait_ready >/dev/null 2>&1; _task11_delayed_ready_rc=$?
_task11_host_state_reads=$(<"$_task11_host_state_reads_file")
assert_eq "delayed handoff publication reaches ready" 0 "$_task11_delayed_ready_rc"
assert_eq "delayed handoff is reread" 2 "$_task11_host_state_reads"
assert_eq "delayed handoff ends ready" ready "$operation_readiness_handoff_state"
unset -f docker readiness_host_sleep
eval "$_saved_task11_handoff_docker_fn"; eval "$_saved_task11_host_sleep_fn"
READINESS_WAIT_ATTEMPTS="$_saved_task11_host_attempts"
READINESS_WAIT_INTERVAL="$_saved_task11_host_interval"

_task11_handoff_operation_id=foreign-operation
_task11_handoff_state=ready
readiness_adapter >/dev/null 2>&1; _task11_adapter_rc=$?
assert_eq "foreign handoff fails closed" 2 "$_task11_adapter_rc"
assert_eq "foreign handoff reports exited" failed-and-exited "$operation_readiness_result"
assert_eq "foreign handoff is diagnosed" 1 "$(printf '%s' "$operation_readiness_diagnostic" | grep -c 'does not match')"

_task11_handoff_operation_id=task11-host-operation
_task11_handoff_state=ready
_task11_handoff_bound=29
readiness_handoff_read >/dev/null 2>&1; _task11_handoff_rc=$?
assert_eq "wrong readiness bound fails closed" 1 "$_task11_handoff_rc"
assert_eq "wrong readiness bound is diagnosed" 1 "$(printf '%s' "$operation_readiness_diagnostic" | grep -c 'unexpected readiness bound')"
_task11_handoff_bound=30
_task11_handoff_malformed=1
readiness_handoff_read >/dev/null 2>&1; _task11_handoff_rc=$?
assert_eq "malformed handoff fails closed" 1 "$_task11_handoff_rc"
assert_eq "malformed handoff is diagnosed" 1 "$(printf '%s' "$operation_readiness_diagnostic" | grep -c 'malformed line')"
_task11_handoff_malformed=0

# Run the real host lifecycle helper twice. The state fixture is emitted by the Docker exec seam
# exactly as agentbox-entrypoint.sh emits it, while Docker run captures the operation id and all
# mounts. No volume removal is available in this recovery path, and both named volumes plus the
# Git/credential policy mounts must be identical on the second operation.
require_sysbox() { :; }; require_jj_state_mount() { :; }; warn_legacy_files() { :; }
exists() { return 1; }; is_running() { return 1; }
build_image() { printf '%s' agentbox:task11-image; }
prepare_host_state() { :; }; add_policy_mounts() { :; }; build_user_mounts() { :; }
wait_jj_state() { :; }; policy_verify_applied_state() { return 0; }
connect_networks() { operation_connect_network_status=ok; return 0; }
operation_mutation_guard() { return 0; }; operation_mount_guard() { return 0; }
policy_resolution_recheck() { return 0; }
grant_sources_validate_snapshot() { return 0; }; grant_sources_recheck() { return 0; }
wait_ready() { return 0; }
run_args=(--runtime=sysbox-runc)
mounts=(-v "$dvol:/var/lib/docker" -v "$jvol:/home/agentbox/.config/jj"
        -v "/host/gh:/home/agentbox/.config/gh:rw"
        -v "/host/ssh:/home/agentbox/.ssh:ro")
grant_labels=()
policy_operation_requested=1; policy_decision_kind=create; policy_needs_recreate=0
operation_record_active=0; policy_resolved_effective[digest]=sha256:task11
_task11_trace="$_saved_task11_state/docker.trace"; : >"$_task11_trace"
docker() {
  printf 'docker:%s\n' "$*" >>"$_task11_trace"
  case "${1:-}" in
    exec)
      printf 'operation_id=%s\n' "$operation_id"
      printf 'state=ready\nretryable=0\nreplacement_attempted=0\n'
      printf 'daemon_evidence=replacement\nwait_attempts=6\nwait_bound_seconds=30\n'
      printf 'diagnostic=\n'
      ;;
    inspect) printf 'new-task11-container-id\n' ;;
    run) _task11_run_args=("$@"); ;;
  esac
  return 0
}
cmd_start >"$_saved_task11_state/first-report" 2>&1; _task11_start_rc=$?
_task11_first_id="$operation_id"
assert_eq "integrated recovery succeeds" 0 "$_task11_start_rc"
assert_eq "integrated report is ready" 1 "$(grep -c '^readiness=ready$' "$_saved_task11_state/first-report")"
assert_eq "integrated report carries daemon evidence" 1 \
  "$(grep -c '^readiness_daemon_evidence=replacement$' "$_saved_task11_state/first-report")"
assert_eq "integrated report carries wait bound" 1 \
  "$(grep -c '^readiness_wait_bound_seconds=30$' "$_saved_task11_state/first-report")"
assert_eq "first run passes operation id" 1 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -c "AGENTBOX_OPERATION_ID=$_task11_first_id")"
assert_eq "first run preserves inner volume" 1 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -c "$dvol:/var/lib/docker")"
assert_eq "first run preserves jj volume" 1 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -c "$jvol:/home/agentbox/.config/jj")"
assert_eq "first run preserves GitHub grant mount" 1 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -c '/home/agentbox/.config/gh:rw')"
assert_eq "first run preserves SSH grant mount" 1 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -c '/home/agentbox/.ssh:ro')"

operation_record_reset_result; policy_operation_requested=1; policy_decision_kind=create
cmd_start >"$_saved_task11_state/second-report" 2>&1; _task11_start_rc=$?
_task11_second_id="$operation_id"
assert_eq "second recovery succeeds" 0 "$_task11_start_rc"
assert_eq "recovery gets fresh operation id" 1 "$([ "$_task11_first_id" != "$_task11_second_id" ] && echo 1 || echo 0)"
assert_eq "recovery preserves inner volume" 1 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -c "$dvol:/var/lib/docker")"
assert_eq "recovery preserves jj volume" 1 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -c "$jvol:/home/agentbox/.config/jj")"
assert_eq "recovery preserves credential boundaries" 2 \
  "$(printf '%s\n' "${_task11_run_args[@]}" | grep -Ec '/home/agentbox/\.config/gh:rw|/home/agentbox/\.ssh:ro')"
assert_eq "recovery performs no volume removal" 0 \
  "$(grep -Ec 'docker:(volume|rm)' "$_task11_trace" || true)"

# A failed recovery keeps the detailed handoff in the durable Task 7 record, where the Task 8
# projection and Task 9 report reload it without consulting the private state file again.
operation_record_reset_result; operation_record_begin
operation_phase=nested-readiness; operation_readiness_result=failed-and-exited
operation_readiness_operation_id=task11-failed-container
operation_readiness_retryable=1; operation_readiness_replacement_attempted=1
operation_readiness_daemon_evidence=replacement-exited
operation_readiness_wait_attempts=60; operation_readiness_wait_bound_seconds=30
operation_readiness_diagnostic="replacement daemon exited before readiness"
operation_record_failure readiness-failed "$operation_readiness_diagnostic" >/dev/null 2>&1 || true
operation_record_load
assert_eq "stored handoff state reloads" failed-and-exited "$operation_state_readiness_state"
assert_eq "stored handoff evidence reloads" replacement-exited "$operation_state_readiness_daemon_evidence"
assert_eq "stored handoff retryability reloads" 1 "$operation_state_readiness_retryable"
assert_eq "stored handoff diagnostic reloads" "$operation_readiness_diagnostic" \
  "$operation_state_readiness_diagnostic"
rm -f "$operation_record_path"

# Every readiness enum is carried through the public report vocabulary, not only the ready path.
for _task11_report_state in starting replacement-attempted ready failed-but-running failed-and-exited; do
  operation_state_reset
  policy_operation_mode=status; operation_record_active=1
  operation_record_path="$_saved_task11_state/report.toml"; operation_id=task11-report
  operation_record_container_name="$cname"; operation_record_inner_docker_volume="$dvol"
  operation_record_jj_volume="$jvol"; operation_readiness_result="$_task11_report_state"
  operation_readiness_operation_id=task11-report
# Human-authorized exception: operation_result_record consumes these globals through the
# sourced report path, which ShellCheck cannot follow across the test seam.
# shellcheck disable=SC2034
  operation_readiness_retryable=1
  # shellcheck disable=SC2034
  operation_readiness_replacement_attempted=0
  operation_readiness_daemon_evidence=live-dockerd
  # shellcheck disable=SC2034
  operation_readiness_wait_attempts=60; operation_readiness_wait_bound_seconds=30
  operation_readiness_diagnostic="state fixture"
  case "$_task11_report_state" in
    ready)
      operation_status=complete; operation_task_status=pass; operation_phase=completion
      operation_agent_execution=allowed; operation_explicit_exec=allowed
      operation_record_cleanup=permitted; operation_readiness_result=ready
      # shellcheck disable=SC2034
      operation_readiness_retryable=0
      ;;
    starting|replacement-attempted)
      operation_status=in-progress; operation_task_status=fail; operation_phase=nested-readiness
      operation_agent_execution=blocked; operation_explicit_exec=blocked
      operation_record_cleanup=forbidden
      ;;
    *)
      operation_status=readiness-failed; operation_task_status=fail; operation_phase=nested-readiness
      operation_agent_execution=blocked; operation_explicit_exec=diagnostic-only
      operation_record_cleanup=forbidden
      ;;
  esac
  policy_operation_status="$operation_status"; policy_readiness_result="$operation_readiness_result"
  _task11_public_report="$(operation_result_record)"
  assert_eq "public report exposes $_task11_report_state" 1 \
    "$(printf '%s\n' "$_task11_public_report" | grep -c "^readiness=$_task11_report_state$")"
  assert_eq "public report keeps $_task11_report_state evidence" 1 \
    "$(printf '%s\n' "$_task11_public_report" | grep -c '^readiness_daemon_evidence=live-dockerd$')"
done
operation_state_reset

unset -f docker wait_ready is_running exists require_sysbox require_jj_state_mount warn_legacy_files
unset -f build_image prepare_host_state add_policy_mounts build_user_mounts wait_jj_state
unset -f policy_verify_applied_state connect_networks operation_mutation_guard operation_mount_guard
unset -f policy_resolution_recheck grant_sources_validate_snapshot grant_sources_recheck
eval "$_saved_task11_docker_fn"; eval "$_saved_task11_wait_ready_fn"; eval "$_saved_task11_is_running_fn"
eval "$_saved_task11_require_sysbox_fn"; eval "$_saved_task11_require_jj_fn"; eval "$_saved_task11_warn_fn"
eval "$_saved_task11_exists_fn"; eval "$_saved_task11_build_fn"; eval "$_saved_task11_prepare_fn"
eval "$_saved_task11_policy_mount_fn"; eval "$_saved_task11_user_mount_fn"; eval "$_saved_task11_wait_jj_fn"
eval "$_saved_task11_verify_fn"; eval "$_saved_task11_connect_fn"; eval "$_saved_task11_mutation_fn"
eval "$_saved_task11_mount_guard_fn"
eval "$_saved_task11_recheck_fn"; eval "$_saved_task11_grant_validate_fn"; eval "$_saved_task11_grant_recheck_fn"
rm -rf "$_saved_task11_state"
if [ -n "$_saved_task11_xdg" ]; then XDG_STATE_HOME="$_saved_task11_xdg"; else unset XDG_STATE_HOME; fi
lock_identity="$_saved_task11_identity"; cname="$_saved_task11_cname"
dvol="$_saved_task11_dvol"; jvol="$_saved_task11_jvol"
eval "$_saved_task11_run_args_decl"; eval "$_saved_task11_mounts_decl"; eval "$_saved_task11_grant_labels_decl"

_task7_networks="$(mktemp)"
printf '%s\n' optional-net >"$_task7_networks"
_saved_task7_cfg_networks="$cfg_networks"
_saved_task7_network_docker_fn="$(declare -f docker)"
cfg_networks="$_task7_networks"
docker() {
  case "$1" in
    network)
      case "$2" in
        inspect) return 1 ;;
        connect) return 1 ;;
      esac
      ;;
  esac
  return 0
}
connect_networks >/dev/null 2>&1
assert_eq "optional network failure is degraded" degraded "$operation_connect_network_status"
assert_eq "network failure is recorded" optional-net=failed "$operation_network_outcomes"
cfg_networks="$_saved_task7_cfg_networks"
unset -f docker
eval "$_saved_task7_network_docker_fn"
rm -f "$_task7_networks"

# A stopped container whose recorded policy matches is started in place. The production command
# path must still build the expected policy mount specification before verification; exercise all
# persisted GitHub/SSH grant combinations with real Git-config and grant-source files.
_saved_task7_inplace_home="$HOME"
_saved_task7_inplace_git_enabled="$policy_git_enabled"
_saved_task7_inplace_grant_gh="$policy_grant_gh"
_saved_task7_inplace_grant_ssh="$policy_grant_all_of_dot_ssh"
_saved_task7_inplace_digest="${policy_resolved_effective[digest]:-}"
_saved_task7_inplace_require_fn="$(declare -f require_sysbox)"
_saved_task7_inplace_jj_mount_fn="$(declare -f require_jj_state_mount)"
_saved_task7_inplace_warn_fn="$(declare -f warn_legacy_files)"
_saved_task7_inplace_running_fn="$(declare -f is_running)"
_saved_task7_inplace_exists_fn="$(declare -f exists)"
_saved_task7_inplace_build_fn="$(declare -f build_image)"
_saved_task7_inplace_wait_jj_fn="$(declare -f wait_jj_state)"
_saved_task7_inplace_ready_fn="$(declare -f readiness_adapter)"
_saved_task7_inplace_verify_fn="$(declare -f policy_verify_applied_state)"
_saved_task7_inplace_connect_fn="$(declare -f connect_networks)"
_saved_task7_inplace_final_fn="$(declare -f policy_final_mutation_guard)"
_saved_task7_inplace_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task7_inplace_grant_validate_fn="$(declare -f grant_sources_validate_snapshot)"
_saved_task7_inplace_grant_recheck_fn="$(declare -f grant_sources_recheck)"
_saved_task7_inplace_docker_fn="$(declare -f docker)"
_task7_inplace_home="$(mktemp -d)"
mkdir -p "$_task7_inplace_home/.config/gh" "$_task7_inplace_home/.ssh"
printf '[user]\n\tname = Task Seven\n' >"$_task7_inplace_home/.gitconfig"
printf 'github.example ssh-ed25519 AAAA\n' >"$_task7_inplace_home/.ssh/known_hosts"
chmod 700 "$_task7_inplace_home/.config/gh" "$_task7_inplace_home/.ssh"
chmod 600 "$_task7_inplace_home/.gitconfig" "$_task7_inplace_home/.ssh/known_hosts"
HOME="$_task7_inplace_home"
require_sysbox() { :; }; require_jj_state_mount() { :; }; warn_legacy_files() { :; }
is_running() { return 1; }; exists() { return 0; }; build_image() { return 1; }
wait_jj_state() { :; }; readiness_adapter() { operation_readiness_result=ready; return 0; }
policy_verify_applied_state() {
  [ "${mount_spec_state[git_config]}" = ro ] || return 1
  if [ "$_task7_expected_gh" = 1 ]; then
    [ "${mount_spec_state[github_config]}" = rw ] || return 1
  else
    [ "${mount_spec_state[github_config]}" = absent ] || return 1
  fi
  if [ "$_task7_expected_ssh" = 1 ]; then
    [ "${mount_spec_state[ssh_dir]}" = ro ] || return 1
    [ "${mount_spec_state[known_hosts]}" = rw ] || return 1
  else
    [ "${mount_spec_state[ssh_dir]}" = absent ] || return 1
    [ "${mount_spec_state[known_hosts]}" = absent ] || return 1
  fi
}
connect_networks() { operation_connect_network_status=ok; return 0; }
policy_final_mutation_guard() { :; }; policy_resolution_recheck() { :; }
grant_sources_validate_snapshot() { :; }; grant_sources_recheck() { :; }
docker() {
  case "$1" in
    inspect)
      case "$3" in
        *Config.Image*) printf 'agentbox:stopped-image\n' ;;
        *Id*) printf 'stopped-container-id\n' ;;
      esac
      ;;
    start) : ;;
  esac
  return 0
}
policy_git_enabled=1
policy_resolved_effective[digest]=sha256:task7-in-place
policy_operation_mode=start; policy_operation_retry=0; policy_operation_requested=1
policy_decision_kind=start-in-place; policy_decision_execution_allowed=1; policy_decision_mutation_allowed=1
policy_needs_recreate=0; operation_record_active=0; operation_record_path=""
for _task7_expected_gh in 0 1; do
  for _task7_expected_ssh in 0 1; do
    policy_grant_gh="$_task7_expected_gh"
    policy_grant_all_of_dot_ssh="$_task7_expected_ssh"
    mount_spec_reset
    cmd_start >/dev/null 2>&1; _task7_inplace_rc=$?
    assert_eq "stopped matching start $_task7_expected_gh/$_task7_expected_ssh returns" 0 "$_task7_inplace_rc"
    if [ -f "$operation_record_path" ]; then _task7_file_rc=0; else _task7_file_rc=1; fi
    assert_eq "stopped matching start $_task7_expected_gh/$_task7_expected_ssh cleans record" 1 "$_task7_file_rc"
  done
done
unset -f require_sysbox require_jj_state_mount warn_legacy_files is_running exists build_image
unset -f wait_jj_state readiness_adapter policy_verify_applied_state connect_networks
unset -f policy_final_mutation_guard policy_resolution_recheck grant_sources_validate_snapshot grant_sources_recheck docker
eval "$_saved_task7_inplace_require_fn"; eval "$_saved_task7_inplace_jj_mount_fn"; eval "$_saved_task7_inplace_warn_fn"
eval "$_saved_task7_inplace_running_fn"; eval "$_saved_task7_inplace_exists_fn"; eval "$_saved_task7_inplace_build_fn"
eval "$_saved_task7_inplace_wait_jj_fn"; eval "$_saved_task7_inplace_ready_fn"; eval "$_saved_task7_inplace_verify_fn"
eval "$_saved_task7_inplace_connect_fn"; eval "$_saved_task7_inplace_final_fn"; eval "$_saved_task7_inplace_recheck_fn"
eval "$_saved_task7_inplace_grant_validate_fn"; eval "$_saved_task7_inplace_grant_recheck_fn"; eval "$_saved_task7_inplace_docker_fn"
HOME="$_saved_task7_inplace_home"
policy_git_enabled="$_saved_task7_inplace_git_enabled"
policy_grant_gh="$_saved_task7_inplace_grant_gh"
policy_grant_all_of_dot_ssh="$_saved_task7_inplace_grant_ssh"
policy_resolved_effective[digest]="$_saved_task7_inplace_digest"
rm -rf "$_task7_inplace_home"

# A replacement writes its in-progress record before docker run and removes it only after every
# verification/readiness phase succeeds. This uses the real cmd_start sequencing with only Docker
# and unrelated host/runtime boundaries mocked.
_saved_task7_require_fn="$(declare -f require_sysbox)"
_saved_task7_jj_mount_fn="$(declare -f require_jj_state_mount)"
_saved_task7_warn_fn="$(declare -f warn_legacy_files)"
_saved_task7_running_fn="$(declare -f is_running)"
_saved_task7_exists_fn="$(declare -f exists)"
_saved_task7_build_fn="$(declare -f build_image)"
_saved_task7_prepare_fn="$(declare -f prepare_host_state)"
_saved_task7_policy_mount_fn="$(declare -f add_policy_mounts)"
_saved_task7_user_mount_fn="$(declare -f build_user_mounts)"
_saved_task7_wait_jj_fn="$(declare -f wait_jj_state)"
_saved_task7_ready_fn="$(declare -f readiness_adapter)"
_saved_task7_verify_fn="$(declare -f policy_verify_applied_state)"
_saved_task7_connect_fn="$(declare -f connect_networks)"
_saved_task7_final_fn="$(declare -f policy_final_mutation_guard)"
_saved_task7_mount_guard_fn="$(declare -f policy_final_mount_guard)"
_saved_task7_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task7_grant_validate_fn="$(declare -f grant_sources_validate_snapshot)"
_saved_task7_grant_recheck_fn="$(declare -f grant_sources_recheck)"
_saved_task7_docker_fn="$(declare -f docker)"
_task7_events="$(mktemp)"
require_sysbox() { :; }; require_jj_state_mount() { :; }; warn_legacy_files() { :; }
task7_running=0; task7_exists=0
is_running() { [ "$task7_running" = 1 ]; }; exists() { [ "$task7_exists" = 1 ]; }
build_image() { printf '%s' agentbox:task7-image; }
prepare_host_state() { :; }; add_policy_mounts() { :; }; build_user_mounts() { :; }
wait_jj_state() { :; }; readiness_adapter() { operation_readiness_result=ready; return 0; }
policy_verify_applied_state() { :; }; connect_networks() { operation_connect_network_status=ok; return 0; }
policy_final_mutation_guard() { :; }; policy_final_mount_guard() { :; }
policy_resolution_recheck() { :; }; grant_sources_validate_snapshot() { :; }; grant_sources_recheck() { :; }
docker() {
  case "$1" in
    run)
      test -f "$operation_record_path" && printf 'record-before-run\n' >>"$_task7_events"
      printf 'run\n' >>"$_task7_events"
      ;;
    stop|rm)
      test -f "$operation_record_path" && printf 'record-before-%s\n' "$1" >>"$_task7_events"
      printf '%s\n' "$1" >>"$_task7_events"
      ;;
    inspect) printf 'new-id\n' ;;
  esac
  return 0
}
XDG_STATE_HOME="$_task7_state"; lock_identity="$(printf task7-lifecycle | sha256sum | cut -d' ' -f1)"
operation_record_active=0; policy_operation_requested=1; policy_decision_kind=create
policy_decision_execution_allowed=1; policy_needs_recreate=0; operation_record_path=""
cmd_start >/dev/null 2>&1; _task7_start_rc=$?
assert_eq "successful replacement returns" 0 "$_task7_start_rc"
assert_eq "record precedes docker run" "record-before-run" "$(sed -n '1p' "$_task7_events")"
if [ -f "$operation_record_path" ]; then _task7_file_rc=0; else _task7_file_rc=1; fi
assert_eq "successful replacement removes record" 1 "$_task7_file_rc"
task7_running=1; task7_exists=1; policy_needs_recreate=1; operation_record_active=0
: >"$_task7_events"
cmd_start >/dev/null 2>&1; _task7_apply_rc=$?
assert_eq "running apply returns" 0 "$_task7_apply_rc"
assert_eq "running apply stops before remove" $'record-before-stop\nstop\nrecord-before-rm\nrm\nrecord-before-run\nrun' "$(sed -n '1,6p' "$_task7_events")"
if [ -f "$operation_record_path" ]; then _task7_file_rc=0; else _task7_file_rc=1; fi
assert_eq "running apply removes completed record" 1 "$_task7_file_rc"
unset -f require_sysbox require_jj_state_mount warn_legacy_files is_running exists build_image
unset -f prepare_host_state add_policy_mounts build_user_mounts wait_jj_state readiness_adapter
unset -f policy_verify_applied_state connect_networks policy_final_mutation_guard policy_final_mount_guard
unset -f policy_resolution_recheck grant_sources_validate_snapshot grant_sources_recheck docker
eval "$_saved_task7_require_fn"; eval "$_saved_task7_jj_mount_fn"; eval "$_saved_task7_warn_fn"
eval "$_saved_task7_running_fn"; eval "$_saved_task7_exists_fn"; eval "$_saved_task7_build_fn"
eval "$_saved_task7_prepare_fn"; eval "$_saved_task7_policy_mount_fn"; eval "$_saved_task7_user_mount_fn"
eval "$_saved_task7_wait_jj_fn"; eval "$_saved_task7_ready_fn"; eval "$_saved_task7_verify_fn"
eval "$_saved_task7_connect_fn"; eval "$_saved_task7_final_fn"; eval "$_saved_task7_mount_guard_fn"
eval "$_saved_task7_recheck_fn"; eval "$_saved_task7_grant_validate_fn"; eval "$_saved_task7_grant_recheck_fn"
eval "$_saved_task7_docker_fn"
rm -f "$_task7_events"
XDG_STATE_HOME="$_saved_task7_xdg"; lock_identity="$_saved_task7_identity"
cname="$_saved_task7_cname"; dvol="$_saved_task7_dvol"; jvol="$_saved_task7_jvol"
policy_operation_requested=0; operation_record_active=0
rm -rf "$_task7_state"

echo
echo "Task 8 operation-state projection (bin/ab)"
# Task 8 consumes the Task 7 record through one validated projection.  Exercise absent state,
# terminal failure, in-progress readiness transitions, diagnostic-only degradation, invalid input,
# and the no-update/no-cleanup permissions without a Docker daemon.
_task8_state="$(mktemp -d)"
_saved_task8_xdg="${XDG_STATE_HOME:-}"
_saved_task8_identity="${lock_identity:-}"
_saved_task8_cname="$cname"; _saved_task8_dvol="$dvol"; _saved_task8_jvol="$jvol"
_saved_task8_requested="$policy_operation_requested"
XDG_STATE_HOME="$_task8_state"
lock_identity="$(printf task8 | sha256sum | cut -d' ' -f1)"
cname=agentbox-task8; dvol=agentbox-docker-task8; jvol=agentbox-jj-task8
policy_resolved_effective[digest]=sha256:task8digest
policy_operation_requested=1
policy_operation_status=none; policy_readiness_result=not-applicable
operation_record_load
assert_eq "missing record is none" none "$operation_state_terminal_status"
assert_eq "missing record is not-applicable" not-applicable "$operation_state_readiness_state"
assert_eq "missing record permits mutation" 1 "$operation_state_mutation_allowed"
assert_eq "missing record permits update" 1 "$operation_state_update_allowed"
assert_eq "missing record has stable volume projection" \
  "inner_docker=$dvol;jj=$jvol" "$operation_state_named_volumes"

operation_record_begin
_task8_failed_id="$operation_id"
operation_phase=removal; operation_old_container_id=old-task8
operation_record_failure removal-failed "docker rm failed" >/dev/null 2>&1
operation_record_load
assert_eq "failed record projects terminal status" removal-failed "$operation_state_terminal_status"
assert_eq "failed record preserves old identity" old-task8 "$operation_state_old_container_id"
assert_eq "failed record does not authorize current identity" "" "$operation_state_container_id"
assert_eq "failed record blocks execution" 0 "$operation_state_execution_allowed"
assert_eq "failed record blocks mutation" 0 "$operation_state_mutation_allowed"
assert_eq "failed record blocks update" 0 "$operation_state_update_allowed"
assert_eq "failed record forbids cleanup" 0 "$operation_state_cleanup_allowed"
assert_eq "failed record disables diagnostic exec" 0 "$operation_state_diagnostic_allowed"
assert_eq "failed record exposes retry" "ab start --apply" "$operation_state_retry_command"
assert_eq "failed record blocks update helper" 1 "$(operation_state_update_allowed; echo $?)"

rm -f "$operation_record_path"
operation_record_begin
operation_phase=nested-readiness; operation_readiness_result=starting
operation_record_update nested-readiness in-progress "" >/dev/null
operation_record_load
assert_eq "starting readiness is accepted" starting "$operation_state_readiness_state"
assert_eq "starting readiness blocks execution" 0 "$operation_state_execution_allowed"
rm -f "$operation_record_path"
operation_record_begin
operation_phase=nested-readiness; operation_readiness_result=replacement-attempted
operation_record_update nested-readiness in-progress "" >/dev/null
operation_record_load
assert_eq "replacement readiness is accepted" replacement-attempted "$operation_state_readiness_state"
assert_eq "replacement readiness blocks update" 0 "$operation_state_update_allowed"

_saved_task8_running_fn="$(declare -f is_running)"
is_running() { return 0; }
rm -f "$operation_record_path"
operation_record_begin
operation_phase=required-network
operation_record_failure network-degraded "optional network unavailable" >/dev/null 2>&1
operation_record_load
assert_eq "degraded record allows diagnostics" 1 "$operation_state_diagnostic_allowed"
assert_eq "degraded record uses old identity for diagnostics" "" "$operation_state_container_id"
assert_eq "degraded record still blocks updates" 0 "$operation_state_update_allowed"
unset -f is_running; eval "$_saved_task8_running_fn"

printf '%s\n' 'status = "in-progress"' 'unknown_field = "x"' >"$operation_record_path"
operation_record_load
assert_eq "unknown projection field is invalid" invalid-record "$operation_state_terminal_status"
assert_eq "invalid projection blocks mutation" 0 "$operation_state_mutation_allowed"
assert_eq "invalid projection blocks updates" 0 "$operation_state_update_allowed"
assert_eq "invalid projection names record" 1 "$(printf '%s' "$operation_state_diagnostic" | grep -c "$operation_record_path")"

# Cross-field relationships are part of the record contract, not just independent enum checks.
rm -f "$operation_record_path"
operation_record_begin
operation_status=complete; operation_phase=preflight; operation_readiness_result=ready
operation_completed_at="2026-09-13T00:00:00Z"; operation_task_status=pass
operation_agent_execution=allowed; operation_explicit_exec=allowed
operation_record_cleanup=permitted
operation_record_write
operation_record_load
assert_eq "complete preflight handoff is invalid" invalid-record "$operation_state_terminal_status"
assert_eq "cross-field invalid state blocks execution" 0 "$operation_state_execution_allowed"
assert_eq "cross-field invalid state blocks cleanup" 0 "$operation_state_cleanup_allowed"

rm -f "$operation_record_path"
operation_record_begin
operation_status=in-progress; operation_phase=required-network; operation_readiness_result=starting
operation_record_write
operation_record_load
assert_eq "in-progress network readiness mismatch is invalid" invalid-record "$operation_state_terminal_status"
assert_eq "readiness mismatch blocks updates" 0 "$operation_state_update_allowed"

# Keep one valid record on disk to exercise the complete-ready projection without deleting it.
rm -f "$operation_record_path"
operation_record_begin
operation_status=complete; operation_phase=completion; operation_readiness_result=ready
operation_completed_at="2026-09-13T00:00:00Z"; operation_task_status=pass
operation_agent_execution=allowed; operation_explicit_exec=allowed
operation_record_cleanup=permitted
operation_record_write
operation_record_load
assert_eq "completed timestamp is set" "2026-09-13T00:00:00Z" "$operation_completed_at"
assert_eq "complete-ready record is accepted" complete "$operation_state_terminal_status"
assert_eq "complete-ready record permits execution" 1 "$operation_state_execution_allowed"
assert_eq "complete-ready record permits cleanup" 1 "$operation_state_cleanup_allowed"

# The parser rejects duplicate fields, unknown enum values, and malformed permission tuples.
printf '%s\n' 'operation_id = "duplicate"' 'operation_id = "again"' >"$operation_record_path"
operation_record_load
assert_eq "duplicate field is invalid" invalid-record "$operation_state_terminal_status"
operation_record_begin
sed -i 's/status = "in-progress"/status = "unknown"/' "$operation_record_path"
operation_record_load
assert_eq "unknown status is invalid" invalid-record "$operation_state_terminal_status"
operation_record_begin
sed -i 's/readiness_result = "not-applicable"/readiness_result = "unknown"/' "$operation_record_path"
operation_record_load
assert_eq "unknown readiness is invalid" invalid-record "$operation_state_terminal_status"
operation_record_begin
sed -i 's/phase = "preflight"/phase = "unknown"/' "$operation_record_path"
operation_record_load
assert_eq "unknown phase is invalid" invalid-record "$operation_state_terminal_status"
operation_record_begin
sed -i 's/agent_execution = "blocked"/agent_execution = "allowed"/' "$operation_record_path"
operation_record_load
assert_eq "inconsistent permission tuple is invalid" invalid-record "$operation_state_terminal_status"

# An unreadable record is not treated as missing state.
operation_record_begin
chmod 000 "$operation_record_path"
operation_record_load
assert_eq "unreadable record is invalid" invalid-record "$operation_state_terminal_status"
chmod 600 "$operation_record_path"

# Cleanup failure retains a fail-closed record and does not leave complete permissions active.
_saved_task8_rm_fn="$(declare -f rm 2>/dev/null || true)"
rm() { return 1; }
operation_record_begin
operation_phase=completion; operation_readiness_result=ready
operation_record_terminal complete pass "" >/dev/null 2>&1; _task8_cleanup_rc=$?
assert_eq "cleanup failure returns non-zero" 1 "$_task8_cleanup_rc"
assert_eq "cleanup failure leaves record" 1 "$([ -f "$operation_record_path" ] && echo 1 || echo 0)"
assert_eq "cleanup failure blocks execution" 0 "$operation_state_execution_allowed"
assert_eq "cleanup failure blocks cleanup" 0 "$operation_state_cleanup_allowed"
assert_eq "cleanup failure blocks updates" 0 "$operation_state_update_allowed"
assert_eq "cleanup failure is diagnostic" 1 "$(printf '%s' "$operation_state_diagnostic" | grep -c 'cleanup failed')"
unset -f rm; [ -n "$_saved_task8_rm_fn" ] && eval "$_saved_task8_rm_fn"
operation_record_load
assert_eq "retained cleanup failure reloads invalid" invalid-record "$operation_state_terminal_status"
rm -f "$operation_record_path"

# Cover the remaining terminal handoffs and explicit recovery identity.  A recovery consumes the
# failed record, then starts a new operation with the same named volumes and a new operation id.
operation_record_begin
operation_phase=creation
operation_record_failure absent-after-failure "docker run failed" >/dev/null 2>&1
operation_record_load
assert_eq "absent-after-failure projects terminal status" absent-after-failure "$operation_state_terminal_status"
rm -f "$operation_record_path"
_saved_task8_running_fn="$(declare -f is_running)"
is_running() { return 1; }
operation_record_begin
operation_phase=nested-readiness; operation_readiness_result=failed-and-exited
operation_record_failure readiness-failed "nested Docker readiness failed" >/dev/null 2>&1
operation_record_load
assert_eq "readiness failure projects terminal status" readiness-failed "$operation_state_terminal_status"
assert_eq "readiness failure preserves failed state" failed-and-exited "$operation_state_readiness_state"
unset -f is_running; eval "$_saved_task8_running_fn"

rm -f "$operation_record_path"
operation_record_begin
operation_phase=removal; operation_old_container_id=recovery-old
operation_record_failure removal-failed "docker rm failed" >/dev/null 2>&1
_task8_recovery_old_id="$operation_id"
_saved_task8_lock_fn="$(declare -f policy_lock_acquire)"
policy_lock_acquire() { :; }
policy_operation_retry=1
policy_operation_begin
assert_eq "policy retry remains requested" 1 "$policy_operation_retry"
assert_eq "explicit recovery marks reconciliation" 1 "$policy_retry_reconcile"
assert_eq "explicit recovery clears ordinary failure gate" none "$policy_operation_status"
operation_record_begin
assert_eq "recovery creates a fresh operation id" 1 "$([ "$operation_id" != "$_task8_recovery_old_id" ] && echo 1 || echo 0)"
assert_eq "recovery preserves Docker volume identity" "$dvol" "$operation_record_inner_docker_volume"
assert_eq "recovery preserves jj volume identity" "$jvol" "$operation_record_jj_volume"
unset -f policy_lock_acquire; eval "$_saved_task8_lock_fn"

# Read-only and refused command boundaries must not invoke update, Docker, or network work while
# a non-complete state is present.  These mocks exercise the real main dispatch for every
# non-complete/invalid state and the ordinary start/build/rebuild/convenience/exec paths.
_saved_task8_begin_fn="$(declare -f policy_operation_begin)"
_saved_task8_load_fn="$(declare -f policy_load_host)"
_saved_task8_update_fn="$(declare -f check_for_update)"
_saved_task8_preflight_fn="$(declare -f policy_preflight)"
_saved_task8_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task8_config_fn="$(declare -f cmd_config)"
_saved_task8_exists_fn="$(declare -f exists)"
_saved_task8_running_fn="$(declare -f is_running)"
_saved_task8_docker_fn="$(declare -f docker)"
_saved_task8_network_fn="$(declare -f connect_networks)"
_saved_task8_sysbox_fn="$(declare -f require_sysbox)"
_saved_task8_record_begin_fn="$(declare -f operation_record_begin_if_needed)"
_saved_task8_record_update_fn="$(declare -f operation_record_update)"
_saved_task8_mutation_guard_fn="$(declare -f operation_mutation_guard)"
_saved_task8_cmd_start_fn="$(declare -f cmd_start)"
_saved_task8_cmd_exec_fn="$(declare -f cmd_exec)"
_task8_trace="$_task8_state/dispatch.trace"
_task8_record="$operation_record_path"
printf 'stable operation record\n' >"$_task8_record"
_task8_dispatch_state=removal-failed
policy_operation_begin() {
  operation_state_terminal_status=""
  case "$_task8_dispatch_state" in
    in-progress)
      operation_state_phase="nested-readiness"; operation_state_readiness_state=starting
      ;;
    removal-failed|absent-after-failure|network-degraded|invalid-record)
      operation_state_phase="required-network"; operation_state_readiness_state="not-applicable"
      ;;
    readiness-failed-running)
      operation_state_terminal_status="readiness-failed"
      operation_state_phase="nested-readiness"; operation_state_readiness_state="failed-but-running"
      ;;
    readiness-failed-exited)
      operation_state_terminal_status="readiness-failed"
      operation_state_phase="nested-readiness"; operation_state_readiness_state="failed-and-exited"
      ;;
    stale)
      operation_state_terminal_status=none
      operation_state_phase=preflight; operation_state_readiness_state="not-applicable"
      policy_decision_kind=refuse
      policy_decision_reason_code=stale-recorded-state
      ;;
  esac
  [ "$_task8_dispatch_state" = invalid-record ] && operation_state_valid=0 || operation_state_valid=1
  [ "${operation_state_terminal_status:-}" = "" ] &&
    operation_state_terminal_status="$_task8_dispatch_state"
  operation_state_update_allowed=0; operation_state_execution_allowed=0
  operation_state_mutation_allowed=0; operation_state_diagnostic_allowed=0
  operation_state_explicit_exec_mode=blocked; policy_decision_update_allowed=0
  policy_operation_status="$operation_state_terminal_status"
  policy_readiness_result="$operation_state_readiness_state"
  assert_eq "$_task8_dispatch_state publishes a phase" 1 \
    "$([ -n "$operation_state_phase" ] && echo 1 || echo 0)"
  assert_eq "$_task8_dispatch_state blocks explicit exec" blocked \
    "$operation_state_explicit_exec_mode"
  printf 'begin:%s\n' "$operation_state_terminal_status" >>"$_task8_trace"
  return 0
}
policy_load_host() { policy_updates_check=1; printf 'policy-load\n' >>"$_task8_trace"; return 0; }
check_for_update() { printf 'update\n' >>"$_task8_trace"; return 0; }
policy_preflight() { printf 'preflight:%s\n' "$1" >>"$_task8_trace"; return 1; }
policy_resolution_recheck() { printf 'resolution\n' >>"$_task8_trace"; return 0; }
cmd_config() { printf 'config\n' >>"$_task8_trace"; return 0; }
exists() { printf 'exists\n' >>"$_task8_trace"; return 1; }
is_running() { printf 'running\n' >>"$_task8_trace"; return 1; }
docker() { printf 'docker:%s\n' "$1" >>"$_task8_trace"; return 1; }
connect_networks() { printf 'network\n' >>"$_task8_trace"; return 1; }
require_sysbox() { printf 'sysbox\n' >>"$_task8_trace"; return 0; }
operation_record_begin_if_needed() { printf 'record-begin\n' >>"$_task8_trace"; return 0; }
operation_record_update() { printf 'record-update:%s\n' "$1" >>"$_task8_trace"; return 0; }
operation_mutation_guard() { printf 'mutation-guard\n' >>"$_task8_trace"; return 0; }
cmd_start() { printf 'start\n' >>"$_task8_trace"; return 0; }
cmd_exec() { printf 'exec\n' >>"$_task8_trace"; return 0; }

_task8_dispatch_states=(in-progress removal-failed absent-after-failure network-degraded
                        readiness-failed-running readiness-failed-exited stale invalid-record)
_task8_dispatch_commands=(start build rebuild claude codex bash exec)
for _task8_dispatch_state in "${_task8_dispatch_states[@]}"; do
  for _task8_dispatch_cmd in "${_task8_dispatch_commands[@]}"; do
    : >"$_task8_trace"
    _task8_before="$(sha256sum "$_task8_record")"
    case "$_task8_dispatch_cmd" in
      start|build|rebuild) _task8_output="$( ( main "$_task8_dispatch_cmd" ) 2>&1 )"; _task8_rc=$? ;;
      exec) _task8_output="$( ( main exec -- true ) 2>&1 )"; _task8_rc=$? ;;
      *) _task8_output="$( ( main "$_task8_dispatch_cmd" --test ) 2>&1 )"; _task8_rc=$? ;;
    esac
    _task8_after="$(sha256sum "$_task8_record")"
    case "$_task8_dispatch_state" in
      invalid-record) _task8_expected_result="invalid-state" ;;
      *) _task8_expected_result=refused ;;
    esac
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd refuses" 2 "$_task8_rc"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd has one result" 1 \
      "$(printf '%s\n' "$_task8_output" | grep -c '^result=' || true)"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd result vocabulary" 1 \
      "$(printf '%s\n' "$_task8_output" | grep -c "^result=$_task8_expected_result$")"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd reports exit" 1 \
      "$(printf '%s\n' "$_task8_output" | grep -c '^exit_status=2$')"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd reports permissions" 1 \
      "$(printf '%s\n' "$_task8_output" | grep -c '^execution_allowed=')"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd keeps record" \
      "$_task8_before" "$_task8_after"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd avoids Docker" 0 \
      "$(grep -c '^docker:' "$_task8_trace" || true)"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd avoids network" 0 \
      "$(grep -c '^network$' "$_task8_trace" || true)"
    assert_eq "$_task8_dispatch_state/$_task8_dispatch_cmd avoids update" 0 \
      "$(grep -c '^update$' "$_task8_trace" || true)"
  done
done

# Repeated read-only reporting keeps the durable record byte-for-byte unchanged and does not
# invoke Docker, network, or update work.  Each command is run twice through main, not through
# the underlying helper, so the dispatch guarantee is tested at the public boundary.
_task8_dispatch_state=removal-failed
for _task8_read_only_cmd in status logs stop config; do
  : >"$_task8_trace"
  _task8_before="$(sha256sum "$_task8_record")"
  ( main "$_task8_read_only_cmd" >/dev/null 2>&1 ) || true
  ( main "$_task8_read_only_cmd" >/dev/null 2>&1 ) || true
  _task8_after="$(sha256sum "$_task8_record")"
  assert_eq "repeated $_task8_read_only_cmd keeps record" "$_task8_before" "$_task8_after"
  assert_eq "repeated $_task8_read_only_cmd avoids Docker" 0 \
    "$(grep -c '^docker:' "$_task8_trace" || true)"
  assert_eq "repeated $_task8_read_only_cmd avoids network" 0 \
    "$(grep -c '^network$' "$_task8_trace" || true)"
  assert_eq "repeated $_task8_read_only_cmd avoids update" 0 \
    "$(grep -c '^update$' "$_task8_trace" || true)"
done

# Keep the original focused checks explicit: a failed state suppresses update checks for all
# read-only reports, and an ordinary start cannot reach Docker after preflight refusal.
_task8_dispatch_state=removal-failed
_task8_update_calls=0; _task8_docker_calls=0
for _task8_read_only_cmd in status logs stop config; do
  ( main "$_task8_read_only_cmd" >/dev/null 2>&1 ) || true
done
assert_eq "read-only failure reports suppress update checks" 0 \
  "$(grep -c '^update$' "$_task8_trace" || true)"
assert_eq "read-only failure reports avoid Docker" 0 \
  "$(grep -c '^docker:' "$_task8_trace" || true)"
unset -f policy_operation_begin policy_load_host check_for_update policy_preflight
unset -f policy_resolution_recheck cmd_config exists is_running docker connect_networks
unset -f require_sysbox operation_record_begin_if_needed operation_record_update
unset -f operation_mutation_guard cmd_start cmd_exec
eval "$_saved_task8_begin_fn"; eval "$_saved_task8_load_fn"; eval "$_saved_task8_update_fn"
eval "$_saved_task8_preflight_fn"; eval "$_saved_task8_recheck_fn"; eval "$_saved_task8_config_fn"
eval "$_saved_task8_exists_fn"; eval "$_saved_task8_running_fn"; eval "$_saved_task8_docker_fn"
eval "$_saved_task8_network_fn"; eval "$_saved_task8_sysbox_fn"
eval "$_saved_task8_record_begin_fn"; eval "$_saved_task8_record_update_fn"
eval "$_saved_task8_mutation_guard_fn"; eval "$_saved_task8_cmd_start_fn"
eval "$_saved_task8_cmd_exec_fn"

rm -f "$operation_record_path"
policy_operation_requested="$_saved_task8_requested"
XDG_STATE_HOME="$_saved_task8_xdg"; lock_identity="$_saved_task8_identity"
cname="$_saved_task8_cname"; dvol="$_saved_task8_dvol"; jvol="$_saved_task8_jvol"
rm -rf "$_task8_state"

echo
echo "Task 9 command reports (bin/ab)"
# Exercise the public start/stop/config boundaries with a small lifecycle seam. The start mock
# covers the idempotent running case, an early failure before a durable operation record, and a
# complete operation report; the read-only commands prove stop-absent and config-init do not
# start a container or perform unrelated work.
_saved_task9_main_parse_runtime_fn="$(declare -f parse_runtime_options)"
_saved_task9_main_begin_fn="$(declare -f policy_operation_begin)"
_saved_task9_main_load_fn="$(declare -f policy_load_host)"
_saved_task9_main_preflight_fn="$(declare -f policy_preflight)"
_saved_task9_main_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task9_main_update_fn="$(declare -f check_for_update)"
_saved_task9_main_start_fn="$(declare -f cmd_start)"
_saved_task9_main_exec_fn="$(declare -f cmd_exec)"
_saved_task9_main_config_fn="$(declare -f cmd_config)"
_saved_task9_main_init_fn="$(declare -f cmd_config_init)"
_saved_task9_main_exists_fn="$(declare -f exists)"
_saved_task9_main_running_fn="$(declare -f is_running)"
_saved_task9_main_docker_fn="$(declare -f docker)"
_task9_main_trace="$(mktemp)"
task9_main_reset() {
  [ "${_task9_fail_begin:-0}" = 1 ] && return 1
  operation_state_reset
  operation_record_active=0
  operation_status=""
  policy_operation_status=none
  policy_readiness_result=not-applicable
  policy_decision_kind=""
  policy_decision_reason_code=""
  policy_decision_explicit_exec_mode=allowed
  policy_updates_check=0
  operation_state_publish
}
parse_runtime_options() { return 0; }
policy_operation_begin() { task9_main_reset || return 1; return 0; }
policy_load_host() {
  [ "${_task9_fail_load:-0}" = 1 ] && return 1
  policy_updates_check=0
  return 0
}
policy_preflight() { policy_decision_update_allowed=0; return 0; }
policy_resolution_recheck() { return 0; }
check_for_update() { echo update >>"$_task9_main_trace"; }
task9_main_start_mode=no-op
cmd_start() {
  case "$task9_main_start_mode" in
    no-op) return 0 ;;
    fail) return 1 ;;
    complete)
      policy_operation_status=complete
      policy_readiness_result=ready
      operation_phase=completion
      command_report_emit
      return 0
      ;;
  esac
}
_task9_exec_rc=0
cmd_exec() { echo exec >>"$_task9_main_trace"; return "$_task9_exec_rc"; }
cmd_config() { echo config >>"$_task9_main_trace"; return 0; }
cmd_config_init() {
  [ "${1:-}" = --bogus ] && return 1
  echo config-init >>"$_task9_main_trace"
  return 0
}
_task9_exists=0; _task9_running=0; _task9_docker_rc=0
exists() { [ "$_task9_exists" = 1 ]; }
is_running() { [ "$_task9_running" = 1 ]; }
docker() {
  echo "docker:$*" >>"$_task9_main_trace"
  if [ "${1:-}" = logs ]; then
    printf 'bounded log line\n'
    return "$_task9_docker_rc"
  fi
  return 0
}

_task9_main_output="$( ( main start ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public running start succeeds" 0 "$_task9_main_rc"
assert_eq "public running start has one result" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=success$')"
assert_eq "public running start reason" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=already-running$')"

task9_main_start_mode=fail
_task9_main_output="$( ( main start ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public early start failure exits one" 1 "$_task9_main_rc"
assert_eq "public early start failure has one result" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=failed$')"
assert_eq "public early start failure reason" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=start-failed$')"

_task9_fail_begin=1
_task9_stdout="$(mktemp)"; _task9_stderr="$(mktemp)"
( main start >"$_task9_stdout" 2>"$_task9_stderr" ); _task9_main_rc=$?
assert_eq "public lifecycle trap failure exits one" 1 "$_task9_main_rc"
assert_eq "public lifecycle trap report is on stdout" 1 \
  "$(grep -c '^result=failed$' "$_task9_stdout")"
assert_eq "public lifecycle trap report is absent from stderr" 0 \
  "$(grep -c '^result=' "$_task9_stderr" || true)"
rm -f "$_task9_stdout" "$_task9_stderr"
_task9_fail_begin=0

task9_main_start_mode=complete
_task9_main_output="$( ( main start ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public complete start succeeds" 0 "$_task9_main_rc"
for _task9_key in result reason phase container_name container_id operation_id record_path readiness \
  network operation_status task_status agent_execution explicit_exec record_cleanup image_reference \
  named_volumes failed_phase retry_command cleanup_allowed execution_allowed mutation_allowed \
  update_allowed diagnostic_allowed explicit_exec_mode diagnostic exit_status; do
  assert_eq "public complete start has one $_task9_key" 1 \
    "$(printf '%s\n' "$_task9_main_output" | grep -c "^$_task9_key=")"
done

_task9_main_output="$( ( main stop ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public absent stop is a report-only success" 0 "$_task9_main_rc"
assert_eq "public absent stop result" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=report-only$')"
assert_eq "public absent stop reason" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=stop-absent$')"

_task9_main_output="$( ( main config init env ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public config init succeeds" 0 "$_task9_main_rc"
assert_eq "public config init reports success" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=config-init$')"
assert_eq "public config init does not start" 0 "$(grep -c '^start$' "$_task9_main_trace" || true)"
assert_eq "public config init reaches init helper" 1 "$(grep -c '^config-init$' "$_task9_main_trace" || true)"

_task9_main_output="$( ( main config ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public config report succeeds" 0 "$_task9_main_rc"
assert_eq "public config report is report-only" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=report-only$')"
assert_eq "public config report reaches config helper" 1 "$(grep -c '^config$' "$_task9_main_trace" || true)"

_task9_exists=0; _task9_running=0
_task9_main_output="$( ( main status ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public absent status succeeds" 0 "$_task9_main_rc"
assert_eq "public absent status lifecycle" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^outer_lifecycle=absent$')"
_task9_exists=1; _task9_running=0
_task9_main_output="$( ( main status ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public stopped status succeeds" 0 "$_task9_main_rc"
assert_eq "public stopped status lifecycle" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^outer_lifecycle=stopped$')"
_task9_running=1
_task9_main_output="$( ( main status ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public running status succeeds" 0 "$_task9_main_rc"
assert_eq "public running status lifecycle" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^outer_lifecycle=running$')"

_task9_docker_rc=0
_task9_main_output="$( ( main logs ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public logs success" 0 "$_task9_main_rc"
assert_eq "public logs report-only" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=report-only$')"
assert_eq "public logs completion reason" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=logs-complete$')"
assert_eq "public logs output bounded" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^bounded log line$')"
_task9_docker_rc=1
_task9_main_output="$( ( main logs ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public logs failure exits one" 1 "$_task9_main_rc"
assert_eq "public logs failure result" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=failed$')"
assert_eq "public logs failure reason" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=logs-failed$')"

_task9_exec_rc=0
_task9_main_output="$( ( main exec -- true ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public exec success" 0 "$_task9_main_rc"
assert_eq "public exec completion result" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=exec-complete$')"
_task9_exec_rc=7
_task9_main_output="$( ( main exec -- true ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public exec preserves child failure" 7 "$_task9_main_rc"
assert_eq "public exec failure result" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=failed$')"
assert_eq "public exec failure reason" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=exec-failed$')"

# Convenience entry points use the same final-result boundary as explicit exec. Exercise both
# successful and failed children so none of the fixed command names can bypass the shared report.
for _task9_convenience in claude codex bash; do
  _task9_exec_rc=0
  _task9_main_output="$( ( main "$_task9_convenience" --test ) 2>&1 )"; _task9_main_rc=$?
  assert_eq "public $_task9_convenience success" 0 "$_task9_main_rc"
  assert_eq "public $_task9_convenience has one result" 1 \
    "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=success$')"
  assert_eq "public $_task9_convenience completion reason" 1 \
    "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=exec-complete$')"
  _task9_exec_rc=7
  _task9_main_output="$( ( main "$_task9_convenience" --test ) 2>&1 )"; _task9_main_rc=$?
  assert_eq "public $_task9_convenience preserves child failure" 7 "$_task9_main_rc"
  assert_eq "public $_task9_convenience failure result" 1 \
    "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=failed$')"
done

# Build/rebuild also need a public success result. Mock only Docker/lifecycle seams so this tests
# the real dispatch and report ordering without requiring a Sysbox host or image build.
_saved_task9_build_require_fn="$(declare -f require_sysbox)"
_saved_task9_build_record_begin_fn="$(declare -f operation_record_begin_if_needed)"
_saved_task9_build_record_update_fn="$(declare -f operation_record_update)"
_saved_task9_build_mutation_guard_fn="$(declare -f operation_mutation_guard)"
_saved_task9_build_mount_guard_fn="$(declare -f operation_mount_guard)"
_saved_task9_build_image_fn="$(declare -f build_image)"
_saved_task9_build_prepare_fn="$(declare -f prepare_host_state)"
_saved_task9_build_add_mounts_fn="$(declare -f add_policy_mounts)"
_saved_task9_build_user_mounts_fn="$(declare -f build_user_mounts)"
_saved_task9_build_verify_fn="$(declare -f policy_verify_applied_state)"
_saved_task9_build_network_fn="$(declare -f connect_networks)"
_saved_task9_build_ready_fn="$(declare -f readiness_adapter)"
_saved_task9_build_terminal_fn="$(declare -f operation_record_terminal)"
_saved_task9_build_result_fn="$(declare -f operation_result_record)"
_saved_task9_build_prune_fn="$(declare -f prune_images)"
require_sysbox() { :; }
operation_record_begin_if_needed() {
  operation_record_active=1; operation_status=in-progress; operation_phase=preflight
  operation_task_status=fail; operation_readiness_result=not-applicable
  operation_record_cleanup=forbidden; operation_state_publish
}
operation_record_update() {
  operation_phase="$1"; operation_status="$2"; operation_diagnostic="${3:-}"
  operation_state_publish
}
operation_mutation_guard() { return 0; }
operation_mount_guard() { return 0; }
build_image() { printf 'agentbox:task9-test-image'; }
prepare_host_state() { :; }
add_policy_mounts() { :; }
build_user_mounts() { :; }
policy_verify_applied_state() { return 0; }
connect_networks() { operation_connect_network_status=ok; return 0; }
readiness_adapter() { operation_readiness_result=ready; return 0; }
operation_record_terminal() {
  operation_status=complete; operation_task_status=pass; operation_phase=completion
  operation_readiness_result=ready; operation_agent_execution=allowed
  operation_explicit_exec=allowed; operation_record_cleanup=permitted
  operation_state_publish
}
operation_result_record() { command_report_emit; }
prune_images() { :; }
exists() { return 1; }
docker() {
  case "${1:-}" in
    inspect) printf 'task9-build-container-id' ;;
    run) return 0 ;;
    *) return 0 ;;
  esac
}
for _task9_build_command in build rebuild; do
  _task9_main_output="$( ( main "$_task9_build_command" ) 2>&1 )"; _task9_main_rc=$?
  assert_eq "public $_task9_build_command succeeds" 0 "$_task9_main_rc"
  assert_eq "public $_task9_build_command has one result" 1 \
    "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=success$')"
  assert_eq "public $_task9_build_command reports completion" 1 \
    "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=operation-complete$')"
done
eval "$_saved_task9_build_require_fn"
eval "$_saved_task9_build_record_begin_fn"
eval "$_saved_task9_build_record_update_fn"
eval "$_saved_task9_build_mutation_guard_fn"
eval "$_saved_task9_build_mount_guard_fn"
eval "$_saved_task9_build_image_fn"
eval "$_saved_task9_build_prepare_fn"
eval "$_saved_task9_build_add_mounts_fn"
eval "$_saved_task9_build_user_mounts_fn"
eval "$_saved_task9_build_verify_fn"
eval "$_saved_task9_build_network_fn"
eval "$_saved_task9_build_ready_fn"
eval "$_saved_task9_build_terminal_fn"
eval "$_saved_task9_build_result_fn"
eval "$_saved_task9_build_prune_fn"

_task9_fail_begin=1
_task9_main_output="$( ( main status ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public operation-load failure exits one" 1 "$_task9_main_rc"
assert_eq "public operation-load failure reports" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=failed$')"
_task9_fail_begin=0; _task9_fail_load=1
_task9_main_output="$( ( main status ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public host-load failure exits one" 1 "$_task9_main_rc"
assert_eq "public host-load failure reports" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=failed$')"
_task9_fail_load=0
_task9_main_output="$( ( main config init --bogus ) 2>&1 )"; _task9_main_rc=$?
assert_eq "public config-init option failure exits one" 1 "$_task9_main_rc"
assert_eq "public config-init option failure reports" 1 "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=config-init-failed$')"

rm -f "$_task9_main_trace"
unset -f parse_runtime_options policy_operation_begin policy_load_host policy_preflight
unset -f policy_resolution_recheck check_for_update cmd_start cmd_exec cmd_config cmd_config_init
unset -f exists is_running docker
eval "$_saved_task9_main_parse_runtime_fn"
eval "$_saved_task9_main_begin_fn"; eval "$_saved_task9_main_load_fn"
eval "$_saved_task9_main_preflight_fn"; eval "$_saved_task9_main_recheck_fn"
eval "$_saved_task9_main_update_fn"; eval "$_saved_task9_main_start_fn"
eval "$_saved_task9_main_exec_fn"
eval "$_saved_task9_main_config_fn"; eval "$_saved_task9_main_init_fn"
eval "$_saved_task9_main_exists_fn"; eval "$_saved_task9_main_running_fn"
eval "$_saved_task9_main_docker_fn"

# Exercise running readiness failures through all diagnostic-safe read-only commands. The record
# hash proves status/logs/stop do not erase or rewrite the durable failure state, while logs still
# exposes bounded diagnostics and stop remains available to recover the outer container.
_saved_task9_readiness_begin_fn="$(declare -f policy_operation_begin)"
_saved_task9_readiness_load_fn="$(declare -f policy_load_host)"
_saved_task9_readiness_exists_fn="$(declare -f exists)"
_saved_task9_readiness_running_fn="$(declare -f is_running)"
_saved_task9_readiness_docker_fn="$(declare -f docker)"
_task9_readiness_record="$(mktemp)"
printf 'readiness failure record\n' >"$_task9_readiness_record"
_task9_readiness_trace="$(mktemp)"
# Human-authorized exception: this fixture exports report globals to sourced bin/ab code.
# shellcheck disable=SC2034
task9_readiness_fixture() {
  policy_operation_requested=1
  operation_state_reset
  operation_record_active=1; operation_status="readiness-failed"
  operation_phase=nested-readiness; operation_readiness_result="${_task9_readiness_kind:-failed-but-running}"
  operation_task_status=fail; operation_agent_execution=blocked
  operation_explicit_exec="diagnostic-only"; operation_record_cleanup=forbidden
  operation_record_path="$_task9_readiness_record"
  operation_id=task9-readiness; operation_diagnostic="nested daemon is not ready"
  operation_retry_command="ab start --apply"; operation_failed_phase=nested-readiness
  policy_operation_status="readiness-failed"
  policy_readiness_result="${_task9_readiness_kind:-failed-but-running}"
  policy_recorded_lifecycle_state=running
  operation_state_publish
}
policy_operation_begin() { task9_readiness_fixture; return 0; }
policy_load_host() { policy_updates_check=0; return 0; }
exists() { return 0; }
is_running() { return 0; }
docker() {
  printf 'docker:%s\n' "$*" >>"$_task9_readiness_trace"
  case "${1:-}" in
    logs) printf 'bounded nested-daemon diagnostic\n'; return 0 ;;
    stop) return 0 ;;
    *) return 0 ;;
  esac
}
_task9_readiness_before="$(sha256sum "$_task9_readiness_record")"
_task9_main_output="$( ( main status ) 2>&1 )"; _task9_main_rc=$?
assert_eq "running readiness status remains available" 1 "$_task9_main_rc"
assert_eq "running readiness status reports failure" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=failed$')"
assert_eq "running readiness status names state" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^readiness=failed-but-running$')"
_task9_main_output="$( ( main logs ) 2>&1 )"; _task9_main_rc=$?
assert_eq "running readiness logs remains available" 0 "$_task9_main_rc"
assert_eq "running readiness logs is report-only" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^result=report-only$')"
assert_eq "running readiness logs is bounded" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^bounded nested-daemon diagnostic$')"
assert_eq "running readiness logs names failed phase" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^failed_phase=nested-readiness$')"
_task9_main_output="$( ( main stop ) 2>&1 )"; _task9_main_rc=$?
assert_eq "running readiness stop remains available" 0 "$_task9_main_rc"
assert_eq "running readiness stop succeeds distinctly" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^reason=stopped$')"
_task9_readiness_after="$(sha256sum "$_task9_readiness_record")"
assert_eq "readiness reports preserve record" "$_task9_readiness_before" "$_task9_readiness_after"
assert_eq "readiness reports do not remove volumes" 0 \
  "$(grep -Ec 'volume (rm|remove)|docker:volume rm' "$_task9_readiness_trace" || true)"
# The daemon-exited terminal readiness result keeps the outer container available through the
# same three commands and remains bounded/read-only.
_task9_readiness_kind=failed-and-exited
_task9_readiness_before="$(sha256sum "$_task9_readiness_record")"
_task9_main_output="$( ( main status ) 2>&1 )"; _task9_main_rc=$?
assert_eq "exited readiness status remains available" 1 "$_task9_main_rc"
assert_eq "exited readiness status names state" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^readiness=failed-and-exited$')"
_task9_main_output="$( ( main logs ) 2>&1 )"; _task9_main_rc=$?
assert_eq "exited readiness logs remains available" 0 "$_task9_main_rc"
assert_eq "exited readiness logs is bounded" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^bounded nested-daemon diagnostic$')"
_task9_main_output="$( ( main stop ) 2>&1 )"; _task9_main_rc=$?
assert_eq "exited readiness stop remains available" 0 "$_task9_main_rc"
assert_eq "exited readiness stop reports state" 1 \
  "$(printf '%s\n' "$_task9_main_output" | grep -c '^readiness=failed-and-exited$')"
_task9_readiness_after="$(sha256sum "$_task9_readiness_record")"
assert_eq "exited readiness reports preserve record" "$_task9_readiness_before" "$_task9_readiness_after"
_task9_readiness_kind=""
rm -f "$_task9_readiness_record" "$_task9_readiness_trace"
unset -f policy_operation_begin policy_load_host exists is_running docker
eval "$_saved_task9_readiness_begin_fn"; eval "$_saved_task9_readiness_load_fn"
eval "$_saved_task9_readiness_exists_fn"; eval "$_saved_task9_readiness_running_fn"
eval "$_saved_task9_readiness_docker_fn"

# The config report is a public read-only boundary. Four policy tiers contribute independently,
# recorded labels are shown with effective-versus-recorded deltas, and a deliberately named
# credential secret in a policy file must never be copied into the report.
_saved_task9_config_begin_fn="$(declare -f policy_operation_begin)"
_saved_task9_config_load_fn="$(declare -f policy_load_host)"
_saved_task9_config_preflight_fn="$(declare -f policy_preflight)"
_saved_task9_config_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task9_config_inspect_fn="$(declare -f policy_inspect_recorded)"
_saved_task9_config_decide_fn="$(declare -f policy_decide)"
_saved_task9_config_update_fn="$(declare -f check_for_update)"
_task9_config_root="$(mktemp -d)"
_task9_config_machine=task9-machine
_task9_config_project=/work/task9-secret-project
mkdir -p "$_task9_config_root/machines/$_task9_config_machine/projects/work/task9-secret-project" \
  "$_task9_config_root/machines/$_task9_config_machine" \
  "$_task9_config_root/projects/work/task9-secret-project"
printf '[git]\nenabled = false\n' >"$_task9_config_root/agentbox.toml"
printf '[github]\ngrant = true\n' >"$_task9_config_root/machines/$_task9_config_machine/agentbox.toml"
printf '[ssh]\ngrant_all = true\n' >"$_task9_config_root/projects/work/task9-secret-project/agentbox.toml"
printf '[git]\nenabled = true\n# credential-secret-must-not-leak\n' \
  >"$_task9_config_root/machines/$_task9_config_machine/projects/work/task9-secret-project/agentbox.toml"
chmod 600 \
  "$_task9_config_root/agentbox.toml" \
  "$_task9_config_root/machines/$_task9_config_machine/agentbox.toml" \
  "$_task9_config_root/projects/work/task9-secret-project/agentbox.toml" \
  "$_task9_config_root/machines/$_task9_config_machine/projects/work/task9-secret-project/agentbox.toml"
_saved_cfg_root="$AB_CFG_ROOT"; _saved_machine="$MACHINE"; _saved_project="$PROJECT_DIR"
AB_CFG_ROOT="$_task9_config_root"; MACHINE="$_task9_config_machine"; PROJECT_DIR="$_task9_config_project"
cfg_env=""; cfg_mounts=""; cfg_networks=""; cfg_dockerfile=""
_task9_config_invalid=0; _task9_config_update_trace="$(mktemp)"
policy_operation_begin() {
  policy_operation_requested=1; operation_state_reset; operation_record_active=0; operation_status=""
  policy_operation_status=none
  policy_readiness_result=not-applicable; operation_state_publish; return 0
}
# Human-authorized exception: this mock exports policy sources to sourced bin/ab code.
# shellcheck disable=SC2034
policy_load_host() {
  policy_git_enabled=1; policy_grant_gh=1; policy_grant_all_of_dot_ssh=1; policy_updates_check=1
  policy_git_source=machine_project; policy_grant_gh_source=machine
  policy_grant_all_of_dot_ssh_source=project; policy_updates_source=global
  return 0
}
policy_preflight() {
  policy_load_host
  policy_decision_update_allowed=$([ "$_task9_config_invalid" = 1 ] && echo 0 || echo 1)
  return 0
}
policy_resolution_recheck() { return 0; }
# Human-authorized exception: this mock exports policy state to sourced bin/ab code.
# shellcheck disable=SC2034
policy_inspect_recorded() {
  if [ "$_task9_config_invalid" = 1 ]; then
    policy_recorded_status=invalid; policy_recorded_classification=invalid
    policy_recorded_detail='invalid operation record; repair with ab start --apply'
    policy_recorded_lifecycle_state=stopped
    policy_recorded_git_enabled=""; policy_recorded_grant_gh=""; policy_recorded_grant_all_of_dot_ssh=""
    policy_recorded_digest=""
  else
    policy_recorded_status=stale; policy_recorded_classification=stale
    policy_recorded_detail='recorded Git blocker mount contradicts git.enabled'
    policy_recorded_lifecycle_state=stopped
    policy_recorded_git_enabled=0; policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=1
    policy_recorded_digest=sha256:recorded
  fi
  return 0
}
policy_decide() {
  policy_decision_kind=report-only
  policy_decision_reason_code=report-stale
  policy_decision_update_allowed=$([ "$_task9_config_invalid" = 1 ] && echo 0 || echo 1)
  return 0
}
check_for_update() { printf 'update\n' >>"$_task9_config_update_trace"; }
_task9_config_output="$( ( main config ) 2>&1 )"; _task9_config_rc=$?
assert_eq "four-tier config report succeeds" 0 "$_task9_config_rc"
_task9_config_display_root="${_task9_config_root/#"$HOME"/\~}"
for _task9_policy_path in \
  "$_task9_config_display_root/agentbox.toml" \
  "$_task9_config_display_root/machines/$_task9_config_machine/agentbox.toml" \
  "$_task9_config_display_root/projects/work/task9-secret-project/agentbox.toml" \
  "$_task9_config_display_root/machines/$_task9_config_machine/projects/work/task9-secret-project/agentbox.toml"; do
  assert_eq "config reports policy tier $_task9_policy_path" 1 \
    "$(printf '%s\n' "$_task9_config_output" | grep -Fc "$_task9_policy_path")"
done
assert_eq "config reports effective git source" 1 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'git.enabled.*true (source: machine_project)')"
assert_eq "config reports effective GitHub source" 1 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'github.grant.*true (source: machine)')"
assert_eq "config reports effective SSH source" 1 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'ssh.grant_all.*true (source: project)')"
assert_eq "config reports recorded labels" 1 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'recorded values:.*git=false.*github=false.*ssh=true')"
assert_eq "config reports exact mount delta" 1 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'recorded Git blocker mount contradicts git.enabled')"
assert_eq "config reports operation state" 1 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'operation state:.*none')"
assert_eq "config report values align" 1 \
  "$(printf '%s\n' "$_task9_config_output" | awk '
    /^  (git\.enabled|github\.grant|ssh\.grant_all|updates\.check|recorded container:|operation state:|operation retry:|operation diagnostic:|operation permissions:|recorded values:)/ {
      if (substr($0, 26, 1) !~ /[^[:space:]]/ || substr($0, 25, 1) != " ") bad=1
      count++
    }
    END { print count == 10 && !bad ? 1 : 0 }
  ')"
assert_eq "config does not leak policy secret" 0 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'credential-secret-must-not-leak')"
_task9_config_invalid=1; : >"$_task9_config_update_trace"
_task9_config_output="$( ( main config ) 2>&1 )"; _task9_config_rc=$?
assert_eq "invalid config report remains read-only" 0 "$_task9_config_rc"
assert_eq "invalid config suppresses update request" 0 \
  "$(grep -c '^update$' "$_task9_config_update_trace" || true)"
assert_eq "invalid config exposes repair direction" 1 \
  "$(printf '%s\n' "$_task9_config_output" | grep -c 'invalid operation record; repair with ab start --apply')"
rm -rf "$_task9_config_root"; rm -f "$_task9_config_update_trace"
AB_CFG_ROOT="$_saved_cfg_root"; MACHINE="$_saved_machine"; PROJECT_DIR="$_saved_project"
unset -f policy_operation_begin policy_load_host policy_preflight policy_resolution_recheck
unset -f policy_inspect_recorded policy_decide check_for_update
eval "$_saved_task9_config_begin_fn"; eval "$_saved_task9_config_load_fn"
eval "$_saved_task9_config_preflight_fn"; eval "$_saved_task9_config_recheck_fn"
eval "$_saved_task9_config_inspect_fn"; eval "$_saved_task9_config_decide_fn"
eval "$_saved_task9_config_update_fn"

# Repeat invalid-config coverage through the real public preflight and operation-record loader.
# The malformed record must be inspected before the update hook is even eligible; both Docker
# inspection and update attempts are recorded in a file so command-substitution boundaries cannot
# hide a side effect.
_saved_task9_real_home="$HOME"; _saved_task9_real_cfg_root="$AB_CFG_ROOT"
_saved_task9_real_machine="$MACHINE"; _saved_task9_real_project="$PROJECT_DIR"
_saved_task9_real_state_home="${XDG_STATE_HOME-}"
_saved_task9_real_begin_fn="$(declare -f policy_operation_begin)"
_saved_task9_real_load_fn="$(declare -f policy_load_host)"
_saved_task9_real_preflight_fn="$(declare -f policy_preflight)"
_saved_task9_real_inspect_fn="$(declare -f policy_inspect_recorded)"
_saved_task9_real_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task9_real_update_fn="$(declare -f check_for_update)"
_saved_task9_real_docker_fn="$(declare -f docker)"
_task9_real_home="$(mktemp -d)"; _task9_real_state="$(mktemp -d)"
_task9_real_trace="$(mktemp)"
HOME="$_task9_real_home"; AB_CFG_ROOT="$_task9_real_home/config"
MACHINE=task9-invalid; PROJECT_DIR=/work/task9-invalid
XDG_STATE_HOME="$_task9_real_state"; mkdir -p "$XDG_STATE_HOME/agentbox/operations"
policy_cli_git_enabled=""; policy_cli_grant_gh=""; policy_cli_grant_all_of_dot_ssh=""
unset AGENTBOX_NO_GIT AGENTBOX_GRANT_GH AGENTBOX_GRANT_ALL_OF_DOT_SSH AGENTBOX_NO_UPDATE_CHECK
policy_input_reset
_task9_real_record_id="$(policy_lock_identity)"
printf 'unknown_field = "invalid"\n' \
  >"$XDG_STATE_HOME/agentbox/operations/$_task9_real_record_id.toml"
unset -f policy_operation_begin policy_load_host policy_preflight
unset -f policy_inspect_recorded policy_resolution_recheck check_for_update docker
_task9_real_begin_impl="${_saved_task9_real_begin_fn/policy_operation_begin/policy_operation_begin_impl}"
_task9_real_load_impl="${_saved_task9_real_load_fn/policy_load_host/policy_load_host_impl}"
_task9_real_preflight_impl="${_saved_task9_real_preflight_fn/policy_preflight/policy_preflight_impl}"
_task9_real_inspect_impl="${_saved_task9_real_inspect_fn/policy_inspect_recorded/policy_inspect_recorded_impl}"
eval "$_task9_real_begin_impl"; eval "$_task9_real_load_impl"
eval "$_task9_real_preflight_impl"; eval "$_task9_real_inspect_impl"
eval "$_saved_task9_real_recheck_fn"; eval "$_saved_task9_real_update_fn"
policy_resolution_recheck() { return 0; }
policy_operation_begin() {
  printf 'begin\n' >>"$_task9_real_trace"
  policy_operation_begin_impl "$@"
}
policy_load_host() {
  printf 'load\n' >>"$_task9_real_trace"
  policy_load_host_impl "$@"
}
policy_preflight() {
  printf 'preflight\n' >>"$_task9_real_trace"
  policy_preflight_impl "$@"
}
policy_inspect_recorded() {
  printf 'inspect\n' >>"$_task9_real_trace"
  policy_inspect_recorded_impl "$@"
}
check_for_update() { printf 'update\n' >>"$_task9_real_trace"; }
docker() {
  printf 'docker:%s\n' "$*" >>"$_task9_real_trace"
  return 1
}
_task9_real_output="$( ( main config ) 2>&1 )"; _task9_real_rc=$?
assert_eq "real invalid config remains report-only" 0 "$_task9_real_rc"
assert_eq "real invalid config enters operation load" 1 \
  "$(grep -c '^begin$' "$_task9_real_trace")"
assert_eq "real invalid config enters preflight" 1 \
  "$(grep -c '^preflight$' "$_task9_real_trace")"
assert_eq "real invalid config loads policy" 1 \
  "$(grep -c '^load$' "$_task9_real_trace")"
assert_eq "real invalid config runs inspection" 1 \
  "$([ "$(grep -c '^inspect$' "$_task9_real_trace")" -ge 1 ] && echo 1 || echo 0)"
assert_eq "real invalid config inspects container before update" 1 \
  "$([ "$(grep -c '^docker:inspect ' "$_task9_real_trace")" -ge 1 ] && echo 1 || echo 0)"
assert_eq "real invalid config never requests update" 0 \
  "$(grep -c '^update$' "$_task9_real_trace" || true)"
assert_eq "real invalid config reports repair direction" 1 \
  "$([ "$(printf '%s\n' "$_task9_real_output" | grep -c 'invalid operation record')" -ge 1 ] && echo 1 || echo 0)"
rm -rf "$_task9_real_home" "$_task9_real_state"; rm -f "$_task9_real_trace"
HOME="$_saved_task9_real_home"; AB_CFG_ROOT="$_saved_task9_real_cfg_root"
MACHINE="$_saved_task9_real_machine"; PROJECT_DIR="$_saved_task9_real_project"
if [ -n "$_saved_task9_real_state_home" ]; then
  XDG_STATE_HOME="$_saved_task9_real_state_home"
else
  unset XDG_STATE_HOME
fi
unset -f policy_operation_begin policy_load_host policy_preflight
unset -f policy_inspect_recorded policy_resolution_recheck check_for_update docker
eval "$_saved_task9_real_begin_fn"; eval "$_saved_task9_real_load_fn"
eval "$_saved_task9_real_preflight_fn"; eval "$_saved_task9_real_inspect_fn"
eval "$_saved_task9_real_recheck_fn"; eval "$_saved_task9_real_update_fn"
eval "$_saved_task9_real_docker_fn"

# Task 9 reports are derived from the Task 8 projection and use one stable vocabulary/exit
# mapping. Exercise report-only, success, degraded, refusal, and invalid-state outcomes while
# checking that the shared identity/readiness/retry fields are present in every result.
_saved_task9_mode="$policy_operation_mode"
_saved_task9_status="$policy_operation_status"
_saved_task9_readiness="$policy_readiness_result"
_saved_task9_active="$operation_record_active"
_saved_task9_operation_status="$operation_status"
_saved_task9_task_status="$operation_task_status"
_saved_task9_record_path="$operation_record_path"
_saved_task9_operation_id="$operation_id"
_saved_task9_phase="$operation_phase"
_saved_task9_diagnostic="$operation_diagnostic"
_saved_task9_network="$operation_network_outcomes"
_saved_task9_retry="$operation_retry_command"
_saved_task9_cleanup="$operation_record_cleanup"
_saved_task9_valid="$operation_state_valid"
# Human-authorized exception: this fixture exports report state to sourced bin/ab code.
# shellcheck disable=SC2034
task9_report_fixture() {
  policy_operation_mode="$1"
  policy_operation_status="$2"
  policy_readiness_result="$3"
  policy_decision_kind=""
  policy_decision_reason_code=""
  policy_decision_explicit_exec_mode=blocked
  policy_explicit_exec_command=0
  operation_record_active=0
  operation_status=""
  operation_task_status=fail
  operation_record_path=/tmp/agentbox-task9-operation.toml
  operation_id=task9-operation
  operation_phase=completion
  operation_diagnostic="safe diagnostic"
  operation_network_outcomes=none
  operation_retry_command="ab start --apply"
  operation_record_cleanup=forbidden
  operation_explicit_exec="diagnostic-only"
  operation_record_container_name="$cname"
  operation_old_container_id=old-task9
  operation_new_container_id=new-task9
  operation_record_policy_digest=sha256:task9
  operation_image_reference=agentbox:task9
  operation_record_inner_docker_volume="$dvol"
  operation_record_jj_volume="$jvol"
  operation_state_valid=1
  operation_state_publish
}

task9_report_fixture status none not-applicable
_task9_report="$(command_report_emit)"
assert_eq "none status report-only result" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^result=report-only$')"
assert_eq "none status report-only exit" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^exit_status=0$')"
AGENTBOX_REPORT=0
assert_eq "report override suppresses output" "" "$(command_report_emit)"
unset AGENTBOX_REPORT
assert_eq "report is opt-in by default" "" "$(command_report_emit)"
# Human-authorized exception: command_report_emit consumes this sourced environment control.
# shellcheck disable=SC2034
AGENTBOX_REPORT=1
assert_eq "report override forces output" 1 "$(command_report_emit | grep -c '^result=report-only$')"
assert_eq "help documents report opt-in" 1 \
  "$("$REPO/bin/ab" --help | grep -c 'AGENTBOX_REPORT=1')"
assert_eq "README documents report opt-in" 1 \
  "$(grep -c 'AGENTBOX_REPORT=1 ab status' "$REPO/README.md")"
assert_eq "report has operation identity" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^operation_id=task9-operation$')"
assert_eq "report has readiness" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^readiness=not-applicable$')"
assert_eq "report has retry direction" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^retry_command=ab start --apply$')"
assert_eq "report permits ordinary execution" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^execution_allowed=1$')"
assert_eq "report permits mutation" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^mutation_allowed=1$')"
assert_eq "report permits update" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^update_allowed=1$')"
assert_eq "report blocks diagnostics by default" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^diagnostic_allowed=0$')"
assert_eq "report names ordinary exec mode" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^explicit_exec_mode=allowed$')"

task9_report_fixture start complete ready
_task9_report="$(command_report_emit)"
assert_eq "complete start succeeds" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^result=success$')"
assert_eq "complete start names phase" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^phase=completion$')"
assert_eq "complete start preserves cleanup permission" 1 \
  "$(printf '%s\n' "$_task9_report" | grep -c '^cleanup_allowed=1$')"

task9_report_fixture rebuild none not-applicable
operation_record_active=1; operation_status=network-degraded; operation_task_status=degraded-fail
operation_state_publish
_task9_report="$(command_report_emit)"
assert_eq "degraded operation result" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^result=degraded$')"
assert_eq "degraded operation exits one" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^exit_status=1$')"
assert_eq "degraded report blocks ordinary execution" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^execution_allowed=0$')"
assert_eq "degraded report blocks mutation" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^mutation_allowed=0$')"
assert_eq "degraded report blocks updates" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^update_allowed=0$')"
assert_eq "degraded report permits diagnostics" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^diagnostic_allowed=1$')"
assert_eq "degraded report names diagnostic mode" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^explicit_exec_mode=diagnostic-only$')"

task9_report_fixture start in-progress starting
_task9_report="$(command_report_emit)"
assert_eq "in-progress start refuses" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^result=refused$')"
assert_eq "refusal exits two" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^exit_status=2$')"
assert_eq "refusal names operation" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^reason=operation-in-progress$')"

task9_report_fixture status invalid-record not-applicable
_task9_report="$(command_report_emit)"
assert_eq "invalid state result" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^result=invalid-state$')"
assert_eq "invalid state names repair direction" 1 \
  "$(printf '%s\n' "$_task9_report" | grep -c '^reason=invalid-operation-record$')"
assert_eq "invalid state retains safe diagnostic" 1 \
  "$(printf '%s\n' "$_task9_report" | grep -c '^diagnostic=safe diagnostic$')"
assert_eq "invalid state blocks execution" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^execution_allowed=0$')"
assert_eq "invalid state blocks diagnostics" 1 "$(printf '%s\n' "$_task9_report" | grep -c '^diagnostic_allowed=0$')"

policy_operation_mode="$_saved_task9_mode"; policy_operation_status="$_saved_task9_status"
policy_readiness_result="$_saved_task9_readiness"; operation_record_active="$_saved_task9_active"
operation_status="$_saved_task9_operation_status"; operation_task_status="$_saved_task9_task_status"
operation_record_path="$_saved_task9_record_path"; operation_id="$_saved_task9_operation_id"
operation_phase="$_saved_task9_phase"; operation_diagnostic="$_saved_task9_diagnostic"
operation_network_outcomes="$_saved_task9_network"; operation_retry_command="$_saved_task9_retry"
operation_record_cleanup="$_saved_task9_cleanup"; operation_state_valid="$_saved_task9_valid"

_decision_record="$(policy_decision_record)"
assert_eq "decision record has one kind" 1 "$(printf '%s\n' "$_decision_record" | grep -c '^kind=')"
assert_eq "decision record has reason" 1 "$(printf '%s\n' "$_decision_record" | grep -c '^reason_code=')"

echo
echo "Task 10 update coordination and retry identity (bin/ab)"
_saved_task10_update_cache="$AB_UPDATE_CACHE"
_saved_task10_update_lock_fd="$update_lock_fd"
_saved_task10_curl_fn="$(declare -f curl 2>/dev/null || true)"
_task10_update_root="$(mktemp -d)"
_task10_update_trace="$_task10_update_root/refresh.trace"
AB_UPDATE_CACHE="$_task10_update_root/cache/update-check"
curl() {
  printf 'refresh\n' >>"$_task10_update_trace"
  sleep 0.15
  printf '%s\n' '{' '  "tag_name": "v9.9.9",' '}'
}

# Different project invocations share one host cache and lock. The second check must skip the
# courtesy request rather than waiting behind or duplicating the first refresh.
( check_for_update >/dev/null 2>&1 ) & _task10_update_pid_a=$!
( check_for_update >/dev/null 2>&1 ) & _task10_update_pid_b=$!
wait "$_task10_update_pid_a"; wait "$_task10_update_pid_b"
assert_eq "concurrent update checks refresh once" 1 "$(grep -c '^refresh$' "$_task10_update_trace" || true)"
assert_eq "update cache contents are complete" v9.9.9 "$(cat "$AB_UPDATE_CACHE")"
assert_eq "update cache directory is private" 700 "$(stat -c '%a' "$(dirname "$AB_UPDATE_CACHE")")"
assert_eq "update cache file is private" 600 "$(stat -c '%a' "$AB_UPDATE_CACHE")"
assert_eq "update lock file is private" 600 "$(stat -c '%a' "$AB_UPDATE_CACHE.lock")"

# A fresh valid cache avoids the network; malformed fresh text is ignored rather than becoming a
# product failure or an unsafe update notice.
: >"$_task10_update_trace"
check_for_update >/dev/null 2>&1; _task10_update_rc=$?
assert_eq "fresh update cache succeeds" 0 "$_task10_update_rc"
assert_eq "fresh update cache avoids refresh" 0 "$(grep -c '^refresh$' "$_task10_update_trace" || true)"
printf '%s' 'not-a-release' >"$AB_UPDATE_CACHE"; chmod 600 "$AB_UPDATE_CACHE"
touch "$AB_UPDATE_CACHE"
: >"$_task10_update_trace"
check_for_update >/dev/null 2>&1; _task10_update_rc=$?
assert_eq "malformed cached version is harmless" 0 "$_task10_update_rc"
assert_eq "malformed cached version avoids refresh" 0 "$(grep -c '^refresh$' "$_task10_update_trace" || true)"

# A stale/offline response is cached atomically as an empty result and remains a successful
# courtesy check. Unsupported release text is likewise ignored without a false notice.
touch -d '2 hours ago' "$AB_UPDATE_CACHE"
curl() { printf 'offline\n' >>"$_task10_update_trace"; return 22; }
: >"$_task10_update_trace"
check_for_update >/dev/null 2>&1; _task10_update_rc=$?
assert_eq "offline update check succeeds" 0 "$_task10_update_rc"
assert_eq "offline result is atomically cached" "" "$(cat "$AB_UPDATE_CACHE")"
assert_eq "offline cache remains private" 600 "$(stat -c '%a' "$AB_UPDATE_CACHE")"
printf '%s' 'unsupported' >"$AB_UPDATE_CACHE"; chmod 600 "$AB_UPDATE_CACHE"; touch -d '2 hours ago' "$AB_UPDATE_CACHE"
curl() { printf '%s\n' '{' '  "tag_name": "stable"' '}'; }
check_for_update >/dev/null 2>&1; _task10_update_rc=$?
assert_eq "unsupported release text succeeds" 0 "$_task10_update_rc"
assert_eq "unsupported release text is not cached as a version" "" "$(cat "$AB_UPDATE_CACHE")"

# Rate limiting is distinct from a generic offline failure but remains courtesy-only: it must
# return success, leave no unsafe cache value, and emit no false newer-release notice.
touch -d '2 hours ago' "$AB_UPDATE_CACHE"
curl() { printf 'rate-limit\n' >>"$_task10_update_trace"; return 22; }
: >"$_task10_update_trace"
_task10_rate_output="$(check_for_update 2>&1)"; _task10_update_rc=$?
assert_eq "rate-limited update check succeeds" 0 "$_task10_update_rc"
assert_eq "rate-limited response is distinct" 1 "$(grep -c '^rate-limit$' "$_task10_update_trace" || true)"
assert_eq "rate-limited result is empty" "" "$(cat "$AB_UPDATE_CACHE")"
assert_eq "rate-limited result has no notice" 0 \
  "$(printf '%s\n' "$_task10_rate_output" | grep -c 'newer release' || true)"

# A valid newer tag is surfaced as a courtesy notice while the helper still returns success and
# stores the validated tag for the next hourly check.
touch -d '2 hours ago' "$AB_UPDATE_CACHE"
curl() { printf '%s\n' '{' '  "tag_name": "v0.0.12"' '}'; }
_task10_newer_output="$(check_for_update 2>&1)"; _task10_update_rc=$?
assert_eq "newer release check succeeds" 0 "$_task10_update_rc"
assert_eq "newer release is cached" v0.0.12 "$(cat "$AB_UPDATE_CACHE")"
assert_eq "newer release notice is shown" 1 \
  "$(printf '%s\n' "$_task10_newer_output" | grep -c 'newer release is available' || true)"

# Contention is bounded and best-effort: a held host-wide lock suppresses only the courtesy
# request, leaving the product command's exit path unaffected.
_task10_lock_held="$_task10_update_root/lock-held"
(
  exec 9>"$AB_UPDATE_CACHE.lock"
  flock -n 9 || exit 1
  : >"$_task10_lock_held"
  sleep 0.25
) & _task10_lock_pid=$!
_task10_wait=0
while [ ! -e "$_task10_lock_held" ] && [ "$_task10_wait" -lt 50 ]; do
  sleep 0.01
  _task10_wait=$((_task10_wait + 1))
done
_task10_update_rc=0
check_for_update >/dev/null 2>&1 || _task10_update_rc=$?
wait "$_task10_lock_pid"
assert_eq "contended update check succeeds" 0 "$_task10_update_rc"

# Each retry gets a fresh operation id while retaining the logical container and named volumes.
_saved_task10_state="${XDG_STATE_HOME-}"; _saved_task10_lock_identity="$lock_identity"
_saved_task10_project="$PROJECT_DIR"; _saved_task10_machine="$MACHINE"
_saved_task10_cname="$cname"; _saved_task10_dvol="$dvol"; _saved_task10_jvol="$jvol"
_saved_task10_operation_requested="$policy_operation_requested"
_task10_state="$(mktemp -d)"; XDG_STATE_HOME="$_task10_state"
PROJECT_DIR=/work/task10-retry; MACHINE=task10; cname=agentbox-task10; dvol=task10-docker; jvol=task10-jj
lock_identity="$(policy_lock_identity)"; policy_operation_requested=1; policy_operation_mode=start
operation_record_sequence=0; operation_record_active=0
operation_record_begin; _task10_first_id="$operation_id"
operation_record_begin; _task10_second_id="$operation_id"
assert_eq "retry operation id is fresh" 1 "$([ "$_task10_first_id" != "$_task10_second_id" ] && echo 1 || echo 0)"
assert_eq "retry preserves container identity" agentbox-task10 "$(sed -n 's/^container_name = "\(.*\)"$/\1/p' "$operation_record_path")"
assert_eq "retry preserves inner volume" task10-docker "$(sed -n 's/^inner_docker_volume = "\(.*\)"$/\1/p' "$operation_record_path")"
assert_eq "retry preserves jj volume" task10-jj "$(sed -n 's/^jj_volume = "\(.*\)"$/\1/p' "$operation_record_path")"

# Every policy-sensitive entry point must stop before record loading when the shared per-project
# lock cannot be acquired; status/logs/stop do not have a later preflight to catch this.
_saved_task10_lock_fn="$(declare -f policy_lock_acquire)"
_saved_task10_record_load_fn="$(declare -f operation_record_load)"
_task10_record_load_calls=0
policy_lock_acquire() { return 1; }
operation_record_load() { _task10_record_load_calls=$((_task10_record_load_calls + 1)); return 0; }
policy_operation_begin >/dev/null 2>&1; _task10_lock_rc=$?
assert_eq "lock failure stops operation begin" 1 "$_task10_lock_rc"
assert_eq "lock failure avoids unlocked record load" 0 "$_task10_record_load_calls"
unset -f policy_lock_acquire operation_record_load
eval "$_saved_task10_lock_fn"; eval "$_saved_task10_record_load_fn"
rm -rf "$_task10_state"
PROJECT_DIR="$_saved_task10_project"; MACHINE="$_saved_task10_machine"
cname="$_saved_task10_cname"; dvol="$_saved_task10_dvol"; jvol="$_saved_task10_jvol"
lock_identity="$_saved_task10_lock_identity"; policy_operation_requested="$_saved_task10_operation_requested"
if [ -n "$_saved_task10_state" ]; then XDG_STATE_HOME="$_saved_task10_state"; else unset XDG_STATE_HOME; fi

unset -f curl
[ -n "$_saved_task10_curl_fn" ] && eval "$_saved_task10_curl_fn"
AB_UPDATE_CACHE="$_saved_task10_update_cache"; update_lock_fd="$_saved_task10_update_lock_fd"
rm -rf "$_task10_update_root"

echo
echo "Task 10 public update and project-lock evidence (bin/ab)"
_saved_task10_cfg_root="$AB_CFG_ROOT"; _saved_task10_home="$HOME"
_saved_task10_project="$PROJECT_DIR"; _saved_task10_machine="$MACHINE"
_saved_task10_cname="$cname"; _saved_task10_dvol="$dvol"; _saved_task10_jvol="$jvol"
_saved_task10_begin_fn="$(declare -f policy_operation_begin)"
_saved_task10_preflight_fn="$(declare -f policy_preflight)"
_saved_task10_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task10_start_fn="$(declare -f cmd_start)"
_saved_task10_exists_fn="$(declare -f exists)"
_saved_task10_running_fn="$(declare -f is_running)"
_saved_task10_docker_fn="$(declare -f docker)"
_saved_task10_update_fn="$(declare -f check_for_update)"
_task10_public_root="$(mktemp -d)"
_task10_public_trace="$_task10_public_root/public.trace"
AB_CFG_ROOT="$_task10_public_root/config"; HOME="$_task10_public_root/home"
PROJECT_DIR="$_task10_public_root/project"; MACHINE=task10-public
mkdir -p "$AB_CFG_ROOT" "$HOME" "$PROJECT_DIR"
: >"$_task10_public_trace"
policy_operation_begin() {
  policy_operation_requested=1; policy_operation_status=none
  policy_readiness_result=not-applicable; operation_state_reset
  operation_state_update_allowed=1; operation_state_valid=1
  return 0
}
exists() { return 1; }
is_running() { return 1; }
docker() { printf 'docker\n' >>"$_task10_public_trace"; return 1; }
check_for_update() { printf 'update\n' >>"$_task10_public_trace"; return 0; }

# Both update controls are public policy inputs: the TOML control and the host environment
# override must suppress the request after normal command dispatch has resolved policy.
printf '%s\n' '[updates]' 'check = false' >"$AB_CFG_ROOT/agentbox.toml"
policy_input_reset
_task10_public_output="$( ( main status ) 2>&1 )"; _task10_public_rc=$?
assert_eq "updates.check=false keeps status successful" 0 "$_task10_public_rc"
assert_eq "updates.check=false suppresses request" 0 "$(grep -c '^update$' "$_task10_public_trace" || true)"
printf '%s\n' '[updates]' 'check = true' >"$AB_CFG_ROOT/agentbox.toml"
AGENTBOX_NO_UPDATE_CHECK=1; export AGENTBOX_NO_UPDATE_CHECK
policy_input_reset; : >"$_task10_public_trace"
_task10_public_output="$( ( main status ) 2>&1 )"; _task10_public_rc=$?
assert_eq "AGENTBOX_NO_UPDATE_CHECK keeps status successful" 0 "$_task10_public_rc"
assert_eq "AGENTBOX_NO_UPDATE_CHECK suppresses request" 0 "$(grep -c '^update$' "$_task10_public_trace" || true)"
unset AGENTBOX_NO_UPDATE_CHECK

# An update failure is courtesy-only: a public start still returns success and performs its one
# mocked mutation. This proves the update result cannot change product status or mutation.
policy_preflight() {
  # Human-authorized exception: command dispatch consumes this sourced policy global.
  # shellcheck disable=SC2034
  policy_updates_check=1; policy_decision_update_allowed=1
  policy_decision_kind=start-in-place; policy_decision_reason_code=policy-matches-recorded
  policy_decision_mutation_allowed=1; policy_decision_execution_allowed=1
  policy_decision_explicit_exec_mode=allowed; policy_operation_status=none
  operation_state_reset; operation_state_update_allowed=1; operation_state_valid=1
  return 0
}
policy_resolution_recheck() { return 0; }
check_for_update() { printf 'update-failed\n' >>"$_task10_public_trace"; return 37; }
cmd_start() { printf 'mutation\n' >>"$_task10_public_trace"; return 0; }
policy_input_reset; : >"$_task10_public_trace"
_task10_public_output="$( ( main start ) 2>&1 )"; _task10_public_rc=$?
assert_eq "update failure leaves public start successful" 0 "$_task10_public_rc"
assert_eq "update failure does not skip mutation" 1 "$(grep -c '^mutation$' "$_task10_public_trace" || true)"
assert_eq "update failure is observed once" 1 "$(grep -c '^update-failed$' "$_task10_public_trace" || true)"

# The host cache is independent of project identity, and atomic mv replacement keeps concurrent
# readers from seeing a partial version while another writer refreshes the same cache.
unset -f check_for_update
eval "$_saved_task10_update_fn"
_saved_task10_update_cache_public="$AB_UPDATE_CACHE"
_task10_cache_root="$_task10_public_root/cache-race"
AB_UPDATE_CACHE="$_task10_cache_root/update-check"
_task10_update_trace_public="$_task10_public_root/update.trace"
: >"$_task10_update_trace_public"
curl() { printf 'refresh\n' >>"$_task10_update_trace_public"; printf '%s\n' '{' '  "tag_name": "v9.9.9"' '}'; }
( PROJECT_DIR="$_task10_public_root/project-a"; check_for_update >/dev/null 2>&1 ) & _task10_update_pid_a=$!
( PROJECT_DIR="$_task10_public_root/project-b"; check_for_update >/dev/null 2>&1 ) & _task10_update_pid_b=$!
wait "$_task10_update_pid_a"; wait "$_task10_update_pid_b"
assert_eq "distinct projects share one refresh" 1 "$(grep -c '^refresh$' "$_task10_update_trace_public" || true)"
update_cache_write v0.0.1
_task10_atomic_bad="$_task10_public_root/atomic.bad"
: >"$_task10_atomic_bad"
(
  _task10_reader_i=0
  while [ "$_task10_reader_i" -lt 300 ]; do
    if [ -f "$AB_UPDATE_CACHE" ]; then
      _task10_reader_value="$(cat "$AB_UPDATE_CACHE")"
      update_release_tag_valid "$_task10_reader_value" || printf 'partial\n' >>"$_task10_atomic_bad"
    fi
    _task10_reader_i=$((_task10_reader_i + 1))
  done
) & _task10_reader_pid=$!
(
  _task10_writer_i=1
  while [ "$_task10_writer_i" -le 80 ]; do
    if update_lock_try_acquire; then
      update_cache_write "v0.0.$_task10_writer_i"
      update_lock_release
    fi
    _task10_writer_i=$((_task10_writer_i + 1))
  done
) & _task10_writer_pid=$!
wait "$_task10_reader_pid"; wait "$_task10_writer_pid"
assert_eq "atomic cache readers see no partial content" 0 "$(grep -c '^partial$' "$_task10_atomic_bad" 2>/dev/null || true)"
AB_UPDATE_CACHE="$_saved_task10_update_cache_public"
unset -f curl
[ -n "$_saved_task10_curl_fn" ] && eval "$_saved_task10_curl_fn"

unset -f policy_operation_begin policy_preflight policy_resolution_recheck cmd_start exists is_running docker check_for_update
eval "$_saved_task10_begin_fn"; eval "$_saved_task10_preflight_fn"
eval "$_saved_task10_recheck_fn"; eval "$_saved_task10_start_fn"
eval "$_saved_task10_exists_fn"; eval "$_saved_task10_running_fn"
eval "$_saved_task10_docker_fn"; eval "$_saved_task10_update_fn"
rm -rf "$_task10_public_root"
AB_CFG_ROOT="$_saved_task10_cfg_root"; HOME="$_saved_task10_home"
PROJECT_DIR="$_saved_task10_project"; MACHINE="$_saved_task10_machine"
cname="$_saved_task10_cname"; dvol="$_saved_task10_dvol"; jvol="$_saved_task10_jvol"

echo
echo "Task 10 public project-lock contention (bin/ab)"
_saved_task10_lock2_home="$HOME"; _saved_task10_lock2_runtime="${XDG_RUNTIME_DIR-}"
_saved_task10_lock2_project="$PROJECT_DIR"; _saved_task10_lock2_machine="$MACHINE"
_saved_task10_lock2_cname="$cname"; _saved_task10_lock2_dvol="$dvol"; _saved_task10_lock2_jvol="$jvol"
_saved_task10_lock2_cfg_root="$AB_CFG_ROOT"
_saved_task10_lock2_timeout="$lock_timeout_seconds"; _saved_task10_lock2_fd="$agentbox_lock_fd"
_saved_task10_lock2_identity="$lock_identity"; _saved_task10_lock2_path="$lock_path"
_saved_task10_lock2_result="$lock_result"
_saved_task10_lock2_docker_fn="$(declare -f docker)"
_saved_task10_lock2_load_fn="$(declare -f operation_record_load)"
_task10_lock2_root="$(mktemp -d)"; HOME="$_task10_lock2_root/home"
XDG_RUNTIME_DIR="$_task10_lock2_root/runtime"; AB_CFG_ROOT="$_task10_lock2_root/config"
PROJECT_DIR="$_task10_lock2_root/project"; MACHINE=task10-lock; cname=agentbox-task10-lock
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$AB_CFG_ROOT" "$PROJECT_DIR"
lock_identity="$(policy_lock_identity)"
lock_path="$XDG_RUNTIME_DIR/agentbox/locks/$lock_identity.lock"
mkdir -p "$(dirname "$lock_path")"; : >"$lock_path"; chmod 600 "$lock_path"
_task10_lock2_held="$_task10_lock2_root/held"; _task10_lock2_trace="$_task10_lock2_root/trace"
: >"$_task10_lock2_trace"
(
  exec 9>"$lock_path"
  flock -n 9 || exit 1
  : >"$_task10_lock2_held"
  sleep 0.5
) & _task10_lock2_pid=$!
_task10_lock2_wait=0
while [ ! -e "$_task10_lock2_held" ] && [ "$_task10_lock2_wait" -lt 50 ]; do
  sleep 0.01
  _task10_lock2_wait=$((_task10_lock2_wait + 1))
done
lock_timeout_seconds=0; agentbox_lock_fd=""
docker() { printf 'docker\n' >>"$_task10_lock2_trace"; return 1; }
operation_record_load() { printf 'record-load\n' >>"$_task10_lock2_trace"; return 0; }
for _task10_lock2_command in start config rebuild exec; do
  case "$_task10_lock2_command" in
    exec) _task10_lock2_output="$( ( main exec -- true ) 2>&1 )"; _task10_lock2_rc=$? ;;
    *) _task10_lock2_output="$( ( main "$_task10_lock2_command" ) 2>&1 )"; _task10_lock2_rc=$? ;;
  esac
  assert_eq "busy lock refuses public $_task10_lock2_command" 1 "$_task10_lock2_rc"
  assert_eq "busy lock is diagnosed for $_task10_lock2_command" 1 \
    "$(printf '%s\n' "$_task10_lock2_output" | grep -c 'project busy')"
done
wait "$_task10_lock2_pid"
assert_eq "busy public commands avoid unlocked record load" 0 "$(grep -c '^record-load$' "$_task10_lock2_trace" || true)"
assert_eq "busy public commands avoid Docker" 0 "$(grep -c '^docker$' "$_task10_lock2_trace" || true)"
unset -f docker operation_record_load
eval "$_saved_task10_lock2_docker_fn"; eval "$_saved_task10_lock2_load_fn"

# An explicit exec child path inherits the already-acquired project lock. The public dispatch
# reaches Docker once without reacquiring the lock inside the child operation.
_saved_task10_reentrant_begin_fn="$(declare -f policy_operation_begin)"
_saved_task10_reentrant_preflight_fn="$(declare -f policy_preflight)"
_saved_task10_reentrant_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task10_reentrant_lock_fn="$(declare -f policy_lock_acquire)"
_saved_task10_reentrant_jj_fn="$(declare -f require_jj_state_mount)"
_saved_task10_reentrant_wait_fn="$(declare -f wait_jj_state)"
_saved_task10_reentrant_running_fn="$(declare -f is_running)"
_saved_task10_reentrant_docker_fn="$(declare -f docker)"
_saved_task10_reentrant_update_fn="$(declare -f check_for_update)"
_task10_reentrant_trace="$_task10_lock2_root/reentrant.trace"
policy_lock_acquire() { printf 'lock\n' >>"$_task10_reentrant_trace"; return 0; }
policy_operation_begin() {
  policy_operation_requested=1; policy_operation_status=none
  policy_readiness_result=not-applicable; operation_state_reset
  operation_state_update_allowed=1; policy_lock_acquire
}
policy_preflight() {
  policy_decision_kind=start-in-place; policy_decision_reason_code=policy-matches-recorded
  policy_decision_execution_allowed=1; policy_decision_update_allowed=1
  policy_decision_explicit_exec_mode=allowed; policy_decision_mutation_allowed=0
  return 0
}
policy_resolution_recheck() { return 0; }
require_jj_state_mount() { return 0; }
wait_jj_state() { return 0; }
is_running() { return 0; }
docker() { printf 'docker-exec\n' >>"$_task10_reentrant_trace"; return 0; }
check_for_update() { return 0; }
policy_input_reset
_task10_reentrant_output="$( ( main exec -- true ) 2>&1 )"; _task10_reentrant_rc=$?
assert_eq "public exec reentrant path succeeds" 0 "$_task10_reentrant_rc"
assert_eq "public exec acquires project lock once" 1 "$(grep -c '^lock$' "$_task10_reentrant_trace" || true)"
assert_eq "public exec invokes child once" 1 "$(grep -c '^docker-exec$' "$_task10_reentrant_trace" || true)"
unset -f policy_operation_begin policy_preflight policy_resolution_recheck policy_lock_acquire
unset -f require_jj_state_mount wait_jj_state is_running docker check_for_update
eval "$_saved_task10_reentrant_begin_fn"; eval "$_saved_task10_reentrant_preflight_fn"
eval "$_saved_task10_reentrant_recheck_fn"; eval "$_saved_task10_reentrant_lock_fn"
eval "$_saved_task10_reentrant_jj_fn"; eval "$_saved_task10_reentrant_wait_fn"; eval "$_saved_task10_reentrant_running_fn"
eval "$_saved_task10_reentrant_docker_fn"; eval "$_saved_task10_reentrant_update_fn"
rm -rf "$_task10_lock2_root"
HOME="$_saved_task10_lock2_home"; if [ -n "$_saved_task10_lock2_runtime" ]; then XDG_RUNTIME_DIR="$_saved_task10_lock2_runtime"; else unset XDG_RUNTIME_DIR; fi
AB_CFG_ROOT="$_saved_task10_lock2_cfg_root"; PROJECT_DIR="$_saved_task10_lock2_project"
MACHINE="$_saved_task10_lock2_machine"; cname="$_saved_task10_lock2_cname"
dvol="$_saved_task10_lock2_dvol"; jvol="$_saved_task10_lock2_jvol"
lock_timeout_seconds="$_saved_task10_lock2_timeout"; agentbox_lock_fd="$_saved_task10_lock2_fd"
lock_identity="$_saved_task10_lock2_identity"; lock_path="$_saved_task10_lock2_path"
lock_result="$_saved_task10_lock2_result"

echo
echo "Task 10 public retry recovery (bin/ab)"
_saved_task10_retry_home="$HOME"; _saved_task10_retry_runtime="${XDG_RUNTIME_DIR-}"
_saved_task10_retry_state="${XDG_STATE_HOME-}"; _saved_task10_retry_cfg_root="$AB_CFG_ROOT"
_saved_task10_retry_project="$PROJECT_DIR"; _saved_task10_retry_machine="$MACHINE"
_saved_task10_retry_cname="$cname"; _saved_task10_retry_dvol="$dvol"; _saved_task10_retry_jvol="$jvol"
_saved_task10_retry_preflight_fn="$(declare -f policy_preflight)"
_saved_task10_retry_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_task10_retry_update_fn="$(declare -f check_for_update)"
_saved_task10_retry_start_fn="$(declare -f cmd_start)"
_saved_task10_retry_running_fn="$(declare -f is_running)"
_saved_task10_retry_docker_fn="$(declare -f docker)"
_task10_retry_root="$(mktemp -d)"
HOME="$_task10_retry_root/home"; XDG_RUNTIME_DIR="$_task10_retry_root/runtime"
XDG_STATE_HOME="$_task10_retry_root/state"; AB_CFG_ROOT="$_task10_retry_root/config"
PROJECT_DIR="$_task10_retry_root/project"; MACHINE=task10-retry
cname=agentbox-task10-retry; dvol=task10-docker; jvol=task10-jj
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$AB_CFG_ROOT" "$PROJECT_DIR"
lock_identity="$(policy_lock_identity)"; lock_path=""; agentbox_lock_fd=""
_task10_retry_trace="$_task10_retry_root/retry.trace"
_task10_retry_write_record() {
  local _task10_retry_state="$1"
  policy_operation_requested=1
  # Human-authorized exception: operation_record_begin consumes this sourced global.
  # shellcheck disable=SC2034
  operation_record_sequence=0
  operation_record_begin || return 1
  operation_image_reference=agentbox:task10-existing
  case "$_task10_retry_state" in
    removal-failed)
      operation_phase=removal
      operation_record_terminal removal-failed fail "remove failed" || return 1
      ;;
    network-degraded)
      operation_phase=required-network
      operation_record_terminal network-degraded degraded-fail "network failed" || return 1
      ;;
    readiness-failed)
      operation_phase=nested-readiness
      operation_readiness_result=failed-and-exited
      operation_record_terminal readiness-failed fail "readiness failed" || return 1
      ;;
  esac
}
is_running() { return 0; }
policy_preflight() {
  printf 'inspect\n' >>"$_task10_retry_trace"
  # Human-authorized exception: command dispatch consumes this sourced policy global.
  # shellcheck disable=SC2034
  policy_updates_check=1; policy_decision_update_allowed=1
  policy_decision_kind=reconcile-stopped; policy_decision_reason_code=explicit-apply
  policy_decision_mutation_allowed=1; policy_decision_execution_allowed=1
  policy_decision_explicit_exec_mode=allowed; policy_decision_explicit_apply_required=0
  policy_needs_recreate=1
  return 0
}
policy_resolution_recheck() { return 0; }
check_for_update() { return 0; }
docker() { printf 'docker\n' >>"$_task10_retry_trace"; return 1; }
cmd_start() {
  local _task10_retry_image="$operation_image_reference"
  printf 'mutate\n' >>"$_task10_retry_trace"
  operation_record_begin_if_needed || return 1
  operation_image_reference="$_task10_retry_image"
  printf 'id=%s\nimage=%s\ncontainer=%s\ninner=%s\njj=%s\nretry=%s\n' \
    "$operation_id" "$operation_image_reference" "$operation_record_container_name" \
    "$operation_record_inner_docker_volume" "$operation_record_jj_volume" \
    "$operation_retry_command" >>"$_task10_retry_trace"
  operation_phase=completion; operation_readiness_result=ready
  operation_record_terminal complete pass "" || return 1
  return 0
}

# Every durable terminal failure has the same explicit public recovery path: inspect once while
# holding the project lock, create one fresh record, reuse the prior image/identities, and perform
# one mocked mutation. Docker is traced separately so a policy-only retry cannot hide a duplicate.
for _task10_retry_state in removal-failed network-degraded readiness-failed; do
  : >"$_task10_retry_trace"
  _task10_retry_write_record "$_task10_retry_state"
  assert_eq "$_task10_retry_state records existing image" "image_reference = \"agentbox:task10-existing\"" \
    "$(grep '^image_reference' "$operation_record_path" || true)"
  _task10_retry_old_id="$operation_id"
  _task10_retry_output="$( ( main start --apply ) 2>&1 )"; _task10_retry_rc=$?
  assert_eq "$_task10_retry_state public retry succeeds" 0 "$_task10_retry_rc"
  assert_eq "$_task10_retry_state performs fresh inspection" 1 \
    "$(grep -c '^inspect$' "$_task10_retry_trace" || true)"
  assert_eq "$_task10_retry_state performs one mutation" 1 \
    "$(grep -c '^mutate$' "$_task10_retry_trace" || true)"
  assert_eq "$_task10_retry_state avoids duplicate Docker mutation" 0 \
    "$(grep -c '^docker$' "$_task10_retry_trace" || true)"
  _task10_retry_new_id="$(sed -n 's/^id=//p' "$_task10_retry_trace")"
  assert_eq "$_task10_retry_state gets a fresh operation id" 1 \
    "$([ "$_task10_retry_old_id" != "$_task10_retry_new_id" ] && echo 1 || echo 0)"
  assert_eq "$_task10_retry_state reuses image" 1 \
    "$(grep -c '^image=agentbox:task10-existing$' "$_task10_retry_trace" || true)"
  assert_eq "$_task10_retry_state preserves container" 1 \
    "$(grep -c '^container=agentbox-task10-retry$' "$_task10_retry_trace" || true)"
  assert_eq "$_task10_retry_state preserves inner volume" 1 \
    "$(grep -c '^inner=task10-docker$' "$_task10_retry_trace" || true)"
  assert_eq "$_task10_retry_state preserves jj volume" 1 \
    "$(grep -c '^jj=task10-jj$' "$_task10_retry_trace" || true)"
  assert_eq "$_task10_retry_state uses retry command" 1 \
    "$(grep -c '^retry=ab start --apply$' "$_task10_retry_trace" || true)"
done
unset -f policy_preflight policy_resolution_recheck check_for_update cmd_start is_running docker
eval "$_saved_task10_retry_preflight_fn"; eval "$_saved_task10_retry_recheck_fn"
eval "$_saved_task10_retry_update_fn"; eval "$_saved_task10_retry_start_fn"
eval "$_saved_task10_retry_running_fn"; eval "$_saved_task10_retry_docker_fn"
rm -rf "$_task10_retry_root"
HOME="$_saved_task10_retry_home"
if [ -n "$_saved_task10_retry_runtime" ]; then XDG_RUNTIME_DIR="$_saved_task10_retry_runtime"; else unset XDG_RUNTIME_DIR; fi
if [ -n "$_saved_task10_retry_state" ]; then XDG_STATE_HOME="$_saved_task10_retry_state"; else unset XDG_STATE_HOME; fi
AB_CFG_ROOT="$_saved_task10_retry_cfg_root"; PROJECT_DIR="$_saved_task10_retry_project"
MACHINE="$_saved_task10_retry_machine"; cname="$_saved_task10_retry_cname"
dvol="$_saved_task10_retry_dvol"; jvol="$_saved_task10_retry_jvol"

echo
echo "Task 12 focused regression coverage (bin/ab)"

echo "T12-01 invalid policy input"
# An invalid environment boolean must fail during argument parsing for every launcher family.
# Keep all later boundaries mocked so this row proves the failure happens before resolution,
# update, Docker, image build, network, or container work.
_saved_t12_invalid_begin_fn="$(declare -f policy_operation_begin)"
_saved_t12_invalid_load_fn="$(declare -f policy_load_host)"
_saved_t12_invalid_preflight_fn="$(declare -f policy_preflight)"
_saved_t12_invalid_recheck_fn="$(declare -f policy_resolution_recheck)"
_saved_t12_invalid_update_fn="$(declare -f check_for_update)"
_saved_t12_invalid_docker_fn="$(declare -f docker)"
_saved_t12_invalid_build_fn="$(declare -f build_image)"
_saved_t12_invalid_network_fn="$(declare -f connect_networks)"
_saved_t12_invalid_start_fn="$(declare -f cmd_start)"
_saved_t12_invalid_exec_fn="$(declare -f cmd_exec)"
_saved_t12_invalid_config_fn="$(declare -f cmd_config)"
_saved_t12_invalid_init_fn="$(declare -f cmd_config_init)"
_task12_invalid_trace="$(mktemp)"
policy_operation_begin() { printf 'operation\n' >>"$_task12_invalid_trace"; return 0; }
policy_load_host() { printf 'policy-load\n' >>"$_task12_invalid_trace"; return 0; }
policy_preflight() { printf 'preflight\n' >>"$_task12_invalid_trace"; return 0; }
policy_resolution_recheck() { printf 'recheck\n' >>"$_task12_invalid_trace"; return 0; }
check_for_update() { printf 'update\n' >>"$_task12_invalid_trace"; return 0; }
docker() { printf 'docker\n' >>"$_task12_invalid_trace"; return 0; }
build_image() { printf 'build\n' >>"$_task12_invalid_trace"; return 0; }
connect_networks() { printf 'network\n' >>"$_task12_invalid_trace"; return 0; }
cmd_start() { printf 'start\n' >>"$_task12_invalid_trace"; return 0; }
cmd_exec() { printf 'exec\n' >>"$_task12_invalid_trace"; return 0; }
cmd_config() { printf 'config\n' >>"$_task12_invalid_trace"; return 0; }
cmd_config_init() { printf 'config-init\n' >>"$_task12_invalid_trace"; return 0; }
export AGENTBOX_GRANT_GH=not-a-boolean
for _task12_invalid_spec in start:start build:build rebuild:rebuild claude:claude codex:codex bash:bash exec:exec; do
  IFS=: read -r _task12_invalid_command _task12_invalid_label <<<"$_task12_invalid_spec"
  : >"$_task12_invalid_trace"
  case "$_task12_invalid_command" in
    start|build|rebuild)
      _task12_invalid_output="$( ( main "$_task12_invalid_command" ) 2>&1 )"; _task12_invalid_rc=$?
      ;;
    exec)
      _task12_invalid_output="$( ( main exec -- true ) 2>&1 )"; _task12_invalid_rc=$?
      ;;
    *)
      _task12_invalid_output="$( ( main "$_task12_invalid_command" --test ) 2>&1 )"; _task12_invalid_rc=$?
      ;;
  esac
  assert_eq "invalid policy $_task12_invalid_label exits before resolution" 2 "$_task12_invalid_rc"
  assert_eq "invalid policy $_task12_invalid_label reports invalid input" 1 \
    "$(printf '%s\n' "$_task12_invalid_output" | grep -c '^reason=invalid-input$' || true)"
  assert_eq "invalid policy $_task12_invalid_label has no side effects" 0 \
    "$(grep -Ec '^(operation|policy-load|preflight|recheck|update|docker|build|network|start|exec|config|config-init)$' "$_task12_invalid_trace" || true)"
done
unset AGENTBOX_GRANT_GH
unset -f policy_operation_begin policy_load_host policy_preflight policy_resolution_recheck
unset -f check_for_update docker build_image connect_networks cmd_start cmd_exec cmd_config cmd_config_init
eval "$_saved_t12_invalid_begin_fn"; eval "$_saved_t12_invalid_load_fn"
eval "$_saved_t12_invalid_preflight_fn"; eval "$_saved_t12_invalid_recheck_fn"
eval "$_saved_t12_invalid_update_fn"; eval "$_saved_t12_invalid_docker_fn"
eval "$_saved_t12_invalid_build_fn"; eval "$_saved_t12_invalid_network_fn"
eval "$_saved_t12_invalid_start_fn"; eval "$_saved_t12_invalid_exec_fn"
eval "$_saved_t12_invalid_config_fn"; eval "$_saved_t12_invalid_init_fn"
rm -f "$_task12_invalid_trace"

echo "T12-02 mount snapshot race"
# A source change after policy snapshot must refuse before custom mounts are appended. Run this
# for both Git policy states and separately exercise the protected-destination and credential
# source guards; all cases retain the pre-race mount array.
_saved_t12_mount_home="$HOME"; _saved_t12_mount_cfg="$cfg_mounts"
_saved_t12_mounts_decl="$(declare -p mounts)"
_saved_t12_mount_git="$policy_git_enabled"; _saved_t12_mount_gh="$policy_grant_gh"
_saved_t12_mount_ssh="$policy_grant_all_of_dot_ssh"; _saved_t12_mount_blocker="$GIT_BLOCKER"
_task12_mount_root="$(mktemp -d)"; HOME="$_task12_mount_root/home"
mkdir -p "$HOME/.config/git" "$HOME/.ssh"
printf '[user]\n\tname = Task Twelve\n' >"$HOME/.gitconfig"
printf '#!/usr/bin/env bash\nexit 1\n' >"$_task12_mount_root/git-blocker"
chmod 755 "$_task12_mount_root/git-blocker"
GIT_BLOCKER="$_task12_mount_root/git-blocker"
_task12_mount_source_a="$_task12_mount_root/source-a"
_task12_mount_source_b="$_task12_mount_root/source-b"
printf 'a\n' >"$_task12_mount_source_a"; printf 'b\n' >"$_task12_mount_source_b"
_task12_mount_file="$_task12_mount_root/mounts"
for _task12_mount_git_enabled in 0 1; do
  policy_git_enabled="$_task12_mount_git_enabled"
  policy_grant_gh=0; policy_grant_all_of_dot_ssh=0
  assert_eq "mount race policy $_task12_mount_git_enabled assembles policy mounts" 0 \
    "$(mount_spec_build >/dev/null 2>&1; echo $?)"
  printf '%s\n' "$_task12_mount_source_a /home/agentbox/data rw" >"$_task12_mount_file"
  cfg_mounts="$_task12_mount_file"
  mounts=(-v /sentinel:/workspace)
  custom_mounts_snapshot_take
  printf '%s\n' "$_task12_mount_source_b /home/agentbox/data rw" >"$_task12_mount_file"
  _task12_mounts_before="${mounts[*]}"
  build_user_mounts >/dev/null 2>&1; _task12_mount_rc=$?
  assert_eq "mount race policy $_task12_mount_git_enabled refuses" 1 "$_task12_mount_rc"
  assert_eq "mount race policy $_task12_mount_git_enabled preserves mounts" \
    "$_task12_mounts_before" "${mounts[*]}"
done
printf '%s\n' "$_task12_mount_source_a /workspace rw" >"$_task12_mount_file"
cfg_mounts="$_task12_mount_file"; mounts=(-v /sentinel:/workspace)
custom_mounts_snapshot_take
_task12_mounts_before="${mounts[*]}"
build_user_mounts >/dev/null 2>&1; _task12_mount_rc=$?
assert_eq "protected mount race refuses" 1 "$_task12_mount_rc"
assert_eq "protected mount race preserves mounts" "$_task12_mounts_before" "${mounts[*]}"
mkdir -p "$HOME/.ssh"; printf 'host key\n' >"$HOME/.ssh/known_hosts"; chmod 600 "$HOME/.ssh/known_hosts"
policy_grant_all_of_dot_ssh=1
grant_sources_snapshot
printf 'changed host key\n' >"$HOME/.ssh/known_hosts"
assert_eq "credential source race refuses" 1 "$(grant_sources_recheck >/dev/null 2>&1; echo $?)"
eval "$_saved_t12_mounts_decl"
HOME="$_saved_t12_mount_home"; cfg_mounts="$_saved_t12_mount_cfg"
policy_git_enabled="$_saved_t12_mount_git"; policy_grant_gh="$_saved_t12_mount_gh"
policy_grant_all_of_dot_ssh="$_saved_t12_mount_ssh"; GIT_BLOCKER="$_saved_t12_mount_blocker"
rm -rf "$_task12_mount_root"

echo "T12-03 command-state matrix"
# Keep the public command families explicit while using the shared pure decision function. The
# expected permissions include the retry/apply direction and update eligibility, not just kind.
task12_decision_case() {
  local name="$1" classification="$2" lifecycle="$3" mode="$4" source="${5:-default}"
  local expected_kind="$6" expected_mutation="$7" expected_execution="$8"
  local expected_update="$9" expected_apply="${10}" expected_reason="${11}"
  decision_fixture
  operation_record_active=0; operation_status=""; operation_explicit_exec=allowed
  operation_state_reset
  policy_recorded_classification="$classification"; policy_recorded_status="$classification"
  policy_recorded_lifecycle_state="$lifecycle"; policy_git_source="$source"
  assert_eq "$name source" "$source" "$policy_git_source"
  if [ "$classification" = valid ] || [ "$classification" = legacy ]; then
    policy_recorded_git_enabled=1; policy_recorded_grant_gh=0
    policy_recorded_grant_all_of_dot_ssh=0
    policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
  fi
  policy_decide "$mode"
  assert_eq "$name kind" "$expected_kind" "$policy_decision_kind"
  assert_eq "$name mutation" "$expected_mutation" "$policy_decision_mutation_allowed"
  assert_eq "$name execution" "$expected_execution" "$policy_decision_execution_allowed"
  assert_eq "$name update" "$expected_update" "$policy_decision_update_allowed"
  assert_eq "$name apply" "$expected_apply" "$policy_decision_explicit_apply_required"
  assert_eq "$name reason" "$expected_reason" "$policy_decision_reason_code"
}
task12_decision_case "absent start" absent absent start default create 1 1 1 0 container-absent
task12_decision_case "absent convenience" absent absent exec default create 1 1 1 0 container-absent
task12_decision_case "absent build" absent absent build default build-recreate 1 0 1 0 explicit-rebuild
task12_decision_case "matching stopped start" valid stopped start default start-in-place 1 1 1 0 policy-matches-recorded
task12_decision_case "matching running exec" valid running exec default start-in-place 0 1 1 0 policy-matches-recorded
task12_decision_case "stale start" stale stopped start default refuse 0 0 0 1 stale-recorded-state
task12_decision_case "stale exec" stale stopped exec default refuse 0 0 0 1 stale-recorded-state
task12_decision_case "stale rebuild" stale stopped rebuild default refuse 0 0 0 1 ambiguous-git-state
task12_decision_case "stale rebuild explicit Git" stale stopped rebuild cli build-recreate 1 0 1 0 explicit-git-reconciliation
task12_decision_case "invalid start" invalid stopped start default refuse 0 0 0 1 invalid-recorded-state
task12_decision_case "legacy stopped start" legacy stopped start default reconcile-stopped 1 1 1 0 legacy-state
task12_decision_case "legacy running convenience" legacy running exec default start-in-place 0 1 1 0 legacy-mounts-match
task12_decision_case "contradictory exec" invalid running exec default refuse 0 0 0 1 invalid-recorded-state

echo "T12-04 recovery permission matrix"
# Project the complete status vocabulary without a live daemon. These rows pin permissions,
# diagnostic identity, retry direction, cleanup, and named-volume retention together.
_saved_t12_operation_status="$policy_operation_status"
_saved_t12_readiness="$policy_readiness_result"
_saved_t12_record_active="$operation_record_active"
_saved_t12_old_id="$operation_old_container_id"
_saved_t12_operation_path="$operation_record_path"
_task12_operation_path="$(mktemp)"; rm -f "$_task12_operation_path"
task12_operation_case() {
  local status="$1" readiness="$2" explicit="$3" expected_exec="$4" expected_mutation="$5"
  local expected_update="$6" expected_diag="$7" expected_cleanup="$8" expected_mode="$9"
  operation_state_reset
  policy_operation_status="$status"; policy_readiness_result="$readiness"
  operation_explicit_exec="$explicit"; operation_record_active=0
  assert_eq "$status explicit mode input" "$explicit" "$operation_explicit_exec"
  operation_record_path="$_task12_operation_path"; operation_old_container_id=t12-old
  operation_record_inner_docker_volume=t12-docker; operation_record_jj_volume=t12-jj
  operation_state_publish
  assert_eq "$status execution" "$expected_exec" "$operation_state_execution_allowed"
  assert_eq "$status mutation" "$expected_mutation" "$operation_state_mutation_allowed"
  assert_eq "$status update" "$expected_update" "$operation_state_update_allowed"
  assert_eq "$status diagnostic" "$expected_diag" "$operation_state_diagnostic_allowed"
  assert_eq "$status cleanup" "$expected_cleanup" "$operation_state_cleanup_allowed"
  assert_eq "$status exec mode" "$expected_mode" "$operation_state_explicit_exec_mode"
  assert_eq "$status retry" "ab start --apply" "$operation_state_retry_command"
  assert_eq "$status volumes" "inner_docker=t12-docker;jj=t12-jj" "$operation_state_named_volumes"
}
task12_operation_case none not-applicable allowed 1 1 1 0 0 allowed
task12_operation_case in-progress starting blocked 0 0 0 0 0 blocked
task12_operation_case removal-failed not-applicable blocked 0 0 0 0 0 blocked
task12_operation_case absent-after-failure not-applicable blocked 0 0 0 0 0 blocked
task12_operation_case network-degraded not-applicable diagnostic-only 0 0 0 1 0 diagnostic-only
task12_operation_case readiness-failed failed-and-exited diagnostic-only 0 0 0 1 0 diagnostic-only
task12_operation_case complete ready allowed 1 1 1 0 1 allowed
task12_operation_case invalid-record not-applicable blocked 0 0 0 0 0 blocked
policy_operation_status="$_saved_t12_operation_status"; policy_readiness_result="$_saved_t12_readiness"
operation_record_active="$_saved_t12_record_active"; operation_old_container_id="$_saved_t12_old_id"
operation_record_path="$_saved_t12_operation_path"; rm -f "$_task12_operation_path"

echo "T12-05 read-only report matrix"
# Report derivation is checked for every public state while Docker/network/update boundaries are
# absent. The existing Task 8 dispatch loop covers command invocation; these rows pin the result
# categories that config/status/logs/stop must expose consistently.
for _task12_report_state in none complete in-progress network-degraded readiness-failed invalid-record; do
  operation_state_reset
  operation_record_active=0; operation_status=""
  policy_operation_status="$_task12_report_state"
  policy_readiness_result=not-applicable
  operation_state_publish
  for _task12_report_command in config status logs stop; do
    policy_operation_mode="$_task12_report_command"
    command_report_derive
    if [ "$_task12_report_state" = invalid-record ]; then
      _task12_expected_result=invalid-state; _task12_expected_rc=2
    elif [ "$_task12_report_command" = stop ]; then
      _task12_expected_result=success; _task12_expected_rc=0
    else
      _task12_expected_result=report-only; _task12_expected_rc=0
    fi
    assert_eq "report $_task12_report_state/$_task12_report_command result" \
      "$_task12_expected_result" "$command_report_result"
    assert_eq "report $_task12_report_state/$_task12_report_command exit" \
      "$_task12_expected_rc" "$command_report_exit_status"
  done
done

echo "T12-07 readiness permission matrix"
# Readiness transitions are consumed by generic exec and by the convenience launchers through the
# same decision layer. Running failures permit diagnostics only; stopped failures remain blocked.
for _task12_readiness in starting replacement-attempted ready failed-but-running failed-and-exited; do
  decision_fixture
  operation_record_active=0; operation_status=""
  operation_state_reset
  policy_recorded_status=valid; policy_recorded_classification=valid
  policy_recorded_lifecycle_state=running; policy_recorded_git_enabled=1
  policy_recorded_grant_gh=0; policy_recorded_grant_all_of_dot_ssh=0
  policy_recorded_digest="sha256:$(policy_digest_for 1 0 0)"
  assert_eq "readiness $_task12_readiness GitHub grant" 0 "$policy_recorded_grant_gh"
  assert_eq "readiness $_task12_readiness SSH grant" 0 "$policy_recorded_grant_all_of_dot_ssh"
  assert_eq "readiness $_task12_readiness digest" \
    "sha256:$(policy_digest_for 1 0 0)" "$policy_recorded_digest"
  policy_readiness_result="$_task12_readiness"
  policy_operation_status=none
  policy_decide exec
  case "$_task12_readiness" in
    starting|replacement-attempted)
      _task12_expected_mode=blocked; _task12_expected_update=0 ;;
    ready)
      _task12_expected_mode=allowed; _task12_expected_update=1 ;;
    *)
      _task12_expected_mode=diagnostic-only; _task12_expected_update=0 ;;
  esac
  assert_eq "readiness $_task12_readiness running mode" "$_task12_expected_mode" \
    "$policy_decision_explicit_exec_mode"
  assert_eq "readiness $_task12_readiness running update" "$_task12_expected_update" \
    "$policy_decision_update_allowed"
  policy_recorded_lifecycle_state=stopped
  policy_decide exec
  case "$_task12_readiness" in
    ready) _task12_expected_mode=allowed ;; *) _task12_expected_mode=blocked ;;
  esac
  assert_eq "readiness $_task12_readiness stopped mode" "$_task12_expected_mode" \
    "$policy_decision_explicit_exec_mode"
done

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS: all %d tests passed\n' "$PASS"
  exit 0
else
  printf 'FAIL: %d failed, %d passed\n' "$FAIL" "$PASS"
  exit 1
fi
