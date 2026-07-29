#!/usr/bin/env bash
# Unit tests for agentbox host-side logic:
#   - bin/ab                :: compute_names, ab_config_candidates, ab_config_file,
#                              ab_config_container_path, ab_parse_mounts_line, ab_mount_dest_owner,
#                              ab_parse_network_line, ab_dockerfile_has_content
#   - agentbox-entrypoint.sh :: ab_parse_port_line, ab_setup_fail, ab_step_fail
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
compute_names "/home/alice/stay"
assert_eq "stay slug"  "home-alice-stay"                                "$slug"
assert_eq "stay cname" "agentbox-home-alice-stay-$(hex16 /home/alice/stay)" "$cname"
assert_eq "stay dvol"  "agentbox-docker-home-alice-stay-$(hex16 /home/alice/stay)" "$dvol"

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
_saved_mounts=("${mounts[@]}")
mounts=(-v "/proj:/workspace" -v "/etc/localtime:/etc/localtime:ro" --mount "type=bind,src=/srv/d,dst=/home/agentbox/d,readonly")
assert_eq "-v dst matched"          "/proj:/workspace"          "$(ab_mount_dest_owner /workspace)"
assert_eq "-v dst with :ro matched" "/etc/localtime:/etc/localtime:ro" "$(ab_mount_dest_owner /etc/localtime)"
assert_eq "--mount dst matched"     "type=bind,src=/srv/d,dst=/home/agentbox/d,readonly" "$(ab_mount_dest_owner /home/agentbox/d)"
assert_eq "unclaimed dst -> empty"  ""                          "$(ab_mount_dest_owner /home/agentbox/other)"
assert_eq "source is not a dst"     ""                          "$(ab_mount_dest_owner /proj)"
mounts=("${_saved_mounts[@]}")

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
