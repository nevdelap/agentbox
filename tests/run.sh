#!/usr/bin/env bash
# Unit tests for agentbox host-side logic:
#   - bin/ab                :: compute_names()  (project dir -> slug/hash/cname/dvol)
#   - agentbox-entrypoint.sh :: ab_parse_port_line()  (ports-file line -> port or nothing)
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
# shellcheck disable=SC1091
source "$REPO/bin/ab"
# shellcheck disable=SC1091
source "$REPO/agentbox-entrypoint.sh"
# shellcheck disable=SC1091
source "$REPO/tests/smoke.sh"   # source-safe: its ab_parse_env_line() is unit-tested below
set +e +u

# Expected hash for a project dir, computed the same way compute_names does (sha256[:16]).
hex16() { printf '%s' "$1" | sha256sum | cut -c1-16; }

echo "compute_names (bin/ab)"

# Exact name for a real project. (This also pins the format against drift.)
compute_names "/home/nevd/stay"
assert_eq "stay slug"  "home-nevd-stay"                                "$slug"
assert_eq "stay cname" "agentbox-home-nevd-stay-$(hex16 /home/nevd/stay)" "$cname"
assert_eq "stay dvol"  "agentbox-docker-home-nevd-stay-$(hex16 /home/nevd/stay)" "$dvol"

# Determinism: same dir twice -> identical names.
compute_names "/workspace"; a="$cname"
compute_names "/workspace"; b="$cname"
assert_eq "deterministic" "$a" "$b"

# The hash disambiguates paths that collapse to the SAME slug: '/' and '-' both fold to '-',
# so /home/nevd/stay and /home-nevd-stay share a slug but MUST get distinct containers.
compute_names "/home/nevd/stay";  sa="$slug"; ca="$cname"
compute_names "/home-nevd-stay";  sb="$slug"; cb="$cname"
assert_eq "same slug collapses"  "$sa" "$sb"
assert_eq "but cname differs"    "different" "$([ "$ca" = "$cb" ] && echo same || echo different)"

# Slug is truncated to 80 chars; the full hash still disambiguates deep/truncated paths.
long="/mnt/$(printf 'a%.0s' {1..200})/proj"
compute_names "$long"
assert_eq "slug truncated to 80" "80" "${#slug}"

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
echo "ab_parse_files_line (bin/ab)"
# ab_parse_files_line leaves a leading ~ literal (copy_files expands it later, differently per
# side), so the expected strings are built from t='~' rather than a literal ~ in quotes.
t='~'
assert_eq "same-path (one token)"   "${t}/.ssh/id_ed25519"$'\t'"${t}/.ssh/id_ed25519" "$(ab_parse_files_line "${t}/.ssh/id_ed25519")"
assert_eq "src + dst (two tokens)"  $'/home/nevd/k\t/home/agentbox/k'          "$(ab_parse_files_line '/home/nevd/k /home/agentbox/k')"
assert_eq "comment dropped"         ""                                         "$(ab_parse_files_line '# a comment')"
assert_eq "blank dropped"           ""                                         "$(ab_parse_files_line '')"
assert_eq "trailing comment"        "${t}/.ssh/k"$'\t'"${t}/.ssh/k"            "$(ab_parse_files_line "${t}/.ssh/k # my mac key")"
assert_eq "extra spaces collapsed"  $'a\tb'                                    "$(ab_parse_files_line '  a   b  ')"

echo
echo "ab_setup_fail (agentbox-entrypoint.sh)"
# A setup.sh failure must surface — to stderr, so `ab logs` shows it — the exit code, the tail
# of the setup log (the actual cause), where to read the full log, and that it auto-retries.
_ab_setup_tmp="$(mktemp)"
printf 'downloading tool...\ncurl: (6) Could not resolve host: github.com\n' >"$_ab_setup_tmp"
SETUP_LOG="$_ab_setup_tmp"
_ab_fail_msg="$(ab_setup_fail 7 2>&1)"
SETUP_LOG=""
rm -f "$_ab_setup_tmp"
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
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS: all %d tests passed\n' "$PASS"
  exit 0
else
  printf 'FAIL: %d failed, %d passed\n' "$FAIL" "$PASS"
  exit 1
fi
